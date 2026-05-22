import Cocoa
import os.log
import CoreGraphics
import ImageIO

// ICDeviceBrowser and the `PtpCamera` class hierarchy used to live here from
// the DAL-plugin era when the agent drove cameras directly via ImageCapture.
// With the CMIO-system-extension migration, USB/PTP work moved entirely
// into the extension; the agent only renders the menu off Darwin-notify
// state. The legacy `PtpCamera*.swift` files were removed and every
// reference to ICDeviceBrowser / PtpCamera in this file deleted.
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // While the status-bar menu is open we must NOT call `statusItem.menu = …`
    // (which is what rebuildMenu does) — reassigning the menu collapses it,
    // killing the Sony +/- stepper interaction mid-click. So when a property-
    // state update arrives during this window we just refresh the model and
    // set `rebuildPending`; `menuDidClose` flushes it.
    private var isStatusMenuOpen = false
    private var rebuildPending   = false

    private let logger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent", category: "Agent")
    private static let agentLog = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent", category: "AgentLog")
    private var xpcListener: NSXPCListener!

    /// Routine status / telemetry logging. Logged at `.info` level so
    /// these lines are dropped from Console.app's default view (they
    /// surface only when you turn on the "Info" filter or pull a
    /// sysdiagnose). Reserve this helper for normal operational
    /// progress messages — anything an end user shouldn't see as
    /// "fault" in their system log.
    ///
    /// History: previously called through to `agentLog.fault(...)`,
    /// which meant every routine "posted claim" / "property state" /
    /// "applicationDidFinishLaunching" line appeared in Console.app's
    /// default view as a fault. Users (and reviewers) interpret that
    /// as "the app is misbehaving"; reduce noise by demoting to info.
    static func log(_ msg: String) {
        agentLog.info("\(msg, privacy: .public)")
    }

    /// Genuine error-level logging. Stays at `.fault` level so it's
    /// visible in Console.app's default view and captured in
    /// sysdiagnose without any extra filters. Use this for conditions
    /// that indicate something is actually broken — e.g. checksum
    /// mismatches in the property-state slot protocol, oversized
    /// payloads we had to drop, USB claim that couldn't recover.
    static func error(_ msg: String) {
        agentLog.fault("\(msg, privacy: .public)")
    }

    private var extensionConnections: [NSXPCConnection] = []
    private var darwinSlotTokens: [Int32] = []

    // Keeps slider/grid action holders alive for the lifetime of the current menu.
    private var menuActionHolders: [AnyObject] = []

    // Extension-published camera property state (via Darwin notify slots, multi-page).
    private var propSlotTokens: [Int32] = []
    /// Read tokens + reassembly state for live-view-failure messages from the
    /// extension. Same multi-page slot-chain protocol as property state, just
    /// a much smaller chain since the payload is a short error string.
    private var lvFailSlotTokens: [Int32] = []
    private var usbBlockedSlotTokens: [Int32] = []
    /// Token for the single-slot menu-bar-visibility publication channel
    /// (see kDarwinMenuBarHidden in PtpCameraAgentProtocol.swift).
    private var menuBarHiddenSlotToken: Int32 = 0
    /// Last published value, used to suppress repeat posts when occlusion
    /// flips between two states that map to the same hidden/visible bool
    /// (e.g. windowing system toggling a private occlusion flag the user
    /// can't see).
    private var lastPublishedMenuBarHidden: Bool? = nil
    /// Full packed payload of the last publication, used to debounce
    /// reason-only transitions (e.g. disabled→overflow) that don't
    /// change the hidden bool but DO change the banner text in the
    /// About window.
    private var lastPublishedMenuBarPayload: UInt64? = nil
    /// Suppresses publication during the launch settling window — for
    /// the first ~3 s after `applicationDidFinishLaunching`, occlusion
    /// notifications fire with non-final window frames and produce
    /// false-positive "hidden" verdicts that the +3 s sanity check then
    /// corrects. Both transitions get published if we don't gate them,
    /// causing a visible banner flash in the About window at launch.
    /// Set to false by the +3 s delayed check, after which all verdicts
    /// are published normally.
    private var menuBarVisibilityGracePeriod: Bool = true
    /// Polling fallback for visibility transitions that don't fire
    /// `NSWindow.didChangeOcclusionStateNotification` — notably, when
    /// the user toggles the agent's menu bar entry in System Settings
    /// → Menu Bar (macOS 26+), the OS destroys the old NSStatusBarWindow
    /// and constructs a fresh one when re-enabled. Our occlusion
    /// observer was registered on the old window, which no longer
    /// exists, so we'd never see the "re-enabled" transition without a
    /// timer-driven re-check. Two seconds is a comfortable tradeoff
    /// between responsiveness and overhead — the check itself is just
    /// a couple of property reads.
    private var menuBarVisibilityPollTimer: Timer? = nil
    private var lvFailPageBuffer: Data?
    private var lvFailPageTotal: Int = 0
    private var lvFailPageCount: Int = 0
    private var lvFailNextPage: Int = 0
    private var usbBlockedPageBuffer: Data?
    private var usbBlockedPageTotal: Int = 0
    private var usbBlockedPageCount: Int = 0
    private var usbBlockedNextPage: Int = 0
    /// De-duplicate identical failure alerts that arrive within a short
    /// window — Canon's EVF state machine and Nikon's prohibit-condition
    /// flow can both fire onLiveViewStartFailed multiple times during a
    /// single user-initiated streaming attempt.
    private var lastLvFailAlertAt: Date = .distantPast
    private var lastLvFailAlertText: String = ""

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
    private static let stickyPropIds: [ProtocolFamily: Set<UInt32>] = [
        .nikon: [0xD1AC],   // LV Image Size
    ]

    private static func stickyKey(_ claimKey: String, _ propId: UInt32) -> String {
        String(format: "%@:%04x", claimKey, propId)
    }

    /// True if `propId` is in the sticky list for this vendor.
    private static func isStickyProperty(propId: UInt32, vendor: ProtocolFamily) -> Bool {
        stickyPropIds[vendor]?.contains(propId) ?? false
    }

    /// Cameras for which we've already replayed sticky values during this
    /// process lifetime. Prevents re-firing SET commands every time the
    /// extension republishes property state (post-set, or via the
    /// kDarwinCameraStateRepublish handshake).
    private var stickyApplied: Set<String> = []
    /// Page-reassembly state for multi-page `kDarwinCameraPropertyState`
    /// transfers. Lifted out of inlined Data/index ivars into the shared
    /// `CameraPropertyStatePageReassembler` so the host app's HUD can
    /// reuse the same wire-format logic without duplicating it.
    private let propPageReassembler: CameraPropertyStatePageReassembler = {
        let r = CameraPropertyStatePageReassembler()
        r.onError = { msg in AppDelegate.error(msg) }
        return r
    }()

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

        // Register the publication slot for menu-bar item visibility (one
        // bool packed into the low byte of a uint64 — the slot model gives
        // us free cross-process sharing without needing the chain
        // protocol other channels use). The +3 s delayed sanity check
        // covers the case where the item starts hidden behind the notch
        // and no further occlusion change ever fires.
        darwin_notify_register_check(kDarwinMenuBarHiddenSlot, &menuBarHiddenSlotToken)
        if let button = statusItem.button, let window = button.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStatusItemOcclusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            // End of the launch grace window — from now on publish
            // every verdict transition, including the initial baseline.
            self?.menuBarVisibilityGracePeriod = false
            self?.checkStatusItemVisibility()
        }

        // Periodic poll fallback (see comment on
        // menuBarVisibilityPollTimer). Started here so it runs for the
        // lifetime of the process; stopped only at termination, which
        // we don't bother explicitly handling because the process is
        // going away anyway.
        menuBarVisibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkStatusItemVisibility()
        }

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

        // USB access coordination: kill ptpcamerad on behalf of the CMIO
        // extension when it asks. See kDarwinNeedUsbAccess docs in
        // PtpCameraAgentProtocol.swift for why this side channel exists.
        var needUsbToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinNeedUsbAccess, &needUsbToken, .main) { [weak self] _ in
            self?.handleNeedUsbAccess()
        }

        xpcListener = NSXPCListener(machServiceName: kPtpCameraAgentMachServiceName)
        xpcListener.delegate = self
        xpcListener.resume()
        AppDelegate.log("PtpCameraAgent: XPC listener started on \(kPtpCameraAgentMachServiceName)")

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

        // Live-view-start failure channel from extension. When the per-vendor
        // `startLiveViewSession` returns false (Nikon prohibit-condition bits,
        // Canon EVF stuck, etc.) the extension publishes a UTF-8 message via
        // a small slot chain. Display it as an NSAlert so the user gets a
        // clear explanation rather than a silent black QuickTime preview.
        lvFailSlotTokens = (0..<kDarwinLiveViewFailedSlotCount).map { i in
            var t: Int32 = 0
            darwin_notify_register_check(kDarwinLiveViewFailedSlotPrefix + "\(i)", &t)
            return t
        }
        var lvFailToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinLiveViewFailed, &lvFailToken, .main) { [weak self] _ in
            self?.handleLiveViewFailure()
        }

        // USB-busy / camera-held-by-other-app channel. Extension posts this
        // when openUsbCamera exhausts retries with kIOReturnExclusiveAccess.
        // The agent enumerates running apps known to keep ImageCapture
        // sessions alive (Preview, Photos, Image Capture, etc.) and shows
        // them in the menu as actionable items — much better UX than the
        // user staring at "Opening PTP session…" forever.
        usbBlockedSlotTokens = (0..<kDarwinUsbBlockedSlotCount).map { i in
            var t: Int32 = 0
            darwin_notify_register_check(kDarwinUsbBlockedSlotPrefix + "\(i)", &t)
            return t
        }
        var usbBlockedToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinUsbBlocked, &usbBlockedToken, .main) { [weak self] _ in
            self?.handleUsbBlocked()
        }

        // Watch for any of our known camera-holding apps exiting — by
        // any means: our own "Quit X" dialog, the user hitting Cmd-Q,
        // Force Quit, a crash, even the app being launched and exiting
        // unrelated to the camera. When one terminates we clear it from
        // every camera's blockingApps and retry the claim for any
        // camera whose list became empty. This means the user can fix
        // the situation themselves and we'll automatically catch up
        // without them needing to invoke our menu action at all.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)

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

    // MARK: - Menu-bar status item visibility detection

    /// Receives NSWindow.didChangeOcclusionStateNotification for the
    /// status item's hosting window. Re-runs the visibility check; if
    /// the bool changed since last publication, posts an update to the
    /// host app so it can show / hide the warning banner in its About
    /// window.
    @objc private func handleStatusItemOcclusionChanged(_ notification: Notification) {
        checkStatusItemVisibility()
    }

    /// Three-state visibility verdict. We need the .undetermined case
    /// because the very first occlusion notification often fires before
    /// the OS has actually placed the status item button in the menu
    /// bar — `button.window.frame.origin` is still at (0,0) or the
    /// button is hosted in a sentinel window with NSZeroRect bounds.
    /// Publishing "hidden" in that window of time produces a spurious
    /// warning banner that never gets corrected (because subsequent
    /// occlusion events match `lastPublishedMenuBarHidden` and the
    /// debounce filter swallows the correction).
    ///
    /// We deliberately do NOT split "hidden" by reason (overflow vs
    /// disabled-in-Settings). The two cases are observationally
    /// indistinguishable on macOS 26: both produce a window frame
    /// inside the menu-bar y-band but with the .visible occlusion flag
    /// cleared. Defaults domains don't expose the toggle state either,
    /// so we surface a single banner that addresses both possibilities.
    private enum StatusItemVisibility {
        case visible
        case hidden
        case undetermined
    }

    /// Compute whether our NSStatusItem is currently visible to the
    /// user. Combines two signals because neither alone is sufficient:
    ///
    /// 1. Occlusion state. `NSWindow.occlusionState.contains(.visible)`
    ///    is the OS's authoritative answer when it knows the answer, and
    ///    macOS does fire `didChangeOcclusionStateNotification` for
    ///    status-bar windows when overflow managers (Control Center,
    ///    Bartender / Ice / Hand Mirror, etc.) collapse them out.
    /// 2. Geometry sanity check. Some macOS versions don't update
    ///    occlusion when the item is pushed off-screen by notch overflow
    ///    — the button still reports a frame, but it's at negative x or
    ///    doesn't intersect any screen's menu bar rect. We catch those
    ///    cases by checking whether the button's screen-space frame
    ///    actually overlaps a visible menu bar.
    ///
    /// If we can't tell yet (no window, NSZeroRect frame), returns
    /// .undetermined so the caller skips publication and waits for the
    /// next occlusion event or the +3s delayed sanity check.
    private func statusItemVisibility() -> StatusItemVisibility {
        guard let button = statusItem?.button,
              let window = button.window else {
            // No button or window means either (a) the item hasn't
            // materialised yet (early in launch — grace period
            // suppresses publication) or (b) the user disabled the item
            // in System Settings → Menu Bar, or a menu bar manager set
            // "always hide" on it. After the grace window, all those
            // map to .hidden — the banner copy covers both reasons.
            return menuBarVisibilityGracePeriod ? .undetermined : .hidden
        }

        let frame = window.frame
        // NSZeroRect / origin-at-zero / sub-pixel frame means the OS
        // hasn't placed the window in the menu bar yet. Don't guess.
        if frame.width < 1 || frame.height < 1 || frame.origin == .zero {
            return .undetermined
        }

        // Two signals — either one voting "hidden" → .hidden:
        //
        //  1. Occlusion state. NSStatusBarWindow clears the .visible
        //     flag whenever the item isn't actually drawn — covers
        //     System Settings toggle off, Bartender "always hide", and
        //     the steady-state of menu-bar overflow.
        //
        //  2. Geometry. Frame doesn't intersect any screen's menu bar
        //     rect — catches the brief moments during menu-bar
        //     shuffling where the OS parks the item off-screen (e.g.
        //     (0, -33)) before bouncing it back.
        //
        // We deliberately don't try to distinguish reason: the two
        // hidden states (user toggle vs. overflow) are observationally
        // identical once the menu bar settles, and the banner copy
        // covers both possibilities.
        let occluded = !window.occlusionState.contains(.visible)
        let menuBarHeight = NSStatusBar.system.thickness
        var intersectsMenuBar = false
        for screen in NSScreen.screens {
            let menuBarRect = NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight,
                width: screen.frame.width,
                height: menuBarHeight)
            if menuBarRect.intersects(frame) {
                intersectsMenuBar = true
                break
            }
        }
        if !intersectsMenuBar || occluded {
            return .hidden
        }
        return .visible
    }

    /// Publish the current hidden/visible bool to the host app via
    /// the kDarwinMenuBarHidden slot. Debounced — only posts when the
    /// value actually changes, so the host app doesn't redraw its
    /// banner on every spurious occlusion flip.
    private func checkStatusItemVisibility() {
        let verdict = statusItemVisibility()
        let hidden: Bool
        switch verdict {
        case .visible:
            hidden = false
        case .hidden:
            hidden = true
        case .undetermined:
            // Window/frame not settled yet. Schedule a quick retry so
            // we don't miss the resolve point if the OS happens to not
            // fire another occlusion notification once it places the
            // button. 250 ms is well below human-perceptible latency
            // for the warning banner appearing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.checkStatusItemVisibility()
            }
            return
        }
        // Suppress all publications during the launch grace window —
        // see comment on menuBarVisibilityGracePeriod for rationale.
        if menuBarVisibilityGracePeriod { return }

        let payload: UInt64 = hidden ? 1 : 0
        if lastPublishedMenuBarPayload == payload { return }
        lastPublishedMenuBarPayload = payload
        lastPublishedMenuBarHidden = hidden

        darwin_notify_set_state(menuBarHiddenSlotToken, payload)
        darwin_notify_post(kDarwinMenuBarHidden)
        AppDelegate.log("PtpCameraAgent: menu-bar item \(hidden ? "HIDDEN" : "visible") — published kDarwinMenuBarHidden=\(payload)")
    }

    // MARK: - USB Access Coordination

    /// Kill ptpcamerad so the CMIO extension (user/262) can claim the PTP
    /// USB interface. Required because ptpcamerad ignores every documented
    /// kernel-level eviction message (USBDeviceOpenSeize, USBInterfaceOpenSeize,
    /// IOUSBHostObjectInitOptionsDeviceSeize). The reliable App-Store-compatible
    /// replacement is IOUSBHost's DeviceCapture option — which requires the
    /// managed `com.apple.vm.device-access` entitlement Apple grants per
    /// application. Until that lands, the agent must run outside the App
    /// Sandbox so this `kill()` succeeds.
    private func handleNeedUsbAccess() {
        let killed = Self.killProcessByName("ptpcamerad")
        AppDelegate.log("PtpCameraAgent: handleNeedUsbAccess killed=\(killed)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            darwin_notify_post(kDarwinUsbAccessReady)
        }
    }

    /// sysctl(KERN_PROC_ALL) + kill() — no child-process spawn, which lets us
    /// avoid the sandbox restriction that blocks `Process.run("/usr/bin/pkill")`.
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
    //
    // `publishCameraState` published the legacy ImageCapture-driven camera
    // list. With the extension owning USB this is now the extension's job —
    // see `publishCameraConnected` in PtpWebcamCameraExtensionProvider. The
    // agent only republishes empty state on legacy kDarwinCameraStateRequest
    // requests for backwards compatibility with any external listeners.

    private func publishCameraState() {
        let cameraList: [[String: String]] = []  // always empty now

        guard let jsonData = try? JSONSerialization.data(withJSONObject: cameraList) else { return }
        let maxPayload = (kDarwinStateSlotCount - 1) * 8
        guard jsonData.count <= maxPayload else {
            AppDelegate.error("PtpCameraAgent: camera state too large (\(jsonData.count) bytes, max \(maxPayload))")
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

    // MARK: - Live view failure (extension → agent)

    private func handleLiveViewFailure() {
        var slot0: UInt64 = 0
        darwin_notify_get_state(lvFailSlotTokens[0], &slot0)
        let totalLength = Int(slot0 >> 32)
        let pageIndex   = Int((slot0 >> 16) & 0xFFFF)
        let pageCount   = Int(slot0 & 0xFFFF)
        guard totalLength > 0, pageCount > 0, pageIndex < pageCount else { return }

        let pageDataSlots = kDarwinLiveViewFailedSlotCount - 2
        let pageSize = pageDataSlots * 8
        let pageOffset = pageIndex * pageSize
        let pageLength = min(pageSize, totalLength - pageOffset)
        guard pageLength > 0 else { return }

        if pageIndex == 0 || lvFailPageBuffer == nil || lvFailPageTotal != totalLength {
            lvFailPageBuffer = Data(count: totalLength)
            lvFailPageTotal = totalLength
            lvFailPageCount = pageCount
            lvFailNextPage = 0
        }
        guard var buffer = lvFailPageBuffer, pageIndex == lvFailNextPage else {
            lvFailPageBuffer = nil
            return
        }
        buffer.withUnsafeMutableBytes { ptr in
            for i in 0..<((pageLength + 7) / 8) {
                var v: UInt64 = 0
                darwin_notify_get_state(lvFailSlotTokens[i + 1], &v)
                let chunkOffset = pageOffset + i * 8
                let chunkSize = min(8, totalLength - chunkOffset)
                if chunkSize > 0 { memcpy(ptr.baseAddress! + chunkOffset, &v, chunkSize) }
            }
        }
        lvFailPageBuffer = buffer
        var csValue: UInt64 = 0
        darwin_notify_get_state(lvFailSlotTokens[kDarwinLiveViewFailedSlotCount - 1], &csValue)
        let expected = UInt32(csValue & 0xFFFFFFFF)
        var computed: UInt32 = 0
        for byte in buffer[pageOffset..<(pageOffset + pageLength)] { computed = computed &+ UInt32(byte) }
        guard computed == expected else { lvFailPageBuffer = nil; return }

        lvFailNextPage += 1
        if lvFailNextPage < lvFailPageCount { return }

        let payload = buffer
        lvFailPageBuffer = nil
        lvFailPageTotal = 0; lvFailPageCount = 0; lvFailNextPage = 0
        guard let text = String(data: payload, encoding: .utf8) else { return }
        presentLiveViewFailureAlert(payload: text)
    }

    // MARK: - USB blocked (extension → agent)

    /// Curated list of apps known to keep an ImageCapture session alive
    /// just by running, even if their UI isn't actively showing camera
    /// content. These are the most common "but PTP Webcam says my camera
    /// is busy!" culprits. When the extension reports USB-blocked we
    /// intersect this list with `NSWorkspace.runningApplications` to
    /// build the "Held by …" UI.
    ///
    /// Order matters: the list is shown to the user in this order if
    /// multiple are running, so put the highest-confidence offenders
    /// first. Bundle IDs only — display names come from `localizedName`
    /// on the NSRunningApplication so locale-translated names are
    /// preserved automatically.
    private static let knownImageCaptureHolders: [String] = [
        "com.apple.Preview",        // adds an ICDeviceBrowser session on launch for "Import from …"
        "com.apple.Photos",         // ditto, for the Import sidebar
        "com.apple.Image_Capture",  // obvious
        "com.adobe.LightroomClassicCC7", "com.adobe.LightroomClassic",  // tethering
        "com.captureone.captureone16", "com.phaseone.captureone",        // Capture One
        "com.helmut-kramer.iPhoto", "com.apple.iPhoto",
        "com.smoothware.imageeditor",
        "us.zoom.xos",              // Zoom enumerates AVCaptureDevices aggressively
        "com.tinrocket.fragment",   // user reports
    ]

    /// Find running apps from `knownImageCaptureHolders`. Returns
    /// (bundleId, localizedName) pairs in the same order as the curated
    /// list — caller decides how many to surface.
    private func detectRunningCameraHolders() -> [(bundleId: String, displayName: String)] {
        let running = NSWorkspace.shared.runningApplications
        var byBundle: [String: NSRunningApplication] = [:]
        for app in running {
            if let bid = app.bundleIdentifier { byBundle[bid] = app }
        }
        return Self.knownImageCaptureHolders.compactMap { bid in
            guard let app = byBundle[bid] else { return nil }
            let name = app.localizedName ?? bid
            return (bundleId: bid, displayName: name)
        }
    }

    private func handleUsbBlocked() {
        var slot0: UInt64 = 0
        darwin_notify_get_state(usbBlockedSlotTokens[0], &slot0)
        let totalLength = Int(slot0 >> 32)
        let pageIndex   = Int((slot0 >> 16) & 0xFFFF)
        let pageCount   = Int(slot0 & 0xFFFF)
        guard totalLength > 0, pageCount > 0, pageIndex < pageCount else { return }

        let pageDataSlots = kDarwinUsbBlockedSlotCount - 2
        let pageSize = pageDataSlots * 8
        let pageOffset = pageIndex * pageSize
        let pageLength = min(pageSize, totalLength - pageOffset)
        guard pageLength > 0 else { return }

        if pageIndex == 0 || usbBlockedPageBuffer == nil || usbBlockedPageTotal != totalLength {
            usbBlockedPageBuffer = Data(count: totalLength)
            usbBlockedPageTotal = totalLength
            usbBlockedPageCount = pageCount
            usbBlockedNextPage = 0
        }
        guard var buffer = usbBlockedPageBuffer, pageIndex == usbBlockedNextPage else {
            usbBlockedPageBuffer = nil; return
        }
        buffer.withUnsafeMutableBytes { ptr in
            for i in 0..<((pageLength + 7) / 8) {
                var v: UInt64 = 0
                darwin_notify_get_state(usbBlockedSlotTokens[i + 1], &v)
                let chunkOffset = pageOffset + i * 8
                let chunkSize = min(8, totalLength - chunkOffset)
                if chunkSize > 0 { memcpy(ptr.baseAddress! + chunkOffset, &v, chunkSize) }
            }
        }
        usbBlockedPageBuffer = buffer

        var csValue: UInt64 = 0
        darwin_notify_get_state(usbBlockedSlotTokens[kDarwinUsbBlockedSlotCount - 1], &csValue)
        let expected = UInt32(csValue & 0xFFFFFFFF)
        var computed: UInt32 = 0
        for byte in buffer[pageOffset..<(pageOffset + pageLength)] { computed = computed &+ UInt32(byte) }
        guard computed == expected else { usbBlockedPageBuffer = nil; return }

        usbBlockedNextPage += 1
        if usbBlockedNextPage < usbBlockedPageCount { return }

        let payload = buffer
        usbBlockedPageBuffer = nil
        usbBlockedPageTotal = 0; usbBlockedPageCount = 0; usbBlockedNextPage = 0
        guard let cameraId = String(data: payload, encoding: .utf8), !cameraId.isEmpty else { return }

        let culprits = detectRunningCameraHolders()
        AppDelegate.error("PtpCameraAgent: USB blocked for \(cameraId) — likely culprits: \(culprits.isEmpty ? "(none known running)" : culprits.map { $0.displayName }.joined(separator: ", "))")
        guard extCameras[cameraId] != nil else { return }
        // Record whether we know any culprits or not — the menu builder
        // uses the empty-vs-non-empty distinction to choose between
        // "⚠ held by X — click to release" and a generic "⚠ camera busy"
        // message. We don't suppress the blocked state just because we
        // couldn't identify the holder: the user still needs to know
        // PTP Webcam can't open the camera so they can investigate.
        extCameras[cameraId]?.blockingApps = culprits
        extCameras[cameraId]?.isBusyUnknownHolder = culprits.isEmpty
        rebuildMenu()
    }

    /// Observer for `NSWorkspace.didTerminateApplicationNotification`.
    /// If a terminated app is in our `knownImageCaptureHolders` list and
    /// is referenced by any camera's `blockingApps`, we remove that
    /// entry. Cameras whose blockingApps list becomes empty get a fresh
    /// claim retry — at that point ptpcamerad has either already exited
    /// (no clients left) or is about to, and our next USB open should
    /// succeed.
    ///
    /// This handles the "user quits Preview from the Dock" path: the
    /// user doesn't have to invoke our menu action; we observe the
    /// termination event and recover automatically.
    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        // Only react to terminations of apps we tracked as blockers. We
        // don't gate on `knownImageCaptureHolders` here because the
        // blocker check already encodes that — but skipping irrelevant
        // events early saves a dict walk on every random app launch.
        guard Self.knownImageCaptureHolders.contains(bundleId) else { return }

        var nowUnblocked: [String] = []
        for (cid, cam) in extCameras {
            guard cam.blockingApps.contains(where: { $0.bundleId == bundleId }) else { continue }
            extCameras[cid]?.blockingApps.removeAll { $0.bundleId == bundleId }
            // Only retry if this was the last blocker — there's no point
            // racing ptpcamerad if other holders are still alive.
            if extCameras[cid]?.blockingApps.isEmpty == true {
                nowUnblocked.append(cid)
            }
        }

        // Always refresh the live "Camera busy" panel — even if no
        // camera is fully unblocked yet, the list shown to the user
        // should shrink by one entry so they see progress.
        refreshBlockerPanelIfVisible()

        if !nowUnblocked.isEmpty {
            AppDelegate.log("PtpCameraAgent: \(bundleId) terminated — retrying \(nowUnblocked.count) camera(s)")
            rebuildMenu()
            // Brief delay so ptpcamerad (now without its last client) has
            // time to actually release the USB device before we try
            // again. Empirically ptpcamerad shuts down within a few
            // hundred ms of its last client disconnecting; 500 ms is
            // comfortable headroom.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                for cid in nowUnblocked {
                    self?.retryClaim(for: cid)
                }
            }
        } else {
            // App was a blocker but other blockers remain — just refresh
            // the menu so the user sees the shortened list.
            rebuildMenu()
        }
    }

    /// Payload format is "<Camera Name>\n<reason>". Splitting on the first
    /// newline keeps the camera name in the dialog title and the long
    /// explanation in the informative text.
    private func presentLiveViewFailureAlert(payload: String) {
        let parts = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let cameraName = parts.count >= 1 ? String(parts[0]) : "Camera"
        let reason     = parts.count >= 2 ? String(parts[1]) : payload
        // Suppress repeat alerts of the same text within 3 seconds — vendor
        // state machines can fire the failure more than once per attempt.
        let now = Date()
        if payload == lastLvFailAlertText, now.timeIntervalSince(lastLvFailAlertAt) < 3.0 {
            return
        }
        lastLvFailAlertText = payload
        lastLvFailAlertAt = now

        AppDelegate.error("PtpCameraAgent: live view failed (\(cameraName)) — \(reason)")
        // NSAlert from a status-bar process needs the app to be active or it
        // can appear behind the foreground app (QuickTime). activate() + the
        // standard NSAlert.runModal flow puts it on top regardless.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("%@ could not start live view",
                                       comment: "LV failure alert title, %@ = camera name"),
            cameraName)
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK"))
        alert.runModal()
    }

    private func handlePropertyStateChange() {
        // Delegate the slot-chain page reassembly to the shared
        // `CameraPropertyStatePageReassembler` (in CameraModel.swift).
        // The host app's CameraPropertyStore uses the same class so the
        // wire-format logic only exists in one place.
        guard let completeData = propPageReassembler.handlePage(slotTokens: propSlotTokens) else { return }
        processPropertyStateJson(completeData)
    }

    private func processPropertyStateJson(_ jsonData: Data) {
        // Wire-format parsing now lives in the shared `ExtCamera.parse`
        // function (see CameraModel.swift). This wrapper only applies
        // the agent-specific side effects: blocked-app continuity,
        // auto-claim on first publish, sticky-property replay, and
        // menu rebuild. The host app's HUD uses the same parser and
        // skips all of these.
        let parsed = ExtCamera.parse(jsonData: jsonData)
        switch parsed {
        case .invalid:
            return
        case .disconnected(let cameraId):
            extCameras.removeValue(forKey: cameraId)
            // Re-arm sticky-replay for this cameraId — if it reconnects later
            // (or under a fresh IOKit registry entry id), we want to replay
            // saved values again.
            stickyApplied.remove(cameraId)
            AppDelegate.log("PtpCameraAgent: camera removed from menu: \(cameraId)")
            rebuildMenu()
            return
        case .camera(var newCam):
            // Preserve a previously-set `blockingApps` / `isBusyUnknownHolder`
            // across re-publishes that come in before the camera actually
            // opens (the extension publishes an empty props=0 state at
            // attach time, before it even tries to claim USB; the blocked
            // diagnostic arrives after that and we shouldn't lose it on
            // the next attach republish). Reset only when a non-empty
            // property set arrives (camera opened — no longer blocked).
            //
            // Also: if the extension republishes without a "name" field
            // for an unrecognised-VID/PID camera, the shared parser
            // substitutes the literal "PTP Camera" fallback. Restore
            // the previously-known name if we had one, so the menu
            // entry doesn't suddenly degrade from a real model name.
            let cameraId = newCam.cameraId
            if let prev = extCameras[cameraId] {
                // Empty-props republish for a camera that already
                // has populated properties: treat as transient
                // noise. Observed on the Z8 mid-session — the
                // extension occasionally emits an empty publish
                // while live view is still running, and naively
                // overwriting the agent's stored state would
                // revert the menu to "Opening PTP session…"
                // until the next populated publish lands. Real
                // disconnects come through the `.disconnected`
                // case which removes the entry outright, so
                // silently dropping the empty publish here can't
                // mask an actual session-loss.
                if newCam.properties.isEmpty && !prev.properties.isEmpty {
                    AppDelegate.log("PtpCameraAgent: ignoring empty-props republish for \(cameraId) (have \(prev.properties.count) prev props)")
                    return
                }
                if newCam.properties.isEmpty {
                    newCam.blockingApps = prev.blockingApps
                    newCam.isBusyUnknownHolder = prev.isBusyUnknownHolder
                }
                if newCam.name == "PTP Camera", prev.name != "PTP Camera" {
                    newCam = ExtCamera(
                        cameraId: cameraId, name: prev.name, claimKey: newCam.claimKey,
                        vid: newCam.vid, pid: newCam.pid, serial: newCam.serial,
                        properties: newCam.properties, orderedPropertyIds: newCam.orderedPropertyIds,
                        vendor: newCam.vendor,
                        blockingApps: newCam.blockingApps)
                    newCam.isBusyUnknownHolder = prev.isBusyUnknownHolder
                }
            }
            extCameras[cameraId] = newCam
            AppDelegate.log("PtpCameraAgent: property state for \(cameraId) claimKey=\(newCam.claimKey) props=\(newCam.properties.count)")

            applySideEffects(for: newCam)
            rebuildMenu()
        }
    }

    /// Side effects after a successful property-state parse: auto-claim
    /// the camera if it was previously claimed, and replay sticky
    /// property values once per session. Extracted so
    /// `processPropertyStateJson` reads as a clean dispatch over the
    /// parser's result enum.
    private func applySideEffects(for newCam: ExtCamera) {
        let claimKey = newCam.claimKey
        let vid = newCam.vid
        let pid = newCam.pid
        let serial = newCam.serial
        let cameraId = newCam.cameraId
        let vendor = newCam.vendor
        let properties = newCam.properties

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

        // Note: `rebuildMenu()` is invoked by `processPropertyStateJson`
        // after this returns — kept there so disconnect and update paths
        // are symmetric.
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
        // Menu single-click = press-and-release in one shot.
        // Send TRIGGER immediately, then CANCEL after ~250 ms so
        // the body has time to drive the AF motor before the
        // shutter-half-press is released. Matches the HUD chip's
        // press-and-hold timing for the no-modifier release case.
        let trigger: UInt64 = UInt64(4) << 56
        postCameraCommand(cameraId: cameraId, packed: trigger, label: "TRIGGER_AF")
        let cancel: UInt64 = UInt64(5) << 56
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.postCameraCommand(cameraId: cameraId, packed: cancel, label: "CANCEL_AF")
        }
    }

    /// Common per-camera Darwin-notify post for both SET_PROP and TRIGGER_AF.
    private func postCameraCommand(cameraId: String, packed: UInt64, label: String) {
        guard let camera = extCameras[cameraId] else {
            AppDelegate.error("PtpCameraAgent: postCameraCommand — unknown cameraId \(cameraId)")
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

    func applicationWillTerminate(_ aNotification: Notification) {
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

        if extCameras.isEmpty {
            let item = NSMenuItem(title: "No Cameras Connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
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

    private func addExtCameraMenu(_ camera: ExtCamera, to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let isClaimed = claimedCameraKeys.contains(camera.claimKey)

        // Single clickable camera header that doubles as the claim toggle.
        //   Claimed:    "<Camera Name> [serial]"                  with checkmark, click to release
        //   Unclaimed:  "<Camera Name> [serial] (click to claim)" no checkmark
        // Experimental bodies — anything not in our verified list — get an
        // "(experimental)" suffix so users know the support hasn't been
        // tested against real hardware and may have gaps or rough edges.
        let displaySerial = formatSerialForDisplay(camera.serial, vendor: camera.vendor)
        let nameWithSerial = displaySerial.isEmpty
            ? camera.name
            : "\(camera.name) [\(displaySerial)]"
        let isExperimental = !isCameraVerified(vid: camera.vid, pid: camera.pid)
        let nameWithFlag = isExperimental
            ? "\(nameWithSerial) (experimental)"
            : nameWithSerial
        let title = isClaimed ? nameWithFlag : "\(nameWithFlag) (click to claim)"
        let header = NSMenuItem(title: title,
                                action: #selector(claimCameraAction(_:)),
                                keyEquivalent: "")
        header.target = self
        header.representedObject = camera.cameraId
        header.state = isClaimed ? .on : .off
        menu.addItem(header)

        if !isClaimed { return }

        if camera.properties.isEmpty {
            if !camera.blockingApps.isEmpty {
                // Extension reported USB busy and the agent identified the
                // culprit(s). Single clickable row opens the confirmation
                // dialog that walks through terminating them.
                let names = camera.blockingApps.map { $0.displayName }.joined(separator: ", ")
                _ = names
                let item = NSMenuItem(title: "  ⚠ Camera Held by Other App…",
                                      action: #selector(promptReleaseBlockedCameraAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = camera.cameraId
                menu.addItem(item)
            } else if camera.isBusyUnknownHolder {
                // Extension reported USB busy but no app from our curated
                // holder list is currently running. Either ptpcamerad is
                // lingering after a holder app already quit, or something
                // we don't track (third-party tether app, browser-based
                // WebUSB, etc.) has the device. No actionable terminate,
                // but the user still sees the camera isn't accessible.
                let item = NSMenuItem(title: "  ⚠ Camera Busy",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: "  Opening PTP session…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            return
        }

        // PTP session is open (properties non-empty). The preview-video
        // item lives here so it doesn't appear while the camera is still
        // being claimed / opened — clicking it before properties were
        // discovered just opened a black preview window.
        let previewItem = NSMenuItem(title: "  Preview Video Stream…",
                                     action: #selector(showPreviewAction(_:)),
                                     keyEquivalent: "")
        previewItem.target = self
        previewItem.representedObject = camera.cameraId
        menu.addItem(previewItem)

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
            // Canon EOS exposes three WB-related slots; surface all
            // three. 0xD1B4 is the live-view WB MODE selector
            // (Auto / Daylight / Cloudy / ... — actual mode codes).
            // 0xD10A is the still-capture WB; in Color-Temp mode it
            // reports the Kelvin value. 0xD1B6 is the live-view
            // Kelvin override for the preview. See
            // `formatCanonExtProp` in `PropertyFormatter.swift` for
            // how each is decoded.
            0xD1B4,   // WB Mode (live view)
            0xD10A,   // WB Still / CT
            0xD1B6,   // EVF Color Temperature
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
            // `camera.formattedValue` honors the composite-display rules
            // in CameraModel.swift — most importantly, when WB is in
            // Color Temperature mode it substitutes the actual Kelvin
            // reading instead of the static "Color Temperature" label.
            // Falls back to the previous per-property formatter when no
            // composite rule applies, so every other row renders the
            // same as before.
            let valueStr = camera.formattedValue(forPropertyId: propId)
                ?? formatExtPropValue(prop, vendor: vendor)
            let item = NSMenuItem(title: "  \(displayName): \(valueStr)", action: nil, keyEquivalent: "")
            item.submenu = buildExtPropSubmenu(prop, propId: propId, camera: camera, vendor: vendor, parentItem: item)
            menu.addItem(item)
        }

        // Autofocus trigger. Per-vendor support:
        //   Nikon:  AfDrive (0x90C1) — solid.
        //   Sony:   AutofocusButton toggle (0xD2C1).
        //   Leica:  LEReleaseStages (0x9004) with push/release stages, the
        //           same release-ladder Adobe Lightroom's plugin uses.
        //   Fuji:   Camera Action property write 0xD208 = 0x0200 + standard
        //           InitiateCapture (0x100E) + poll AFStatus (0xD209). We
        //           gate on the presence of 0xD208 so older bodies without
        //           the Camera Action prop don't get a dead menu item.
        //   Canon / Panasonic / Olympus / Sigma: not wired yet — AF opcodes
        //           either need on-camera coordinate payloads or haven't
        //           been verified against hardware.
        let supportsAf: Bool = {
            switch vendor {
            case .nikon, .leica: return true
            case .sony: return camera.properties[0xD2C1] != nil
            // Fuji: 0xD208 is sometimes missing from GetDeviceInfo even on
            // bodies that accept the prop write. Show the
            // menu item for all Fuji bodies; the extension logs and bails
            // cleanly if the prop write returns AccessDenied.
            case .fuji: return true
            default: return false
            }
        }()
        if supportsAf {
            menu.addItem(NSMenuItem.separator())
            let afItem = NSMenuItem(title: "  Autofocus",
                                    action: #selector(extAutofocusAction(_:)),
                                    keyEquivalent: "")
            afItem.target = self
            afItem.representedObject = camera.cameraId
            menu.addItem(afItem)
        }
    }

    // Build the appropriate submenu for a writable ext-camera property.
    // Priority: 2D WB-tune matrix → 1D WB-tune bar → Planckian locus
    // (CT props) → enum (with optional WB sub-props) → slider (range,
    // no enum).
    private func buildExtPropSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                     camera: ExtCamera, vendor: ProtocolFamily = .unknown,
                                     parentItem: NSMenuItem? = nil) -> NSMenu? {
        guard prop.writable else { return nil }
        // Some cameras (notably Sony A7) report intrinsically read-only sensor
        // properties as writable in GetAllPropData. Suppress submenu building
        // for the known-physical-read-only set so they don't get sliders.
        if intrinsicallyReadOnlyProps.contains(propId) { return nil }

        // WB tune properties: 2D matrix for the 168/1224 encodings,
        // 1D green↔magenta bar for everything else. Both branches
        // reuse the same NSView pickers the host-app HUD uses, so
        // the menu and HUD look and behave identically.
        if let tune = camera.tuneStyle(forPropertyId: propId) {
            switch tune {
            case .grid2D(let rangeMax):
                return buildWbTuneGridSubmenu(
                    prop, propId: propId, cameraId: camera.cameraId,
                    rangeMin: 0, rangeMax: rangeMax)
            case .bar1D(let values):
                return buildWbTune1DBarSubmenu(
                    prop, propId: propId, cameraId: camera.cameraId,
                    values: values)
            }
        }

        // Colour-temperature Kelvin values: Planckian-locus picker
        // (same NSView the HUD's CT chip uses).
        if camera.isColorTemperatureProperty(propId),
           let rMin = prop.rangeMin, let rMax = prop.rangeMax {
            let step = max(1, prop.rangeStep?.intValue ?? 100)
            return buildPlanckianLocusSubmenu(
                prop, propId: propId, cameraId: camera.cameraId,
                rangeMin: rMin.intValue, rangeMax: rMax.intValue, step: step)
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
                   case let subPropIds = ExtCamera.whiteBalanceSubPropertyIds(
                       forModeValue: enumVal.uint32Value),
                   !subPropIds.isEmpty {
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
    /// Insets around custom NSView-based menu items, split per
    /// axis because the two macOS UI eras need very different
    /// values:
    ///
    /// • Pre-26 menus render custom views flush against their
    ///   rounded corners — we need a uniform 8 pt on all sides
    ///   for them to breathe.
    ///
    /// • macOS 26 ("Tahoe", Liquid Glass) adds its own generous
    ///   vertical padding around custom NSMenuItem views, so we
    ///   add zero vertical ourselves (otherwise the picker reads
    ///   as floating in too much air). It does NOT add equivalent
    ///   horizontal padding though, so we still need a moderate
    ///   horizontal inset for the picker to clear the menu's
    ///   rounded corners.
    private static let menuPickerHInset: CGFloat = {
        if #available(macOS 26.0, *) { return 12 }
        return 8
    }()
    private static let menuPickerVInset: CGFloat = {
        if #available(macOS 26.0, *) { return 0 }
        return 8
    }()

    /// Wrap a picker NSView in a padded container and stick it on
    /// the NSMenuItem. Used by all three custom-picker submenus
    /// (2D grid, 1D bar, Planckian locus) so they share the same
    /// margin treatment.
    private func wrappedMenuItem(picker: NSView) -> NSMenuItem {
        let pickerSize = picker.frame.size
        let hInset = Self.menuPickerHInset
        let vInset = Self.menuPickerVInset
        let wrapper = NSView(frame: NSRect(
            x: 0, y: 0,
            width: pickerSize.width + 2 * hInset,
            height: pickerSize.height + 2 * vInset))
        picker.setFrameOrigin(NSPoint(x: hInset, y: vInset))
        wrapper.addSubview(picker)
        let item = NSMenuItem()
        item.view = wrapper
        return item
    }

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
        let submenu = NSMenu()
        submenu.addItem(wrappedMenuItem(picker: grid))
        return submenu
    }

    /// 1D bar picker on either the green↔magenta or amber↔blue
    /// axis, picked by propId (Sony 0xD21C is the only A-B tune
    /// the agent and HUD both know about today). Mirrors the
    /// HUD's `TuneBarStrip` so menu and HUD look identical.
    private func buildWbTune1DBarSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                         cameraId: String, values: [Int]) -> NSMenu {
        let size = WbTune1DBarView.idealSize(cellCount: values.count)
        let bar = WbTune1DBarView(frame: NSRect(origin: .zero, size: size))
        bar.axis = TuneBarAxis.forPropertyId(propId)
        bar.values = values
        bar.currentValue = prop.value.intValue
        bar.onValueSelected = { [weak self] val in
            self?.postPropertyCommand(cameraId: cameraId, propId: propId,
                                      value: NSNumber(value: val))
        }
        let submenu = NSMenu()
        submenu.addItem(wrappedMenuItem(picker: bar))
        return submenu
    }

    /// CIE-style Planckian-locus picker for colour-temperature
    /// Kelvin properties (Nikon 0xD01E, Sony 0xD20F). Same view
    /// the HUD's CT chip uses, just rendered into an NSMenuItem
    /// for the agent's status-bar menu surface.
    private func buildPlanckianLocusSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                            cameraId: String,
                                            rangeMin: Int, rangeMax: Int, step: Int) -> NSMenu {
        let size = PlanckianLocusView.idealSize()
        let picker = PlanckianLocusView(frame: NSRect(origin: .zero, size: size))
        picker.configure(rangeMin: rangeMin, rangeMax: rangeMax, step: step,
                         currentKelvin: prop.value.intValue)
        picker.onValueSelected = { [weak self] val in
            self?.postPropertyCommand(cameraId: cameraId, propId: propId, value: NSNumber(value: val))
        }
        let submenu = NSMenu()
        submenu.addItem(wrappedMenuItem(picker: picker))
        return submenu
    }

    // NSMenuItem containing a SonyStepperView (− value +). The buttons can be
    // clicked repeatedly without dismissing the menu.
    private func buildSonyStepperSubmenu(_ prop: ExtCameraProperty, propId: UInt32,
                                         enumValues: [NSNumber], cameraId: String,
                                         vendor: ProtocolFamily,
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
                                    vendor: ProtocolFamily = .unknown,
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
    /// True when a camera is in our verified list — entries we've end-to-end
    /// tested against real hardware. Unknown VID/PID combinations and
    /// known-but-unconfirmed entries fall into "experimental" territory:
    /// they may work fine, but property discovery / live view / control
    /// might have rough edges we haven't ironed out.
    private func isCameraVerified(vid: UInt16, pid: UInt16) -> Bool {
        guard let entry = PtpKnownCameras.lookup(vid: vid, pid: pid) else { return false }
        return entry.confirmed
    }

    private func formatSerialForDisplay(_ serial: String, vendor: ProtocolFamily) -> String {
        guard vendor == .nikon, !serial.isEmpty else { return serial }
        let trimmed = String(serial.drop(while: { $0 == "0" }))
        // Don't return "" if the camera literally reported all zeros — show
        // the original so it's obvious something odd is going on.
        return trimmed.isEmpty ? serial : trimmed
    }

    private func formatExtPropValue(_ prop: ExtCameraProperty, vendor: ProtocolFamily = .unknown) -> String {
        formatExtPropRaw(prop.value, propId: prop.propertyId, vendor: vendor)
    }

    // MARK: - Menu Actions

    @objc private func extAutofocusAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String else { return }
        postAutofocusCommand(cameraId: cameraId)
    }

    @objc private func changePropertyAction(_ sender: NSMenuItem) {
        if let change = sender.representedObject as? ExtPropertyChangeInfo {
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

    /// Menu action for the "⚠ Camera busy — held by X — click to release"
    /// row. Opens a confirmation NSAlert listing every app the agent has
    /// identified as blocking ANY currently-affected camera (not just the
    /// one the user clicked through), and on confirm terminates all of
    /// them and retries the claim for every camera whose blockingApps
    /// included any of the terminated bundles. The set-based handling is
    /// what fixes the multi-camera case — if a single Preview holds two
    /// cameras hostage, one click cleans both up.
    @objc private func promptReleaseBlockedCameraAction(_ sender: NSMenuItem) {
        guard let cameraId = sender.representedObject as? String else { return }
        // We could try to send `quit` Apple Events from here, but every
        // sandbox-compatible path we explored is broken on current macOS:
        //   - `NSRunningApplication.terminate()` from the agent: sandboxd
        //     denies appleevent-send even with `automation.apple-events`
        //     declared (TCC attribution walks to the SMAppService parent
        //     and never resolves correctly for LSUIElement helpers).
        //   - Routing the same call through the host app via a custom
        //     URL: NSAppleScript "tell application id" hits
        //     `procNotFound destPort == NULL` from a sandboxed sender on
        //     macOS 26 even though the target app is reachable from
        //     `osascript` in Terminal.
        //   - `temporary-exception.apple-events`: requires hardcoded
        //     bundle IDs, which kills the dynamic-detection design.
        // So we surface a purely informative panel and let the user
        // quit the apps themselves. The `handleAppTerminated(_:)`
        // observer (NSWorkspace notification — no entitlement required)
        // picks up each quit and refreshes this panel. When the holder
        // list becomes empty, the panel closes and the camera claim
        // retries automatically.
        _ = cameraId  // recovery is camera-agnostic — observer touches all blocked cameras
        showOrRefreshBlockerPanel()
    }

    /// Modeless panel listing apps that are holding the camera. Stays
    /// onscreen and updates live as the user quits each app; auto-closes
    /// when nothing's left to quit. Single-instance.
    private var blockerPanel: NSPanel?
    private var blockerPanelBodyLabel: NSTextField?

    private func showOrRefreshBlockerPanel() {
        let holders = detectRunningCameraHolders()
        guard !holders.isEmpty else {
            // Nothing actually holds the camera right now — close any
            // stale panel, clear stale blockingApps, and retry every
            // affected camera. (User may have quit the holders before
            // clicking our menu item.)
            AppDelegate.log("PtpCameraAgent: blocker panel — no holders currently running, clearing stale state")
            closeBlockerPanel()
            var affected: [String] = []
            for (cid, cam) in extCameras where !cam.blockingApps.isEmpty {
                extCameras[cid]?.blockingApps.removeAll()
                affected.append(cid)
            }
            rebuildMenu()
            for cid in affected { retryClaim(for: cid) }
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        if blockerPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false)
            panel.title = "Camera Busy"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating

            let container = NSView(frame: panel.contentView!.bounds)
            container.autoresizingMask = [.width, .height]

            let label = NSTextField(wrappingLabelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isSelectable = true
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            container.addSubview(label)
            blockerPanelBodyLabel = label

            let dismissButton = NSButton(title: "Dismiss",
                                         target: self,
                                         action: #selector(closeBlockerPanelAction(_:)))
            dismissButton.translatesAutoresizingMaskIntoConstraints = false
            dismissButton.keyEquivalent = "\r"
            dismissButton.bezelStyle = .rounded
            container.addSubview(dismissButton)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
                dismissButton.topAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 16),
                dismissButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
                dismissButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            ])

            panel.contentView = container
            panel.center()
            blockerPanel = panel
        }

        updateBlockerPanelText(with: holders)
        blockerPanel?.makeKeyAndOrderFront(nil)
    }

    private func updateBlockerPanelText(with holders: [(bundleId: String, displayName: String)]) {
        guard let label = blockerPanelBodyLabel else { return }
        let displayNames = holders.map { $0.displayName }
        let bulletList = displayNames.map { "  •  \($0)" }.joined(separator: "\n")
        let lead = displayNames.count == 1
            ? "PTP Webcam can't access the camera because this app is using it:"
            : "PTP Webcam can't access the camera because these apps are using it:"
        let trail = displayNames.count == 1
            ? "Please quit it to release the camera. You can reopen it once PTP Webcam has finished enumerating the cameras."
            : "Please quit them to release the camera. You can reopen them once PTP Webcam has finished enumerating the cameras."
        label.stringValue = "\(lead)\n\n\(bulletList)\n\n\(trail)\n\nThis window will close automatically when the apps have been quit."
    }

    /// Re-evaluate the holder list and refresh or auto-close the panel.
    /// Called from `handleAppTerminated(_:)` so the list shrinks live as
    /// the user closes each holder.
    private func refreshBlockerPanelIfVisible() {
        guard blockerPanel != nil else { return }
        let holders = detectRunningCameraHolders()
        if holders.isEmpty {
            closeBlockerPanel()
        } else {
            updateBlockerPanelText(with: holders)
        }
    }

    @objc private func closeBlockerPanelAction(_ sender: Any?) {
        closeBlockerPanel()
    }

    private func closeBlockerPanel() {
        blockerPanel?.orderOut(nil)
        blockerPanel?.close()
        blockerPanel = nil
        blockerPanelBodyLabel = nil
    }

    /// Re-issue the claim command for a camera (used after we successfully
    /// terminate a blocking app, so the extension gets another shot at
    /// opening the USB interface).
    private func retryClaim(for cameraId: String) {
        guard let camera = extCameras[cameraId] else { return }
        let parts = camera.claimKey.split(separator: ":")
        let vid  = UInt16(parts.count > 0 ? UInt32(parts[0], radix: 16) ?? 0 : 0)
        let pid  = UInt16(parts.count > 1 ? UInt32(parts[1], radix: 16) ?? 0 : 0)
        let serial = parts.count > 2 ? String(parts[2...].joined(separator: ":")) : ""
        AppDelegate.log("PtpCameraAgent: retry claim for \(camera.claimKey)")
        sendClaimCommand(vid: vid, pid: pid, serial: serial, claim: true)
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

        // We used to replay the legacy `cameras` dict to the new XPC peer here
        // (so reconnecting clients got current state without waiting for the
        // next attach). That dict is gone — the extension publishes camera
        // state directly via Darwin notify slots now, which any XPC client
        // would already be listening on.

        return true
    }
}


// MARK: - PtpCameraAgentProtocol

// The PtpCameraAgentProtocol's `startLiveView` / `stopLiveView` /
// `setPropertyValue` methods are XPC entry points from the legacy
// ImageCapture path. With the CMIO-extension architecture the extension
// owns USB and the agent is no longer in the loop for these — we keep
// the conformance so existing XPC clients don't get a connection error,
// but the implementations just log and return.
extension AppDelegate: PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String) {
        AppDelegate.log("PtpCameraAgent: legacy XPC startLiveView(\(cameraId)) — no-op")
    }

    func stopLiveView(forCamera cameraId: String) {
        AppDelegate.log("PtpCameraAgent: legacy XPC stopLiveView(\(cameraId)) — no-op")
    }

    func setPropertyValue(_ value: Any, forProperty propertyId: NSNumber, onCamera cameraId: String) {
        logger.info("legacy XPC setProperty \(propertyId, privacy: .public) for \(cameraId, privacy: .public) — ignored, extension owns properties")
    }

}

// MARK: - Extension-published camera types
//
// The `ExtCameraProperty` and `ExtCamera` structs, plus the JSON parser
// for the `kDarwinCameraPropertyState` slot chain, now live in the
// shared file `CameraModel.swift` so the host app's preview-window HUD
// can read the same data without duplicating the wire-format logic.
// `ProtocolFamily` is declared in SupportedCameras.swift (also shared).

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
    private let vendor: ProtocolFamily
    private let onStep: (NSNumber) -> Void
    /// Called with the formatted current-value string on every step, so the
    /// caller can mirror it into the parent menu item's title.
    var onDisplay: ((String) -> Void)?

    private let prevButton  = NSButton()
    private let valueLabel  = NSTextField(labelWithString: "")
    private let nextButton  = NSButton()

    init(propId: UInt32, enumValues: [NSNumber], currentValue: NSNumber,
         vendor: ProtocolFamily, onStep: @escaping (NSNumber) -> Void) {
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

// (Was: `nikonWbTuneIds`. The agent now routes through
// `camera.tuneStyle(forPropertyId:)` in CameraModel.swift, which
// owns the canonical list of tune property IDs and the
// 1D-vs-2D distinction. The local Set was last-referenced before
// the menu/HUD dispatch unification and is now dead.)

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

// (Was: `nikonWbSubProperties`. The canonical mapping lives in
// `CameraModel.swift` as `nikonWhiteBalanceSubProperties` and is
// exposed via `ExtCamera.whiteBalanceSubPropertyIds(forModeValue:)`
// — used both by the agent's per-mode WB submenu and the HUD's
// `whiteBalanceTunePropertyIds()`. Single source of truth.)

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
func displayName(for propId: UInt32, vendor: ProtocolFamily) -> String? {
    if vendor == .canon, let n = canonExtPropDisplayNames[propId] { return n }
    return extPropDisplayNames[propId]
}

// nikonExtPropValueNames lives in PropertyFormatter.swift.
