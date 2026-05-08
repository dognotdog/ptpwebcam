import Foundation
import ImageCaptureCore
import os.log

// MARK: - Sony PTP Constants

let PTP_CMD_SONY_CONNECT: UInt16 = 0x9201
let PTP_CMD_SONY_GETPROPERTIES: UInt16 = 0x9202
let PTP_CMD_SONY_GETPROPDESC: UInt16 = 0x9203
let PTP_CMD_SONY_GETPROPVAL: UInt16 = 0x9204
let PTP_CMD_SONY_SETPROPABS: UInt16 = 0x9205
let PTP_CMD_SONY_SETPROPSTEP: UInt16 = 0x9207
let PTP_CMD_SONY_GETALLPROPDATA: UInt16 = 0x9209

private let SONY_GETALLPROPS_MAGICNUMBER: UInt32 = 0xC8
private let SONY_LV_IMAGE_OBJECTID: UInt32 = 0xFFFFC002

let PTP_PROP_SONY_IMAGESIZE: UInt32 = 0xD203
let PTP_PROP_SONY_SHUTTERSPEED: UInt32 = 0xD20D
let PTP_PROP_SONY_COLORTEMP: UInt32 = 0xD20F
let PTP_PROP_SONY_WB_GREENMAGENTA: UInt32 = 0xD210
let PTP_PROP_SONY_FOCUSFOUND: UInt32 = 0xD213
let PTP_PROP_SONY_ZOOM: UInt32 = 0xD214
let PTP_PROP_SONY_BATTERYLEVEL: UInt32 = 0xD218
let PTP_PROP_SONY_PICTURE_EFFECT: UInt32 = 0xD21B
let PTP_PROP_SONY_WB_AMBERBLUE: UInt32 = 0xD21C
let PTP_PROP_SONY_ISO: UInt32 = 0xD21E
let PTP_PROP_SONY_LV_STATUS: UInt32 = 0xD221
let PTP_PROP_SONY_AUTOFOCUSBUTTON: UInt32 = 0xD2C1
let PTP_PROP_SONY_SHUTTERBUTTON: UInt32 = 0xD2C2

let PTP_EVENT_SONY_PROPVALCHANGED: UInt16 = 0xC203

// MARK: - Sony Connect State

private enum SonyConnectStatus {
    case start
    case connecting1, connecting2
    case getProperties, connecting3
    case getPropertyDescriptions
    case connected, error
}

// MARK: - PtpCameraSony

class PtpCameraSony: PtpCamera {

    private var connectStatus: SonyConnectStatus = .start

    static func registerCameras() {
        let cameras: [(productId: UInt16, model: String, confirmed: Bool)] = [
            (0x079B, "A68", false),
            (0x079C, "A6300", false),
            (0x079E, "A99-II", false),
            (0x07A4, "A6500", false),
            (0x0953, "A77-II", false),
            (0x0954, "A7S", true),
            (0x0957, "A5100", false),
            (0x096F, "A7-III", false),
            (0x0A6B, "A7R-II", false),
            (0x0A71, "A7S-II", false),
            (0x0C2A, "A9", false),
            (0x0C33, "A7R-III", false),
            (0x0C34, "A7-III", false),
            (0x0CAA, "A6400", false),
            (0x0CCC, "A7R-IV", false),
        ]
        register(vendorId: 0x054C, cameras: cameras, make: "Sony", cameraClass: PtpCameraSony.self)
    }

    // MARK: - Init

    required init(icCamera: ICCameraDevice, cameraId: String,
                  delegate: PtpCameraDelegate, cameraInfo: PtpCameraInfo) {
        super.init(icCamera: icCamera, cameraId: cameraId, delegate: delegate, cameraInfo: cameraInfo)
    }

    // MARK: - UI Properties

    override var uiProperties: [UInt32] {
        [
            0x5001, // Battery Level
            PTP_PROP_SONY_BATTERYLEVEL,
            0x5008, // Focal Length
            0x500E, // Exposure Program
            0x5007, // Aperture
            0x500F, // ISO
            PTP_PROP_SONY_ISO,
            0x500D, // Exposure Time
            PTP_PROP_SONY_SHUTTERSPEED,
            0x5005, // White Balance
            PTP_PROP_SONY_WB_GREENMAGENTA,
            PTP_PROP_SONY_WB_AMBERBLUE,
            0x5010, // Exposure Bias
            0x500A, // Focus Mode
            PTP_PROP_SONY_LV_STATUS,
        ]
    }

    // MARK: - Property Names

    override var propertyNames: [UInt32: String] {
        var names = super.propertyNames
        names.merge([
            0xD200: "DPC Compensation",
            0xD201: "Dynamic Range Optimization",
            PTP_PROP_SONY_IMAGESIZE: "Image Size",
            PTP_PROP_SONY_SHUTTERSPEED: "Shutter Speed",
            PTP_PROP_SONY_COLORTEMP: "WB Color Temp",
            PTP_PROP_SONY_WB_GREENMAGENTA: "WB Tune Green-Magenta",
            PTP_PROP_SONY_FOCUSFOUND: "Focus Found",
            PTP_PROP_SONY_ZOOM: "Zoom",
            PTP_PROP_SONY_BATTERYLEVEL: "Battery Level",
            PTP_PROP_SONY_PICTURE_EFFECT: "Picture Effect",
            PTP_PROP_SONY_WB_AMBERBLUE: "WB Tune Amber-Blue",
            PTP_PROP_SONY_ISO: "ISO",
            PTP_PROP_SONY_LV_STATUS: "LiveView Status",
            PTP_PROP_SONY_AUTOFOCUSBUTTON: "Autofocus Button",
            PTP_PROP_SONY_SHUTTERBUTTON: "Shutter Button",
        ]) { _, new in new }
        return names
    }

    // MARK: - Property Value Names

    override var propertyValueNames: [UInt32: [UInt32: String]] {
        var names = super.propertyValueNames
        let sonyNames: [UInt32: [UInt32: String]] = [
            PTP_PROP_SONY_ISO: [0xFFFFFF: "Auto ISO"],
            0x5005: [
                0x8001: "Flourescent Warm White", 0x8002: "Flourescent Cool White",
                0x8003: "Flourescent Day White", 0x8004: "Flourescent Daylight",
                0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Color Temperature",
                0x8020: "Custom 1", 0x8021: "Custom 2", 0x8022: "Custom 3",
                0x8030: "Auto Underwater",
            ],
        ]
        for (propId, values) in sonyNames {
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
        case PTP_PROP_SONY_SHUTTERSPEED:
            return formatSonyShutterSpeed(n.uint32Value)
        case PTP_PROP_SONY_BATTERYLEVEL:
            return n.intValue == -1 ? "Unknown" : String(format: "%.0f%%", n.doubleValue)
        case PTP_PROP_SONY_WB_GREENMAGENTA, PTP_PROP_SONY_WB_AMBERBLUE:
            if let info = properties[propId],
               let defaultVal = info.defaultValue as? NSNumber {
                return "\(n.intValue - defaultVal.intValue)"
            }
            return "\(n.intValue)"
        default:
            return super.formatValue(val, forProperty: propId)
        }
    }

    private func formatSonyShutterSpeed(_ val: UInt32) -> String {
        let nom = UInt16(val >> 16)
        let den = UInt16(val & 0x0000FFFF)
        if val == 0xFFFFFFFF { return "Bulb" }
        if val == 0xFFFFFFFE { return "Flash" }
        if den == 10 && nom != 1 {
            return String(format: "%.1f s", 0.1 * Double(nom))
        } else if nom == 10 && den != 1 {
            return String(format: "1/%.1f s", 0.1 * Double(den))
        } else if den > 1 {
            return "\(nom)/\(den) s"
        } else {
            return "\(nom) s"
        }
    }

    // MARK: - Live View

    override func startLiveView() {
        cameraDidBecomeReadyForLiveViewStreaming()
    }

    override func stopLiveView() {
        super.stopLiveView()
    }

    override func requestLiveViewImage() {
        if shouldRequestNewLiveViewImage() {
            sendCommand(buildCommand(code: PTP_CMD_GETOBJECT, parameters: [SONY_LV_IMAGE_OBJECTID]))
        }
    }

    // MARK: - Autofocus

    override var canAutofocus: Bool {
        isPropertySupported(UInt16(PTP_PROP_SONY_AUTOFOCUSBUTTON))
    }

    override func performAutofocus() {
        guard isPropertySupported(UInt16(PTP_PROP_SONY_AUTOFOCUSBUTTON)) else { return }

        queryPropertyDescription(PTP_PROP_SONY_AUTOFOCUSBUTTON)
        setProperty(PTP_PROP_SONY_AUTOFOCUSBUTTON, value: NSNumber(value: 2))

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.setProperty(PTP_PROP_SONY_AUTOFOCUSBUTTON, value: NSNumber(value: 1))
        }
    }

    // MARK: - Device Info

    override func deviceInfoReceived() {
        for propId in supportedProperties {
            queryPropertyDescription(UInt32(propId))
        }

        if isOperationSupported(PTP_CMD_SONY_CONNECT) {
            connectStatus = .connecting1
            sendCommand(buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [1]))
        } else {
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        }
    }

    // MARK: - Property Query Override

    override func queryPropertyDescription(_ propertyId: UInt32) {
        if isOperationSupported(PTP_CMD_SONY_GETPROPDESC) {
            sendCommand(buildCommand(code: PTP_CMD_SONY_GETPROPDESC, parameters: [propertyId]))
        } else if isOperationSupported(PTP_CMD_GETPROPDESC) {
            sendCommand(buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [propertyId]))
        } else if isOperationSupported(PTP_CMD_SONY_GETALLPROPDATA) {
            sendCommand(buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA))
        }
    }

    // MARK: - Property Set Override

    override func setProperty(_ propertyId: UInt32, value: NSNumber) {
        guard let info = properties[propertyId] else { return }

        if info.incremental {
            incrementProperty(propertyId, toValue: value)
        } else if info.button {
            incrementProperty(propertyId, by: value.int32Value)
        } else {
            let data = encodeValue(value, dataType: info.dataType)
            sendCommand(buildCommand(code: PTP_CMD_SONY_SETPROPABS, parameters: [propertyId]), data: data)
        }
    }

    private func incrementProperty(_ propertyId: UInt32, toValue value: NSNumber) {
        guard let info = properties[propertyId],
              let rangeArray = info.range as? [NSNumber],
              let currentValue = info.value as? NSNumber else { return }

        guard let oldIndex = rangeArray.firstIndex(of: currentValue),
              let newIndex = rangeArray.firstIndex(of: value) else { return }

        let difference = Int32(newIndex - oldIndex)
        incrementProperty(propertyId, by: difference)
    }

    private func incrementProperty(_ propertyId: UInt32, by increment: Int32) {
        var inc = increment
        let data = Data(bytes: &inc, count: 4)
        sendCommand(buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [propertyId]), data: data)
    }

    // MARK: - PTP Event Handling

    override func handlePtpEvent(_ eventCode: UInt16, data: Data) {
        switch eventCode {
        case PTP_EVENT_SONY_PROPVALCHANGED:
            guard data.count >= 16 else { return }
            let propertyId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
            if displayName(forProperty: propertyId) != nil {
                queryPropertyDescription(propertyId)
            }
        default:
            super.handlePtpEvent(eventCode, data: data)
        }
    }

    // MARK: - Command Handling

    override func handleCommand(_ code: UInt16, data: Data?, response: Data, fullCommand: Data) {
        switch code {
        case PTP_CMD_SONY_CONNECT:
            handleConnectResponse()
        case PTP_CMD_SONY_GETPROPERTIES:
            if let data = data {
                parseSonyPropertiesResponse(data)
                if connectStatus == .getProperties {
                    connectStatus = .connecting3
                    sendCommand(buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [3]))
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.sendCommand(self!.buildCommand(code: PTP_CMD_SONY_GETPROPERTIES,
                                                          parameters: [SONY_GETALLPROPS_MAGICNUMBER]))
                }
            }
        case PTP_CMD_SONY_GETALLPROPDATA:
            if let data = data { parseSonyAllPropertyDataResponse(data) }
            if connectStatus == .getPropertyDescriptions {
                connectStatus = .connected
            }
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        case PTP_CMD_SONY_GETPROPDESC:
            if let data = data { parsePropertyDescription(data) }
        case PTP_CMD_SONY_SETPROPABS, PTP_CMD_SONY_SETPROPSTEP:
            break
        case PTP_CMD_GETOBJECT:
            let param = fullCommand.count >= 16
                ? fullCommand.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                : UInt32(0)
            if param == SONY_LV_IMAGE_OBJECTID {
                liveViewImageReceived()
                if let data = data, let jpegData = extractLiveViewJpegData(data) {
                    delegate?.cameraReceivedLiveViewJpeg(jpegData, camera: self)
                }
            } else {
                super.handleCommand(code, data: data, response: response, fullCommand: fullCommand)
            }
        default:
            super.handleCommand(code, data: data, response: response, fullCommand: fullCommand)
        }
    }

    private func handleConnectResponse() {
        switch connectStatus {
        case .connecting1:
            connectStatus = .connecting2
            sendCommand(buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [2]))
        case .connecting2:
            if isOperationSupported(PTP_CMD_SONY_GETPROPERTIES) {
                connectStatus = .getProperties
                sendCommand(buildCommand(code: PTP_CMD_SONY_GETPROPERTIES,
                                          parameters: [SONY_GETALLPROPS_MAGICNUMBER]))
            } else {
                connectStatus = .connecting3
                sendCommand(buildCommand(code: PTP_CMD_SONY_CONNECT, parameters: [3]))
            }
        case .connecting3:
            connectStatus = .connected
            if isOperationSupported(PTP_CMD_SONY_GETALLPROPDATA) {
                connectStatus = .getPropertyDescriptions
                sendCommand(buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA))
            }
        default:
            break
        }
    }

    // MARK: - Sony Property Parsing

    private func parseSonyPropertiesResponse(_ data: Data) {
        guard data.count >= 2 else { return }
        let code = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
        guard code == UInt16(SONY_GETALLPROPS_MAGICNUMBER) else { return }

        let p = PtpDataParser(data.subdata(in: 2..<data.count))
        if let propArray = p.readArray(elementType: 4) {
            for prop in propArray {
                supportedProperties.append(prop.uint16Value)
            }
        }
    }

    private func parseSonyAllPropertyDataResponse(_ data: Data) {
        guard data.count > 8 else { return }
        let p = PtpDataParser(data.subdata(in: 8..<data.count))

        while p.remaining > 0 {
            guard let propId = p.readUInt16(),
                  let dataType = p.readUInt16(),
                  let flags = p.readUInt8(),
                  let readwrite = p.readUInt8(),
                  let defaultValue = p.readItem(ofType: dataType),
                  let currentValue = p.readItem(ofType: dataType),
                  let formFlag = p.readUInt8() else { break }

            var range: Any? = nil
            switch formFlag {
            case 0x01:
                if let rmin = p.readItem(ofType: dataType),
                   let rmax = p.readItem(ofType: dataType),
                   let rstep = p.readItem(ofType: dataType) {
                    range = ["min": rmin, "max": rmax, "step": rstep]
                }
            case 0x02:
                if let enumCount = p.readUInt16() {
                    var enumValues: [Any] = []
                    for _ in 0..<enumCount {
                        if let val = p.readItem(ofType: dataType) {
                            enumValues.append(val)
                        }
                    }
                    range = enumValues
                }
            default: break
            }

            let incremental = (flags & 0x01) == 0
            let button = (flags & 0x80) != 0
            let rw = readwrite == 1

            let info = PtpPropertyInfo(
                propertyId: UInt32(propId), dataType: UInt32(dataType), writable: rw,
                defaultValue: defaultValue, value: currentValue, range: range,
                incremental: incremental, button: button)
            properties[UInt32(propId)] = info

            if !supportedProperties.contains(propId) {
                supportedProperties.append(propId)
            }

            receivedProperty(UInt32(propId))
        }

        DispatchQueue.main.async { self.delegate?.cameraPropertiesChanged(self) }
    }
}
