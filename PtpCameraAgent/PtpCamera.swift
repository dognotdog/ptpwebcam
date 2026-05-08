import Foundation
import ImageCaptureCore
import os.log

// MARK: - PTP Constants

let PTP_TYPE_COMMAND: UInt16 = 0x0001

let PTP_CMD_GETDEVICEINFO: UInt16 = 0x1001
let PTP_CMD_GETSTORAGEIDS: UInt16 = 0x1004
let PTP_CMD_GETOBJECT: UInt16 = 0x1009
let PTP_CMD_GETPROPDESC: UInt16 = 0x1014
let PTP_CMD_GETPROPVAL: UInt16 = 0x1015
let PTP_CMD_SETPROPVAL: UInt16 = 0x1016

let PTP_RSP_OK: UInt16 = 0x2001
let PTP_RSP_DEVICEBUSY: UInt16 = 0x2019

// MARK: - Camera Registry Entry

struct PtpCameraInfo {
    let make: String
    let model: String
    let cameraClass: PtpCamera.Type
    let confirmed: Bool
}

// MARK: - Property Info

struct PtpPropertyInfo {
    let propertyId: UInt32
    let dataType: UInt32
    let writable: Bool
    var defaultValue: Any
    var value: Any
    var range: Any?
    var incremental: Bool = false
    var button: Bool = false
}

// MARK: - PTP Data Parser

class PtpDataParser {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    func skip(_ count: Int) { offset += count }

    private func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var val: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &val) { ptr in
            data.copyBytes(to: ptr, from: (data.startIndex + offset)..<(data.startIndex + offset + size))
        }
        offset += size
        return T(littleEndian: val)
    }

    func readUInt8() -> UInt8? { read() }
    func readUInt16() -> UInt16? { read() }
    func readUInt32() -> UInt32? { read() }
    func readInt8() -> Int8? { read() }
    func readInt16() -> Int16? { read() }
    func readInt32() -> Int32? { read() }
    func readUInt64() -> UInt64? { read() }
    func readInt64() -> Int64? { read() }

    func readPtpString() -> String? {
        guard let charCount = readUInt8() else { return nil }
        if charCount == 0 { return "" }
        let byteCount = Int(charCount) * 2
        guard remaining >= byteCount else { return nil }
        var chars: [UInt16] = []
        for _ in 0..<charCount {
            guard let ch: UInt16 = read() else { return nil }
            if ch != 0 { chars.append(ch) }
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }

    func readValue(ofType dt: UInt16) -> NSNumber? {
        switch dt {
        case 1: return readInt8().map { NSNumber(value: $0) }
        case 2: return readUInt8().map { NSNumber(value: $0) }
        case 3: return readInt16().map { NSNumber(value: $0) }
        case 4: return readUInt16().map { NSNumber(value: $0) }
        case 5: return readInt32().map { NSNumber(value: $0) }
        case 6: return readUInt32().map { NSNumber(value: $0) }
        case 7: return readInt64().map { NSNumber(value: $0) }
        case 8: return readUInt64().map { NSNumber(value: $0) }
        default: return nil
        }
    }

    func readItem(ofType dt: UInt16) -> Any? {
        if dt == 0xFFFF { return readPtpString() }
        if dt >= 0x4001 && dt <= 0x400A { return readArray(elementType: dt - 0x4000) }
        return readValue(ofType: dt)
    }

    func readArray(elementType: UInt16) -> [NSNumber]? {
        guard let count = readUInt32() else { return nil }
        var result: [NSNumber] = []
        for _ in 0..<count {
            guard let val = readValue(ofType: elementType) else { return nil }
            result.append(val)
        }
        return result
    }
}

// MARK: - PtpCamera Delegate

protocol PtpCameraDelegate: AnyObject {
    func cameraPropertiesChanged(_ camera: PtpCamera)
    func cameraReady(_ camera: PtpCamera)
    func cameraRemoved(_ camera: PtpCamera)
    func cameraReceivedLiveViewJpeg(_ data: Data, camera: PtpCamera)
}

// MARK: - PtpCamera

class PtpCamera: NSObject {

    // MARK: Camera Registry

    private static var supportedCameras: [UInt16: [UInt16: PtpCameraInfo]] = [:]
    private static var registryInitialized = false

    static func register(vendorId: UInt16, cameras: [(productId: UInt16, model: String, confirmed: Bool)],
                         make: String, cameraClass: PtpCamera.Type) {
        var models = supportedCameras[vendorId] ?? [:]
        for cam in cameras {
            models[cam.productId] = PtpCameraInfo(
                make: make, model: cam.model, cameraClass: cameraClass, confirmed: cam.confirmed)
        }
        supportedCameras[vendorId] = models
    }

    private static func initializeRegistry() {
        guard !registryInitialized else { return }
        registryInitialized = true
        PtpCameraNikon.registerCameras()
        PtpCameraCanon.registerCameras()
        PtpCameraSony.registerCameras()
    }

    static func isDeviceSupported(_ device: ICDevice) -> PtpCameraInfo? {
        initializeRegistry()
        return supportedCameras[UInt16(device.usbVendorID)]?[UInt16(device.usbProductID)]
    }

    static func cameraForDevice(_ icCamera: ICCameraDevice, cameraId: String,
                                delegate: PtpCameraDelegate) -> PtpCamera? {
        initializeRegistry()
        guard let info = isDeviceSupported(icCamera) else { return nil }
        return info.cameraClass.init(icCamera: icCamera, cameraId: cameraId,
                                     delegate: delegate, cameraInfo: info)
    }

    // MARK: Non-Advertised Operations

    static var nonAdvertisedOperations: [UInt16: [UInt16: [UInt16]]] = [:]

    // MARK: Instance Properties

    let icCamera: ICCameraDevice
    let cameraId: String
    let cameraInfo: PtpCameraInfo
    weak var delegate: PtpCameraDelegate?

    let logger = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "PtpCamera")
    private var transactionId: UInt32 = 0

    var name: String { icCamera.name ?? "PTP Camera" }
    var manufacturer: String?
    var model: String?
    var supportedProperties: [UInt16] = []
    var supportedOperations: [UInt16] = []
    var properties: [UInt32: PtpPropertyInfo] = [:]
    private(set) var isSessionOpen = false

    // MARK: Subclass Overridable

    var uiProperties: [UInt32] {
        [0x5001, 0x5008, 0x500E, 0x5007, 0x500F, 0x500D, 0x5010, 0x5005]
    }

    var currentUiProperties: [UInt32] { uiProperties }

    var propertyValueNames: [UInt32: [UInt32: String]] {
        [
            0x500E: [
                0x0001: "Manual", 0x0002: "Automatic",
                0x0003: "Aperture Priority", 0x0004: "Shutter Priority",
                0x0005: "Creative", 0x0006: "Action", 0x0007: "Portrait",
            ],
            0x5005: [
                0x0001: "Manual", 0x0002: "Automatic", 0x0003: "One-Push Auto",
                0x0004: "Daylight", 0x0005: "Fluorescent", 0x0006: "Tungsten", 0x0007: "Flash",
            ],
            0x500A: [
                0x0001: "Manual", 0x0002: "Auto", 0x0003: "Auto Macro",
            ],
            0x500B: [
                0x0001: "Average", 0x0002: "Center-weighted",
                0x0003: "Multi-spot", 0x0004: "Center-spot",
            ],
        ]
    }

    var propertyNames: [UInt32: String] {
        [
            0x5001: "Battery Level", 0x5005: "White Balance",
            0x5007: "Aperture", 0x5008: "Focal Length",
            0x5009: "Focus Distance", 0x500A: "Focus Mode",
            0x500B: "Exposure Metering", 0x500D: "Exposure Time",
            0x500E: "Exposure Program", 0x500F: "ISO",
            0x5010: "Exposure Correction",
        ]
    }

    var canAutofocus: Bool { false }

    // MARK: Live View State

    private(set) var isInLiveView: Bool = false
    private var liveViewRequestInProgress = false
    private let liveViewLock = NSLock()
    private var frameTimer: DispatchSourceTimer?
    private let frameQueue = DispatchQueue(label: "org.ptpwebcam.liveview", qos: .userInteractive)

    // MARK: Init

    required init(icCamera: ICCameraDevice, cameraId: String,
                  delegate: PtpCameraDelegate, cameraInfo: PtpCameraInfo) {
        self.icCamera = icCamera
        self.cameraId = cameraId
        self.delegate = delegate
        self.cameraInfo = cameraInfo
        super.init()
    }

    func openSession() {
        icCamera.delegate = self
        icCamera.requestOpenSession()
    }

    func closeSession() {
        if isSessionOpen { icCamera.requestCloseSession() }
    }

    // MARK: Property Display

    func displayName(forProperty propId: UInt32) -> String? {
        propertyNames[propId]
    }

    func formatValue(_ val: Any, forProperty propId: UInt32) -> String {
        guard let n = val as? NSNumber else { return "\(val)" }
        if let names = propertyValueNames[propId], let name = names[n.uint32Value] {
            return name
        }
        switch propId {
        case 0x5001: return "\(n.intValue)%"
        case 0x5007: return String(format: "f/%.1f", Double(n.intValue) * 0.01)
        case 0x5008: return String(format: "%.1f mm", Double(n.intValue) * 0.01)
        case 0x5009: return "\(n.intValue) mm"
        case 0x500D:
            let t = Double(n.intValue) * 0.0001
            return t > 0 && t < 1.0
                ? String(format: "1/%.0f s", 1.0 / t)
                : String(format: "%.1f s", t)
        case 0x500F: return "ISO \(n.intValue)"
        case 0x5010: return String(format: "%+.1f EV", Double(n.intValue) * 0.001)
        default: return "\(n)"
        }
    }

    func isOperationSupported(_ opCode: UInt16) -> Bool {
        supportedOperations.contains(opCode)
    }

    func isPropertySupported(_ propCode: UInt16) -> Bool {
        supportedProperties.contains(propCode)
    }

    // MARK: PTP Command Building

    func nextTransactionId() -> UInt32 {
        transactionId += 1
        return transactionId
    }

    func buildCommand(code: UInt16, parameters: [UInt32] = []) -> Data {
        var data = Data(capacity: 12 + parameters.count * 4)
        var length = UInt32(12 + parameters.count * 4)
        var type = PTP_TYPE_COMMAND
        var cmd = code
        var txn = nextTransactionId()
        data.append(Data(bytes: &length, count: 4))
        data.append(Data(bytes: &type, count: 2))
        data.append(Data(bytes: &cmd, count: 2))
        data.append(Data(bytes: &txn, count: 4))
        for var p in parameters {
            data.append(Data(bytes: &p, count: 4))
        }
        return data
    }

    func encodeValue(_ value: NSNumber, dataType: UInt32) -> Data {
        var data = Data()
        switch dataType {
        case 1, 2:
            var v = value.uint8Value; data.append(Data(bytes: &v, count: 1))
        case 3, 4:
            var v = value.uint16Value; data.append(Data(bytes: &v, count: 2))
        case 5, 6:
            var v = value.uint32Value; data.append(Data(bytes: &v, count: 4))
        case 7, 8:
            var v = value.uint64Value; data.append(Data(bytes: &v, count: 8))
        default: break
        }
        return data
    }

    // MARK: PTP Commands

    func queryDeviceInfo() {
        sendCommand(buildCommand(code: PTP_CMD_GETDEVICEINFO))
    }

    func queryPropertyDescription(_ propertyId: UInt32) {
        sendCommand(buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [propertyId]))
    }

    func setProperty(_ propertyId: UInt32, value: NSNumber) {
        guard let info = properties[propertyId] else { return }
        let cmd = buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [propertyId])
        sendCommand(cmd, data: encodeValue(value, dataType: info.dataType))
    }

    func performAutofocus() {}

    // MARK: Live View

    func startLiveView() {}

    func stopLiveView() {
        frameTimer?.cancel()
        frameTimer = nil
        isInLiveView = false
        liveViewLock.lock()
        liveViewRequestInProgress = false
        liveViewLock.unlock()
    }

    func requestLiveViewImage() {}

    func cameraDidBecomeReadyForLiveViewStreaming() {
        isInLiveView = true
        startFrameTimer()
        requestLiveViewImage()
    }

    private func startFrameTimer() {
        frameTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.requestLiveViewImage()
        }
        timer.resume()
        frameTimer = timer
    }

    func shouldRequestNewLiveViewImage() -> Bool {
        liveViewLock.lock()
        defer { liveViewLock.unlock() }
        guard isInLiveView, !liveViewRequestInProgress else { return false }
        liveViewRequestInProgress = true
        return true
    }

    func liveViewImageReceived() {
        liveViewLock.lock()
        liveViewRequestInProgress = false
        liveViewLock.unlock()
    }

    func extractLiveViewJpegData(_ data: Data) -> Data? {
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])

        // find the last SOI marker
        var soiOffset: Data.Index? = nil
        var searchFrom = data.startIndex
        while let range = data.range(of: soi, in: searchFrom..<data.endIndex) {
            soiOffset = range.lowerBound
            searchFrom = range.upperBound
        }
        guard let start = soiOffset else { return nil }
        let afterSoi = data.index(start, offsetBy: 2)
        guard afterSoi < data.endIndex else { return nil }
        guard let eoiRange = data.range(of: eoi, in: afterSoi..<data.endIndex) else { return nil }
        return data[start..<eoiRange.upperBound]
    }

    func sendCommand(_ command: Data, data: Data? = nil) {
        icCamera.requestSendPTPCommand(
            command, outData: data,
            sendCommandDelegate: self,
            didSendCommand: #selector(didSendPTPCommand(_:inData:response:error:contextInfo:)),
            contextInfo: nil)
    }

    // MARK: PTP Response Handler

    @objc func didSendPTPCommand(_ command: Data, inData data: Data?, response: Data,
                                  error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        if let error = error {
            logger.error("PTP error: \(error.localizedDescription)")
            return
        }
        guard command.count >= 8 else { return }
        let cmdCode = command.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
        handleCommand(cmdCode, data: data, response: response, fullCommand: command)
    }

    func handleCommand(_ code: UInt16, data: Data?, response: Data, fullCommand: Data) {
        switch code {
        case PTP_CMD_GETDEVICEINFO:
            if let data = data { parseDeviceInfo(data) }
        case PTP_CMD_GETPROPDESC:
            if let data = data { parsePropertyDescription(data) }
        case PTP_CMD_SETPROPVAL:
            if fullCommand.count >= 16 {
                let propId = fullCommand.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                queryPropertyDescription(propId)
            }
        default:
            break
        }
    }

    // MARK: PTP Parsing

    func parseDeviceInfo(_ data: Data) {
        let p = PtpDataParser(data)
        _ = p.readUInt16() // standard version
        _ = p.readUInt32() // vendor extension ID
        _ = p.readUInt16() // vendor extension version
        _ = p.readPtpString() // vendor desc
        _ = p.readUInt16() // functional mode

        if let ops = p.readArray(elementType: 4) {
            supportedOperations = ops.map { $0.uint16Value }
        }
        _ = p.readArray(elementType: 4) // events

        if let props = p.readArray(elementType: 4) {
            supportedProperties = props.map { $0.uint16Value }
        }
        _ = p.readArray(elementType: 4) // capture formats
        _ = p.readArray(elementType: 4) // image formats

        manufacturer = p.readPtpString()
        model = p.readPtpString()

        // Add non-advertised operations
        let vid = UInt16(icCamera.usbVendorID)
        let pid = UInt16(icCamera.usbProductID)
        if let extraOps = Self.nonAdvertisedOperations[vid]?[pid] {
            supportedOperations.append(contentsOf: extraOps)
        }

        logger.info("\(self.manufacturer ?? "?") \(self.model ?? "?") — \(self.supportedProperties.count) properties, \(self.supportedOperations.count) operations")

        deviceInfoReceived()
    }

    func deviceInfoReceived() {
        for propId in supportedProperties {
            queryPropertyDescription(UInt32(propId))
        }
        DispatchQueue.main.async { self.delegate?.cameraReady(self) }
    }

    func parsePropertyDescription(_ data: Data) {
        let p = PtpDataParser(data)
        guard let propId = p.readUInt16(),
              let dataType = p.readUInt16(),
              let rwFlag = p.readUInt8(),
              let defaultValue = p.readItem(ofType: dataType),
              let currentValue = p.readItem(ofType: dataType),
              let formFlag = p.readUInt8() else { return }

        var range: Any? = nil
        switch formFlag {
        case 0x01:
            if let rmin = p.readItem(ofType: dataType),
               let rmax = p.readItem(ofType: dataType),
               let rstep = p.readItem(ofType: dataType) {
                range = ["min": rmin, "max": rmax, "step": rstep]
            }
        case 0x02:
            range = p.readArray(elementType: dataType)
        default: break
        }

        let info = PtpPropertyInfo(
            propertyId: UInt32(propId), dataType: UInt32(dataType), writable: rwFlag != 0,
            defaultValue: defaultValue, value: currentValue, range: range)
        properties[UInt32(propId)] = info
        receivedProperty(UInt32(propId))

        DispatchQueue.main.async { self.delegate?.cameraPropertiesChanged(self) }
    }

    func receivedProperty(_ propertyId: UInt32) {}

    func handlePtpEvent(_ eventCode: UInt16, data: Data) {
        if eventCode == 0x4006, data.count >= 16 {
            let propId = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
            queryPropertyDescription(propId)
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension PtpCamera: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error = error {
            logger.error("Open session failed: \(error.localizedDescription)")
            return
        }
        logger.info("Session opened: \(self.name)")
        isSessionOpen = true
        queryDeviceInfo()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        isSessionOpen = false
    }

    func didRemove(_ device: ICDevice) {
        delegate?.cameraRemoved(self)
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard eventData.count >= 8 else { return }
        let eventCode = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
        handlePtpEvent(eventCode, data: eventData)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}
}
