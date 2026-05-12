// UsbCanonCamera.swift
// Canon EOS PTP session running directly over USB inside the CMIO extension.

import Foundation
import os.log

// MARK: - Canon PTP Constants

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

final class UsbCanonCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbCanonCamera")
        // Canon polls GetEvent for property changes; less frequent than Nikon/Sony
        // interrupt-IN poll since each call is a full PTP transaction.
        eventPollInterval = 15
    }

    // MARK: - Vendor connect

    override func performVendorConnect() {
        parseDeviceInfo()  // populates supportedOps

        if supportedOps.contains(PTP_CMD_CANON_SETREMOTEMODE) {
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_SETREMOTEMODE, parameters: [1]))
            cameraLog.fault("SetRemoteMode(1)")
        }
        if supportedOps.contains(PTP_CMD_CANON_SETEVENTMODE) {
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_SETEVENTMODE, parameters: [1]))
            cameraLog.fault("SetEventMode(1)")
        }
    }

    // MARK: - Property discovery

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        // Canon publishes properties via the event queue. Drain it for ~3s.
        for _ in 0..<30 {
            if closing { return [:] }
            Thread.sleep(forTimeInterval: 0.1)
            pollGetEvent()
        }
        return discoveredProperties
    }

    // MARK: - Live view session

    override func startLiveViewSession() -> Bool {
        setPropertyEos(propId: PTP_PROP_CANON_EVF_MODE, value: 1)

        var lvState = CanonLvState.waitingEvfMode
        for _ in 0..<100 {
            if stopLv || closing { return false }
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
            cameraLog.fault("EVF did not become ready — aborting live view")
            return false
        }
        cameraLog.fault("EVF on")
        return true
    }

    override func stopLiveViewSession() {
        setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 0)
    }

    // MARK: - Frame fetch

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_CANON_GETVIEWFINDERDATA, parameters: [0x00100000])
        guard let (inData, _) = try? transport.sendPtpCommand(cmd), let data = inData else { return nil }
        return extractJpegFromLiveViewData(data)
    }

    // MARK: - Event polling

    override func pollEvents() {
        pollGetEvent()
    }

    @discardableResult
    private func pollGetEvent(onPropertyChanged: ((UInt32, UInt32) -> Void)? = nil) -> Bool {
        guard sessionOpen, supportedOps.contains(PTP_CMD_CANON_GETEVENT) else { return false }
        guard let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_GETEVENT)),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else { return false }
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

    override func performPropertySet(_ pending: PendingSet) {
        if pending.propId < 0x9000 {
            sendStandardSetPropVal(propId: pending.propId, value: pending.value, dataType: pending.dataType)
        } else {
            setPropertyEos(propId: pending.propId, value: pending.value)
        }
        if let updated = getDevicePropDesc(pending.propId) {
            discoveredProperties[pending.propId] = updated
            onPropertiesDiscovered?([pending.propId: updated])
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
            cameraLog.fault("setPropertyEos 0x\(String(propId, radix:16), privacy: .public)=\(value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
        }
    }
}
