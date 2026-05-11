import Cocoa
import ImageCaptureCore
import os.log
import CoreGraphics
import ImageIO

@main
class AppDelegate: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate {

    private let logger = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "Agent")
    private static let agentLog = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "AgentLog")
    private var deviceBrowser: ICDeviceBrowser!
    private var xpcListener: NSXPCListener!
    private var surfaceXpcListener: NSXPCListener!

    static func log(_ msg: String) {
        agentLog.fault("\(msg, privacy: .public)")
    }

    private var cameras: [String: PtpCamera] = [:]
    private var extensionConnections: [NSXPCConnection] = []
    private var darwinSlotTokens: [Int32] = []
    private var lvFrameSlotTokens: [Int32] = []
    private var lvCmdSlotTokens: [Int32] = []
    private var lvSurfaceSlotTokens: [Int32] = []
    // IOSurfaces created by the agent; extension calls IOSurfaceLookup to access them.
    private var ownedSurfaces: [String: IOSurface] = [:]

    // Keeps slider/grid action holders alive for the lifetime of the current menu.
    private var menuActionHolders: [AnyObject] = []

    // Extension-published camera property state (via Darwin notify slots, multi-page).
    private var propSlotTokens: [Int32] = []
    private var propCmdToken: Int32 = 0
    private var extCameras: [String: ExtCamera] = [:]
    // Page-reassembly state for multi-page property state transfers.
    private var propPageBuffer: Data? = nil
    private var propPageTotal: Int = 0
    private var propPageCount: Int = 0
    private var propNextPage: Int = 0

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
        xpcListener = NSXPCListener(machServiceName: kPtpCameraAgentMachServiceName)
        xpcListener.delegate = self
        xpcListener.resume()
        AppDelegate.log("PtpCameraAgent: XPC listener started on \(kPtpCameraAgentMachServiceName)")

        surfaceXpcListener = NSXPCListener(machServiceName: kPtpSurfaceSharingMachServiceName)
        surfaceXpcListener.delegate = self
        surfaceXpcListener.resume()
        AppDelegate.log("PtpCameraAgent: surface XPC listener started on \(kPtpSurfaceSharingMachServiceName)")

        // ICDeviceBrowser is intentionally NOT started.
        // Starting it causes icdd to claim exclusive USB ownership of PTP cameras,
        // preventing the CMIO extension (user/262) from opening them via IOUSBLib.
        // Camera detection is now done in the extension via IOKit notifications.
        AppDelegate.log("PtpCameraAgent: ICDeviceBrowser disabled (extension owns USB)")

        // USB access coordination: the extension can't kill ptpcamerad (different UID).
        // We do it here (same UID 501) when the extension requests it.
        var needUsbToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinNeedUsbAccess, &needUsbToken, .main) { [weak self] _ in
            self?.handleNeedUsbAccess()
        }
        // Also kill ptpcamerad at startup so the first stream attempt doesn't race.
        handleNeedUsbAccess()

        // Property state slots: extension publishes camera property JSON here.
        propSlotTokens = (0..<kDarwinPropertySlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinPropertySlotPrefix + "\(i)", &token)
            return token
        }
        // Property command slot: agent writes SET_PROP command here before posting kDarwinCameraPropertyCmd.
        darwin_notify_register_check(kDarwinPropertyCmdSlot, &propCmdToken)
        // Subscribe to property state notifications from extension.
        var propStateToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinCameraPropertyState, &propStateToken, .main) { [weak self] _ in
            self?.handlePropertyStateChange()
        }
    }

    // MARK: - USB Access Coordination

    /// Kill ptpcamerad so the CMIO extension (user/262) can open the PTP USB interface.
    /// ptpcamerad (Apple's PTP transport daemon) claims PTP interfaces automatically.
    /// We use sysctl KERN_PROC_ALL + kill() directly — no child-process spawn needed,
    /// which avoids the sandbox restriction that blocked pkill (exit code 3).
    private func handleNeedUsbAccess() {
        let killed = Self.killProcessByName("ptpcamerad")
        AppDelegate.log("PtpCameraAgent: handleNeedUsbAccess killed=\(killed)")
        // Signal extension that USB is ready (small delay for process cleanup).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            darwin_notify_post(kDarwinUsbAccessReady)
        }
    }

    /// Find all processes named `name` and send SIGTERM.  Returns true if ≥1 was found.
    /// Uses sysctl(KERN_PROC_ALL) + kill() — no child-process spawn.
    @discardableResult
    private static func killProcessByName(_ name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 1
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        sysctl(&mib, 4, &procs, &size, nil, 0)

        let count = size / MemoryLayout<kinfo_proc>.stride
        var found = false
        for i in 0..<count {
            var p = procs[i]
            // p_comm is a fixed-width C array (MAXCOMLEN=16 chars)
            let procName = withUnsafeBytes(of: &p.kp_proc.p_comm) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            if procName == name {
                let pid = p.kp_proc.p_pid
                let result = kill(pid, SIGKILL)
                log("PtpCameraAgent: kill(\(name) pid=\(pid)) rc=\(result) errno=\(errno)")
                found = true
            }
        }
        if !found {
            log("PtpCameraAgent: \(name) not found — nothing to kill")
        }
        return found
    }

    // MARK: - Darwin Notify State Publishing

    private func publishCameraState() {
        var cameraList: [[String: String]] = []
        for (cameraId, camera) in cameras {
            cameraList.append(["cameraId": cameraId, "name": camera.name])
        }

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

    // MARK: - Property State (extension → agent)

    private func handlePropertyStateChange() {
        var slot0: UInt64 = 0
        darwin_notify_get_state(propSlotTokens[0], &slot0)
        let totalLength = Int(slot0 >> 32)
        let pageIndex = Int((slot0 >> 16) & 0xFFFF)
        let pageCount = Int(slot0 & 0xFFFF)
        guard totalLength > 0, pageCount > 0, pageIndex < pageCount else { return }

        let pageDataSlots = kDarwinPropertySlotCount - 2  // 1022 data slots per page
        let pageSize = pageDataSlots * 8                   // 8176 bytes per page
        let pageOffset = pageIndex * pageSize
        let pageLength = min(pageSize, totalLength - pageOffset)
        guard pageLength > 0 else { return }

        // Start fresh buffer on page 0 or unexpected state.
        if pageIndex == 0 || propPageBuffer == nil || propPageTotal != totalLength {
            propPageBuffer = Data(count: totalLength)
            propPageTotal = totalLength
            propPageCount = pageCount
            propNextPage = 0
        }

        guard var buffer = propPageBuffer,
              pageIndex == propNextPage else {
            AppDelegate.log("PtpCameraAgent: property state page \(pageIndex) out of order (expected \(propNextPage)), resetting")
            propPageBuffer = nil
            return
        }

        // Read data slots into the correct position in the buffer.
        buffer.withUnsafeMutableBytes { ptr in
            for i in 0..<((pageLength + 7) / 8) {
                var value: UInt64 = 0
                darwin_notify_get_state(propSlotTokens[i + 1], &value)
                let chunkOffset = pageOffset + i * 8
                let chunkSize = min(8, totalLength - chunkOffset)
                if chunkSize > 0 { memcpy(ptr.baseAddress! + chunkOffset, &value, chunkSize) }
            }
        }
        propPageBuffer = buffer

        // Verify checksum for this page.
        var csValue: UInt64 = 0
        darwin_notify_get_state(propSlotTokens[kDarwinPropertySlotCount - 1], &csValue)
        let expectedChecksum = UInt32(csValue & 0xFFFFFFFF)
        var computedChecksum: UInt32 = 0
        for byte in buffer[pageOffset..<(pageOffset + pageLength)] {
            computedChecksum = computedChecksum &+ UInt32(byte)
        }
        guard computedChecksum == expectedChecksum else {
            AppDelegate.log("PtpCameraAgent: property state page \(pageIndex) checksum mismatch (\(computedChecksum) != \(expectedChecksum)), resetting")
            propPageBuffer = nil
            return
        }

        propNextPage += 1

        if propNextPage == pageCount {
            let completeData = propPageBuffer!
            propPageBuffer = nil
            processPropertyStateJson(completeData)
        }
    }

    private func processPropertyStateJson(_ jsonData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let cameraId = json["id"] as? String,
              let propsList = json["props"] as? [[String: Any]] else { return }

        if let removed = json["disconnected"] as? Bool, removed {
            extCameras.removeValue(forKey: cameraId)
            AppDelegate.log("PtpCameraAgent: camera removed from menu: \(cameraId)")
            rebuildMenu()
            return
        }

        var properties: [UInt32: ExtCameraProperty] = [:]
        var orderedIds: [UInt32] = []

        for entry in propsList {
            guard let propId = (entry["i"] as? Int).map({ UInt32($0) }),
                  let dataType = (entry["dt"] as? Int).map({ UInt16($0) }),
                  let writable = (entry["w"] as? Int).map({ $0 != 0 }),
                  let value = entry["v"] as? NSNumber else { continue }
            let enumValues = (entry["e"] as? [NSNumber])
            var rangeMin: NSNumber?; var rangeMax: NSNumber?; var rangeStep: NSNumber?
            if let r = entry["r"] as? [String: NSNumber] {
                rangeMin = r["min"]; rangeMax = r["max"]; rangeStep = r["step"]
            }
            let prop = ExtCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: value, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep)
            properties[propId] = prop
            orderedIds.append(propId)
        }

        let name = (json["name"] as? String) ?? extCameras[cameraId]?.name ?? "PTP Camera"
        extCameras[cameraId] = ExtCamera(cameraId: cameraId, name: name,
                                         properties: properties, orderedPropertyIds: orderedIds)
        AppDelegate.log("PtpCameraAgent: property state updated for \(cameraId) (\(properties.count) properties)")
        rebuildMenu()
    }

    // MARK: - Property Command (agent → extension)

    private func postPropertyCommand(propId: UInt32, value: NSNumber) {
        let packed: UInt64 = (UInt64(3) << 56) | (UInt64(propId) << 32) | UInt64(value.uint32Value)
        darwin_notify_set_state(propCmdToken, packed)
        darwin_notify_post(kDarwinCameraPropertyCmd)
        AppDelegate.log("PtpCameraAgent: posted SET_PROP 0x\(String(propId, radix:16)) = \(value)")
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
        // Surface arrives via XPC (SurfaceSharingProtocol.receiveSurface).
        // Frames are dropped in publishLiveViewFrame until the surface is registered.
        camera.startLiveView()
    }

    private func handleLiveViewStopCommand() {
        guard let cameraId = readLiveViewCmdCameraId(),
              let camera = cameras[cameraId] else { return }
        AppDelegate.log("PtpCameraAgent: Darwin live view stop for \(cameraId)")
        camera.stopLiveView()
        ownedSurfaces.removeValue(forKey: cameraId)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        deviceBrowser?.stop()
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
        menuActionHolders = []
        let menu = NSMenu()

        let allCameras = Array(cameras.values)
        let hasExtCameras = !extCameras.isEmpty
        if allCameras.isEmpty && !hasExtCameras {
            let item = NSMenuItem(title: "No Cameras Connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for camera in allCameras {
            addCameraMenu(camera, to: menu)
        }

        for camera in extCameras.values {
            addExtCameraMenu(camera, to: menu)
        }

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

    private func addExtCameraMenu(_ camera: ExtCamera, to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        let header = NSMenuItem(title: camera.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let previewItem = NSMenuItem(title: "  Preview Video Stream…",
                                     action: #selector(showPreviewAction(_:)),
                                     keyEquivalent: "")
        previewItem.target = self
        previewItem.representedObject = camera.cameraId
        menu.addItem(previewItem)

        if camera.properties.isEmpty {
            let item = NSMenuItem(title: "  Loading properties…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        // Curated ordered list matching old DAL plugin uiPtpProperties for Nikon.
        // nil entries become separators (deferred so trailing/double separators are skipped).
        // WB tune sub-properties (0xD017–0xD150) are NOT listed here — they appear as
        // sub-menus inside the WB mode value items instead.
        let nikonUiList: [UInt32?] = [
            0x5001,   // Battery Level
            0x5008,   // Focal Length
            0xD1A6,   // LiveView Selector
            0xD1A2,   // LiveView Status
            nil,
            0x500E,   // Exposure Mode
            0x5007,   // Aperture
            0xD1A9,   // Movie Aperture
            0x500F,   // ISO
            0xD054,   // Auto ISO
            0xD100,   // Shutter Speed
            0xD1A8,   // Movie Shutter Speed
            0x5005,   // White Balance
            0x5010,   // Exposure Bias
            0xD1AB,   // Movie Exposure Bias
            0xD061,   // AF Mode
            0xD05D,   // AF Area Mode
            0xD1A3,   // LiveView Zoom
            0xD1A0,   // LiveView AF Mirror Mode
            0xD1A5,   // Exposure Preview
            0xD17B,   // Exposure Preview (apply settings)
            0xD1AC,   // Live Image Size
        ]

        // Still/video mode filtering (matches currentUiPtpProperties in old Nikon DAL plugin).
        let movieOnlyProps: Set<UInt32> = [0xD1A9, 0xD1A8, 0xD1AB]
        let stillOnlyProps: Set<UInt32> = [0x5007, 0xD100, 0x5010]
        var inVideoMode: Bool? = nil
        if let lvSelector = camera.properties[0xD1A6] {
            inVideoMode = lvSelector.value.uint32Value == 1
        }

        var pendingSeparator = false
        var addedAny = false

        for entry in nikonUiList {
            guard let propId = entry else {
                if addedAny { pendingSeparator = true }
                continue
            }
            guard let prop = camera.properties[propId] else { continue }

            if let videoMode = inVideoMode {
                if videoMode && stillOnlyProps.contains(propId) { continue }
                if !videoMode && movieOnlyProps.contains(propId) { continue }
            }

            if pendingSeparator { menu.addItem(NSMenuItem.separator()); pendingSeparator = false }
            addedAny = true

            let displayName = extPropDisplayNames[propId] ?? String(format: "0x%04X", propId)
            let valueStr = formatExtPropValue(prop)
            let item = NSMenuItem(title: "  \(displayName): \(valueStr)", action: nil, keyEquivalent: "")
            item.submenu = buildExtPropSubmenu(prop, propId: propId, camera: camera)
            menu.addItem(item)
        }
    }

    // Build the appropriate submenu for a writable ext-camera property.
    // Priority: grid (WB tune) → enum (with optional WB sub-props) → slider (range, no enum).
    private func buildExtPropSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                     camera: ExtCamera) -> NSMenu? {
        guard prop.writable else { return nil }

        // Grid view for WB fine-tune matrix properties.
        if nikonWbTuneIds.contains(propId),
           let rMin = prop.rangeMin, let rMax = prop.rangeMax {
            return buildWbTuneGridSubmenu(prop, propId: propId, cameraId: camera.cameraId,
                                         rangeMin: rMin.intValue, rangeMax: rMax.intValue)
        }

        // Enum list (discrete values).
        if let enumValues = prop.enumValues, !enumValues.isEmpty {
            let submenu = NSMenu()
            for enumVal in enumValues {
                let valStr = formatExtPropRaw(enumVal, propId: propId)
                let subItem = NSMenuItem(title: valStr,
                                        action: #selector(changePropertyAction(_:)),
                                        keyEquivalent: "")
                subItem.target = self
                subItem.representedObject = ExtPropertyChangeInfo(
                    cameraId: camera.cameraId, propertyId: propId, value: enumVal)
                if prop.value == enumVal { subItem.state = .on }

                // Attach WB sub-properties (tune grid / color-temp) to each WB mode value.
                if propId == 0x5005,
                   let subPropIds = nikonWbSubProperties[enumVal.uint32Value] {
                    let subPropMenu = NSMenu()
                    for subId in subPropIds {
                        guard let subProp = camera.properties[subId] else { continue }
                        let subName = extPropDisplayNames[subId] ?? String(format: "0x%04X", subId)
                        let subVal  = formatExtPropValue(subProp)
                        let subItem2 = NSMenuItem(title: "\(subName): \(subVal)",
                                                  action: nil, keyEquivalent: "")
                        subItem2.submenu = buildExtPropSubmenu(subProp, propId: subId,
                                                               camera: camera)
                        subPropMenu.addItem(subItem2)
                    }
                    if subPropMenu.numberOfItems > 0 { subItem.submenu = subPropMenu }
                }

                submenu.addItem(subItem)
            }
            return submenu
        }

        // Slider for range-only properties (too many steps for a discrete list).
        if let rMin = prop.rangeMin, let rMax = prop.rangeMax, let rStep = prop.rangeStep,
           rStep.doubleValue > 0 {
            return buildSliderSubmenu(prop, propId: propId, cameraId: camera.cameraId,
                                     rMin: rMin.doubleValue, rMax: rMax.doubleValue,
                                     rStep: rStep.doubleValue)
        }

        return nil
    }

    // NSMenuItem containing a WbTuneGridView.
    private func buildWbTuneGridSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                        cameraId: String, rangeMin: Int, rangeMax: Int) -> NSMenu {
        let size = WbTuneGridView.idealSize(gridSize: 13)
        let grid = WbTuneGridView(frame: NSRect(origin: .zero, size: size))
        grid.gridSize  = 13
        grid.rangeMin  = rangeMin
        grid.rangeMax  = rangeMax
        grid.currentValue = prop.value.intValue
        grid.onValueSelected = { [weak self] val in
            self?.postPropertyCommand(propId: propId, value: NSNumber(value: val))
        }
        let gridItem = NSMenuItem()
        gridItem.view = grid
        let submenu = NSMenu()
        submenu.addItem(gridItem)
        return submenu
    }

    // NSMenuItem containing an NSSlider (fires only on mouse-up, not continuously).
    private func buildSliderSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                    cameraId: String,
                                    rMin: Double, rMax: Double, rStep: Double) -> NSMenu {
        let holder = SliderActionHolder(propId: propId, rangeMin: rMin, rangeStep: rStep) {
            [weak self] val in self?.postPropertyCommand(propId: propId, value: NSNumber(value: val))
        }
        menuActionHolders.append(holder)

        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 160, height: 16))
        slider.minValue    = rMin
        slider.maxValue    = rMax
        slider.doubleValue = prop.value.doubleValue
        slider.isContinuous = false
        slider.target = holder
        slider.action = #selector(SliderActionHolder.sliderChanged(_:))

        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        let submenu = NSMenu()
        submenu.addItem(sliderItem)
        return submenu
    }

    private func formatExtPropValue(_ prop: ExtCameraProperty) -> String {
        formatExtPropRaw(prop.value, propId: prop.propertyId)
    }

    private func formatNikonShutterSpeed(_ val: UInt32) -> String {
        let nom = UInt16(val >> 16)
        let den = UInt16(val & 0xFFFF)
        if val == 0xFFFFFFFF { return "Bulb" }
        if val == 0xFFFFFFFE { return "Flash" }
        if den == 10 && nom != 1 {
            let secs = 0.1 * Double(nom)
            return secs == Double(Int(secs)) ? "\(Int(secs))\"" : String(format: "%.1f\"", secs)
        } else if nom == 10 && den != 1 {
            let fps = 0.1 * Double(den)
            return fps == Double(Int(fps)) ? "1/\(Int(fps))" : String(format: "1/%.0f", fps)
        } else if den > 1 {
            return "\(nom)/\(den)"
        } else {
            return "\(nom)\""
        }
    }

    private func formatExtPropRaw(_ value: NSNumber, propId: UInt32) -> String {
        if let name = nikonExtPropValueNames[propId]?[value.uint32Value] { return name }
        switch propId {
        case 0x5001:         return "\(value.intValue)%"
        case 0x5007, 0xD1A9: return String(format: "f/%.1f", Double(value.intValue) * 0.01)
        case 0x5008:         return String(format: "%.1f mm", Double(value.intValue) * 0.01)
        case 0x500F:         return "ISO \(value.intValue)"
        case 0xD100, 0xD1A8: return formatNikonShutterSpeed(value.uint32Value)
        case 0x5010, 0xD1AB: return String(format: "%+.1f EV", Double(value.intValue) * 0.001)
        case 0xD01E:         return "\(value.intValue) K"
        case 0xD1A2, 0xD1A5, 0xD17B: return value.boolValue ? "On" : "Off"
        // WB tuning: signed int, range typically -3…+3
        case 0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D,
             0xD150, 0xD212, 0xD213, 0xD215, 0xD216, 0xD218, 0xD219, 0xD21B:
            return value.intValue >= 0 ? "+\(value.intValue)" : "\(value.intValue)"
        default:             return "\(value)"
        }
    }

    // MARK: - Menu Actions

    @objc private func autofocusAction(_ sender: NSMenuItem) {
        guard let camera = sender.representedObject as? PtpCamera else { return }
        camera.performAutofocus()
    }

    @objc private func changePropertyAction(_ sender: NSMenuItem) {
        if let change = sender.representedObject as? PropertyChangeInfo {
            change.camera.setProperty(change.propertyId, value: change.value)
        } else if let change = sender.representedObject as? ExtPropertyChangeInfo {
            postPropertyCommand(propId: change.propertyId, value: change.value)
        }
    }

    @objc private func showPreviewAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String,
              let camera = extCameras[cameraId],
              let encodedName = camera.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "ptpwebcam://preview?name=\(encodedName)") else { return }
        NSWorkspace.shared.open(url)
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
        // Do NOT open a PTP session here. The CMIO extension opens the USB interface directly
        // via IOUSBHost (user/262 bootstrap). If we also called openSession(), icdd would hold
        // the USB interface exclusively and the extension's IOUSBHostInterface init would fail.
        // The agent's role is detection + state publication only; live view is extension-owned.

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
        ownedSurfaces.removeValue(forKey: cameraId)
        publishCameraState()
        rebuildMenu()
    }

    func cameraReceivedLiveViewJpeg(_ data: Data, camera: PtpCamera) {
        publishLiveViewFrame(data, cameraId: camera.cameraId)
    }

    // MARK: - Live View via IOSurface
    //
    // Extension creates an IOSurface (1920×1080 BGRA) and sends it to the agent via XPC
    // (SurfaceSharingProtocol.receiveSurface — transfers the Mach send right, bypassing
    // the cross-UID IOSurfaceLookup restriction).
    // Agent draws each incoming JPEG into the surface and posts kDarwinLiveViewFrame.
    // Extension wraps the same surface in a CVPixelBuffer and sends it to CMIO.

    private func publishLiveViewFrame(_ jpegData: Data, cameraId: String) {
        guard let surface = ownedSurfaces[cameraId] else {
            AppDelegate.log("PtpCameraAgent: no surface for \(cameraId) — skipping frame")
            return
        }

        // Decode JPEG → CGImage.
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            AppDelegate.log("PtpCameraAgent: JPEG decode failed size=\(jpegData.count)")
            return
        }

        surface.lock(options: [], seed: nil)
        let w = surface.width
        let h = surface.height
        let bpr = surface.bytesPerRow
        let baseAddr = surface.baseAddress
        let ctxOk: Bool
        if let ctx = CGContext(
            data: baseAddr,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctxOk = true
        } else {
            AppDelegate.log("PtpCameraAgent: CGContext init failed w=\(w) h=\(h) bpr=\(bpr)")
            ctxOk = false
        }
        surface.unlock(options: [], seed: nil)
        guard ctxOk else { return }

        // Signal extension to consume the frame.
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
        AppDelegate.log("PtpCameraAgent: shouldAcceptNewConnection on \(listener === surfaceXpcListener ? "surface" : "main") listener from PID \(newConnection.processIdentifier)")

        if listener === surfaceXpcListener {
            // Surface-sharing connection: extension sends us its IOSurface via Mach send right.
            let surfaceInterface = NSXPCInterface(with: SurfaceSharingProtocol.self)
            surfaceInterface.setClasses(
                NSSet(object: IOSurface.self as AnyObject) as! Set<AnyHashable>,
                for: #selector(SurfaceSharingProtocol.receiveSurface(_:cameraId:reply:)),
                argumentIndex: 0,
                ofReply: false
            )
            newConnection.exportedInterface = surfaceInterface
            newConnection.exportedObject = self
            newConnection.invalidationHandler = {
                AppDelegate.log("PtpCameraAgent: surface XPC connection invalidated")
            }
            newConnection.resume()
            return true
        }

        // Main agent connection.
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
        }

        return true
    }
}

// MARK: - SurfaceSharingProtocol

extension AppDelegate: SurfaceSharingProtocol {
    func receiveSurface(_ surface: IOSurface, cameraId: String, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.ownedSurfaces[cameraId] = surface
            AppDelegate.log("PtpCameraAgent: received IOSurface via XPC size=\(surface.width)×\(surface.height) for \(cameraId)")
            reply(true)
        }
    }

    func requestSurface(cameraId: String, reply: @escaping (IOSurface?) -> Void) {
        reply(nil) // not used
    }
}

// MARK: - PtpCameraAgentProtocol

extension AppDelegate: PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String) {
        DispatchQueue.main.async {
            AppDelegate.log("PtpCameraAgent: XPC startLiveView for \(cameraId)")
            self.cameras[cameraId]?.startLiveView()
        }
    }

    func stopLiveView(forCamera cameraId: String) {
        DispatchQueue.main.async {
            AppDelegate.log("PtpCameraAgent: XPC stopLiveView for \(cameraId)")
            self.cameras[cameraId]?.stopLiveView()
            self.ownedSurfaces.removeValue(forKey: cameraId)
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

// MARK: - Extension-published camera types

struct ExtCameraProperty {
    let propertyId: UInt32
    let dataType: UInt16
    let writable: Bool
    let value: NSNumber
    let enumValues: [NSNumber]?
    let rangeMin: NSNumber?
    let rangeMax: NSNumber?
    let rangeStep: NSNumber?
}

struct ExtCamera {
    let cameraId: String
    let name: String
    var properties: [UInt32: ExtCameraProperty]
    let orderedPropertyIds: [UInt32]
}

private class ExtPropertyChangeInfo {
    let cameraId: String
    let propertyId: UInt32
    let value: NSNumber

    init(cameraId: String, propertyId: UInt32, value: NSNumber) {
        self.cameraId = cameraId
        self.propertyId = propertyId
        self.value = value
    }
}

// Keeps a slider's action alive for the duration of the menu.
private class SliderActionHolder: NSObject {
    let propId: UInt32
    let rangeMin: Double
    let rangeStep: Double
    let callback: (Double) -> Void

    init(propId: UInt32, rangeMin: Double, rangeStep: Double, callback: @escaping (Double) -> Void) {
        self.propId = propId; self.rangeMin = rangeMin
        self.rangeStep = rangeStep; self.callback = callback
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let step = rangeStep > 0 ? rangeStep : 1
        let snapped = rangeMin + floor((sender.doubleValue - rangeMin) / step) * step
        callback(snapped)
    }
}

// WB tune property IDs that get a grid view instead of an enum list.
private let nikonWbTuneIds: Set<UInt32> = [
    0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D,
    0xD150, 0xD212, 0xD213, 0xD215, 0xD216, 0xD218, 0xD219, 0xD21B,
]

// WB mode value → list of sub-property IDs shown below that value's menu item.
// Mirrors PtpCameraNikon.uiPtpSubProperties.
private let nikonWbSubProperties: [UInt32: [UInt32]] = [
    0x0002: [0xD017, 0xD141],  // Auto          → WB Auto Tune + WB Auto Type
    0x0004: [0xD01A],          // Daylight       → WB Sunny Tune
    0x0005: [0xD019, 0xD14F],  // Fluorescent    → WB Fluorescent Tune + Fluorescent Type
    0x0006: [0xD018],          // Tungsten       → WB Incandescent Tune
    0x0007: [0xD01B],          // Flash          → WB Flash Tune
    0x8010: [0xD01C],          // Cloudy         → WB Cloudy Tune
    0x8011: [0xD01D],          // Shade          → WB Shade Tune
    0x8012: [0xD01E, 0xD150],  // Color Temp     → WB Color Temperature + Color Temp Tune
]

private let extPropDisplayNames: [UInt32: String] = [
    // PTP standard (0x5xxx)
    0x5001: "Battery Level",
    0x5002: "Functional Mode",
    0x5003: "Image Size",
    0x5004: "Compression Setting",
    0x5005: "White Balance",
    0x5006: "RGB Gain",
    0x5007: "Aperture",
    0x5008: "Focal Length",
    0x5009: "Focus Distance",
    0x500A: "Focus Mode",
    0x500B: "Metering Mode",
    0x500C: "Flash Mode",
    0x500D: "Exposure Time",
    0x500E: "Exposure Mode",
    0x500F: "ISO",
    0x5010: "Exposure Bias",
    0x5011: "Date/Time",
    0x5012: "Capture Delay",
    0x5013: "Burst Count",
    0x5014: "Burst Interval",
    0x5015: "Timelapse Count",
    0x5016: "Timelapse Interval",
    0x5017: "Focus Metering Mode",
    0x5018: "Upload URL",
    0x5019: "Artist",
    0x501A: "Copyright Info",
    0x501B: "Supported Streams",
    0x501C: "Enabled Streams",
    0x501D: "Video Format",
    0x501E: "Video Resolution",
    0x501F: "Video Quality",
    0x5020: "Video Frame Rate",
    0x5021: "Video Contrast",
    0x5022: "Video Brightness",
    // Nikon vendor (0xDxxx) — from PtpCameraNikon.propertyNames
    0xD017: "WB Auto Tune",
    0xD018: "WB Incandescent Tune",
    0xD019: "WB Fluorescent Tune",
    0xD01A: "WB Sunny Tune",
    0xD01B: "WB Flash Tune",
    0xD01C: "WB Cloudy Tune",
    0xD01D: "WB Shade Tune",
    0xD01E: "WB Color Temperature",
    0xD023: "Flash Exposure Comp",
    0xD028: "Bracketing",
    0xD029: "Auto Bracket Order",
    0xD02A: "Auto Bracket Selection",
    0xD02B: "Bracket Count",
    0xD02C: "Bracket Increment",
    0xD054: "Auto ISO",
    0xD05D: "AF Area Mode",
    0xD061: "AF Mode",
    0xD0C0: "Flash Sign",
    0xD0C3: "ISO Auto Time",
    0xD0C4: "Tune AF",
    0xD0C5: "Tone Comp",
    0xD0C7: "Movie ISO Auto",
    0xD100: "Shutter Speed",
    0xD101: "Max Aperture",
    0xD102: "Color Model",
    0xD103: "Auto DX Crop",
    0xD104: "Scene Mode",
    0xD105: "Vibration Reduction",
    0xD108: "AF Assist",
    0xD109: "CF Card Status",
    0xD10A: "SD Card Status",
    0xD10B: "Recording Media",
    0xD10D: "AF Lock",
    0xD10E: "Active D-Lighting",
    0xD10F: "Picture Control",
    0xD110: "Picture Control Data",
    0xD120: "Image Area",
    0xD121: "Shutter Count",
    0xD122: "Auto AF Area",
    0xD130: "Flash Mode Manual Power",
    0xD131: "Flash Mode Commander",
    0xD135: "Bracketing Mode",
    0xD136: "Bracketing Order",
    0xD140: "Flash Commander Mode",
    0xD141: "WB Auto Type",
    0xD142: "WB Auto Kelvin",
    0xD14F: "WB Fluorescent Type",
    0xD150: "WB Color Temp Tune",
    0xD153: "Long Exp NR",
    0xD154: "High ISO NR",
    0xD155: "Distortion Control",
    0xD156: "Vignette Control",
    0xD157: "Auto Distortion",
    0xD160: "Movie Quality",
    0xD161: "Movie Size",
    0xD162: "Movie Frame Rate",
    0xD163: "Movie Wind Filter",
    0xD164: "Movie ISO Auto",
    0xD165: "Movie Metering",
    0xD166: "Movie VR",
    0xD167: "Movie Time Remaining",
    0xD168: "Record Button",
    0xD169: "Live View WB",
    0xD16A: "Movie Manual Movie ISO",
    0xD16C: "Movie Recording Dest",
    0xD16E: "Movie HDMI Output Size",
    0xD170: "Movie Sound Recording",
    0xD171: "Movie Microphone Sens",
    0xD173: "Movie Headphone Volume",
    0xD174: "Movie Wind Screen",
    0xD17B: "Exposure Preview",
    0xD17C: "Flash Rating",
    0xD17D: "Movie VR Mode",
    0xD1A0: "LiveView AF Mirror Mode",
    0xD1A2: "LiveView Status",
    0xD1A3: "LiveView Zoom",
    0xD1A4: "LV Prohibit Condition",
    0xD1A5: "Exposure Preview",
    0xD1A6: "LiveView Selector",
    0xD1A7: "Movie Rec Mode",
    0xD1A8: "Movie Shutter Speed",
    0xD1A9: "Movie Aperture",
    0xD1AB: "Movie Exposure Bias",
    0xD1AC: "Live Image Size",
    0xD1AD: "Save Media",
    0xD200: "Flash Sync Speed",
    0xD201: "Flash Shutter Speed",
    0xD212: "Movie WB Auto Tune",
    0xD213: "Movie WB Incandescent Tune",
    0xD215: "Movie WB Fluorescent Tune",
    0xD216: "Movie WB Sunny Tune",
    0xD218: "Movie WB Cloudy Tune",
    0xD219: "Movie WB Shade Tune",
    0xD21B: "Movie WB Color Temp Tune",
]

// Enum value → human-readable string for Nikon UI properties.
private let nikonExtPropValueNames: [UInt32: [UInt32: String]] = [
    0x500E: [  // Exposure Mode (PTP standard + Nikon scene modes)
        0x0001: "Manual (M)", 0x0002: "Program (P)",
        0x0003: "Aperture (A)", 0x0004: "Shutter (S)",
        0x8010: "Auto", 0x8011: "Portrait", 0x8012: "Landscape",
        0x8013: "Close-up", 0x8014: "Sports", 0x8015: "Night Portrait",
        0x8016: "Flash Off", 0x8017: "Child", 0x8018: "Scene",
        0x8019: "Effects", 0x8050: "U1", 0x8051: "U2", 0x8052: "U3",
    ],
    0x5005: [  // White Balance (PTP standard + Nikon extras)
        0x0001: "Manual", 0x0002: "Auto", 0x0003: "One-Push Auto",
        0x0004: "Daylight", 0x0005: "Fluorescent", 0x0006: "Tungsten", 0x0007: "Flash",
        0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Color Temperature",
        0x8013: "Preset", 0x8014: "Off", 0x8016: "Natural Light Auto",
    ],
    0x500A: [  // Focus Mode
        0x0001: "Manual", 0x0002: "Auto", 0x0003: "Auto Macro",
        0x8010: "[S] Single", 0x8011: "[C] Continuous",
        0x8012: "[A] Automatic", 0x8013: "[F] Constant",
    ],
    0x500B: [  // Metering Mode
        0x0001: "Average", 0x0002: "Center-weighted",
        0x0003: "Multi-spot", 0x0004: "Center-spot",
    ],
    0xD054: [  // Auto ISO
        0x0000: "Off", 0x0001: "On",
    ],
    0xD1A5: [  // Exposure Preview
        0x0000: "Off", 0x0001: "On",
    ],
    0xD17B: [  // Exposure Preview (apply settings)
        0x0000: "Off", 0x0001: "On",
    ],
    0xD10B: [  // Recording Media
        0x0000: "Card", 0x0001: "SDRAM", 0x0002: "Card + SDRAM",
    ],
    0xD141: [  // WB Auto Type
        0x0000: "Standard", 0x0001: "Incandescent",
    ],
    0xD14F: [  // WB Fluorescent Type
        0x0000: "Sodium Mixed", 0x0001: "Cool White",
        0x0002: "Warm White", 0x0003: "White",
        0x0004: "Day White", 0x0005: "Daylight",
        0x0006: "High Color Temp Mercury",
    ],
    0xD1A0: [  // LV Mirror Mode
        0x0000: "Mirror Down (AF)", 0x0001: "Mirror Up (AF)",
    ],
    0xD1A6: [  // LV Selector
        0x0000: "Still", 0x0001: "Movie",
    ],
    0xD061: [  // LV AF Mode
        0x0000: "Single (S)", 0x0001: "Constant (F)",
        0x0002: "Continuous (C)", 0x0003: "Manual Lens", 0x0004: "Manual",
    ],
    0xD05D: [  // LV AF Area Mode
        0x0000: "Face Detect", 0x0001: "Wide Area",
        0x0002: "Normal Area", 0x0003: "Target Tracking",
    ],
    0xD1AC: [  // LV Image Size
        0x0000: "Undefined", 0x0001: "QVGA (320×240)",
        0x0002: "VGA (640×480)", 0x0003: "XGA (1024×768)",
    ],
]
