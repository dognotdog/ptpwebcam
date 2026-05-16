import Foundation
import ImageCaptureCore
import os.log

// MARK: - Nikon PTP Constants

let PTP_RSP_NIKON_NOTLIVEVIEW: UInt16 = 0xA00B
let PTP_RSP_NIKON_INVALIDSTATUS: UInt16 = 0xA004

let PTP_CMD_NIKON_AFDRIVE: UInt16 = 0x90C1
let PTP_CMD_NIKON_DEVICEREADY: UInt16 = 0x90C8
let PTP_CMD_NIKON_GETVENDORPROPS: UInt16 = 0x90CA
let PTP_CMD_NIKON_STARTLIVEVIEW: UInt16 = 0x9201
let PTP_CMD_NIKON_STOPLIVEVIEW: UInt16 = 0x9202
let PTP_CMD_NIKON_GETLIVEVIEWIMG: UInt16 = 0x9203
let PTP_CMD_NIKON_MFDRIVE: UInt16 = 0x9204
let PTP_CMD_NIKON_GETVENDORCODES: UInt16 = 0x9439

let PTP_PROP_NIKON_WBTUNE_AUTO: UInt32 = 0xD017
let PTP_PROP_NIKON_WBTUNE_INCADESCENT: UInt32 = 0xD018
let PTP_PROP_NIKON_WBTUNE_FLOURESCENT: UInt32 = 0xD019
let PTP_PROP_NIKON_WBTUNE_SUNNY: UInt32 = 0xD01A
let PTP_PROP_NIKON_WBTUNE_FLASH: UInt32 = 0xD01B
let PTP_PROP_NIKON_WBTUNE_CLOUDY: UInt32 = 0xD01C
let PTP_PROP_NIKON_WBTUNE_SHADE: UInt32 = 0xD01D
let PTP_PROP_NIKON_WB_COLORTEMP: UInt32 = 0xD01E
let PTP_PROP_NIKON_ISOAUTOCONTROL: UInt32 = 0xD054
let PTP_PROP_NIKON_LV_AF: UInt32 = 0xD05D
let PTP_PROP_NIKON_LV_AFMODE: UInt32 = 0xD061
let PTP_PROP_NIKON_SHUTTERSPEED: UInt32 = 0xD100
let PTP_PROP_NIKON_RECORDINGMEDIA: UInt32 = 0xD10B
let PTP_PROP_NIKON_WBTUNE_AUTOTYPE: UInt32 = 0xD141
let PTP_PROP_NIKON_WBTUNE_FLTYPE: UInt32 = 0xD14F
let PTP_PROP_NIKON_WBTUNE_COLORTEMP: UInt32 = 0xD150
let PTP_PROP_NIKON_LV_APPLYSETTINGS: UInt32 = 0xD17B
let PTP_PROP_NIKON_LV_MODE: UInt32 = 0xD1A0
let PTP_PROP_NIKON_LV_STATUS: UInt32 = 0xD1A2
let PTP_PROP_NIKON_LV_ZOOM: UInt32 = 0xD1A3
let PTP_PROP_NIKON_LV_PROHIBIT: UInt32 = 0xD1A4
let PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW: UInt32 = 0xD1A5
let PTP_PROP_NIKON_LV_SELECTOR: UInt32 = 0xD1A6
let PTP_PROP_NIKON_MOVIE_SHUTTERSPEED: UInt32 = 0xD1A8
let PTP_PROP_NIKON_MOVIE_FNUM: UInt32 = 0xD1A9
let PTP_PROP_NIKON_MOVIE_EXPOSUREBIAS: UInt32 = 0xD1AB
let PTP_PROP_NIKON_LV_IMAGESIZE: UInt32 = 0xD1AC
let PTP_PROP_NIKON_MOVIE_WBTUNE_AUTO: UInt32 = 0xD212
let PTP_PROP_NIKON_MOVIE_WBTUNE_INCADESCENT: UInt32 = 0xD213
let PTP_PROP_NIKON_MOVIE_WBTUNE_FLOURESCENT: UInt32 = 0xD215
let PTP_PROP_NIKON_MOVIE_WBTUNE_SUNNY: UInt32 = 0xD216
let PTP_PROP_NIKON_MOVIE_WBTUNE_CLOUDY: UInt32 = 0xD218
let PTP_PROP_NIKON_MOVIE_WBTUNE_SHADE: UInt32 = 0xD219
let PTP_PROP_NIKON_MOVIE_WBTUNE_COLORTEMP: UInt32 = 0xD21B

// MARK: - PtpCameraNikon

private let nikonLiveViewHeaderLengths: [UInt16: Int] = [
    0x041A: 64, 0x041C: 64, 0x0420: 64, 0x0421: 128,
    0x0422: 64, 0x0423: 128, 0x0425: 64, 0x0426: 128,
    0x0428: 384, 0x0429: 384, 0x042A: 384, 0x042B: 384,
    0x042C: 384, 0x042D: 384, 0x042E: 384, 0x042F: 384,
    0x0430: 384, 0x0431: 384, 0x0432: 384, 0x0433: 384,
    0x0434: 384, 0x0435: 384, 0x0436: 384, 0x0437: 384,
    0x0438: 384, 0x0439: 384, 0x043A: 384, 0x043B: 384,
    0x043C: 384, 0x043D: 384, 0x043F: 384, 0x0440: 384,
    0x0441: 384, 0x0442: 384, 0x0443: 384, 0x0444: 384,
    0x0445: 384, 0x0446: 384, 0x0447: 384, 0x0448: 384,
    0x044B: 384, 0x044C: 384, 0x044F: 384, 0x0450: 384, 0x0451: 384,
]

private enum NikonLvStatus { case off, waiting, on, restartStopping }

class PtpCameraNikon: PtpCamera {

    private var requiredPropertiesForReadiness: Set<UInt32> = []
    private var lvStatus: NikonLvStatus = .off

    private var liveViewHeaderLength: Int {
        nikonLiveViewHeaderLengths[UInt16(icCamera.usbProductID)] ?? 384
    }

    static func registerCameras() {
        // Single source of truth lives in PtpKnownCameras.table.
        register(vendorId: PtpKnownCameras.vidNikon,
                 cameras: PtpKnownCameras.entries(forVendor: PtpKnownCameras.vidNikon),
                 make: "Nikon",
                 cameraClass: PtpCameraNikon.self)

        nonAdvertisedOperations[0x04B0] = [
            0x042C: [PTP_CMD_NIKON_STARTLIVEVIEW, PTP_CMD_NIKON_STOPLIVEVIEW, PTP_CMD_NIKON_GETLIVEVIEWIMG],
            0x0433: [PTP_CMD_NIKON_GETVENDORPROPS, PTP_CMD_NIKON_STARTLIVEVIEW, PTP_CMD_NIKON_STOPLIVEVIEW, PTP_CMD_NIKON_GETLIVEVIEWIMG],
            0x0445: [PTP_CMD_NIKON_GETVENDORPROPS, PTP_CMD_NIKON_STARTLIVEVIEW, PTP_CMD_NIKON_STOPLIVEVIEW, PTP_CMD_NIKON_GETLIVEVIEWIMG],
        ]
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
            0x5008, // Focal Length
            PTP_PROP_NIKON_LV_SELECTOR,
            PTP_PROP_NIKON_LV_STATUS,
            0x500E, // Exposure Program
            0x5007, // Aperture
            PTP_PROP_NIKON_MOVIE_FNUM,
            0x500F, // ISO
            PTP_PROP_NIKON_ISOAUTOCONTROL,
            PTP_PROP_NIKON_SHUTTERSPEED,
            PTP_PROP_NIKON_MOVIE_SHUTTERSPEED,
            0x5005, // White Balance
            0x5010, // Exposure Bias
            PTP_PROP_NIKON_MOVIE_EXPOSUREBIAS,
            PTP_PROP_NIKON_LV_AFMODE,
            PTP_PROP_NIKON_LV_AF,
            PTP_PROP_NIKON_LV_ZOOM,
            PTP_PROP_NIKON_LV_MODE,
            PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW,
            PTP_PROP_NIKON_LV_APPLYSETTINGS,
            PTP_PROP_NIKON_LV_IMAGESIZE,
        ]
    }

    override var currentUiProperties: [UInt32] {
        let movieProps: Set<UInt32> = [
            PTP_PROP_NIKON_MOVIE_FNUM, PTP_PROP_NIKON_MOVIE_SHUTTERSPEED, PTP_PROP_NIKON_MOVIE_EXPOSUREBIAS,
        ]
        let stillProps: Set<UInt32> = [0x5007, PTP_PROP_NIKON_SHUTTERSPEED, 0x5010]

        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_SELECTOR)) {
            let inVideoMode = (properties[PTP_PROP_NIKON_LV_SELECTOR]?.value as? NSNumber)?.intValue == 1
            let filterSet = inVideoMode ? stillProps : movieProps
            return uiProperties.filter { !filterSet.contains($0) }
        }

        return uiProperties
    }

    // MARK: - Property Names

    override var propertyNames: [UInt32: String] {
        var names = super.propertyNames
        names.merge([
            PTP_PROP_NIKON_WBTUNE_AUTO: "WB Auto Tune",
            PTP_PROP_NIKON_WBTUNE_INCADESCENT: "WB Incadescent Tune",
            PTP_PROP_NIKON_WBTUNE_FLOURESCENT: "WB Flourescent Tune",
            PTP_PROP_NIKON_WBTUNE_SUNNY: "WB Sunny Tune",
            PTP_PROP_NIKON_WBTUNE_FLASH: "WB Flash Tune",
            PTP_PROP_NIKON_WBTUNE_CLOUDY: "WB Cloudy Tune",
            PTP_PROP_NIKON_WBTUNE_SHADE: "WB Shade Tune",
            PTP_PROP_NIKON_WB_COLORTEMP: "Color Temperature",
            PTP_PROP_NIKON_LV_AFMODE: "AF Mode",
            PTP_PROP_NIKON_LV_AF: "AF Area Mode",
            PTP_PROP_NIKON_SHUTTERSPEED: "Shutter Speed",
            PTP_PROP_NIKON_MOVIE_SHUTTERSPEED: "Movie Shutter Speed",
            PTP_PROP_NIKON_MOVIE_FNUM: "Movie Aperture",
            PTP_PROP_NIKON_RECORDINGMEDIA: "Recording Media",
            PTP_PROP_NIKON_WBTUNE_AUTOTYPE: "WB Auto Type",
            PTP_PROP_NIKON_WBTUNE_FLTYPE: "WB Flourescent Type",
            PTP_PROP_NIKON_WBTUNE_COLORTEMP: "Color Temp Tune",
            PTP_PROP_NIKON_ISOAUTOCONTROL: "Auto ISO",
            PTP_PROP_NIKON_LV_MODE: "LiveView AF Mirror Mode",
            PTP_PROP_NIKON_LV_STATUS: "LiveView Status",
            PTP_PROP_NIKON_LV_ZOOM: "LiveView Zoom",
            PTP_PROP_NIKON_LV_PROHIBIT: "LiveView Prohibit Condition",
            PTP_PROP_NIKON_LV_APPLYSETTINGS: "Exposure Preview",
            PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW: "Exposure Preview",
            PTP_PROP_NIKON_LV_SELECTOR: "LiveView Selector",
            PTP_PROP_NIKON_LV_IMAGESIZE: "Live Image Size",
        ]) { _, new in new }
        return names
    }

    // MARK: - Property Value Names

    override var propertyValueNames: [UInt32: [UInt32: String]] {
        var names = super.propertyValueNames
        let nikonNames: [UInt32: [UInt32: String]] = [
            0x500E: [
                0x8010: "Auto", 0x8011: "Portrait", 0x8012: "Landscape",
                0x8013: "Close-up", 0x8014: "Sports", 0x8015: "Night Portrait",
                0x8016: "Flash Off Auto", 0x8017: "Child", 0x8018: "SCENE",
                0x8019: "EFFECTS", 0x8050: "U1", 0x8051: "U2", 0x8052: "U3",
            ],
            0x5005: [
                0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Color Temperature",
                0x8013: "Preset", 0x8014: "Off", 0x8016: "Natural Light Auto",
            ],
            0x500A: [
                0x8010: "[S] Single", 0x8011: "[C] Continuous",
                0x8012: "[A] Automatic", 0x8013: "[F] Constant",
            ],
            0x501C: [
                0x8010: "Single Point", 0x8011: "Auto Area", 0x8012: "3D Tracking",
            ],
            PTP_PROP_NIKON_ISOAUTOCONTROL: [0: "Off", 1: "On"],
            PTP_PROP_NIKON_LV_APPLYSETTINGS: [0: "Off", 1: "On"],
            PTP_PROP_NIKON_LV_AF: [
                0x0000: "Face Detect", 0x0001: "Wide Area",
                0x0002: "Normal Area", 0x0003: "Target Tracking",
            ],
            PTP_PROP_NIKON_LV_AFMODE: [
                0x0000: "[S] Single", 0x0001: "[F] Constant",
                0x0002: "[C] Continuous", 0x0003: "Manual Lens", 0x0004: "Manual",
            ],
            PTP_PROP_NIKON_LV_MODE: [
                0x0000: "Mirror-down for AF (hand-held mode)",
                0x0001: "Mirror-up for AF (tripod mode)",
            ],
            PTP_PROP_NIKON_LV_SELECTOR: [0x0000: "Still", 0x0001: "Movie"],
            PTP_PROP_NIKON_RECORDINGMEDIA: [0x0000: "Card", 0x0001: "SDRAM", 0x0002: "Card and SDRAM"],
            PTP_PROP_NIKON_WBTUNE_AUTOTYPE: [0x0000: "Standard", 0x0001: "Incadescent"],
            PTP_PROP_NIKON_WBTUNE_FLTYPE: [
                0x0000: "Sodium Mixed", 0x0001: "Cool White FL", 0x0002: "Warm White FL",
                0x0003: "White FL", 0x0004: "Day White FL", 0x0005: "Daylight FL",
                0x0006: "High Color Temp Mercury",
            ],
            PTP_PROP_NIKON_LV_IMAGESIZE: [
                0x0000: "Undefined", 0x0001: "QVGA 320x240",
                0x0002: "VGA 640x480", 0x0003: "XGA 1024x768",
            ],
        ]
        for (propId, values) in nikonNames {
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
        case PTP_PROP_NIKON_WB_COLORTEMP:
            return String(format: "%.0f K", n.doubleValue)
        case PTP_PROP_NIKON_MOVIE_FNUM:
            return String(format: "f/%.1f", 0.01 * n.doubleValue)
        case PTP_PROP_NIKON_SHUTTERSPEED, PTP_PROP_NIKON_MOVIE_SHUTTERSPEED:
            return formatNikonShutterSpeed(n.uint32Value)
        case PTP_PROP_NIKON_WBTUNE_AUTO, PTP_PROP_NIKON_WBTUNE_INCADESCENT,
             PTP_PROP_NIKON_WBTUNE_FLOURESCENT, PTP_PROP_NIKON_WBTUNE_SUNNY,
             PTP_PROP_NIKON_WBTUNE_FLASH, PTP_PROP_NIKON_WBTUNE_CLOUDY,
             PTP_PROP_NIKON_WBTUNE_SHADE, PTP_PROP_NIKON_WBTUNE_COLORTEMP,
             PTP_PROP_NIKON_MOVIE_WBTUNE_AUTO, PTP_PROP_NIKON_MOVIE_WBTUNE_INCADESCENT,
             PTP_PROP_NIKON_MOVIE_WBTUNE_FLOURESCENT, PTP_PROP_NIKON_MOVIE_WBTUNE_SUNNY,
             PTP_PROP_NIKON_MOVIE_WBTUNE_CLOUDY, PTP_PROP_NIKON_MOVIE_WBTUNE_SHADE,
             PTP_PROP_NIKON_MOVIE_WBTUNE_COLORTEMP:
            return "\(n.intValue)"
        case PTP_PROP_NIKON_LV_STATUS, PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
            return n.boolValue ? "On" : "Off"
        case PTP_PROP_NIKON_LV_APPLYSETTINGS:
            return n.boolValue ? "Off" : "On"
        default:
            return super.formatValue(val, forProperty: propId)
        }
    }

    private func formatNikonShutterSpeed(_ val: UInt32) -> String {
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

    // MARK: - Autofocus

    override var canAutofocus: Bool {
        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_AFMODE)),
           let afModeInfo = properties[PTP_PROP_NIKON_LV_AFMODE],
           let value = afModeInfo.value as? NSNumber {
            return value.intValue != 3 && value.intValue != 4
        }
        return isOperationSupported(PTP_CMD_NIKON_AFDRIVE)
    }

    override func performAutofocus() {
        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_AFMODE)) {
            queryPropertyDescription(PTP_PROP_NIKON_LV_AFMODE)
        }
        if isOperationSupported(PTP_CMD_NIKON_AFDRIVE) {
            sendCommand(buildCommand(code: PTP_CMD_NIKON_AFDRIVE))
        }
    }

    // MARK: - Device Info

    override func deviceInfoReceived() {
        for propId in supportedProperties {
            queryPropertyDescription(UInt32(propId))
        }

        if isOperationSupported(PTP_CMD_NIKON_GETVENDORPROPS) {
            sendCommand(buildCommand(code: PTP_CMD_NIKON_GETVENDORPROPS))
        } else if isOperationSupported(PTP_CMD_NIKON_GETVENDORCODES) {
            sendCommand(buildCommand(code: PTP_CMD_NIKON_GETVENDORCODES, parameters: [0x0D]))
        } else {
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        }
    }

    // MARK: - Live View

    override func startLiveView() {
        lvStatus = .waiting
        sendCommand(buildCommand(code: PTP_CMD_NIKON_STARTLIVEVIEW))

        if isOperationSupported(PTP_CMD_NIKON_DEVICEREADY) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
                self?.pollDeviceReady()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard self?.lvStatus == .waiting else { return }
                self?.cameraDidBecomeReadyForLiveViewStreaming()
            }
        }
    }

    override func stopLiveView() {
        sendCommand(buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
        lvStatus = .off
        super.stopLiveView()
        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_STATUS)) {
            queryPropertyDescription(PTP_PROP_NIKON_LV_STATUS)
        }
    }

    override func requestLiveViewImage() {
        if shouldRequestNewLiveViewImage() {
            sendCommand(buildCommand(code: PTP_CMD_NIKON_GETLIVEVIEWIMG))
        }
    }

    private func pollDeviceReady() {
        sendCommand(buildCommand(code: PTP_CMD_NIKON_DEVICEREADY))
    }

    private func restartLiveView() {
        lvStatus = .restartStopping
        super.stopLiveView()
        sendCommand(buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
    }

    // MARK: - Command Handling

    override func handleCommand(_ code: UInt16, data: Data?, response: Data, fullCommand: Data) {
        switch code {
        case PTP_CMD_NIKON_GETVENDORPROPS:
            if let data = data { parseVendorPropertiesResponse(data) }
        case PTP_CMD_NIKON_GETVENDORCODES:
            if let data = data { parseVendorCodesResponse(data) }
        case PTP_CMD_NIKON_GETLIVEVIEWIMG:
            liveViewImageReceived()
            handleNikonLiveViewImageResponse(data: data, response: response)
        case PTP_CMD_NIKON_DEVICEREADY:
            let rspCode = response.count >= 8 ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) } : UInt16(0)
            switch rspCode {
            case PTP_RSP_DEVICEBUSY:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.pollDeviceReady()
                }
            case PTP_RSP_OK:
                if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_STATUS)) {
                    queryPropertyDescription(PTP_PROP_NIKON_LV_STATUS)
                } else {
                    cameraDidBecomeReadyForLiveViewStreaming()
                }
                if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW)) {
                    queryPropertyDescription(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW)
                }
            default:
                logger.error("DEVICEREADY returned 0x\(String(rspCode, radix: 16), privacy: .public)")
                stopLiveView()
            }
        case PTP_CMD_NIKON_STARTLIVEVIEW:
            let rspCode = response.count >= 8 ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) } : UInt16(0)
            if rspCode != PTP_RSP_OK {
                logger.warning("STARTLIVEVIEW returned 0x\(String(rspCode, radix: 16), privacy: .public)")
            }
        case PTP_CMD_NIKON_STOPLIVEVIEW:
            if lvStatus == .restartStopping {
                startLiveView()
            }
        default:
            super.handleCommand(code, data: data, response: response, fullCommand: fullCommand)
        }
    }

    private func handleNikonLiveViewImageResponse(data: Data?, response: Data) {
        guard let data = data else {
            let rspCode = response.count >= 8 ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) } : UInt16(0)
            logger.warning("GETLIVEVIEWIMG: no data, rsp=0x\(String(rspCode, radix: 16), privacy: .public)")
            if rspCode != PTP_RSP_DEVICEBUSY && lvStatus == .on {
                restartLiveView()
            }
            return
        }
        let rspCode = response.count >= 8 ? response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) } : UInt16(PTP_RSP_OK)
        // Mirror old ObjC behaviour: only bail on NOTLIVEVIEW; attempt JPEG extraction for OK and any other code.
        if rspCode == PTP_RSP_NIKON_NOTLIVEVIEW {
            logger.info("GETLIVEVIEWIMG: camera not in live view")
            return
        }
        if rspCode != PTP_RSP_OK {
            logger.warning("GETLIVEVIEWIMG: non-OK rsp=0x\(String(rspCode, radix: 16), privacy: .public), data=\(data.count, privacy: .public)B — attempting extraction anyway")
        }
        let headerLen = liveViewHeaderLength
        guard data.count > headerLen else {
            logger.warning("GETLIVEVIEWIMG: data too short (\(data.count, privacy: .public) <= headerLen \(headerLen, privacy: .public))")
            return
        }
        let jpegData = data.subdata(in: headerLen..<data.count)
        let firstBytes = jpegData.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.info("GETLIVEVIEWIMG: data=\(data.count, privacy: .public)B header=\(headerLen, privacy: .public) jpeg=\(jpegData.count, privacy: .public)B start=[\(firstBytes, privacy: .public)]")
        delegate?.cameraReceivedLiveViewJpeg(jpegData, camera: self)
    }

    // MARK: - Vendor Property Parsing

    private func parseVendorPropertiesResponse(_ data: Data) {
        guard data.count >= 4 else { return }
        let count = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard data.count >= 4 + Int(count) * 2 else { return }

        for i in 0..<Int(count) {
            let propId = data.withUnsafeBytes { $0.load(fromByteOffset: 4 + i * 2, as: UInt16.self) }
            supportedProperties.append(propId)
            queryPropertyDescription(UInt32(propId))
        }

        beginReadinessTracking()
    }

    private func parseVendorCodesResponse(_ data: Data) {
        guard data.count >= 4 else { return }
        let count = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard data.count >= 4 + Int(count) * 4 else { return }

        for i in 0..<Int(count) {
            let propId32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4 + i * 4, as: UInt32.self) }
            supportedProperties.append(UInt16(propId32 & 0xFFFF))
            queryPropertyDescription(propId32)
        }

        beginReadinessTracking()
    }

    private func beginReadinessTracking() {
        requiredPropertiesForReadiness = []

        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_SELECTOR)) {
            requiredPropertiesForReadiness.insert(PTP_PROP_NIKON_LV_SELECTOR)
        }
        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_IMAGESIZE)) {
            requiredPropertiesForReadiness.insert(PTP_PROP_NIKON_LV_IMAGESIZE)
        }
        if isPropertySupported(UInt16(PTP_PROP_NIKON_LV_PROHIBIT)) {
            requiredPropertiesForReadiness.insert(PTP_PROP_NIKON_LV_PROHIBIT)
        }

        if requiredPropertiesForReadiness.isEmpty {
            DispatchQueue.main.async { self.delegate?.cameraReady(self) }
        }
    }

    // MARK: - Property Received

    override func receivedProperty(_ propertyId: UInt32) {
        if !requiredPropertiesForReadiness.isEmpty && requiredPropertiesForReadiness.contains(propertyId) {
            if propertyId == PTP_PROP_NIKON_LV_IMAGESIZE,
               let info = properties[PTP_PROP_NIKON_LV_IMAGESIZE],
               let range = info.range as? [NSNumber],
               let maxSize = range.last {
                setProperty(PTP_PROP_NIKON_LV_IMAGESIZE, value: maxSize)
                queryPropertyDescription(PTP_PROP_NIKON_LV_IMAGESIZE)
            }
            requiredPropertiesForReadiness.remove(propertyId)
            if requiredPropertiesForReadiness.isEmpty {
                DispatchQueue.main.async { self.delegate?.cameraReady(self) }
            }
        }

        switch propertyId {
        case PTP_PROP_NIKON_LV_STATUS:
            let isOn = (properties[PTP_PROP_NIKON_LV_STATUS]?.value as? NSNumber)?.intValue ?? 0 > 0
            if lvStatus == .waiting && isOn {
                lvStatus = .on
                cameraDidBecomeReadyForLiveViewStreaming()
            }
        default:
            break
        }
    }
}
