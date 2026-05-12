// UsbSonyCamera.swift
// Sony Alpha PTP session running directly over USB inside the CMIO extension.

import Foundation
import os.log

// MARK: - Sony PTP Constants

private let PTP_CMD_OPENSESSION:           UInt16 = 0x1002
private let PTP_CMD_CLOSESESSION:          UInt16 = 0x1003
private let PTP_CMD_GETDEVICEINFO:         UInt16 = 0x1001
private let PTP_CMD_GETOBJECT:             UInt16 = 0x1009
private let PTP_RSP_OK:                    UInt16 = 0x2001
private let PTP_RSP_DEVICEBUSY:            UInt16 = 0x2019

private let PTP_CMD_SONY_CONNECT:          UInt16 = 0x9201
private let PTP_CMD_SONY_GETPROPERTIES:    UInt16 = 0x9202
private let PTP_CMD_SONY_GETPROPDESC:      UInt16 = 0x9203
private let PTP_CMD_SONY_SETPROPABS:       UInt16 = 0x9205
private let PTP_CMD_SONY_SETPROPSTEP:      UInt16 = 0x9207
private let PTP_CMD_SONY_GETALLPROPDATA:   UInt16 = 0x9209

private let SONY_GETALLPROPS_MAGICNUMBER:  UInt32 = 0xC8
private let SONY_LV_IMAGE_OBJECTID:        UInt32 = 0xFFFFC002

private let PTP_EVENT_SONY_PROPVALCHANGED: UInt16 = 0xC203

// MARK: - UsbSonyCamera

final class UsbSonyCamera: UsbCameraProtocol {

    private let transport: UsbPtpTransport
    private let cameraLog = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "UsbSonyCamera")
    private let queue = DispatchQueue(label: "org.ptpwebcam.sonycamera", qos: .userInteractive)

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
        cameraLog.fault("UsbSonyCamera: init vid=0x\(String(transport.vendorId, radix:16), privacy: .public) pid=0x\(String(transport.productId, radix:16), privacy: .public) name=\(transport.deviceName, privacy: .public)")
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

    // MARK: - Phase 1: Session open + Sony connect sequence

    private func runOpenSessionPhase() {
        Thread.sleep(forTimeInterval: 0.5)
        if closing { return }

        // Drain any stale data the camera may have queued before we send the first command.
        _ = transport.drainBulkIn(timeout: 0.05)

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
                    let (_, rsp2) = try transport.sendPtpCommand(
                        transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1]))
                    code = transport.responseCode(from: rsp2)
                }
                if code == PTP_RSP_OK {
                    opened = true
                    sessionOpen = true
                    cameraLog.fault("UsbSonyCamera: session opened (attempt \(attempt, privacy: .public))")
                    break
                }
            } catch {
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.5) }
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
                cameraLog.fault("UsbSonyCamera: GetDeviceInfo — \(ops.count, privacy: .public) ops")
            }
        }

        // Sony connect sequence: Connect(1) → Connect(2) → GetProperties(0xC8) → Connect(3) → GetAllPropData
        guard supportedOps.contains(PTP_CMD_SONY_CONNECT) else {
            cameraLog.fault("UsbSonyCamera: Sony connect op not supported")
            return
        }

        _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [1]))
        Thread.sleep(forTimeInterval: 0.1)
        _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [2]))
        Thread.sleep(forTimeInterval: 0.1)

        if supportedOps.contains(PTP_CMD_SONY_GETPROPERTIES) {
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_SONY_GETPROPERTIES,
                                       parameters: [SONY_GETALLPROPS_MAGICNUMBER]))
            Thread.sleep(forTimeInterval: 0.1)
        }

        _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [3]))
        Thread.sleep(forTimeInterval: 0.2)

        if supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA) {
            if let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA)),
               transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
                parseSonyAllPropertyDataResponse(data)
            }
        }

        let propCount = discoveredProperties.count
        cameraLog.fault("UsbSonyCamera: discovered \(propCount, privacy: .public) properties")
        if !discoveredProperties.isEmpty {
            onPropertiesDiscovered?(discoveredProperties)
        }
    }

    // MARK: - Phase 2: Live view (GetObject loop — no STARTLIVEVIEW needed for Sony)

    private func runLiveViewPhase() {
        guard sessionOpen && !closing else { return }

        cameraLog.fault("UsbSonyCamera: entering GetObject live view loop")
        let targetInterval: TimeInterval = 1.0 / 30.0
        var frameCount = 0
        var pollCounter = 0

        while !stopLv && !closing {
            autoreleasepool {
                drainPendingSets()
                guard !stopLv && !closing else { return }

                // Poll interrupt-IN for property change events every ~5 frames (~150 ms at 30 fps)
                pollCounter += 1
                if pollCounter % 5 == 0 { pollInterruptEvents() }

                let frameStart = Date()
                do {
                    let cmd = transport.buildCommand(code: PTP_CMD_GETOBJECT, parameters: [SONY_LV_IMAGE_OBJECTID])
                    let (inData, rsp) = try transport.sendPtpCommand(cmd)
                    let code = transport.responseCode(from: rsp)

                    if code == PTP_RSP_DEVICEBUSY {
                        Thread.sleep(forTimeInterval: 0.033)
                        return
                    }

                    if let data = inData, let jpeg = extractJpegFromLiveViewData(data) {
                        frameCount += 1
                        if frameCount == 1 || frameCount == 10 || frameCount % 150 == 0 {
                            cameraLog.fault("UsbSonyCamera: frame #\(frameCount, privacy: .public) \(jpeg.count, privacy: .public)B → CMIO")
                        }
                        onJpegFrame?(jpeg)
                    }
                } catch {
                    if !stopLv && !closing {
                        cameraLog.fault("UsbSonyCamera: GetObject error: \(String(describing: error), privacy: .public) — pausing")
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }

                let elapsed = -frameStart.timeIntervalSinceNow
                let remaining = targetInterval - elapsed
                if remaining > 0.001 { Thread.sleep(forTimeInterval: remaining) }
            }
        }

        cameraLog.fault("UsbSonyCamera: LV loop exited")
    }

    // MARK: - Interrupt event polling (Sony property change notifications)

    private func pollInterruptEvents() {
        while let eventData = transport.readInterruptEvent(timeout: 0.01) {
            guard eventData.count >= 16 else { continue }
            let eventCode = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
            guard eventCode == PTP_EVENT_SONY_PROPVALCHANGED else { continue }
            let propId = UInt32(eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) })
            // Re-fetch via GetAllPropData or GetPropDesc
            if supportedOps.contains(PTP_CMD_SONY_GETPROPDESC) {
                if let (inData, rsp) = try? transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_SONY_GETPROPDESC, parameters: [propId])),
                   transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
                    parseSonyPropDescResponse(data)
                }
            }
        }
    }

    // MARK: - Sony property parsing

    private func parseSonyAllPropertyDataResponse(_ data: Data) {
        guard data.count > 8 else { return }
        let p = PtpPropParser(data.subdata(in: 8 ..< data.count))
        var changed: [UInt32: UsbCameraProperty] = [:]

        while p.remaining > 0 {
            guard let propId16  = p.readU16(),
                  let dataType  = p.readU16(),
                  let flags     = p.readU8(),
                  let readwrite = p.readU8(),
                  let _         = p.readNum(ofType: dataType),  // default value (skip)
                  let current   = p.readNum(ofType: dataType),
                  let formFlag  = p.readU8() else { break }

            let propId      = UInt32(propId16)
            let incremental = (flags & 0x01) == 0
            let isButton    = (flags & 0x80) != 0
            let writable    = readwrite == 1

            var enumValues: [NSNumber]?
            var rangeMin, rangeMax, rangeStep: NSNumber?

            switch formFlag {
            case 0x01:
                rangeMin  = p.readNum(ofType: dataType)
                rangeMax  = p.readNum(ofType: dataType)
                rangeStep = p.readNum(ofType: dataType)
            case 0x02:
                if let count = p.readU16() {
                    var vals: [NSNumber] = []
                    for _ in 0..<count {
                        if let v = p.readNum(ofType: dataType) { vals.append(v) }
                    }
                    enumValues = vals
                }
            default: break
            }

            let prop = UsbCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: current, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
                incremental: incremental, isButton: isButton)
            discoveredProperties[propId] = prop
            changed[propId] = prop
        }

        if !changed.isEmpty {
            onPropertiesDiscovered?(changed)
        }
    }

    // Sony 0x9203 GetPropDesc returns the same extended format as GetAllPropData:
    // propId(2)|dataType(2)|flags(1)|readwrite(1)|default(N)|current(N)|formFlag(1)|[form]
    // (Standard PTP parsePropDesc() omits the flags byte and misaligns everything.)
    private func parseSonyPropDescResponse(_ data: Data) {
        let p = PtpPropParser(data)
        guard let propId16  = p.readU16(),
              let dataType  = p.readU16(),
              let flags     = p.readU8(),
              let readwrite = p.readU8(),
              let _         = p.readNum(ofType: dataType),
              let current   = p.readNum(ofType: dataType),
              let formFlag  = p.readU8() else {
            cameraLog.fault("UsbSonyCamera: parseSonyPropDescResponse — failed to parse header (dataLen=\(data.count, privacy: .public))")
            return
        }

        let propId      = UInt32(propId16)
        let incremental = discoveredProperties[propId]?.incremental ?? ((flags & 0x01) == 0)
        let isButton    = discoveredProperties[propId]?.isButton    ?? ((flags & 0x80) != 0)
        let writable    = readwrite == 1

        var enumValues: [NSNumber]?
        var rangeMin, rangeMax, rangeStep: NSNumber?

        switch formFlag {
        case 0x01:
            rangeMin  = p.readNum(ofType: dataType)
            rangeMax  = p.readNum(ofType: dataType)
            rangeStep = p.readNum(ofType: dataType)
        case 0x02:
            if let count = p.readU16() {
                var vals: [NSNumber] = []
                for _ in 0..<count {
                    if let v = p.readNum(ofType: dataType) { vals.append(v) }
                }
                enumValues = vals
            }
        default: break
        }

        let updated = UsbCameraProperty(
            propertyId: propId, dataType: dataType, writable: writable,
            value: current, enumValues: enumValues,
            rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
            incremental: incremental, isButton: isButton)
        discoveredProperties[propId] = updated
        cameraLog.fault("UsbSonyCamera: parseSonyPropDescResponse 0x\(String(propId, radix:16), privacy: .public) value=\(current, privacy: .public)")
        onPropertiesDiscovered?([propId: updated])
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
        }
    }

    private func setPropertyDirect(propId: UInt32, value: UInt32, dataType: UInt16) {
        let existing = discoveredProperties[propId]
        let hexId = String(propId, radix: 16)
        var usedStep = false

        if existing?.isButton == true {
            var inc = Int16(truncatingIfNeeded: Int32(bitPattern: value))
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [propId])
            _ = try? transport.sendPtpCommand(cmd, outData: Data(bytes: &inc, count: 2))
            cameraLog.fault("UsbSonyCamera: SetPropStep(button) 0x\(hexId, privacy: .public) inc=\(Int(inc), privacy: .public)")
            usedStep = true

        } else if existing?.incremental == true, let enumValues = existing?.enumValues {
            let targetVal = NSNumber(value: value)
            let cur = existing!.value
            if let oldIdx = enumValues.firstIndex(of: cur),
               let newIdx = enumValues.firstIndex(of: targetVal) {
                var step = Int16(newIdx - oldIdx)
                let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [propId])
                _ = try? transport.sendPtpCommand(cmd, outData: Data(bytes: &step, count: 2))
                cameraLog.fault("UsbSonyCamera: SetPropStep 0x\(hexId, privacy: .public) \(cur, privacy: .public)→\(value, privacy: .public) step=\(Int(step), privacy: .public)")
                usedStep = true
            } else {
                cameraLog.fault("UsbSonyCamera: SetPropStep 0x\(hexId, privacy: .public) — enum index not found cur=\(cur, privacy: .public) target=\(value, privacy: .public) enumCount=\(enumValues.count, privacy: .public)")
            }

        } else {
            var outData = Data()
            switch dataType {
            case 1: outData.appendLE(UInt8(bitPattern: Int8(bitPattern: UInt8(value & 0xFF))))
            case 2: outData.appendLE(UInt8(value & 0xFF))
            case 3: outData.appendLE(UInt16(bitPattern: Int16(bitPattern: UInt16(value & 0xFFFF))))
            case 4: outData.appendLE(UInt16(value & 0xFFFF))
            default: outData.appendLE(value)
            }
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPABS, parameters: [propId])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) {
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("UsbSonyCamera: SetPropAbs 0x\(hexId, privacy: .public)=\(value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
            }
        }

        // Wait for camera to apply the change before re-reading.
        if usedStep { Thread.sleep(forTimeInterval: 0.20) }

        // Prefer Sony GetPropDesc (0x9203) for single-property re-read.
        // Fall back to GetAllPropData (0x9209) if GetPropDesc is unsupported or returns an error.
        if supportedOps.contains(PTP_CMD_SONY_GETPROPDESC) {
            do {
                let (inData, rsp) = try transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_SONY_GETPROPDESC, parameters: [propId]))
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("UsbSonyCamera: GetPropDesc 0x\(hexId, privacy: .public) → rsp=0x\(String(code, radix:16), privacy: .public) len=\(inData?.count ?? -1, privacy: .public)")
                if code == PTP_RSP_OK, let data = inData {
                    parseSonyPropDescResponse(data)
                    return
                }
            } catch {
                cameraLog.fault("UsbSonyCamera: GetPropDesc 0x\(hexId, privacy: .public) threw: \(String(describing: error), privacy: .public)")
            }
        } else {
            cameraLog.fault("UsbSonyCamera: GetPropDesc not in supportedOps — trying GetAllPropData")
        }

        // GetAllPropData fallback: refreshes all properties, known-good format.
        if supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA) {
            if let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA)),
               transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
                cameraLog.fault("UsbSonyCamera: GetAllPropData fallback after set 0x\(hexId, privacy: .public) len=\(data.count, privacy: .public)")
                parseSonyAllPropertyDataResponse(data)
            } else {
                cameraLog.fault("UsbSonyCamera: GetAllPropData fallback failed for 0x\(hexId, privacy: .public)")
            }
        }
    }

    // MARK: - Cleanup

    private func runCleanUp() {
        if sessionOpen {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
            sessionOpen = false
            cameraLog.fault("UsbSonyCamera: session closed")
        }
        transport.close()
        cameraLog.fault("UsbSonyCamera: transport closed")
    }
}
