import Cocoa
import ImageCaptureCore
import os.log
import CoreGraphics
import ImageIO

@main
class AppDelegate: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate, NSMenuDelegate {

    // While the status-bar menu is open we must NOT call `statusItem.menu = …`
    // (which is what rebuildMenu does) — reassigning the menu collapses it,
    // killing the Sony +/- stepper interaction mid-click. So when a property-
    // state update arrives during this window we just refresh the model and
    // set `rebuildPending`; `menuDidClose` flushes it.
    private var isStatusMenuOpen = false
    private var rebuildPending   = false

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

    private var extCameras: [String: ExtCamera] = [:]

    private var claimedCameraKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "claimedCameraKeys") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "claimedCameraKeys") }
    }

    /// Per-camera remembered property values. Map key is
    /// "<claimKey>:<propIdHex>" → UInt32 value. Currently used to persist the
    /// chosen live-view stream resolution per Nikon body, so picking 1024×768
    /// once survives reconnects (the default 640×480 would otherwise come
    /// back every plug). Storage is a flat `[String: NSNumber]` dict in
    /// UserDefaults — keep the schema simple so a future "forget settings"
    /// menu can clear it without migrations.
    private var stickyPropertyValues: [String: UInt32] {
        get {
            let dict = UserDefaults.standard.dictionary(forKey: "stickyPropertyValues") ?? [:]
            var result: [String: UInt32] = [:]
            for (k, v) in dict { if let n = v as? NSNumber { result[k] = n.uint32Value } }
            return result
        }
        set {
            let dict = newValue.mapValues { NSNumber(value: $0) }
            UserDefaults.standard.set(dict, forKey: "stickyPropertyValues")
        }
    }

    /// Property IDs that should be persisted across reconnects, per vendor.
    /// Right now only Nikon's "Live Image Size" (0xD1AC) — the camera resets
    /// to its default (often 640×480) on every fresh PTP session, so without
    /// this the user has to repick their preferred resolution every plug.
    /// Extend the set as we identify more "remember-the-last-pick" properties.
    private static let stickyPropIds: [CameraVendor: Set<UInt32>] = [
        .nikon: [0xD1AC],   // LV Image Size
    ]

    private static func stickyKey(_ claimKey: String, _ propId: UInt32) -> String {
        String(format: "%@:%04x", claimKey, propId)
    }

    /// True if `propId` is in the sticky list for this vendor.
    private static func isStickyProperty(propId: UInt32, vendor: CameraVendor) -> Bool {
        stickyPropIds[vendor]?.contains(propId) ?? false
    }

    /// Cameras for which we've already replayed sticky values during this
    /// process lifetime. Prevents re-firing SET commands every time the
    /// extension republishes property state (post-set, or via the
    /// kDarwinCameraStateRepublish handshake).
    private var stickyApplied: Set<String> = []
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
        // We do it here (same UID 501) when the extension requests it (at stream start only).
        var needUsbToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinNeedUsbAccess, &needUsbToken, .main) { [weak self] _ in
            self?.handleNeedUsbAccess()
        }

        // Property state slots: extension publishes camera property JSON here.
        propSlotTokens = (0..<kDarwinPropertySlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinPropertySlotPrefix + "\(i)", &token)
            return token
        }
        // Per-camera claim and property-command channels are registered on-the-fly
        // in sendClaimCommand / postPropertyCommand (same vid.pid.crc suffix scheme).
        // Subscribe to property state notifications from extension.
        var propStateToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinCameraPropertyState, &propStateToken, .main) { [weak self] _ in
            self?.handlePropertyStateChange()
        }

        // Darwin notify posts are NOT replayed for subscribers that weren't
        // running when the post fired. After a fresh launch (launchd
        // respawn, reinstall, user-cycled camera causing agent restart),
        // we'd have no record of currently-connected cameras until the next
        // attach event. Ask the extension to republish everything it knows.
        // Tiny delay so the extension's dispatch handler is wired up before
        // we fire — both processes register on .main and the agent might
        // have come up before the extension dispatched its registration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            darwin_notify_post(kDarwinCameraStateRepublish)
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
            // Re-arm sticky-replay for this cameraId — if it reconnects later
            // (or under a fresh IOKit registry entry id), we want to replay
            // saved values again.
            stickyApplied.remove(cameraId)
            AppDelegate.log("PtpCameraAgent: camera removed from menu: \(cameraId)")
            rebuildMenu()
            return
        }

        // Build stable claim key from VID:PID:serial.
        let vid    = (json["vid"]    as? UInt16) ?? (json["vid"] as? Int).map { UInt16($0) } ?? 0
        let pid    = (json["pid"]    as? UInt16) ?? (json["pid"] as? Int).map { UInt16($0) } ?? 0
        let serial = (json["serial"] as? String) ?? ""
        let claimKey = serial.isEmpty
            ? String(format: "%04x:%04x", vid, pid)
            : String(format: "%04x:%04x:%@", vid, pid, serial)

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
            let incremental = (entry["inc"] as? Int) == 1
            let isButton    = (entry["btn"] as? Int) == 1
            let prop = ExtCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: value, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
                incremental: incremental, isButton: isButton)
            properties[propId] = prop
            orderedIds.append(propId)
        }

        let name = (json["name"] as? String) ?? extCameras[cameraId]?.name ?? "PTP Camera"
        let vendor: CameraVendor
        switch vid {
        case 0x04B0: vendor = .nikon
        case 0x054C: vendor = .sony
        case 0x04A9: vendor = .canon
        default:     vendor = .unknown
        }
        extCameras[cameraId] = ExtCamera(cameraId: cameraId, name: name, claimKey: claimKey,
                                         vid: vid, pid: pid, serial: serial,
                                         properties: properties, orderedPropertyIds: orderedIds,
                                         vendor: vendor)
        AppDelegate.log("PtpCameraAgent: property state for \(cameraId) claimKey=\(claimKey) props=\(properties.count)")

        // Auto-claim if this camera was previously claimed and the session isn't open yet.
        if properties.isEmpty, claimedCameraKeys.contains(claimKey), vid != 0 {
            AppDelegate.log("PtpCameraAgent: auto-claiming \(claimKey)")
            sendClaimCommand(vid: vid, pid: pid, serial: serial, claim: true)
        }

        // Replay saved sticky property values exactly once per camera-session
        // (first property publish after connect). For each sticky propId we
        // know about, if the user has a remembered value and the camera's
        // current value differs, post a SET. The `stickyApplied` guard keeps
        // us from re-firing on every subsequent state republish (e.g. after
        // a successful SET or the agent-startup republish handshake).
        if !properties.isEmpty, !stickyApplied.contains(cameraId) {
            stickyApplied.insert(cameraId)
            let saved = stickyPropertyValues
            for propId in Self.stickyPropIds[vendor] ?? [] {
                guard let savedVal = saved[Self.stickyKey(claimKey, propId)],
                      let current = properties[propId] else { continue }
                if current.value.uint32Value != savedVal {
                    AppDelegate.log("PtpCameraAgent: replaying sticky prop \(claimKey)/0x\(String(propId, radix:16)) = \(savedVal) (camera has \(current.value))")
                    postPropertyCommand(cameraId: cameraId, propId: propId, value: NSNumber(value: savedVal))
                }
            }
        }

        rebuildMenu()
    }

    // MARK: - Claim Command (agent → extension)

    private func sendClaimCommand(vid: UInt16, pid: UInt16, serial: String, claim: Bool) {
        let crc = crc32OfString(serial) & 0x00FFFFFF
        let suffix = String(format: "%04x.%04x.%06x", vid, pid, crc)
        let slotName   = kDarwinClaimCameraSlot + "." + suffix
        let notifyName = kDarwinClaimCamera     + "." + suffix
        var slotToken: Int32 = 0
        darwin_notify_register_check(slotName, &slotToken)
        darwin_notify_set_state(slotToken, claim ? 1 : 2)
        darwin_notify_post(notifyName)
        notify_cancel(slotToken)
        AppDelegate.log("PtpCameraAgent: posted claim cmd=\(claim ? 1 : 2) vid=\(vid) pid=\(pid) serial='\(serial)'")
    }

    private func crc32OfString(_ s: String) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in s.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1)) }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Property Command (agent → extension)

    private func postPropertyCommand(cameraId: String, propId: UInt32, value: NSNumber) {
        let packed: UInt64 = (UInt64(3) << 56) | (UInt64(propId) << 32) | UInt64(value.uint32Value)
        postCameraCommand(cameraId: cameraId, packed: packed,
                          label: "SET_PROP 0x\(String(propId, radix:16)) = \(value)")
    }

    /// Trigger an autofocus cycle on the named camera. Encoded as cmd=4 on the
    /// per-camera property command channel; the extension routes it to
    /// `camera.triggerAutofocus()` which dispatches to the vendor implementation.
    private func postAutofocusCommand(cameraId: String) {
        let packed: UInt64 = UInt64(4) << 56
        postCameraCommand(cameraId: cameraId, packed: packed, label: "TRIGGER_AF")
    }

    /// Common per-camera Darwin-notify post for both SET_PROP and TRIGGER_AF.
    private func postCameraCommand(cameraId: String, packed: UInt64, label: String) {
        guard let camera = extCameras[cameraId] else {
            AppDelegate.log("PtpCameraAgent: postCameraCommand — unknown cameraId \(cameraId)")
            return
        }
        let crc = crc32OfString(camera.serial) & 0x00FFFFFF
        let suffix = String(format: "%04x.%04x.%06x", camera.vid, camera.pid, crc)
        let slotName   = kDarwinPropertyCmdSlot     + "." + suffix
        let notifyName = kDarwinCameraPropertyCmd   + "." + suffix
        var slotToken: Int32 = 0
        darwin_notify_register_check(slotName, &slotToken)
        darwin_notify_set_state(slotToken, packed)
        darwin_notify_post(notifyName)
        notify_cancel(slotToken)
        AppDelegate.log("PtpCameraAgent: posted \(label) on \(camera.name) (\(cameraId))")
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
        // Defer if the menu is currently open — see `isStatusMenuOpen`.
        if isStatusMenuOpen {
            rebuildPending = true
            return
        }
        menuActionHolders = []
        let menu = NSMenu()
        menu.delegate = self

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

        // Always-available "About" entry — surfaces the main app window
        // (subscription / project info) without the user having to find the
        // App's Dock icon. Routes via the `ptpwebcam://about` URL scheme so
        // we don't need an XPC channel from the agent to the app process.
        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "About PTP Webcam…",
                                   action: #selector(openAboutAction(_:)),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate (status-bar menu open/close tracking)

    func menuWillOpen(_ menu: NSMenu) {
        // Only the top-level status menu has us as delegate; submenus don't.
        isStatusMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isStatusMenuOpen = false
        // Flush any property-state update that arrived while the menu was
        // open (and therefore couldn't safely trigger a rebuild).
        if rebuildPending {
            rebuildPending = false
            rebuildMenu()
        }
    }

    /// Opens the App's main window. Posted as a `ptpwebcam://about` URL so
    /// the App handles it via `application(_:open:)` (already wired). If the
    /// App isn't running, NSWorkspace launches it; if it is, the URL routes
    /// to the live instance via Apple Events.
    @objc private func openAboutAction(_ sender: NSMenuItem) {
        guard let url = URL(string: "ptpwebcam://about") else { return }
        NSWorkspace.shared.open(url)
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

        let isClaimed = claimedCameraKeys.contains(camera.claimKey)

        // Single clickable camera header that doubles as the claim toggle.
        //   Claimed:    "<Camera Name> [serial]"                  with checkmark, click to release
        //   Unclaimed:  "<Camera Name> [serial] (click to claim)" no checkmark
        let displaySerial = formatSerialForDisplay(camera.serial, vendor: camera.vendor)
        let nameWithSerial = displaySerial.isEmpty
            ? camera.name
            : "\(camera.name) [\(displaySerial)]"
        let title = isClaimed ? nameWithSerial : "\(nameWithSerial) (click to claim)"
        let header = NSMenuItem(title: title,
                                action: #selector(claimCameraAction(_:)),
                                keyEquivalent: "")
        header.target = self
        header.representedObject = camera.cameraId
        header.state = isClaimed ? .on : .off
        menu.addItem(header)

        if !isClaimed { return }

        let previewItem = NSMenuItem(title: "  Preview Video Stream…",
                                     action: #selector(showPreviewAction(_:)),
                                     keyEquivalent: "")
        previewItem.target = self
        previewItem.representedObject = camera.cameraId
        menu.addItem(previewItem)

        if camera.properties.isEmpty {
            let item = NSMenuItem(title: "  Opening PTP session…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let vendor  = camera.vendor
        let isNikon = vendor == .nikon
        let isSony  = vendor == .sony

        // nil entries become separators (deferred so trailing/double separators are skipped).
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

        // Sony UI property list mirrors PtpCameraSony.uiProperties.
        // WB tune offsets (0xD210, 0xD21C) appear as sub-items after 0x5005.
        let sonyUiList: [UInt32?] = [
            0x5001,   // Battery Level
            0xD218,   // Sony Battery Level
            nil,
            0x500E,   // Exposure Program
            0x5007,   // Aperture
            0x500F,   // ISO
            0xD21E,   // Sony ISO
            0xD20D,   // Sony Shutter Speed
            nil,
            0x5005,   // White Balance
            0xD20F,   // WB Color Temp (Kelvin)
            0xD210,   // WB Tune Green–Magenta
            0xD21C,   // WB Tune Amber–Blue
            nil,
            0x5010,   // Exposure Bias
            0x500A,   // Focus Mode
        ]

        // Canon EOS UI list — mirrors UsbCanonCamera.canonUiPropertyIds in the
        // extension. The agent's PropertyFormatter has Canon-specific mappings
        // for the 0xD1xx codes; without the right uiList here only battery
        // (which Nikon and Canon share) would appear in the menu.
        // The DSLR T5i has no electronic viewfinder; the 0xD1Bx "EVF" props
        // are internal Live View state (output device, exposure preview,
        // etc.) that aren't useful in the menu and don't correspond to
        // physical controls on this camera. Drop them.
        let canonUiList: [UInt32?] = [
            0x5001,   // Battery Level
            nil,
            0xD105,   // Exposure Mode (Auto Exposure)
            0xD101,   // Aperture
            0xD103,   // ISO
            0xD102,   // Shutter Speed
            nil,
            0xD10A,   // WB Color Temp
            0xD104,   // Exposure Bias
            0xD108,   // Focus Mode
            0xD107,   // Metering Mode
        ]

        let uiList: [UInt32?]
        switch vendor {
        case .sony:  uiList = sonyUiList
        case .canon: uiList = canonUiList
        default:     uiList = nikonUiList
        }

        // Still/video mode filtering (Nikon only; not needed for Sony or Canon).
        let movieOnlyProps: Set<UInt32> = isNikon ? [0xD1A9, 0xD1A8, 0xD1AB] : []
        let stillOnlyProps: Set<UInt32> = isNikon ? [0x5007, 0xD100, 0x5010] : []
        var inVideoMode: Bool? = nil
        if isNikon, let lvSelector = camera.properties[0xD1A6] {
            inVideoMode = lvSelector.value.uint32Value == 1
        }

        var pendingSeparator = false
        var addedAny = false

        for entry in uiList {
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

            let displayName = displayName(for: propId, vendor: vendor) ?? String(format: "0x%04X", propId)
            let valueStr = formatExtPropValue(prop, vendor: vendor)
            let item = NSMenuItem(title: "  \(displayName): \(valueStr)", action: nil, keyEquivalent: "")
            item.submenu = buildExtPropSubmenu(prop, propId: propId, camera: camera, vendor: vendor, parentItem: item)
            menu.addItem(item)
        }

        // Autofocus trigger. Nikon: AfDrive (0x90C1). Sony: AutofocusButton
        // toggle (0xD2C1) — known unreliable on A7-series in tethered mode,
        // so we label it experimental. Canon: not yet implemented at the
        // extension side.
        if vendor == .nikon || (vendor == .sony && camera.properties[0xD2C1] != nil) {
            menu.addItem(NSMenuItem.separator())
            let title = vendor == .sony ? "  Autofocus (experimental)" : "  Autofocus"
            let afItem = NSMenuItem(title: title,
                                    action: #selector(extAutofocusAction(_:)),
                                    keyEquivalent: "")
            afItem.target = self
            afItem.representedObject = camera.cameraId
            menu.addItem(afItem)
        }
    }

    // Build the appropriate submenu for a writable ext-camera property.
    // Priority: grid (WB tune) → enum (with optional WB sub-props) → slider (range, no enum).
    private func buildExtPropSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                     camera: ExtCamera, vendor: CameraVendor = .unknown,
                                     parentItem: NSMenuItem? = nil) -> NSMenu? {
        guard prop.writable else { return nil }
        // Some cameras (notably Sony A7) report intrinsically read-only sensor
        // properties as writable in GetAllPropData. Suppress submenu building
        // for the known-physical-read-only set so they don't get sliders.
        if intrinsicallyReadOnlyProps.contains(propId) { return nil }

        // Grid view for WB fine-tune matrix properties (only for the known 0-168 / 0-1224 encodings).
        if nikonWbTuneIds.contains(propId),
           let rMin = prop.rangeMin, let rMax = prop.rangeMax,
           rMin.intValue == 0, rMax.intValue == 168 || rMax.intValue == 1224 {
            return buildWbTuneGridSubmenu(prop, propId: propId, cameraId: camera.cameraId,
                                         rangeMin: rMin.intValue, rangeMax: rMax.intValue)
        }

        // Sony incremental properties (ISO / aperture / shutter on A7-series
        // and newer): the camera only accepts SetPropStep, moving one enum
        // position at a time. Show a +/- stepper the user can click
        // repeatedly without the menu collapsing, rather than a long enum
        // list. Needs at least 2 values to step between.
        if prop.incremental, !prop.isButton,
           let enumValues = prop.enumValues, enumValues.count >= 2 {
            return buildSonyStepperSubmenu(prop, propId: propId, enumValues: enumValues,
                                           cameraId: camera.cameraId, vendor: vendor,
                                           parentItem: parentItem)
        }

        // Enum list (discrete values).
        if let enumValues = prop.enumValues, !enumValues.isEmpty {
            let submenu = NSMenu()
            for enumVal in enumValues {
                let valStr = formatExtPropRaw(enumVal, propId: propId, vendor: vendor)
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
                        let subName = displayName(for: subId, vendor: vendor) ?? String(format: "0x%04X", subId)
                        let subVal  = formatExtPropValue(subProp, vendor: vendor)
                        let subItem2 = NSMenuItem(title: "\(subName): \(subVal)",
                                                  action: nil, keyEquivalent: "")
                        subItem2.submenu = buildExtPropSubmenu(subProp, propId: subId,
                                                               camera: camera, vendor: vendor,
                                                               parentItem: subItem2)
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
                                     rStep: rStep.doubleValue, vendor: vendor,
                                     parentItem: parentItem)
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
            self?.postPropertyCommand(cameraId: cameraId, propId: propId, value: NSNumber(value: val))
        }
        let gridItem = NSMenuItem()
        gridItem.view = grid
        let submenu = NSMenu()
        submenu.addItem(gridItem)
        return submenu
    }

    // NSMenuItem containing a SonyStepperView (− value +). The buttons can be
    // clicked repeatedly without dismissing the menu.
    private func buildSonyStepperSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                         enumValues: [NSNumber], cameraId: String,
                                         vendor: CameraVendor,
                                         parentItem: NSMenuItem?) -> NSMenu {
        let displayName = displayName(for: propId, vendor: vendor) ?? String(format: "0x%04X", propId)
        let stepper = SonyStepperView(
            propId: propId, enumValues: enumValues, currentValue: prop.value, vendor: vendor
        ) { [weak self] target in
            self?.postPropertyCommand(cameraId: cameraId, propId: propId, value: target)
        }
        if let parentItem {
            stepper.onDisplay = { [weak parentItem] formatted in
                parentItem?.title = "  \(displayName): \(formatted)"
            }
        }
        // Keep the view alive for the menu's lifetime. NSMenuItem.view retains
        // it, but stash a reference too so it survives even if the item is
        // mutated; mirrors how SliderActionHolder instances are retained.
        menuActionHolders.append(stepper)

        let item = NSMenuItem()
        item.view = stepper
        let submenu = NSMenu()
        submenu.addItem(item)
        return submenu
    }

    // NSMenuItem containing an NSSlider. Updates parent item title live while dragging.
    private func buildSliderSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                    cameraId: String,
                                    rMin: Double, rMax: Double, rStep: Double,
                                    vendor: CameraVendor = .unknown,
                                    parentItem: NSMenuItem? = nil) -> NSMenu {
        let displayName = displayName(for: propId, vendor: vendor) ?? String(format: "0x%04X", propId)
        let holder = SliderActionHolder(propId: propId, rangeMin: rMin, rangeStep: rStep) {
            [weak self] val in self?.postPropertyCommand(cameraId: cameraId, propId: propId, value: NSNumber(value: val))
        }
        if let parentItem {
            holder.onDisplay = { [weak self, weak parentItem] val in
                guard let self, let parentItem else { return }
                let formatted = formatExtPropRaw(NSNumber(value: val), propId: propId, vendor: vendor)
                parentItem.title = "  \(displayName): \(formatted)"
            }
        }
        menuActionHolders.append(holder)

        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 160, height: 16))
        slider.minValue     = rMin
        slider.maxValue     = rMax
        slider.doubleValue  = prop.value.doubleValue
        slider.isContinuous = true
        slider.target = holder
        slider.action = #selector(SliderActionHolder.sliderChanged(_:))

        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        let submenu = NSMenu()
        submenu.addItem(sliderItem)
        return submenu
    }

    /// Trim a camera's PTP-reported serial for display in the menu. Nikon
    /// bodies (D800, Z 8, …) report their serial as a fixed-width zero-padded
    /// decimal string ("000005004922"); strip the leading zeros so the
    /// menu shows the human-readable form printed on the camera body
    /// ("5004922"). Other vendors typically use alphanumeric serials where
    /// leading zeros are significant — leave them untouched.
    private func formatSerialForDisplay(_ serial: String, vendor: CameraVendor) -> String {
        guard vendor == .nikon, !serial.isEmpty else { return serial }
        let trimmed = String(serial.drop(while: { $0 == "0" }))
        // Don't return "" if the camera literally reported all zeros — show
        // the original so it's obvious something odd is going on.
        return trimmed.isEmpty ? serial : trimmed
    }

    private func formatExtPropValue(_ prop: ExtCameraProperty, vendor: CameraVendor = .unknown) -> String {
        formatExtPropRaw(prop.value, propId: prop.propertyId, vendor: vendor)
    }

    // MARK: - Menu Actions

    @objc private func autofocusAction(_ sender: NSMenuItem) {
        guard let camera = sender.representedObject as? PtpCamera else { return }
        camera.performAutofocus()
    }

    @objc private func extAutofocusAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String else { return }
        postAutofocusCommand(cameraId: cameraId)
    }

    @objc private func changePropertyAction(_ sender: NSMenuItem) {
        if let change = sender.representedObject as? PropertyChangeInfo {
            change.camera.setProperty(change.propertyId, value: change.value)
        } else if let change = sender.representedObject as? ExtPropertyChangeInfo {
            postPropertyCommand(cameraId: change.cameraId, propId: change.propertyId, value: change.value)

            // Remember the user's pick for properties in the sticky list so
            // the value gets reapplied automatically on the next reconnect.
            if let camera = extCameras[change.cameraId],
               Self.isStickyProperty(propId: change.propertyId, vendor: camera.vendor) {
                var sticky = stickyPropertyValues
                sticky[Self.stickyKey(camera.claimKey, change.propertyId)] = change.value.uint32Value
                stickyPropertyValues = sticky
                AppDelegate.log("PtpCameraAgent: sticky prop saved \(camera.claimKey)/0x\(String(change.propertyId, radix:16)) = \(change.value)")
            }
        }
    }

    @objc private func showPreviewAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String,
              let camera = extCameras[cameraId],
              let encodedName = camera.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "ptpwebcam://preview?name=\(encodedName)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func claimCameraAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String,
              let camera = extCameras[cameraId] else { return }
        let claiming = !claimedCameraKeys.contains(camera.claimKey)
        var keys = claimedCameraKeys
        if claiming { keys.insert(camera.claimKey) } else { keys.remove(camera.claimKey) }
        claimedCameraKeys = keys
        let parts = camera.claimKey.split(separator: ":")
        let vid  = UInt16(parts.count > 0 ? UInt32(parts[0], radix: 16) ?? 0 : 0)
        let pid  = UInt16(parts.count > 1 ? UInt32(parts[1], radix: 16) ?? 0 : 0)
        let serial = parts.count > 2 ? String(parts[2...].joined(separator: ":")) : ""
        AppDelegate.log("PtpCameraAgent: \(claiming ? "claiming" : "releasing") \(camera.claimKey)")
        sendClaimCommand(vid: vid, pid: pid, serial: serial, claim: claiming)
        rebuildMenu()
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
        logger.info("setProperty \(propertyId, privacy: .public) requested for \(cameraId, privacy: .public)")
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

enum CameraVendor {
    case nikon
    case sony
    case canon
    case unknown
}

struct ExtCameraProperty {
    let propertyId: UInt32
    let dataType: UInt16
    let writable: Bool
    let value: NSNumber
    let enumValues: [NSNumber]?
    let rangeMin: NSNumber?
    let rangeMax: NSNumber?
    let rangeStep: NSNumber?
    // Sony step-flags (default false for other vendors). `incremental` means
    // the camera is driven by SetPropStep — the menu shows +/- steppers
    // rather than a value picker. `isButton` is a momentary control.
    var incremental: Bool = false
    var isButton: Bool = false
}

struct ExtCamera {
    let cameraId: String
    let name: String
    let claimKey: String
    let vid: UInt16
    let pid: UInt16
    let serial: String
    var properties: [UInt32: ExtCameraProperty]
    let orderedPropertyIds: [UInt32]
    let vendor: CameraVendor
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
class SliderActionHolder: NSObject {
    let propId: UInt32
    let rangeMin: Double
    let rangeStep: Double
    let onCommand: (Double) -> Void
    var onDisplay: ((Double) -> Void)?

    private var debounceTimer: Timer?
    private var pendingValue: Double = 0

    init(propId: UInt32, rangeMin: Double, rangeStep: Double, onCommand: @escaping (Double) -> Void) {
        self.propId = propId; self.rangeMin = rangeMin
        self.rangeStep = rangeStep; self.onCommand = onCommand
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let step = rangeStep > 0 ? rangeStep : 1
        let snapped = rangeMin + floor((sender.doubleValue - rangeMin) / step) * step
        onDisplay?(snapped)
        pendingValue = snapped
        debounceTimer?.invalidate()
        // Schedule on `.common` rather than the default mode. The status-bar
        // menu runs its run loop in `.eventTracking` while it's open; a
        // default-mode timer doesn't fire until the menu closes, which made
        // slider commits visibly LAG until the user dismissed the menu.
        // `.common` covers default + tracking + modal so the debounce fires
        // 150 ms after the last drag event regardless of menu state.
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.onCommand(self.pendingValue)
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }
}

/// Custom menu-item view: a dial-style stepper for Sony incremental
/// properties (ISO / aperture / shutter on A7-series and newer bodies, which
/// the camera drives via SetPropStep one enum position at a time).
///
/// Layout is `‹ prevValue ›   currentValue   ‹ nextValue ›` — the side
/// buttons show the ACTUAL neighbouring values rather than bare +/- glyphs,
/// so it reads like a dial: you see what you're about to step toward. The
/// centre shows the current value in bold.
///
/// Why a custom view instead of menu items: clicking an NSButton embedded in
/// a menu-item view does NOT dismiss the menu, so the user can keep tapping.
/// A normal `<value>` menu item would collapse the whole menu on first click.
///
/// Each click advances a LOCAL index and refreshes immediately (optimistic),
/// then posts the new target enum value through `onStep`. The extension's
/// Sony set path clamps to a ±1 SetPropStep and keeps its own cache synced
/// via a post-set GetAllPropData refresh, so sending absolute targets
/// computed from this local index converges correctly under rapid clicking.
final class SonyStepperView: NSView {
    private let enumValues: [NSNumber]
    private var index: Int
    private let propId: UInt32
    private let vendor: CameraVendor
    private let onStep: (NSNumber) -> Void
    /// Called with the formatted current-value string on every step, so the
    /// caller can mirror it into the parent menu item's title.
    var onDisplay: ((String) -> Void)?

    private let prevButton  = NSButton()
    private let valueLabel  = NSTextField(labelWithString: "")
    private let nextButton  = NSButton()

    init(propId: UInt32, enumValues: [NSNumber], currentValue: NSNumber,
         vendor: CameraVendor, onStep: @escaping (NSNumber) -> Void) {
        self.propId      = propId
        self.enumValues  = enumValues
        self.vendor      = vendor
        self.onStep      = onStep
        self.index       = enumValues.firstIndex(of: currentValue) ?? 0
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))

        // "Lower" value sits on the left, "higher" on the right. Sony enum
        // tables are ordered low→high for these properties, so prev = index-1.
        prevButton.frame = NSRect(x: 6, y: 3, width: 78, height: 24)
        prevButton.bezelStyle = .rounded
        prevButton.target = self
        prevButton.action = #selector(stepDown)
        addSubview(prevButton)

        valueLabel.frame = NSRect(x: 88, y: 4, width: 84, height: 22)
        valueLabel.alignment = .center
        valueLabel.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
        addSubview(valueLabel)

        nextButton.frame = NSRect(x: 176, y: 3, width: 78, height: 24)
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(stepUp)
        addSubview(nextButton)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func formatted(_ idx: Int) -> String {
        guard enumValues.indices.contains(idx) else { return "" }
        return formatExtPropRaw(enumValues[idx], propId: propId, vendor: vendor)
    }

    private func refresh() {
        guard enumValues.indices.contains(index) else { return }
        let current = formatted(index)
        valueLabel.stringValue = current

        // Side buttons show the neighbouring value. At a boundary the button
        // is blanked and disabled so the dial visibly "bottoms out".
        if index > 0 {
            prevButton.title = "‹ \(formatted(index - 1))"
            prevButton.isEnabled = true
        } else {
            prevButton.title = ""
            prevButton.isEnabled = false
        }
        if index < enumValues.count - 1 {
            nextButton.title = "\(formatted(index + 1)) ›"
            nextButton.isEnabled = true
        } else {
            nextButton.title = ""
            nextButton.isEnabled = false
        }

        onDisplay?(current)
    }

    @objc private func stepDown() {
        guard index > 0 else { return }
        index -= 1
        refresh()
        onStep(enumValues[index])
    }

    @objc private func stepUp() {
        guard index < enumValues.count - 1 else { return }
        index += 1
        refresh()
        onStep(enumValues[index])
    }
}

// WB tune property IDs that get a grid view instead of an enum list.
private let nikonWbTuneIds: Set<UInt32> = [
    0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D,
    0xD150, 0xD212, 0xD213, 0xD215, 0xD216, 0xD218, 0xD219, 0xD21B,
]

// Properties that are intrinsically read-only sensor readings, even if the
// camera reports them as writable in its property descriptor. Sony A7 in
// particular flags battery / focal length / focus-found as "writable" in
// GetAllPropData; the menu must not build a submenu (slider, enum, etc.) for
// these or the user gets a misleading control that can't actually be applied.
private let intrinsicallyReadOnlyProps: Set<UInt32> = [
    0x5001,   // Standard PTP Battery Level
    0x5008,   // Standard PTP Focal Length
    0xD213,   // Sony Focus Found (sensor)
    0xD218,   // Sony Battery Level
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
    // Canon EOS vendor names are kept in a separate `canonExtPropDisplayNames`
    // dictionary below — many Canon 0xD1xx codes collide with Nikon ones
    // (e.g. Canon 0xD103 = ISO; Nikon 0xD103 = Auto DX Crop). The lookup
    // helper `displayName(for:vendor:)` picks the vendor-specific table first.
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
    // 0xD218 = Sony Battery Level (Nikon movie WB Cloudy Tune is not in the Nikon UI list)
    0xD218: "Battery Level",
    0xD219: "Movie WB Shade Tune",
    0xD21B: "Movie WB Color Temp Tune",
    // Sony-specific
    0xD20D: "Shutter Speed",
    0xD20F: "WB Color Temp",
    0xD210: "WB Tune G–M",
    0xD21C: "WB Tune A–B",
    0xD21E: "ISO",
]

// Canon EOS vendor display names — kept separate from extPropDisplayNames
// because many of these codes mean something different on Nikon bodies. The
// `displayName(for:vendor:)` helper picks this table first when the camera
// vendor is Canon. Codes match UsbCanonCamera.canonUiPropertyIds.
private let canonExtPropDisplayNames: [UInt32: String] = [
    0xD101: "Aperture",
    0xD102: "Shutter Speed",
    0xD103: "ISO",
    0xD104: "Exposure Bias",
    0xD105: "Exposure Mode",
    0xD107: "Metering Mode",
    0xD108: "Focus Mode",
    0xD10A: "WB Color Temp",
    0xD129: "Picture Style",
    0xD12C: "LV Eye Detect",
    0xD1B0: "EVF Output Device",
    0xD1B1: "EVF Mode",
    0xD1B2: "EVF DoF Preview",
    0xD1B4: "EVF White Balance",
    0xD1B6: "EVF Color Temperature",
    0xD1B7: "EVF Exposure Preview",
]

/// Vendor-aware lookup into the display-name tables. Falls back to the
/// generic (Nikon/standard-PTP) table when the camera-specific table doesn't
/// know the code.
func displayName(for propId: UInt32, vendor: CameraVendor) -> String? {
    if vendor == .canon, let n = canonExtPropDisplayNames[propId] { return n }
    return extPropDisplayNames[propId]
}

// nikonExtPropValueNames lives in PropertyFormatter.swift.
