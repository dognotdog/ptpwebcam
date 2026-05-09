import Cocoa
import ImageCaptureCore
import os.log
import IOSurface
import CoreGraphics
import ImageIO

@main
class AppDelegate: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate {

    private let logger = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "Agent")
    private var deviceBrowser: ICDeviceBrowser!
    private var xpcListener: NSXPCListener!
    private static let logFile: FileHandle? = {
        let path = "/tmp/PtpCameraAgent.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        logFile?.seekToEndOfFile()
        logFile?.write(line.data(using: .utf8)!)
        NSLog("%@", msg)
    }

    private var cameras: [String: PtpCamera] = [:]
    private var extensionConnections: [NSXPCConnection] = []
    private var simulatedCameras: [String: NSDictionary] = [:]
    #if DEBUG
    private var simulatedStripeSpeed: String {
        get { UserDefaults.standard.string(forKey: "simulatedStripeSpeed") ?? "medium" }
        set { UserDefaults.standard.set(newValue, forKey: "simulatedStripeSpeed") }
    }
    #endif
    private var darwinSlotTokens: [Int32] = []
    private var lvFrameSlotTokens: [Int32] = []
    private var lvCmdSlotTokens: [Int32] = []
    private var lvSurfaceSlotTokens: [Int32] = []
    // IOSurfaces created by the extension and looked up here via IOSurfaceLookup (works in sandbox).
    private var remoteSurfaces: [String: IOSurface] = [:]

    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppDelegate.log("PtpCameraAgent: applicationDidFinishLaunching build=\(buildVersion)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(named: "StatusBarIcon") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "PTP"
        }
        rebuildMenu()

        darwinSlotTokens = (0..<kDarwinStateSlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinStateSlotPrefix + "\(i)", &token)
            return token
        }

        var requestToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinCameraStateRequest, &requestToken, .main) { [weak self] _ in
            AppDelegate.log("PtpCameraAgent: received Darwin state request")
            self?.publishCameraState()
        }

        lvFrameSlotTokens = (0..<kDarwinLiveViewFrameSlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinLiveViewFrameSlotPrefix + "\(i)", &token)
            return token
        }
        lvCmdSlotTokens = (0..<kDarwinLiveViewCmdSlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinLiveViewCmdSlotPrefix + "\(i)", &token)
            return token
        }

        lvSurfaceSlotTokens = (0..<kDarwinLiveViewSurfaceSlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinLiveViewSurfaceSlotPrefix + "\(i)", &token)
            return token
        }

        var lvStartToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinLiveViewStart, &lvStartToken, .main) { [weak self] _ in
            self?.handleLiveViewStartCommand()
        }
        var lvStopToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinLiveViewStop, &lvStopToken, .main) { [weak self] _ in
            self?.handleLiveViewStopCommand()
        }
        var lvSurfaceToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinLiveViewSurfaceReady, &lvSurfaceToken, .main) { [weak self] _ in
            self?.handleSurfaceReady()
        }

        xpcListener = NSXPCListener(machServiceName: kPtpCameraAgentMachServiceName)
        xpcListener.delegate = self
        xpcListener.resume()
        AppDelegate.log("PtpCameraAgent: XPC listener started on \(kPtpCameraAgentMachServiceName)")

        deviceBrowser = ICDeviceBrowser()
        deviceBrowser.delegate = self
        deviceBrowser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        deviceBrowser.start()
        AppDelegate.log("PtpCameraAgent: ICDeviceBrowser started")

        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.addSimulatedCamera()
        }
        #endif
    }

    #if DEBUG
    private func addSimulatedCamera() {
        let cameraId = "simulated-nikon-d800"
        let info: NSDictionary = [
            "name": "Simulated Nikon D800",
            "cameraId": cameraId,
        ]
        simulatedCameras[cameraId] = info
        AppDelegate.log("PtpCameraAgent: Adding simulated camera: \(cameraId)")
        publishCameraState()
        rebuildMenu()
    }
    #endif

    // MARK: - Darwin Notify State Publishing

    private func publishCameraState() {
        var cameraList: [[String: String]] = []
        for (cameraId, camera) in cameras {
            cameraList.append(["cameraId": cameraId, "name": camera.name])
        }
        #if DEBUG
        for (cameraId, info) in simulatedCameras {
            cameraList.append(["cameraId": cameraId, "name": info["name"] as? String ?? "Simulated", "isDemo": "1", "stripeSpeed": simulatedStripeSpeed])
        }
        #endif

        guard let jsonData = try? JSONSerialization.data(withJSONObject: cameraList) else { return }
        let maxPayload = (kDarwinStateSlotCount - 1) * 8
        guard jsonData.count <= maxPayload else {
            AppDelegate.log("PtpCameraAgent: camera state too large (\(jsonData.count) bytes, max \(maxPayload))")
            return
        }

        darwin_notify_set_state(darwinSlotTokens[0], UInt64(jsonData.count) << 32)

        for i in 0..<((jsonData.count + 7) / 8) {
            let offset = i * 8
            var value: UInt64 = 0
            let chunkSize = min(8, jsonData.count - offset)
            _ = jsonData.withUnsafeBytes { ptr in
                memcpy(&value, ptr.baseAddress! + offset, chunkSize)
            }
            darwin_notify_set_state(darwinSlotTokens[i + 1], value)
        }

        darwin_notify_post(kDarwinCameraStateChanged)
        AppDelegate.log("PtpCameraAgent: published \(cameraList.count) camera(s), \(jsonData.count) bytes via Darwin state slots")
    }

    // MARK: - Live View Command Handling (extension → agent)

    private func readLiveViewCmdCameraId() -> String? {
        var slot0: UInt64 = 0
        darwin_notify_get_state(lvCmdSlotTokens[0], &slot0)
        let length = Int(slot0 & 0xFFFFFFFF)
        guard length > 0, length <= (kDarwinLiveViewCmdSlotCount - 1) * 8 else { return nil }

        var idData = Data(count: length)
        let slotCount = (length + 7) / 8
        for i in 0..<slotCount {
            var value: UInt64 = 0
            darwin_notify_get_state(lvCmdSlotTokens[i + 1], &value)
            let offset = i * 8
            let chunkSize = min(8, length - offset)
            _ = idData.withUnsafeMutableBytes { ptr in
                memcpy(ptr.baseAddress! + offset, &value, chunkSize)
            }
        }
        return String(data: idData, encoding: .utf8)
    }

    private func handleLiveViewStartCommand() {
        guard let cameraId = readLiveViewCmdCameraId(),
              let camera = cameras[cameraId] else { return }
        AppDelegate.log("PtpCameraAgent: Darwin live view start for \(cameraId)")
        // Read the surface registration directly from slots — the extension always sets them
        // before posting kDarwinLiveViewStart, so the state is already present even if the
        // kDarwinLiveViewSurfaceReady dispatch notification was missed.
        handleSurfaceReady()
        camera.startLiveView()
    }

    private func handleLiveViewStopCommand() {
        guard let cameraId = readLiveViewCmdCameraId(),
              let camera = cameras[cameraId] else { return }
        AppDelegate.log("PtpCameraAgent: Darwin live view stop for \(cameraId)")
        camera.stopLiveView()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        deviceBrowser.stop()
        for camera in cameras.values {
            camera.closeSession()
        }
        try? FileManager.default.removeItem(atPath: kPtpCameraStatePath)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Status Bar Menu

    func rebuildMenu() {
        let menu = NSMenu()

        let allCameras = Array(cameras.values)
        let hasSimulated: Bool
        #if DEBUG
        hasSimulated = !simulatedCameras.isEmpty
        #else
        hasSimulated = false
        #endif

        if allCameras.isEmpty && !hasSimulated {
            let item = NSMenuItem(title: "No Cameras Connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for camera in allCameras {
            addCameraMenu(camera, to: menu)
        }

        #if DEBUG
        for (_, info) in simulatedCameras {
            let name = info["name"] as? String ?? "Simulated Camera"
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let simItem = NSMenuItem(title: "  (simulated — no PTP session)", action: nil, keyEquivalent: "")
            simItem.isEnabled = false
            menu.addItem(simItem)

            let speedMenu = NSMenu()
            for speed in ["slow", "medium", "fast"] {
                let subItem = NSMenuItem(title: speed.capitalized, action: #selector(setStripeSpeed(_:)), keyEquivalent: "")
                subItem.target = self
                subItem.representedObject = speed
                subItem.state = (speed == simulatedStripeSpeed) ? .on : .off
                speedMenu.addItem(subItem)
            }
            let speedItem = NSMenuItem(title: "  Stripe Speed: \(simulatedStripeSpeed.capitalized)", action: nil, keyEquivalent: "")
            speedItem.submenu = speedMenu
            menu.addItem(speedItem)
        }
        #endif

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit PTP Camera Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addCameraMenu(_ camera: PtpCamera, to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let displayName = camera.model ?? camera.name
        let header = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !camera.isSessionOpen {
            let item = NSMenuItem(title: "  Connecting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        if camera.properties.isEmpty {
            let item = NSMenuItem(title: "  Loading properties…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        // Show UI properties in defined order, then remaining known properties
        var shown = Set<UInt32>()
        for propId in camera.currentUiProperties {
            if let info = camera.properties[propId] {
                addPropertyMenuItem(info, camera: camera, to: menu)
                shown.insert(propId)
            }
        }

        let remaining = camera.properties.keys
            .filter { !shown.contains($0) && camera.displayName(forProperty: $0) != nil }
            .sorted()
        if !remaining.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for propId in remaining {
                if let info = camera.properties[propId] {
                    addPropertyMenuItem(info, camera: camera, to: menu)
                }
            }
        }

        if camera.canAutofocus {
            menu.addItem(NSMenuItem.separator())
            let afItem = NSMenuItem(title: "  Autofocus", action: #selector(autofocusAction(_:)), keyEquivalent: "")
            afItem.target = self
            afItem.representedObject = camera
            menu.addItem(afItem)
        }
    }

    private func addPropertyMenuItem(_ info: PtpPropertyInfo, camera: PtpCamera, to menu: NSMenu) {
        let valueStr = camera.formatValue(info.value, forProperty: info.propertyId)
        let displayName = camera.displayName(forProperty: info.propertyId) ?? String(format: "0x%04X", info.propertyId)
        let title = "  \(displayName): \(valueStr)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

        if info.writable, let enumValues = info.range as? [NSNumber], !enumValues.isEmpty {
            let submenu = NSMenu()
            for enumVal in enumValues {
                let valStr = camera.formatValue(enumVal, forProperty: info.propertyId)
                let subItem = NSMenuItem(title: valStr, action: #selector(changePropertyAction(_:)), keyEquivalent: "")
                subItem.target = self
                subItem.representedObject = PropertyChangeInfo(
                    camera: camera, propertyId: info.propertyId, value: enumVal)
                if let currentNum = info.value as? NSNumber, currentNum.isEqual(to: enumVal) {
                    subItem.state = .on
                }
                submenu.addItem(subItem)
            }
            item.submenu = submenu
        } else if info.writable, let rangeDict = info.range as? [String: Any],
                  let rmin = rangeDict["min"] as? NSNumber,
                  let rmax = rangeDict["max"] as? NSNumber,
                  let rstep = rangeDict["step"] as? NSNumber {
            let submenu = NSMenu()
            let stepVal = rstep.doubleValue
            if stepVal > 0 {
                let count = Int((rmax.doubleValue - rmin.doubleValue) / stepVal) + 1
                if count <= 50 {
                    var v = rmin.doubleValue
                    while v <= rmax.doubleValue {
                        let numVal = NSNumber(value: Int32(v))
                        let valStr = camera.formatValue(numVal, forProperty: info.propertyId)
                        let subItem = NSMenuItem(title: valStr, action: #selector(changePropertyAction(_:)), keyEquivalent: "")
                        subItem.target = self
                        subItem.representedObject = PropertyChangeInfo(
                            camera: camera, propertyId: info.propertyId, value: numVal)
                        if let currentNum = info.value as? NSNumber, currentNum.int32Value == numVal.int32Value {
                            subItem.state = .on
                        }
                        submenu.addItem(subItem)
                        v += stepVal
                    }
                    item.submenu = submenu
                }
            }
        }

        menu.addItem(item)
    }

    // MARK: - Menu Actions

    #if DEBUG
    @objc private func setStripeSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? String else { return }
        simulatedStripeSpeed = speed
        publishCameraState()
        rebuildMenu()
    }
    #endif

    @objc private func autofocusAction(_ sender: NSMenuItem) {
        guard let camera = sender.representedObject as? PtpCamera else { return }
        camera.performAutofocus()
    }

    @objc private func changePropertyAction(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? PropertyChangeInfo else { return }
        change.camera.setProperty(change.propertyId, value: change.value)
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        AppDelegate.log("PtpCameraAgent: deviceBrowserDidEnumerateLocalDevices, devices: \(browser.devices?.count ?? 0)")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        AppDelegate.log("PtpCameraAgent: didAdd device: \(device.name ?? "unnamed") type=\(device.type.rawValue)")
        guard let icCamera = device as? ICCameraDevice else { return }

        let cameraId = device.uuidString ?? device.name ?? "unknown"
        AppDelegate.log("PtpCameraAgent: Camera added: \(cameraId) (\(device.name ?? "unnamed"))")

        guard let camera = PtpCamera.cameraForDevice(icCamera, cameraId: cameraId, delegate: self) else {
            AppDelegate.log("PtpCameraAgent: Unsupported camera: \(cameraId)")
            return
        }
        cameras[cameraId] = camera
        camera.openSession()

        publishCameraState()
        rebuildMenu()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let cameraId = device.uuidString ?? device.name ?? "unknown"
        AppDelegate.log("PtpCameraAgent: Camera removed: \(cameraId)")
        cameras.removeValue(forKey: cameraId)
        publishCameraState()
        rebuildMenu()
    }
}

// MARK: - PtpCameraDelegate

extension AppDelegate: PtpCameraDelegate {
    func cameraPropertiesChanged(_ camera: PtpCamera) {
        rebuildMenu()
    }

    func cameraReady(_ camera: PtpCamera) {
        AppDelegate.log("PtpCameraAgent: Camera ready: \(camera.manufacturer ?? "?") \(camera.model ?? "?")")
        rebuildMenu()
    }

    func cameraRemoved(_ camera: PtpCamera) {
        let cameraId = camera.cameraId
        cameras.removeValue(forKey: cameraId)
        remoteSurfaces.removeValue(forKey: cameraId)
        publishCameraState()
        rebuildMenu()
    }

    func cameraReceivedLiveViewJpeg(_ data: Data, camera: PtpCamera) {
        publishLiveViewFrame(data, cameraId: camera.cameraId)
    }

    // MARK: - IOSurface Registration (extension → agent)

    private func handleSurfaceReady() {
        var slot0: UInt64 = 0
        darwin_notify_get_state(lvSurfaceSlotTokens[0], &slot0)
        let surfaceId = IOSurfaceID(slot0 >> 32)
        let cameraIdLength = Int(slot0 & 0xFFFFFFFF)

        guard surfaceId != 0, cameraIdLength > 0,
              cameraIdLength <= (kDarwinLiveViewSurfaceSlotCount - 1) * 8 else {
            AppDelegate.log("PtpCameraAgent: handleSurfaceReady: bad slot0=0x\(String(slot0, radix: 16))")
            return
        }

        var cameraIdData = Data(count: cameraIdLength)
        let slotCount = (cameraIdLength + 7) / 8
        for i in 0..<slotCount {
            var value: UInt64 = 0
            darwin_notify_get_state(lvSurfaceSlotTokens[i + 1], &value)
            let offset = i * 8
            let chunkSize = min(8, cameraIdLength - offset)
            _ = cameraIdData.withUnsafeMutableBytes { ptr in
                memcpy(ptr.baseAddress! + offset, &value, chunkSize)
            }
        }
        guard let cameraId = String(data: cameraIdData, encoding: .utf8) else { return }

        guard let surface = IOSurfaceLookup(surfaceId) else {
            AppDelegate.log("PtpCameraAgent: IOSurfaceLookup failed id=\(surfaceId) cameraId=\(cameraId)")
            return
        }
        remoteSurfaces[cameraId] = surface
        AppDelegate.log("PtpCameraAgent: registered remote IOSurface id=\(surfaceId) for \(cameraId)")
    }

    // MARK: - Live View Frame Publishing via IOSurface (agent draws into extension's surface)

    private func publishLiveViewFrame(_ jpegData: Data, cameraId: String) {
        // We draw into the IOSurface that the extension created and registered with us.
        guard let surface = remoteSurfaces[cameraId] else {
            AppDelegate.log("PtpCameraAgent: publishLiveViewFrame: no surface for \(cameraId) — skipping frame")
            return
        }

        // Decode JPEG to CGImage
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            AppDelegate.log("PtpCameraAgent: JPEG decode failed size=\(jpegData.count)")
            return
        }

        // Draw into the extension's IOSurface (BGRA)
        surface.lock(options: [], seed: nil)
        if let ctx = CGContext(
            data: surface.baseAddress,
            width: surface.width, height: surface.height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: surface.width, height: surface.height))
        }
        surface.unlock(options: [], seed: nil)

        // Notify extension: slot 0 = cameraId length, slots 1-N = cameraId bytes
        let cameraIdData = cameraId.data(using: .utf8) ?? Data()
        darwin_notify_set_state(lvFrameSlotTokens[0], UInt64(cameraIdData.count))
        let slotCount = min((cameraIdData.count + 7) / 8, kDarwinLiveViewFrameSlotCount - 1)
        for i in 0..<slotCount {
            var value: UInt64 = 0
            let offset = i * 8
            let chunkSize = min(8, cameraIdData.count - offset)
            _ = cameraIdData.withUnsafeBytes { buf in
                memcpy(&value, buf.baseAddress! + offset, chunkSize)
            }
            darwin_notify_set_state(lvFrameSlotTokens[i + 1], value)
        }
        darwin_notify_post(kDarwinLiveViewFrame)
    }
}

// MARK: - NSXPCListenerDelegate

extension AppDelegate: NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        AppDelegate.log("PtpCameraAgent: shouldAcceptNewConnection from PID \(newConnection.processIdentifier)")

        let agentInterface = NSXPCInterface(with: PtpCameraAgentProtocol.self)
        newConnection.exportedInterface = agentInterface
        newConnection.exportedObject = self

        let delegateInterface = NSXPCInterface(with: PtpCameraAgentDelegateProtocol.self)
        newConnection.remoteObjectInterface = delegateInterface

        newConnection.invalidationHandler = { [weak self] in
            self?.extensionConnections.removeAll { $0 === newConnection }
            AppDelegate.log("PtpCameraAgent: XPC connection invalidated")
        }

        extensionConnections.append(newConnection)
        newConnection.resume()
        AppDelegate.log("PtpCameraAgent: XPC connection accepted")

        DispatchQueue.main.async {
            guard let proxy = newConnection.remoteObjectProxy as? PtpCameraAgentDelegateProtocol else { return }
            for (cameraId, camera) in self.cameras {
                let info: NSDictionary = [
                    "name": camera.name,
                    "cameraId": cameraId,
                ]
                proxy.cameraConnected(cameraId, info: info)
            }
            #if DEBUG
            for (cameraId, info) in self.simulatedCameras {
                proxy.cameraConnected(cameraId, info: info)
            }
            #endif
        }

        return true
    }
}

// MARK: - PtpCameraAgentProtocol

extension AppDelegate: PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String) {
        DispatchQueue.main.async {
            self.cameras[cameraId]?.startLiveView()
        }
    }

    func stopLiveView(forCamera cameraId: String) {
        DispatchQueue.main.async {
            self.cameras[cameraId]?.stopLiveView()
        }
    }

    func setPropertyValue(_ value: Any, forProperty propertyId: NSNumber, onCamera cameraId: String) {
        logger.info("setProperty \(propertyId) requested for \(cameraId)")
        guard let camera = cameras[cameraId], let numValue = value as? NSNumber else { return }
        camera.setProperty(propertyId.uint32Value, value: numValue)
    }
}

// MARK: - Helper

private class PropertyChangeInfo {
    let camera: PtpCamera
    let propertyId: UInt32
    let value: NSNumber

    init(camera: PtpCamera, propertyId: UInt32, value: NSNumber) {
        self.camera = camera
        self.propertyId = propertyId
        self.value = value
    }
}
