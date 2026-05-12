// UsbCanonCamera.swift
// Canon EOS PTP session running directly over USB inside the CMIO extension.

import Foundation
import os.log

// MARK: - Canon PTP Constants

private let PTP_CMD_OPENSESSION:              UInt16 = 0x1002
private let PTP_CMD_CLOSESESSION:             UInt16 = 0x1003
private let PTP_CMD_GETDEVICEINFO:            UInt16 = 0x1001
private let PTP_CMD_GETPROPDESC:              UInt16 = 0x1014
private let PTP_CMD_SETPROPVAL:               UInt16 = 0x1016
private let PTP_RSP_OK:                       UInt16 = 0x2001
private let PTP_RSP_DEVICEBUSY:               UInt16 = 0x2019

private let PTP_CMD_CANON_SETPROPVAL_EX:      UInt16 = 0x9110
private let PTP_CMD_CANON_SETREMOTEMODE:      UInt16 = 0x9114
private let PTP_CMD_CANON_SETEVENTMODE:       UInt16 = 0x9115
private let PTP_CMD_CANON_GETEVENT:           UInt16 = 0x9116
private let PTP_CMD_CANON_GETVIEWFINDERDATA:  UInt16 = 0x9153

private let PTP_PROP_CANON_EVF_OUTPUTDEVICE:  UInt32 = 0xD1B0
private let PTP_PROP_CANON_EVF_MODE:          UInt32 = 0xD1B1

private let PTP_EVENT_CANON_PROPVALCHANGED:   UInt32 = 0xC189
private let PTP_EVENT_CANON_AVAILLISTCHANGED: UInt32 = 0xC18A

private enum CanonLvState { case off, waitingEvfMode, waitingOutputDevice, on }

// MARK: - UsbCanonCamera

final class UsbCanonCamera: UsbCameraProtocol {

    private let transport: UsbPtpTransport
    private let cameraLog = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "UsbCanonCamera")
    private let queue = DispatchQueue(label: "org.ptpwebcam.canoncamera", qos: .userInteractive)

    private var stopLv   = false
    private var closing  = false
    private var sessionOpen = false
    private var supportedOps: Set<UInt16> = []

    private var discoveredProperties: [UInt32: UsbCameraProperty] = [:]

    private struct PendingSet { let propId: UInt32; let value: UInt32; let dataType: UInt16 }
    private var pendingSets: [PendingSet] = []
    private let pendingLock = NSLock()

    var onJpegFrame: ((Data) -> Void)?
    var onPropertiesDiscovered: (([UInt32: UsbCameraProperty]) -> Void)?

    init(transport: UsbPtpTransport) {
        self.transport = transport
        cameraLog.fault("UsbCanonCamera: init vid=0x\(String(transport.vendorId, radix:16), privacy: .public) pid=0x\(String(transport.productId, radix:16), privacy: .public) name=\(transport.deviceName, privacy: .public)")
    }

    // MARK: - Lifecycle

    func openSessionAndDiscover() {
        queue.async { [weak self] in self?.runOpenSessionPhase() }
    }

    func startLiveView() {
        guard !closing else { return }
        stopLv = false
        queue.async { [weak self] in self?.runLiveViewPhase() }
    }

    func stopLiveView() {
        stopLv = true
    }

    func close() {
        stopLv  = true
        closing = true
        queue.async { [weak self] in self?.runCleanUp() }
    }

    // MARK: - Phase 1: Session open + property discovery

    private func runOpenSessionPhase() {
        Thread.sleep(forTimeInterval: 0.5)
        if closing { return }

        // OPEN_SESSION
        var opened = false
        for attempt in 1...5 {
            if closing { return }
            do {
                let cmd = transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1])
                let (_, rsp) = try transport.sendPtpCommand(cmd)
                var code = transport.responseCode(from: rsp)
                if code == 0x201E {
                    _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
                    Thread.sleep(forTimeInterval: 0.3)
                    let (_, rsp2) = try transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1]))
                    code = transport.responseCode(from: rsp2)
                }
                if code == PTP_RSP_OK {
                    opened = true
                    sessionOpen = true
                    cameraLog.fault("UsbCanonCamera: session opened (attempt \(attempt, privacy: .public))")
                    break
                }
                cameraLog.fault("UsbCanonCamera: OPEN_SESSION code=0x\(String(code, radix:16), privacy: .public)")
            } catch {
                cameraLog.fault("UsbCanonCamera: OPEN_SESSION attempt \(attempt, privacy: .public): \(String(describing: error), privacy: .public)")
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.5); transport.clearStalls() }
            }
        }
        guard opened else { return }
        if closing { return }

        // GetDeviceInfo — parse supported operations
        if let (inData, rsp) = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_GETDEVICEINFO)),
           transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
            let p = PtpPropParser(data)
            _ = p.readU16(); _ = p.readU32(); _ = p.readU16()
            p.skipPtpString(); _ = p.readU16()
            if let ops = p.readU16Array() {
                supportedOps = Set(ops)
                cameraLog.fault("UsbCanonCamera: GetDeviceInfo — \(ops.count, privacy: .public) ops")
            }
        }

        // SetRemoteMode(1)
        if supportedOps.contains(PTP_CMD_CANON_SETREMOTEMODE) {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CANON_SETREMOTEMODE, parameters: [1]))
            cameraLog.fault("UsbCanonCamera: SetRemoteMode(1)")
        }

        // SetEventMode(1)
        if supportedOps.contains(PTP_CMD_CANON_SETEVENTMODE) {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CANON_SETEVENTMODE, parameters: [1]))
            cameraLog.fault("UsbCanonCamera: SetEventMode(1)")
        }

        // Collect initial property snapshot from GetEvent
        for _ in 0..<30 {
            if closing { return }
            Thread.sleep(forTimeInterval: 0.1)
            pollGetEvent()
        }

        let propCount = discoveredProperties.count
        cameraLog.fault("UsbCanonCamera: discovered \(propCount, privacy: .public) properties")
        if !discoveredProperties.isEmpty {
            onPropertiesDiscovered?(discoveredProperties)
        }
    }

    // MARK: - Phase 2: Live view

    private func runLiveViewPhase() {
        guard sessionOpen && !closing else { return }

        // Enable EVF
        setPropertyEos(propId: PTP_PROP_CANON_EVF_MODE, value: 1)

        var lvState = CanonLvState.waitingEvfMode
        for _ in 0..<100 {
            if stopLv || closing { return }
            Thread.sleep(forTimeInterval: 0.05)
            pollGetEvent { [self] propId, value in
                switch (propId, lvState) {
                case (PTP_PROP_CANON_EVF_MODE, .waitingEvfMode) where value == 1:
                    lvState = .waitingOutputDevice
                    setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 2)
                case (PTP_PROP_CANON_EVF_OUTPUTDEVICE, .waitingOutputDevice) where (value & 0x02) != 0:
                    lvState = .on
                default:
                    break
                }
            }
            if lvState == .on { break }
        }

        if lvState != .on {
            cameraLog.fault("UsbCanonCamera: EVF did not become ready — aborting live view")
            return
        }

        cameraLog.fault("UsbCanonCamera: EVF on — entering GetViewfinderData loop")
        let targetInterval: TimeInterval = 1.0 / 30.0
        var frameCount = 0

        while !stopLv && !closing {
            autoreleasepool {
                drainPendingSets()
                guard !stopLv && !closing else { return }

                frameCount += 1
                if frameCount % 15 == 0 { pollGetEvent() }

                let frameStart = Date()
                let cmd = transport.buildCommand(code: PTP_CMD_CANON_GETVIEWFINDERDATA, parameters: [0x00100000])
                if let (inData, _) = try? transport.sendPtpCommand(cmd), let data = inData {
                    if let jpeg = extractJpegFromLiveViewData(data) {
                        if frameCount == 1 || frameCount == 10 || frameCount % 150 == 0 {
                            cameraLog.fault("UsbCanonCamera: frame #\(frameCount, privacy: .public) \(jpeg.count, privacy: .public)B → CMIO")
                        }
                        onJpegFrame?(jpeg)
                    }
                }

                let elapsed = -frameStart.timeIntervalSinceNow
                let remaining = targetInterval - elapsed
                if remaining > 0.001 { Thread.sleep(forTimeInterval: remaining) }
            }
        }

        cameraLog.fault("UsbCanonCamera: LV loop exited")
        if !closing {
            setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 0)
        }
    }

    // MARK: - GetEvent polling

    @discardableResult
    private func pollGetEvent(onPropertyChanged: ((UInt32, UInt32) -> Void)? = nil) -> Bool {
        guard sessionOpen, supportedOps.contains(PTP_CMD_CANON_GETEVENT) else { return false }
        guard let (inData, rsp) = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CANON_GETEVENT)),
              transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData else { return false }

        parseCanonEventResponse(data, onPropertyChanged: onPropertyChanged)
        return true
    }

    private func parseCanonEventResponse(_ data: Data, onPropertyChanged: ((UInt32, UInt32) -> Void)?) {
        var offset = 0
        while offset + 8 <= data.count {
            let len  = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset,     as: UInt32.self) })
            let type = data.withUnsafeBytes     { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
            guard len >= 8, offset + len <= data.count else { break }
            let blockData = data.subdata(in: (offset + 8) ..< (offset + len))
            parseCanonEventBlock(blockData, type: type, onPropertyChanged: onPropertyChanged)
            offset += len
        }
    }

    private func parseCanonEventBlock(_ blockData: Data, type: UInt32, onPropertyChanged: ((UInt32, UInt32) -> Void)?) {
        switch type {
        case PTP_EVENT_CANON_PROPVALCHANGED:
            guard blockData.count >= 4 else { return }
            let propId = blockData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let valueData = blockData.subdata(in: 4 ..< blockData.count)
            let (value, _) = readEosValue(from: valueData, offset: 0, rawType: eosRawType(forPropId: propId))
            guard let value = value else { return }

            let existing = discoveredProperties[propId]
            let dataType = existing?.dataType ?? UInt16(eosRawType(forPropId: propId))
            let updated = UsbCameraProperty(
                propertyId: propId, dataType: dataType,
                writable: existing?.writable ?? false,
                value: value,
                enumValues: existing?.enumValues,
                rangeMin: existing?.rangeMin,
                rangeMax: existing?.rangeMax,
                rangeStep: existing?.rangeStep)
            discoveredProperties[propId] = updated
            onPropertyChanged?(propId, value.uint32Value)

        case PTP_EVENT_CANON_AVAILLISTCHANGED:
            guard blockData.count >= 8 else { return }
            let propId      = blockData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let rawDataType = blockData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let rawType     = UInt8(rawDataType & 0xFF)
            guard rawType >= 1 && rawType <= 6 else { return }

            if blockData.count > 8 {
                let arrayData = blockData.subdata(in: 8 ..< blockData.count)
                let values = readEosArray(from: arrayData, rawType: rawType)
                let existing = discoveredProperties[propId]
                let updated = UsbCameraProperty(
                    propertyId: propId, dataType: UInt16(rawType),
                    writable: !values.isEmpty,
                    value: existing?.value ?? NSNumber(value: 0),
                    enumValues: values.isEmpty ? nil : values,
                    rangeMin: nil, rangeMax: nil, rangeStep: nil)
                discoveredProperties[propId] = updated
            }

        default:
            break
        }
    }

    // MARK: - EOS data helpers

    private func eosRawType(forPropId propId: UInt32) -> UInt8 {
        discoveredProperties[propId].map { UInt8($0.dataType & 0xFF) } ?? 6  // default UInt32
    }

    private func readEosValue(from data: Data, offset: Int, rawType: UInt8) -> (NSNumber?, Int) {
        guard offset + 4 <= data.count else { return (nil, 0) }
        switch rawType {
        case 1: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int8.self) }),  4)
        case 2: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt8.self) }), 4)
        case 3: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int16.self) }), 4)
        case 4: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }),4)
        case 5: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }), 4)
        case 6: return (NSNumber(value: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }),4)
        default: return (nil, 4)
        }
    }

    private func readEosArray(from data: Data, rawType: UInt8) -> [NSNumber] {
        guard data.count >= 4 else { return [] }
        let count = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        var result: [NSNumber] = []
        var offset = 4
        for _ in 0..<count {
            let (val, bytesRead) = readEosValue(from: data, offset: offset, rawType: rawType)
            if let val = val { result.append(val) }
            offset += max(bytesRead, 4)
            if offset > data.count { break }
        }
        return result
    }

    // MARK: - Property set

    func setProperty(propId: UInt32, value: UInt32, dataType: UInt16) {
        pendingLock.lock()
        pendingSets.append(PendingSet(propId: propId, value: value, dataType: dataType))
        pendingLock.unlock()
        queue.async { [weak self] in self?.drainPendingSets() }
    }

    private func drainPendingSets() {
        pendingLock.lock()
        let cmds = pendingSets; pendingSets.removeAll()
        pendingLock.unlock()

        for cmd in cmds {
            guard sessionOpen else { break }
            setPropertyDirect(propId: cmd.propId, value: cmd.value, dataType: cmd.dataType)
            if let updated = discoverSingleProperty(cmd.propId) {
                discoveredProperties[cmd.propId] = updated
                onPropertiesDiscovered?([cmd.propId: updated])
            }
        }
    }

    private func setPropertyDirect(propId: UInt32, value: UInt32, dataType: UInt16) {
        if propId < 0x9000 {
            // Standard PTP SETPROPVAL
            var outData = Data()
            switch dataType {
            case 1: outData.appendLE(UInt8(bitPattern: Int8(bitPattern: UInt8(value & 0xFF))))
            case 2: outData.appendLE(UInt8(value & 0xFF))
            case 3: outData.appendLE(UInt16(bitPattern: Int16(bitPattern: UInt16(value & 0xFFFF))))
            case 4: outData.appendLE(UInt16(value & 0xFFFF))
            default: outData.appendLE(value)
            }
            let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [propId])
            _ = try? transport.sendPtpCommand(cmd, outData: outData)
        } else {
            setPropertyEos(propId: propId, value: value)
        }
    }

    private func setPropertyEos(propId: UInt32, value: UInt32) {
        var outData = Data()
        outData.appendLE(UInt32(12))  // block: [len:4][propId:4][value:4]
        outData.appendLE(propId)
        outData.appendLE(value)
        let cmd = transport.buildCommand(code: PTP_CMD_CANON_SETPROPVAL_EX)
        if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) {
            let code = transport.responseCode(from: rsp)
            cameraLog.fault("UsbCanonCamera: setPropertyEos 0x\(String(propId, radix:16), privacy: .public)=\(value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
        }
    }

    private func discoverSingleProperty(_ propId: UInt32) -> UsbCameraProperty? {
        guard propId < 0x9000,
              let (inData, rsp) = try? transport.sendPtpCommand(
                  transport.buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [propId])),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else { return nil }
        return PtpPropParser(data).parsePropDesc()
    }

    // MARK: - Cleanup

    private func runCleanUp() {
        if sessionOpen {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
            sessionOpen = false
            cameraLog.fault("UsbCanonCamera: session closed")
        }
        transport.close()
        cameraLog.fault("UsbCanonCamera: transport closed")
    }
}
