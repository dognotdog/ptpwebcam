import Foundation
import ImageCaptureCore
import os.log

// MARK: - Canon PTP Constants

let PTP_CMD_CANON_SETPROPVAL_EX: UInt16 = 0x9110
let PTP_CMD_CANON_SETREMOTEMODE: UInt16 = 0x9114
let PTP_CMD_CANON_SETEVENTMODE: UInt16 = 0x9115
let PTP_CMD_CANON_GETEVENT: UInt16 = 0x9116
let PTP_CMD_CANON_KEEPDEVICEON: UInt16 = 0x911D
let PTP_CMD_CANON_REQUESTPROPVAL: UInt16 = 0x9127
let PTP_CMD_CANON_GETVIEWFINDERDATA: UInt16 = 0x9153
let PTP_CMD_CANON_DOAF: UInt16 = 0x9154
let PTP_CMD_CANON_DRIVELENS: UInt16 = 0x9155
let PTP_CMD_CANON_AF_CANCEL: UInt16 = 0x9160

let PTP_PROP_CANON_APERTURE: UInt32 = 0xD101
let PTP_PROP_CANON_EXPOSURETIME: UInt32 = 0xD102
let PTP_PROP_CANON_ISO: UInt32 = 0xD103
let PTP_PROP_CANON_EXPOSUREBIAS: UInt32 = 0xD104
let PTP_PROP_CANON_AUTOEXPOSURE: UInt32 = 0xD105
let PTP_PROP_CANON_METERINGMODE: UInt32 = 0xD107
let PTP_PROP_CANON_FOCUSMODE: UInt32 = 0xD108
let PTP_PROP_CANON_LV_EYEDETECT: UInt32 = 0xD12C
let PTP_PROP_CANON_EVF_OUTPUTDEVICE: UInt32 = 0xD1B0
let PTP_PROP_CANON_EVF_MODE: UInt32 = 0xD1B1
let PTP_PROP_CANON_EVF_DOF_PREVIEW: UInt32 = 0xD1B2
let PTP_PROP_CANON_EVF_WHITEBALANCE: UInt32 = 0xD1B4
let PTP_PROP_CANON_EVF_COLORTEMP: UInt32 = 0xD1B6
let PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW: UInt32 = 0xD1B7
let PTP_PROP_CANON_FOCUSINFO: UInt32 = 0xD1D3

let PTP_EVENT_CANON_PROPVALCHANGED: UInt32 = 0xC189
let PTP_EVENT_CANON_AVAILLISTCHANGED: UInt32 = 0xC18A

// Canon EOS data type masks
private let PTP_DATATYPE_EOS_MASK: UInt32 = 0x10000
private let PTP_DATATYPE_EOS_ARRAY_MASK: UInt32 = 0x14000

private enum CanonLvStatus { case off, waiting, on }

// MARK: - PtpCameraCanon

class PtpCameraCanon: PtpCamera {

    private var eventPollTimer: DispatchSourceTimer?
    private var lvStatus: CanonLvStatus = .off

    static func registerCameras() {
        // Single source of truth lives in PtpKnownCameras.table.
        register(vendorId: PtpKnownCameras.vidCanon,
                 cameras: PtpKnownCameras.entries(forVendor: PtpKnownCameras.vidCanon),
                 make: "Canon",
                 cameraClass: PtpCameraCanon.self)
    }

    // MARK: - Init

    required init(icCamera: ICCameraDevice, cameraId: String,
                  delegate: PtpCameraDelegate, cameraInfo: PtpCameraInfo) {
        super.init(icCamera: icCamera, cameraId: cameraId, delegate: delegate, cameraInfo: cameraInfo)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.queryCanonEvents()
        }
        timer.resume()
        eventPollTimer = timer
    }

    // MARK: - Cleanup

    override func didRemove(_ device: ICDevice) {
        eventPollTimer?.cancel()
        eventPollTimer = nil
        super.didRemove(device)
    }

    // MARK: - UI Properties

    override var uiProperties: [UInt32] {
        [
            0x5001, // Battery Level
            0x5008, // Focal Length
            0x500E, // Exposure Program
            PTP_PROP_CANON_APERTURE,
            PTP_PROP_CANON_ISO,
            PTP_PROP_CANON_AUTOEXPOSURE,
            PTP_PROP_CANON_EXPOSURETIME,
            PTP_PROP_CANON_EVF_WHITEBALANCE,
            PTP_PROP_CANON_EVF_COLORTEMP,
            PTP_PROP_CANON_EXPOSUREBIAS,
            PTP_PROP_CANON_METERINGMODE,
            PTP_PROP_CANON_LV_EYEDETECT,
            PTP_PROP_CANON_EVF_DOF_PREVIEW,
            PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW,
        ]
    }

    // MARK: - Property Names

    override var propertyNames: [UInt32: String] {
        var names = super.propertyNames
        names.merge([
            PTP_PROP_CANON_EVF_OUTPUTDEVICE: "LiveView Output Device",
            PTP_PROP_CANON_EVF_MODE: "EVF Mode",
            PTP_PROP_CANON_EVF_WHITEBALANCE: "EVF Whitebalance",
            PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW: "Exposure Preview",
            PTP_PROP_CANON_EXPOSUREBIAS: "Exposure Correction",
            PTP_PROP_CANON_METERINGMODE: "Metering Mode",
            PTP_PROP_CANON_FOCUSMODE: "Focus Mode",
            PTP_PROP_CANON_APERTURE: "Aperture",
            PTP_PROP_CANON_EXPOSURETIME: "Shutter Speed",
            PTP_PROP_CANON_ISO: "ISO",
            PTP_PROP_CANON_LV_EYEDETECT: "AF Eye Detection",
        ]) { _, new in new }
        return names
    }

    // MARK: - Property Value Names

    override var propertyValueNames: [UInt32: [UInt32: String]] {
        var names = super.propertyValueNames
        let canonNames: [UInt32: [UInt32: String]] = [
            PTP_PROP_CANON_EVF_OUTPUTDEVICE: [
                0x00000000: "Off", 0x00000001: "TFT",
                0x00000002: "PC", 0x00000003: "TFT+PC",
            ],
            PTP_PROP_CANON_EVF_MODE: [
                0x00000000: "Off", 0x00000001: "On",
            ],
            PTP_PROP_CANON_EVF_WHITEBALANCE: [
                0: "Auto", 1: "Daylight", 2: "Cloudy", 3: "Tungsten",
                4: "Flourescent", 5: "Flash", 6: "Manual", 8: "Shade",
                9: "Color Temp", 10: "Custom 1", 11: "Custom 2", 12: "Custom 3",
                15: "Manual 2", 16: "Manual 3", 18: "Manual 4", 19: "Manual 5",
                20: "Custom 4", 21: "Custom 5",
            ],
        ]
        for (propId, values) in canonNames {
            if let existing = names[propId] {
                names[propId] = existing.merging(values) { _, new in new }
            } else {
                names[propId] = values
            }
        }
        return names
    }

    // MARK: - Value Formatting

    override func formatValue(_ val: Any, forProperty propId: UInt32) -> String {
        guard let n = val as? NSNumber else { return "\(val)" }

        switch propId {
        case PTP_PROP_CANON_APERTURE:
            return formatCanonAperture(n.intValue)
        case PTP_PROP_CANON_ISO:
            return formatCanonISO(n.intValue)
        case PTP_PROP_CANON_EXPOSURETIME:
            return formatCanonShutterSpeed(n.intValue)
        case PTP_PROP_CANON_EXPOSUREBIAS:
            return String(format: "%+.1f", 0.1 * Double(n.int8Value))
        default:
            return super.formatValue(val, forProperty: propId)
        }
    }

    private func formatCanonAperture(_ raw: Int) -> String {
        let ival = raw - 8
        let base = ival / 16
        let frac = ival - base * 16
        let roundedFrac = (10.0 * (1.0 + 0.1 * (10.0 * Double(frac) / 16.0))) / 10.0
        var val = pow(2.0, Double(base)) * roundedFrac

        if frac != 0 {
            let targets = [0.7, 1.0, 1.1, 1.3, 1.4, 1.8, 2.0, 2.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0]
            for i in 0..<10 {
                let decadeLow = pow(10.0, Double(i))
                let decadeHigh = pow(10.0, Double(i + 1))
                if val > decadeLow && val < decadeHigh {
                    let dval = val / decadeLow
                    for k in 1..<(targets.count - 1) {
                        if dval >= targets[k] && dval < targets[k + 1] {
                            val = decadeLow * targets[k]
                            break
                        }
                    }
                    break
                }
            }
        }

        return String(format: "f/%.1f", val)
    }

    private func formatCanonISO(_ raw: Int) -> String {
        let base = raw / 8
        let frac = raw - base * 8
        let roundedFrac = (10.0 * (1.0 + 0.1 * floor(10.0 * Double(frac) / 8.0))) / 10.0
        var val = 100.0 * pow(2.0, Double(base - 9)) * roundedFrac
        var roundedVal = val

        if frac != 0 {
            let targets = [0.8, 1.0, 1.25, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.4, 8.0, 10.0, 12.5]
            for i in 0..<10 {
                let decadeLow = pow(10.0, Double(i))
                let decadeHigh = pow(10.0, Double(i + 1))
                if val > decadeLow && val < decadeHigh {
                    let dval = val / decadeLow
                    for k in 1..<(targets.count - 1) {
                        if abs(dval - targets[k]) < abs(dval - targets[k - 1]) &&
                           abs(dval - targets[k]) < abs(dval - targets[k + 1]) {
                            roundedVal = decadeLow * targets[k]
                            break
                        }
                    }
                    break
                }
            }
        }

        return String(format: "ISO %.0f", roundedVal)
    }

    private func formatCanonShutterSpeed(_ raw: Int) -> String {
        var base = raw / 8
        var frac = raw - base * 8
        base = base - 7

        let over1sec = raw <= 56
        if over1sec {
            base = -base - (frac > 0 ? 1 : 0)
            frac = (8 - frac) % 8
        }

        let val = pow(2.0, Double(base)) * 0.1 * floor(10.0 * (1.0 + Double(frac) / 8.0))

        var targets = [0.8, 1.0, 1.25, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.4, 8.0, 10.0, 12.5]
        var roundedVal = val
        for i in 0..<10 {
            if i < 2 { targets[2] = 1.3; targets[6] = 3.0; targets[9] = 6.0 }
            else { targets[2] = 1.25; targets[6] = 3.2; targets[9] = 6.4 }
            let decadeLow = pow(10.0, Double(i))
            let decadeHigh = pow(10.0, Double(i + 1))
            if val > decadeLow && val < decadeHigh {
                let dval = val / decadeLow
                for k in 1..<(targets.count - 1) {
                    if abs(dval - targets[k]) < abs(dval - targets[k - 1]) &&
                       abs(dval - targets[k]) < abs(dval - targets[k + 1]) {
                        roundedVal = decadeLow * targets[k]
                        break
                    }
                }
                break
            }
        }

        if over1sec {
            return roundedVal < 3.0
                ? String(format: "%.1f s", roundedVal)
                : String(format: "%.0f s", roundedVal)
        } else {
            return roundedVal < 3.0
                ? String(format: "1/%.1f s", roundedVal)
                : String(format: "1/%.0f s", roundedVal)
        }
    }

    // MARK: - Autofocus

    override var canAutofocus: Bool {
        let afOpSupported = isOperationSupported(PTP_CMD_CANON_DOAF)
        if afOpSupported, isPropertySupported(UInt16(PTP_PROP_CANON_FOCUSMODE)),
           let info = properties[PTP_PROP_CANON_FOCUSMODE],
           let val = info.value as? NSNumber {
            return val.intValue != 3
        }
        return afOpSupported
    }

    override func performAutofocus() {
        if isOperationSupported(PTP_CMD_CANON_AF_CANCEL) {
            sendCommand(buildCommand(code: PTP_CMD_CANON_AF_CANCEL))
        }
        if isOperationSupported(PTP_CMD_CANON_DOAF) {
            sendCommand(buildCommand(code: PTP_CMD_CANON_DOAF))
        }
    }

    // MARK: - Device Info

    override func deviceInfoReceived() {
        for propId in supportedProperties {
            queryPropertyDescription(UInt32(propId))
        }

        if isOperationSupported(PTP_CMD_CANON_SETREMOTEMODE) {
            sendCommand(buildCommand(code: PTP_CMD_CANON_SETREMOTEMODE, parameters: [1]))
        } else {
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        }
    }

    // MARK: - Property Query Override

    override func queryPropertyDescription(_ propertyId: UInt32) {
        if propertyId < 0x9000 {
            super.queryPropertyDescription(propertyId)
            return
        }
        if isOperationSupported(PTP_CMD_CANON_REQUESTPROPVAL) {
            sendCommand(buildCommand(code: PTP_CMD_CANON_REQUESTPROPVAL, parameters: [propertyId]))
        }
    }

    // MARK: - Property Set Override

    override func setProperty(_ propertyId: UInt32, value: NSNumber) {
        if propertyId < 0x9000 {
            super.setProperty(propertyId, value: value)
            return
        }
        guard let info = properties[propertyId] else { return }
        let valueData = encodeEosValue(value, dataType: info.dataType)
        var blockData = Data(capacity: 8 + valueData.count)
        var len = UInt32(8 + valueData.count)
        var propId = propertyId
        blockData.append(Data(bytes: &len, count: 4))
        blockData.append(Data(bytes: &propId, count: 4))
        blockData.append(valueData)
        sendCommand(buildCommand(code: PTP_CMD_CANON_SETPROPVAL_EX), data: blockData)
    }

    // MARK: - Live View

    override func startLiveView() {
        lvStatus = .waiting
        setProperty(PTP_PROP_CANON_EVF_MODE, value: NSNumber(value: 1))
    }

    override func stopLiveView() {
        lvStatus = .off
        super.stopLiveView()
    }

    override func requestLiveViewImage() {
        if shouldRequestNewLiveViewImage() {
            sendCommand(buildCommand(code: PTP_CMD_CANON_GETVIEWFINDERDATA, parameters: [0x00100000]))
        }
    }

    override func receivedProperty(_ propertyId: UInt32) {
        switch propertyId {
        case PTP_PROP_CANON_EVF_MODE:
            if lvStatus == .waiting,
               let info = properties[PTP_PROP_CANON_EVF_MODE],
               let val = info.value as? NSNumber, val.intValue == 1 {
                setProperty(PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: NSNumber(value: 2))
            }
        case PTP_PROP_CANON_EVF_OUTPUTDEVICE:
            if let info = properties[PTP_PROP_CANON_EVF_OUTPUTDEVICE],
               let val = info.value as? NSNumber,
               (val.uint32Value & 0x02) != 0,
               lvStatus == .waiting {
                lvStatus = .on
                cameraDidBecomeReadyForLiveViewStreaming()
            }
        default:
            break
        }
    }

    // MARK: - Canon Event Polling

    private func queryCanonEvents() {
        if isSessionOpen {
            sendCommand(buildCommand(code: PTP_CMD_CANON_GETEVENT))
        }
    }

    // MARK: - Command Handling

    override func handleCommand(_ code: UInt16, data: Data?, response: Data, fullCommand: Data) {
        switch code {
        case PTP_CMD_CANON_SETREMOTEMODE:
            if isOperationSupported(PTP_CMD_CANON_SETEVENTMODE) {
                sendCommand(buildCommand(code: PTP_CMD_CANON_SETEVENTMODE, parameters: [1]))
            } else {
                DispatchQueue.main.async { self.delegate?.cameraReady(self) }
            }
        case PTP_CMD_CANON_SETEVENTMODE:
            let propertiesToQuery: [UInt32] = [
                PTP_PROP_CANON_EVF_OUTPUTDEVICE,
                PTP_PROP_CANON_EVF_MODE,
            ] + uiProperties
            for propId in propertiesToQuery {
                queryPropertyDescription(propId)
            }
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        case PTP_CMD_CANON_GETEVENT:
            if let data = data { parseCanonEventResponse(data) }
        case PTP_CMD_CANON_SETPROPVAL_EX:
            let respCode = response.count >= 8
                ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
                : UInt16(0)
            if let data = data, (respCode == PTP_RSP_OK || respCode == PTP_RSP_DEVICEBUSY), data.count >= 8 {
                let propId = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                let valueData = data.subdata(in: 8..<data.count)
                canonPropertyChanged(propId, data: valueData)
            }
        case PTP_CMD_CANON_GETVIEWFINDERDATA:
            liveViewImageReceived()
            if let data = data {
                let rspCode = response.count >= 8 ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) } : UInt16(PTP_RSP_OK)
                if rspCode == PTP_RSP_OK || rspCode == PTP_RSP_DEVICEBUSY {
                    if let jpegData = extractLiveViewJpegData(data) {
                        delegate?.cameraReceivedLiveViewJpeg(jpegData, camera: self)
                    }
                }
            }
        case PTP_CMD_CANON_REQUESTPROPVAL, PTP_CMD_CANON_DOAF, PTP_CMD_CANON_AF_CANCEL:
            break
        default:
            super.handleCommand(code, data: data, response: response, fullCommand: fullCommand)
        }
    }

    // MARK: - Canon Event Parsing

    private func parseCanonEventResponse(_ data: Data) {
        var offset = 0
        while offset + 8 <= data.count {
            let len = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) })
            let type = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
            guard len >= 8, offset + len <= data.count else { break }
            let blockData = data.subdata(in: (offset + 8)..<(offset + len))
            if !blockData.isEmpty {
                parseCanonEventBlock(blockData, type: type)
            }
            offset += len
        }
    }

    private func parseCanonEventBlock(_ blockData: Data, type: UInt32) {
        switch type {
        case PTP_EVENT_CANON_PROPVALCHANGED:
            guard blockData.count >= 4 else { return }
            let propertyId = blockData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let valueData = blockData.subdata(in: 4..<blockData.count)
            canonPropertyChanged(propertyId, data: valueData)
        case PTP_EVENT_CANON_AVAILLISTCHANGED:
            guard blockData.count >= 8 else { return }
            let propertyId = blockData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let rawDataType = blockData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let eosDataType = PTP_DATATYPE_EOS_MASK + rawDataType
            let arrayDataType = (rawDataType <= 7) ? PTP_DATATYPE_EOS_ARRAY_MASK + rawDataType : UInt32(0)
            if blockData.count > 8, arrayDataType != 0 {
                let arrayData = blockData.subdata(in: 8..<blockData.count)
                let values = readEosArray(from: arrayData, elementType: eosDataType)

                var info = properties[propertyId] ?? PtpPropertyInfo(
                    propertyId: propertyId, dataType: eosDataType, writable: false,
                    defaultValue: NSNumber(value: 0), value: NSNumber(value: 0))
                info = PtpPropertyInfo(
                    propertyId: propertyId, dataType: eosDataType,
                    writable: !values.isEmpty,
                    defaultValue: info.defaultValue, value: info.value,
                    range: values)
                properties[propertyId] = info
                if !supportedProperties.contains(UInt16(propertyId & 0xFFFF)) {
                    supportedProperties.append(UInt16(propertyId & 0xFFFF))
                }
            }
        default:
            break
        }
    }

    private func canonPropertyChanged(_ propertyId: UInt32, data: Data) {
        var info = properties[propertyId]
        var dataType = info?.dataType ?? 0

        if dataType == 0 {
            if data.count >= 4 { dataType = PTP_DATATYPE_EOS_MASK + 6 }
            else { return }
        }

        let (value, _) = readEosValue(from: data, offset: 0, dataType: dataType)
        guard let value = value else { return }

        let newInfo = PtpPropertyInfo(
            propertyId: propertyId, dataType: dataType,
            writable: info?.writable ?? false,
            defaultValue: info?.defaultValue ?? value, value: value,
            range: info?.range)
        properties[propertyId] = newInfo

        if !supportedProperties.contains(UInt16(propertyId & 0xFFFF)) {
            supportedProperties.append(UInt16(propertyId & 0xFFFF))
        }

        receivedProperty(propertyId)
        DispatchQueue.main.async { self.delegate?.cameraPropertiesChanged(self) }
    }

    // MARK: - EOS Data Type Helpers

    private func readEosValue(from data: Data, offset: Int, dataType: UInt32) -> (value: NSNumber?, bytesRead: Int) {
        guard offset + 4 <= data.count else { return (nil, 0) }
        let rawType = dataType & 0xFF
        switch rawType {
        case 1:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int8.self) }
            return (NSNumber(value: val), 4)
        case 2:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt8.self) }
            return (NSNumber(value: val), 4)
        case 3:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int16.self) }
            return (NSNumber(value: val), 4)
        case 4:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
            return (NSNumber(value: val), 4)
        case 5:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
            return (NSNumber(value: val), 4)
        case 6:
            let val = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            return (NSNumber(value: val), 4)
        default:
            return (nil, 4)
        }
    }

    private func readEosArray(from data: Data, elementType: UInt32) -> [NSNumber] {
        guard data.count >= 4 else { return [] }
        let count = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        var result: [NSNumber] = []
        var offset = 4
        for _ in 0..<count {
            let (val, bytesRead) = readEosValue(from: data, offset: offset, dataType: elementType)
            if let val = val { result.append(val) }
            offset += bytesRead
            if offset > data.count { break }
        }
        return result
    }

    private func encodeEosValue(_ value: NSNumber, dataType: UInt32) -> Data {
        var data = Data(count: 4)
        let rawType = dataType & 0xFF
        data.withUnsafeMutableBytes { ptr in
            switch rawType {
            case 1: ptr.storeBytes(of: value.int8Value, as: Int8.self)
            case 2: ptr.storeBytes(of: value.uint8Value, as: UInt8.self)
            case 3: ptr.storeBytes(of: value.int16Value, as: Int16.self)
            case 4: ptr.storeBytes(of: value.uint16Value, as: UInt16.self)
            case 5: ptr.storeBytes(of: value.int32Value, as: Int32.self)
            case 6: ptr.storeBytes(of: value.uint32Value, as: UInt32.self)
            default: break
            }
        }
        return data
    }
}
