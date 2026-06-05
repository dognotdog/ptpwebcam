// MainWindowView.swift
// Top-level UI shown when the user opens PTP Webcam from the Dock / Finder.
// Provides app status (extension state, build version) and a place to start
// or manage an in-app subscription.

import SwiftUI
import StoreKit
import SystemExtensions
// NOTE: deliberately not importing AVFoundation here. An earlier
// version of ServiceHealthObserver queried
// AVCaptureDevice.DiscoverySession to detect "extension installed",
// and that broke CMIO device enumeration for the in-app live
// preview (see comment in `poll()`). The dependency is gone and
// the import along with it, so a future contributor can't add
// it back by accident without re-importing first. Install state
// now comes from `OSSystemExtensionRequest.propertiesRequest` —
// see `ExtensionInstallProbe` below.

/// Observes the agent's menu-bar status item visibility via the
/// `kDarwinMenuBarHidden` Darwin notify slot. The agent posts when the
/// occlusion state of its NSStatusItem flips (notch overflow, third-party
/// menu-bar managers collapsing it, Control Center hiding it). We
/// republish as a `@Published` bool so the SwiftUI About window can show
/// a warning banner without imperative reload logic.
///
/// Singleton because there's only one agent and the slot read is cheap —
/// no point in having multiple Views each register their own dispatch
/// token. Lives as long as the host app process.
final class MenuBarVisibilityObserver: ObservableObject {
    static let shared = MenuBarVisibilityObserver()

    /// True while the agent has published "hidden". Drives the warning
    /// banner in MainWindowView. We intentionally don't try to
    /// distinguish overflow-hidden from intentionally-disabled — the
    /// two states are observationally identical on macOS 26 (same
    /// frame, same occlusion state, no defaults-domain signal flips
    /// between them) so the banner copy addresses both possibilities.
    @Published private(set) var menuBarItemHidden: Bool = false

    private var slotToken: Int32 = 0
    private var notifyToken: Int32 = 0

    private init() {
        // Register the slot for reads, then subscribe to posts. Both
        // tokens are kept for the lifetime of the process — there's no
        // unsubscribe path because the observer is a long-lived
        // singleton tied to the app, not to any specific view.
        darwin_notify_register_check(kDarwinMenuBarHiddenSlot, &slotToken)
        darwin_notify_register_dispatch(kDarwinMenuBarHidden, &notifyToken, .main) { [weak self] _ in
            self?.refresh()
        }
        // Read the current slot value at init in case the agent posted
        // before our window was opened — Darwin notify doesn't replay
        // for late subscribers.
        refresh()
    }

    private func refresh() {
        var state: UInt64 = 0
        darwin_notify_get_state(slotToken, &state)
        let hidden = (state & 0xFF) != 0
        if hidden != menuBarItemHidden {
            menuBarItemHidden = hidden
        }
    }
}

/// Polls the three service-health Darwin notify slots
/// (extension heartbeat, agent heartbeat, "agent saw extension"
/// stamp) every 2 s and publishes coarse health flags the
/// MainWindowView uses to drive its fault banners.
///
/// Why polling instead of subscribing to the heartbeat posts: we
/// care about *staleness*, which is the absence of recent posts.
/// A dispatch handler can't fire on absence. The poll interval
/// (2 s, same cadence as the heartbeats themselves) keeps the
/// banner latency under ~5 s for any real fault.
///
/// AVCaptureDevice discovery sits on the same timer: a CMIO
/// extension that's been removed/disabled in System Settings >
/// Privacy disappears from AVCaptureDevice.DiscoverySession but
/// stops posting heartbeats too, so the two signals together
/// distinguish "extension not installed" (no AVCaptureDevice)
/// from "installed but crashed" (AVCaptureDevice present,
/// heartbeat stale).
///
/// Lives as a singleton for the same reason MenuBarVisibilityObserver
/// does — one host app, one timer, no per-view dispatch tokens.
final class ServiceHealthObserver: ObservableObject {
    static let shared = ServiceHealthObserver()

    /// True iff the CMIO extension's bundle is registered with
    /// systemextensionsd and currently enabled — i.e. the system
    /// will (or has) load(ed) it. Source: a periodic
    /// `OSSystemExtensionRequest.propertiesRequest` against our
    /// extension's bundle ID. False means one of:
    ///   • Never installed (fresh user, never opened the host app)
    ///   • Uninstalled via `systemextensionsctl uninstall`
    ///   • Disabled in System Settings → General → Login Items &
    ///     Extensions → Camera Extensions
    ///   • Caught in "isUninstalling" (between request and
    ///     completion)
    /// Notably, true does NOT imply the extension process is
    /// currently running — see `extensionAlive` for that.
    @Published private(set) var extensionInstalled: Bool = true

    /// True iff the extension's heartbeat slot has been updated
    /// in the last `staleThreshold` seconds. Distinct from
    /// `extensionInstalled`: the system can have the extension
    /// registered (installed=true) but its process not currently
    /// running (alive=false) — macOS terminates idle CMIO
    /// extensions under memory pressure and respawns them on the
    /// next CMIO client request.
    @Published private(set) var extensionAlive:     Bool = true

    /// True iff the agent's heartbeat slot has been updated in
    /// the last `staleThreshold` seconds. The agent runs as a
    /// login item with KeepAlive — expected to be alive whenever
    /// the user is logged in.
    @Published private(set) var agentAlive:         Bool = true

    /// True iff both heartbeats are fresh but the agent's
    /// "saw extension" timestamp is stale by `commsThreshold`.
    /// In practice this means libnotify dispatch broke between
    /// the two processes (rare but observed after sleep/wake
    /// cycles where the kernel resets per-process notify state
    /// without re-firing the registrations).
    @Published private(set) var commsBroken:        Bool = false

    /// Heartbeats fire every 2 s. Allow two missed posts before
    /// declaring the service down — covers normal scheduling
    /// jitter and a single GC pause without flashing the banner.
    private let staleThreshold: TimeInterval = 5
    /// Comms staleness uses a wider window because libnotify
    /// dispatch hiccups are usually transient — five missed
    /// heartbeats is a clearer signal than two.
    private let commsThreshold: TimeInterval = 12
    /// Grace period after the host app launches before any
    /// banner can appear. The extension and agent may take a few
    /// seconds to spin up their first heartbeats, and showing
    /// "extension not running" for two seconds on every launch
    /// would be a worse UX than a brief blind window.
    private let launchGrace:    TimeInterval = 8

    private let launchedAt: TimeInterval
    private var pollTimer: Timer?
    private var extHbToken:   Int32 = 0
    private var agentHbToken: Int32 = 0
    private var sawExtToken:  Int32 = 0

    /// Polls systemextensionsd for our extension's install state
    /// on a slow cadence (every `installProbeInterval`). Decoupled
    /// from the heartbeat 2 s timer because the install state
    /// changes minute-scale at fastest, and an OSSystemExtension
    /// properties request is heavier than a slot read (crosses a
    /// process boundary via XPC).
    private var installProbe: ExtensionInstallProbe!
    private var installProbeTimer: Timer?
    private let installProbeInterval: TimeInterval = 10


    private init() {
        launchedAt = Date().timeIntervalSince1970
        darwin_notify_register_check(kDarwinExtensionHeartbeatSlot, &extHbToken)
        darwin_notify_register_check(kDarwinAgentHeartbeatSlot,     &agentHbToken)
        darwin_notify_register_check(kDarwinAgentSawExtensionSlot,  &sawExtToken)

        // Stand up the OSSystemExtensionRequest pump. The probe
        // calls our `installStateChanged` whenever a new result
        // arrives — `extensionInstalled` is the published mirror
        // of its last result. Initial state is "unknown but
        // assume installed" (true) so we don't flash the banner
        // before the first probe completes; the launch-grace
        // window covers any transient false-positive window here
        // anyway.
        installProbe = ExtensionInstallProbe(bundleId: "org.ptpwebcam.PtpWebcamApp.CameraExtension") { [weak self] installed in
            // Hop to .main — the SystemExtensions delegate
            // callbacks come back on whatever queue we passed
            // (we use .main), but make it explicit so the
            // @Published assignment always flows through the
            // run loop SwiftUI expects.
            DispatchQueue.main.async { [weak self] in
                self?.applyInstallState(installed)
            }
        }
        installProbe.kick()

        // Kick off an immediate read so the published flags reflect
        // reality before the first timer tick (otherwise SwiftUI
        // paints "all good" defaults for 2 s post-launch).
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        installProbeTimer = Timer.scheduledTimer(withTimeInterval: installProbeInterval, repeats: true) { [weak self] _ in
            self?.installProbe.kick()
        }
    }

    /// Update `extensionInstalled` from the probe's result.
    /// Called on `.main`. We don't apply launch-grace here
    /// because the probe's `kick()` runs on init — by the time
    /// SwiftUI is asking for a paint, we typically already have
    /// the answer.
    private func applyInstallState(_ installed: Bool) {
        if installed != extensionInstalled {
            extensionInstalled = installed
        }
    }

    private func poll() {
        let now = Date().timeIntervalSince1970

        var extStamp:   UInt64 = 0
        var agentStamp: UInt64 = 0
        var sawStamp:   UInt64 = 0
        darwin_notify_get_state(extHbToken,   &extStamp)
        darwin_notify_get_state(agentHbToken, &agentStamp)
        darwin_notify_get_state(sawExtToken,  &sawStamp)

        // Liveness signals — fresh heartbeat slots within the
        // staleness window. These ONLY measure whether each
        // process posted a heartbeat recently. "Alive" is the
        // honest term; we used to call the extension flag
        // "running" but reused the same staleness check as a
        // proxy for "installed", which conflated two distinct
        // concepts. Now the install check has its own source
        // (OSSystemExtensionRequest, see `installProbe`) and
        // these flags only have to mean what they say.
        let extAliveFresh   = (now - TimeInterval(extStamp))   <= staleThreshold
        let agentAliveFresh = (now - TimeInterval(agentStamp)) <= staleThreshold
        let sawFresh        = (now - TimeInterval(sawStamp))   <= commsThreshold

        let inGrace = (now - launchedAt) < launchGrace

        // Apply: never raise a banner during the launch grace
        // window (heartbeats may not have arrived yet). After
        // that, the flags reflect the latest poll's reading.
        // `extensionInstalled` is NOT touched here — its source
        // is the OSSystemExtensionRequest probe, applied via
        // `applyInstallState` on a separate timer cadence.
        let newExtAlive    = inGrace ? true  : extAliveFresh
        let newAgentAlive  = inGrace ? true  : agentAliveFresh
        // Comms-broken only meaningful when both sides claim alive
        // — if one is down, the dedicated banner covers it and we
        // suppress the comms banner to avoid double-stacking.
        let newCommsBroken = inGrace ? false :
            (extAliveFresh && agentAliveFresh && !sawFresh)

        // `extensionInstalled` is owned by the OSSystemExtension
        // probe, not this poll — only the liveness + comms flags
        // are updated here.
        if newExtAlive    != extensionAlive   { extensionAlive   = newExtAlive }
        if newAgentAlive  != agentAlive       { agentAlive       = newAgentAlive }
        if newCommsBroken != commsBroken      { commsBroken      = newCommsBroken }
    }
}

/// Drives a periodic `OSSystemExtensionRequest.propertiesRequest`
/// against the CMIO extension's bundle identifier and reports
/// the result via a callback. Lives as long as
/// `ServiceHealthObserver` does (one per process).
///
/// We keep the request + delegate behind a small NSObject
/// subclass because SwiftUI's `ObservableObject` (a
/// `final class : ObservableObject`) can't conform to
/// `OSSystemExtensionRequestDelegate` cleanly: the delegate
/// protocol requires NSObjectProtocol conformance, and folding
/// that into ServiceHealthObserver would force its callers to
/// reason about Objective-C runtime semantics. A dedicated
/// helper keeps the SwiftUI side pure-Swift.
private final class ExtensionInstallProbe: NSObject, OSSystemExtensionRequestDelegate {
    /// Called on the delegate queue (which we pin to .main when
    /// submitting). True iff at least one `OSSystemExtensionProperties`
    /// entry for our bundle ID is enabled and not in the
    /// uninstalling state — i.e. systemextensionsd will (or has)
    /// load(ed) our extension.
    private let report: (Bool) -> Void
    private let bundleId: String
    /// Track the in-flight request so we don't pile up overlapping
    /// probes if the periodic timer fires while the previous
    /// answer is still pending. (Unlikely — properties requests
    /// finish in <100 ms — but a hung XPC peer shouldn't multiply
    /// our outstanding work.)
    private var inFlight: OSSystemExtensionRequest?

    init(bundleId: String, report: @escaping (Bool) -> Void) {
        self.bundleId = bundleId
        self.report = report
        super.init()
    }

    /// Start a new properties request. No-ops if one is already
    /// in flight.
    func kick() {
        guard inFlight == nil else { return }
        let req = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: bundleId,
            queue: .main)
        req.delegate = self
        inFlight = req
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    /// Properties responses arrive here. An empty array means
    /// systemextensionsd has no record of our bundle ID — i.e.
    /// not installed. A populated array can still mean "not
    /// usable" if every entry is uninstalling; we treat
    /// "installed" as "at least one entry with isEnabled=true
    /// and isUninstalling=false". Disabled-but-installed (user
    /// flipped the toggle in System Settings) reports false here,
    /// matching the user's mental model that the extension isn't
    /// "installed and ready" from PTP Webcam's perspective.
    func request(_ request: OSSystemExtensionRequest,
                 foundProperties properties: [OSSystemExtensionProperties]) {
        let usable = properties.contains { props in
            props.isEnabled && !props.isUninstalling
        }
        inFlight = nil
        report(usable)
    }

    /// `didFinishWithResult` fires for activation/deactivation
    /// requests after `foundProperties`; for a properties request
    /// it signals "we're done, but only `foundProperties` carried
    /// data." If `foundProperties` was never called (rare error
    /// case), we'll have already cleared `inFlight` either way;
    /// guard against a double-clear by checking first.
    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        inFlight = nil
    }

    /// XPC error / systemextensionsd unavailable. We don't change
    /// the published flag from here — keeping the last-known
    /// value avoids flashing a banner on transient errors. The
    /// next periodic kick will retry.
    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        inFlight = nil
    }

    /// Not used for a properties request (no replacement
    /// happening) but required by the protocol.
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    /// Not used for a properties request. Required by protocol.
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}
}

/// Subscribes to the extension's per-camera streaming-state slot
/// chain and re-publishes the result as a `Set<UInt32>` of CRC32
/// camera-id hashes for SwiftUI views to consume. One singleton
/// per process — same shape as MenuBarVisibilityObserver — so
/// the chip view can `@ObservedObject` it without each chip
/// having to register its own dispatch token.
final class StreamingStateObserver: ObservableObject {
    static let shared = StreamingStateObserver()

    /// CRC32s of camera IDs currently delivering CMIO frames.
    /// Empty when no camera is being previewed by any client.
    @Published private(set) var streamingCameraCrcs: Set<UInt32> = []

    private var slotTokens: [Int32] = []
    private var notifyToken: Int32 = 0

    private init() {
        // Register all 8 slot tokens up front so we can read them
        // synchronously inside the dispatch handler. Tokens are
        // process-scoped and free; cost is trivial.
        slotTokens = (0..<kDarwinStreamingSlotCount).map { i in
            var t: Int32 = 0
            darwin_notify_register_check(kDarwinStreamingSlotPrefix + "\(i)", &t)
            return t
        }
        darwin_notify_register_dispatch(kDarwinStreamingChanged, &notifyToken, .main) { [weak self] _ in
            self?.refresh()
        }
        // Pull current state once so a host app that launches
        // while a stream is already active sees the dot
        // immediately instead of having to wait for the next
        // start/stop transition.
        refresh()
    }

    private func refresh() {
        var crcs: Set<UInt32> = []
        for token in slotTokens {
            var v: UInt64 = 0
            darwin_notify_get_state(token, &v)
            let crc = UInt32(v & 0xFFFFFFFF)
            if crc != 0 { crcs.insert(crc) }
        }
        if crcs != streamingCameraCrcs {
            streamingCameraCrcs = crcs
        }
    }
}

/// PreferenceKey used to surface the natural intrinsic height of the
/// MainWindowView's inner content stack up to the window controller.
/// The `reduce` takes the max so partial subview measurements during
/// transitions never shrink the published height below the real value.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension Notification.Name {
    /// Posted by MainWindowView whenever its inner content stack reports
    /// a new natural height. MainWindowController pins the window's
    /// contentMaxSize to this so the user can shrink-but-not-stretch.
    static let mainWindowNaturalHeightChanged = Notification.Name("org.ptpwebcam.mainWindowNaturalHeightChanged")
}

struct MainWindowView: View {
    @StateObject private var store = SubscriptionStore()
    @ObservedObject private var menuBarVisibility = MenuBarVisibilityObserver.shared
    @ObservedObject private var serviceHealth = ServiceHealthObserver.shared
    @ObservedObject private var cameraStore = CameraPropertyStore.shared
    @ObservedObject private var streamingState = StreamingStateObserver.shared

    /// True when the user holds any active subscription. Used by
    /// `productRow` to pick the right call-to-action label — "Switch"
    /// reads more honestly than "Subscribe" when the row would actually
    /// route through StoreKit's tier-change flow.
    private var hasAnyActiveSubscription: Bool {
        if case .subscribed = store.entitlement { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    var body: some View {
        // ScrollView so that on low-resolution screens (1366×768 laptops,
        // where the menu bar + Dock leave only ~670 pt of usable height)
        // the bottom of the content stays reachable when the window can't
        // fit it all. `.scrollBounceBehavior(.basedOnSize)` keeps the
        // overscroll feel only when there's actually something to scroll
        // — on a 1080p+ display the content fits and the view behaves
        // like an ordinary fixed panel.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Connected-cameras chips sit between the header and
                // the service-health banners. When no camera is
                // present we still render the row, swapped for a
                // single dashed-outline placeholder chip — visible
                // negative space reads more clearly than a missing
                // section ("did I plug it in?" vs nothing-to-see).
                connectedCamerasSection
                // Service-health banners are ordered by severity:
                // "not installed" is the only one that blocks all
                // functionality, so it comes first. "Not running"
                // is a runtime fault but recoverable on next demand.
                // Comms-broken is the rarest and least actionable.
                // Each banner is independently shown — multiple can
                // appear together when several conditions hold.
                if !serviceHealth.extensionInstalled {
                    extensionNotInstalledWarning
                } else if !serviceHealth.extensionAlive {
                    extensionNotRunningWarning
                }
                if !serviceHealth.agentAlive {
                    agentNotRunningWarning
                }
                if serviceHealth.commsBroken {
                    commsBrokenWarning
                }
                if menuBarVisibility.menuBarItemHidden {
                    menuBarHiddenWarning
                }
                // Footer (help/issue links) sits above subscription
                // so the actionable links — submit issue, visit
                // site, help — are reachable without scrolling
                // past the StoreKit tier list. No divider above
                // the footer: the VStack's natural spacing
                // already separates it cleanly from the cameras /
                // banners block above. The subscription section
                // anchors the bottom of the window because it's
                // the densest block and benefits from being out
                // of the eye's first-scan path.
                footer
                Divider()
                subscriptionSection
            }
            .padding(28)
            .frame(width: 520, alignment: .topLeading)
            // Measure the natural intrinsic height of the content stack
            // and publish it via NotificationCenter. The window
            // controller listens and pins `contentMaxSize` to this value,
            // so the user can shrink the window (the ScrollView handles
            // overflow) but can't grow it past where empty space would
            // start showing below the buttons.
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { newHeight in
            NotificationCenter.default.post(
                name: .mainWindowNaturalHeightChanged,
                object: nil,
                userInfo: ["height": newHeight])
        }
        .task { await store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        // `.center` keeps the title + tagline vertically balanced against
        // the now-96px icon — at `.top` the short two-line text column
        // sits flush against the icon's top edge and the bottom half of
        // the icon visually floats with nothing beside it.
        HStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                // App name + version share the same headline tier so the
                // build is legible at a glance — the tertiary-caption
                // version line that used to live below was too small to
                // read without leaning toward the screen.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("PTP Webcam").font(.title).bold()
                    Text(appVersion).font(.title).bold().monospacedDigit()
                }
                Text("Turn your PTP-tethered camera into a webcam.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Menu-bar hidden warning

    /// Shown when MenuBarVisibilityObserver reports that the agent's
    /// NSStatusItem is currently not on-screen. Common causes: the
    /// macOS menu bar is overflowing past the notch, Control Center
    /// has collapsed older items, or a third-party manager (Bartender /
    /// Ice / Hand Mirror) has the item hidden. We can't fix any of those
    /// from inside the app — they're all user-side settings — so the
    /// banner explains the situation rather than offering a fix button.
    /// True on macOS 26 (Tahoe) and later, where System Settings
    /// includes a dedicated "Menu Bar" pane that lets users toggle
    /// individual menu bar items off. Earlier macOS versions don't
    /// have that pane, so referencing it in the banner would just
    /// confuse the user.
    private var hasSystemMenuBarSettings: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Single warning banner shown whenever the agent reports its
    /// menu bar icon as not visible. We intentionally don't split by
    /// reason: the two underlying causes (item turned off via System
    /// Settings → Menu Bar / Bartender, vs. menu bar too crowded to
    /// fit the item) are observationally identical from inside the
    /// agent's process (same window frame, same occlusion flag, same
    /// defaults state), so the copy has to cover both possibilities.
    /// We do branch on OS version so we only mention System Settings
    /// → Menu Bar on macOS 26+ where that pane actually exists.
    private var menuBarHiddenWarning: some View {
        let body: String
        if hasSystemMenuBarSettings {
            body = "Either it’s turned off in System Settings → Menu Bar, your menu bar is too crowded to fit it (e.g. behind the camera notch), or a menu bar manager such as Bartender or Ice is hiding it. Re-enable it in System Settings, quit some other menu bar apps to make room, or check your menu bar manager — otherwise PTP Webcam’s controls won’t be reachable."
        } else {
            body = "Either your menu bar is too crowded to fit it (e.g. behind the camera notch), or a menu bar manager such as Bartender or Ice is hiding it. Quit some other menu bar apps to make room, or check your menu bar manager — otherwise PTP Webcam’s controls won’t be reachable."
        }
        return warningBanner(
            severity: .warning,
            title: "PTP Webcam’s menu bar icon isn’t visible",
            body:  body)
    }

    // MARK: - Connected cameras

    /// Stable order for the chips: alphabetical by friendly
    /// camera name. `cameraStore.cameras` is a dictionary, so
    /// SwiftUI would otherwise re-shuffle chips on every property
    /// publish. Per-vendor grouping isn't applied because the
    /// chip's vendor accent colour already disambiguates at a
    /// glance.
    private var sortedCameras: [ExtCamera] {
        cameraStore.cameras.values.sorted { $0.name < $1.name }
    }

    /// Flow layout of one chip per connected camera, or a single
    /// dashed-outline placeholder chip when no camera is present.
    /// The heading was removed: the chip row reads as its own
    /// section on first glance, and the placeholder is more
    /// informative as a UI element than as a label-plus-blank
    /// area would have been.
    private var connectedCamerasSection: some View {
        // SwiftUI's native `FlowLayout` requires macOS 13+; we
        // use the simpler `WrappingHStack` shim below so older
        // deployment targets get the same wrap behaviour.
        // `.frame(maxWidth: .infinity)` is the part that makes
        // centering work — the parent VStack uses
        // `alignment: .leading`, so without this the
        // WrappingHStack would shrink to its natural width and
        // sit flush against the leading edge of the content
        // column. Filling the column lets WrappingHStack's
        // place-subviews pass compute its centered x offset
        // against the actual window width rather than against
        // the row's own width.
        WrappingHStack(spacing: 8) {
            if sortedCameras.isEmpty {
                emptyCameraChip
            } else {
                ForEach(sortedCameras, id: \.cameraId) { camera in
                    cameraChip(for: camera)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Placeholder shown when no camera is connected. Same
    /// 80 × 80 footprint as a real chip so the section keeps a
    /// consistent height, but rendered as a low-contrast,
    /// dashed-outline card with a hint of explanatory text.
    /// Not a Button — there's no action to fire when no camera
    /// exists — but it carries an accessibility label so
    /// VoiceOver still announces the empty state.
    private var emptyCameraChip: some View {
        VStack(spacing: 4) {
            Image(systemName: "camera")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No camera\nconnected")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 80, height: 80)
        .background(
            // No material fill — the dashed border alone is the
            // visual signal that this slot is unoccupied. A
            // solid background would have read as "this is also
            // a tile, just with strange text" rather than
            // "nothing here yet."
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No camera connected")
    }

    /// Per-camera tile: square card with the simplified PTP
    /// Webcam silhouette on top (the same artwork the agent uses
    /// for its menu bar status item, rendered as a template so
    /// it adapts to light/dark window appearance), the camera's
    /// friendly model name below, and an optional one-line
    /// status qualifier ("(experimental)" or "(unsupported)")
    /// underneath for non-verified models. Supported cameras
    /// show no status text so the common case stays uncluttered.
    /// Unclaimed cameras render as the placeholder-style chip
    /// (dashed outline, low-contrast everything) rather than the
    /// solid card. Clicking them prompts to claim instead of
    /// opening preview, because there's nothing to preview yet
    /// — the PTP session hasn't been opened. Same 80 × 80
    /// footprint as a claimed chip so the layout stays
    /// consistent as cameras transition between states.
    @ViewBuilder
    private func cameraChip(for camera: ExtCamera) -> some View {
        if camera.properties.isEmpty {
            unclaimedCameraChip(for: camera)
        } else {
            claimedCameraChip(for: camera)
        }
    }

    /// Dashed-outline variant for cameras the extension has
    /// detected but not yet opened a PTP session against.
    /// Identical structure to a claimed chip — icon on top, name
    /// below — but everything is rendered in the low-contrast
    /// tertiary tint and the card has no fill. Tap brings up the
    /// claim confirmation dialog.
    private func unclaimedCameraChip(for camera: ExtCamera) -> some View {
        let support = supportStatus(for: camera)
        return Button {
            promptToClaim(camera: camera)
        } label: {
            VStack(spacing: 2) {
                Image(nsImage: Self.menuBarStyleIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.tertiary)
                // 30 pt text block, vertically centered, name
                // truncates if it doesn't fit at one line. We
                // don't show the support qualifier here because
                // it adds noise on a tile whose primary message
                // is "click to claim me" — the qualifier is
                // already covered by the support tooltip on
                // hover and by VoiceOver below.
                Text(camera.name)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity,
                           minHeight: 30, maxHeight: 30,
                           alignment: .center)
            }
            .padding(6)
            .frame(width: 80, height: 80)
            // Dashed outline only — same recipe as
            // `emptyCameraChip` so the two read as variants of
            // the same idea (slot exists, but it's empty / not
            // yet active).
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(camera.name)
        .accessibilityValue("not claimed")
        .accessibilityHint("Claim this camera to allow preview and control")
        .accessibilityAddTraits(.isButton)
        // Tooltip leads with the click action so the user knows
        // what happens before they commit. The support-tier
        // sentence is appended only when it conveys new info
        // (experimental / unsupported) — for a confirmed
        // camera the click-to-claim line stands on its own.
        .help(tooltipText(action: "Claim camera.", support: support))
    }

    /// Show an NSAlert asking the user to confirm claiming this
    /// camera, and on confirm, post the same Darwin-notify
    /// claim command the agent's menu uses. Using NSAlert
    /// instead of a SwiftUI `.alert(...)` because the latter
    /// requires `@State` plumbing in the parent view and we
    /// only need a one-shot modal — NSAlert is shorter, blocks
    /// the window naturally, and the visual is identical.
    private func promptToClaim(camera: ExtCamera) {
        let alert = NSAlert()
        alert.messageText = "Claim \(camera.name)?"
        alert.informativeText = "Claiming the camera allows PTP Webcam to control it. Other apps that use the camera may stop working until you release it again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Claim")
        alert.addButton(withTitle: "Cancel")
        // Tie the alert to the main window so it appears as a
        // sheet rather than a free-floating window. If we can't
        // find the window (rare — the user got here from the
        // chip in the main window) fall back to runModal which
        // shows it as an app-modal dialog.
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    Self.sendClaimCommand(vid: camera.vid,
                                          pid: camera.pid,
                                          serial: camera.serial,
                                          claim: true)
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                Self.sendClaimCommand(vid: camera.vid,
                                      pid: camera.pid,
                                      serial: camera.serial,
                                      claim: true)
            }
        }
    }

    /// Post the claim command on the same per-camera Darwin
    /// notify channel the agent uses (see the agent's
    /// `sendClaimCommand` for the canonical implementation —
    /// kept in sync by construction). The slot's value is `1`
    /// for claim, `2` for release; we currently only ever send
    /// `1` from here because the chip only surfaces the
    /// unclaimed → claimed transition. Static so we don't have
    /// to thread `self` through the alert closure.
    private static func sendClaimCommand(vid: UInt16, pid: UInt16,
                                          serial: String, claim: Bool) {
        let crc = ptpwebcamCRC32(Array(serial.utf8)) & 0x00FFFFFF
        let suffix = String(format: "%04x.%04x.%06x", vid, pid, crc)
        let slotName   = kDarwinClaimCameraSlot + "." + suffix
        let notifyName = kDarwinClaimCamera     + "." + suffix
        var slotToken: Int32 = 0
        darwin_notify_register_check(slotName, &slotToken)
        darwin_notify_set_state(slotToken, claim ? 1 : 2)
        darwin_notify_post(notifyName)
        notify_cancel(slotToken)

        // Broadcast the same change on the shared "claim state
        // changed" channel so the agent (which owns the
        // UserDefaults persistence of `claimedCameraKeys`) can
        // mirror it. Without this the agent's menu would still
        // show this camera as unclaimed even though the
        // extension has actually opened the session — the agent
        // tracks claim state in its own UserDefaults set rather
        // than reading the extension's live state.
        let packed: UInt64 =
            (UInt64(claim ? 1 : 2) << 56) |
            (UInt64(crc)             << 32) |
            (UInt64(vid)             << 16) |
             UInt64(pid)
        var annTok: Int32 = 0
        darwin_notify_register_check(kDarwinClaimAnnounceSlot, &annTok)
        darwin_notify_set_state(annTok, packed)
        darwin_notify_post(kDarwinClaimAnnounce)
        notify_cancel(annTok)
    }

    /// Solid-card variant for cameras the extension has fully
    /// opened (PTP session active, properties discovered). Tap
    /// opens the live preview window. Same as the previous
    /// single-form chip — extracted unchanged so the unclaimed
    /// path can substitute its placeholder-style version.
    private func claimedCameraChip(for camera: ExtCamera) -> some View {
        let support   = supportStatus(for: camera)
        let qualifier = support.qualifierText
        let readiness = readinessState(for: camera)
        // Whole tile is a button so the click target spans the
        // entire 80 × 80 square. `.plain` style strips the
        // default rectangular bezel — the rounded-material
        // background below is the visual affordance, and the
        // tile would look wrong sitting inside an extra macOS
        // push-button frame.
        return Button {
            (NSApp.delegate as? AppDelegate)?.openPreview(cameraName: camera.name)
        } label: {
            // ZStack so we can layer a top-leading readiness
            // dot over the icon+text VStack without re-flowing
            // the text block's geometry.
            ZStack(alignment: .topLeading) {
                VStack(spacing: 2) {
                    // Icon: aspect-ratio preserving, fills the
                    // full rectangle above the text rows.
                    // `.scaledToFit()` is mandatory — without
                    // it the silhouette stretches to fill the
                    // frame and reads as distorted.
                    Image(nsImage: Self.menuBarStyleIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(.primary)

                    // Text block: a fixed-height 30 pt container
                    // that holds either a single centered Text
                    // (when there's no qualifier line to show)
                    // or a name-over-qualifier VStack (when
                    // there is). The `Group` + `.frame(…,
                    // alignment: .center)` is what produces the
                    // vertical centering — a VStack with a
                    // Spacer below the name would let the name
                    // sit visually higher than the qualified-
                    // chip neighbour does. By picking the layout
                    // up front based on `qualifier`, the
                    // unqualified case has no qualifier row in
                    // its layout at all (rather than an
                    // invisible-but-still-claiming-space
                    // placeholder), so SwiftUI's default
                    // `.center` frame alignment correctly
                    // centers the single Text inside the 30 pt
                    // frame.
                    Group {
                        if let qualifier {
                            VStack(spacing: 0) {
                                Text(camera.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(qualifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(camera.name)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                        }
                    }
                    // `.frame` can't mix maxWidth and a fixed height in
                    // one call — using `minHeight == maxHeight` is the
                    // documented idiom for pinning the height while
                    // letting the width flex.
                    .frame(maxWidth: .infinity,
                           minHeight: 30, maxHeight: 30,
                           alignment: .center)
                }

                // Readiness / recording indicator. Three states:
                //   • .streaming — filled red dot (live frames)
                //   • .ready     — filled gray dot (PTP session
                //                  open, properties discovered,
                //                  could stream immediately)
                //   • .detected  — outlined dot (camera visible
                //                  at USB level but PTP session
                //                  isn't open yet)
                // Position is pushed all the way to the corner
                // (2pt offset from each edge) so it reads as a
                // status pip rather than an interior badge.
                // Accessibility-hidden because its meaning is
                // already exposed via the button's
                // `accessibilityValue` below — leaving the dot
                // visible to VoiceOver would double-announce
                // "Recording" on every focus tick.
                readinessIndicator(readiness)
                    .padding(2)
                    .accessibilityHidden(true)
            }
            .padding(6)
            // 80 × 80 outer square. Sets both width and height
            // explicitly so the WrappingHStack always lays out
            // identical-sized cards and the icon's flex area is
            // deterministic.
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial))
            .contentShape(Rectangle())   // hit-test the whole square,
                                          // not just opaque label pixels
        }
        .buttonStyle(.plain)
        // Collapse the entire chip's child views (icon + name +
        // qualifier + dot) into a single accessibility element
        // that we curate by hand. Without this, VoiceOver would
        // auto-compose the label from every child Text in the
        // ZStack — producing noisy reads like "Nikon Z8
        // (experimental) Recording button". The explicit label /
        // value / hint split below maps to VoiceOver's
        // name + state + action-description conventions and
        // produces the announcement order one would expect
        // ("Nikon Z8, experimental, recording, button, opens
        // live preview window").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(camera.name)
        .accessibilityValue(accessibilityValue(support: support, readiness: readiness))
        .accessibilityHint("Opens live preview window")
        .accessibilityAddTraits(.isButton)
        // `.help` becomes the on-hover tooltip AND a second-tier
        // accessibility description on macOS. Leads with the
        // click action ("opens live preview") and appends the
        // support-tier explanation only when it adds information
        // beyond "this is a verified camera".
        .help(tooltipText(action: "Open the live preview.", support: support))
    }

    /// Build the hover-tooltip string. Always opens with the
    /// click action (the user's near-term question is "what
    /// happens if I click?"); the support-tier sentence is only
    /// appended for experimental / unsupported cameras where the
    /// extra context changes the user's expectations of what
    /// they'll see after clicking.
    private func tooltipText(action: String,
                              support: CameraSupportStatus) -> String {
        switch support {
        case .supported:    return action
        case .experimental: return "\(action) \(support.tooltip)"
        case .unknown:      return "\(action) \(support.tooltip)"
        }
    }

    /// Compose the VoiceOver `accessibilityValue` string from the
    /// camera's support tier and current readiness. Examples:
    ///   • supported + ready       → "ready"
    ///   • supported + streaming   → "recording"
    ///   • experimental + streaming→ "experimental, recording"
    ///   • unsupported + detected  → "unsupported, connected, not ready to stream"
    /// Empty parts are dropped so the final string is naturally
    /// readable rather than including hollow commas.
    private func accessibilityValue(support: CameraSupportStatus,
                                     readiness: CameraReadinessState) -> String {
        var parts: [String] = []
        // Support tier first — the qualifier reads more
        // naturally before the dynamic state ("experimental,
        // recording") than after.
        switch support {
        case .supported:    break
        case .experimental: parts.append("experimental")
        case .unknown:      parts.append("unsupported")
        }
        switch readiness {
        case .streaming: parts.append("recording")
        case .ready:     parts.append("ready")
        case .detected:  parts.append("connected, not ready to stream")
        }
        return parts.joined(separator: ", ")
    }

    /// Render the readiness pip. Size + stroke chosen so the
    /// outlined-only state still reads as a deliberate dot at
    /// 80 pt chip width (a thinner stroke disappears against
    /// `.regularMaterial`; a wider one starts to look like a
    /// button).
    @ViewBuilder
    private func readinessIndicator(_ state: CameraReadinessState) -> some View {
        switch state {
        case .streaming:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        case .ready:
            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
        case .detected:
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1.2)
                .frame(width: 8, height: 8)
        }
    }

    /// Resolve the readiness state for a chip. Order of checks
    /// matters: streaming beats ready (a streaming camera is
    /// trivially also ready), ready beats detected.
    private func readinessState(for camera: ExtCamera) -> CameraReadinessState {
        if streamingState.streamingCameraCrcs.contains(crc32(of: camera.cameraId)) {
            return .streaming
        }
        // `properties.isEmpty` is a clean stand-in for "PTP
        // session not yet open": the extension publishes
        // `publishCameraConnected` with `props: []` immediately
        // on USB attach (before the session is opened), then
        // re-publishes with populated properties after
        // discovery succeeds. The host app's parser preserves
        // the empty-props state, so an entry in `cameras` with
        // zero properties is exactly the "connected but not
        // ready to live stream" condition.
        if camera.properties.isEmpty {
            return .detected
        }
        return .ready
    }

    private enum CameraReadinessState {
        case streaming, ready, detected
        var accessibilityLabel: String {
            switch self {
            case .streaming: return "Recording"
            case .ready:     return "Ready"
            case .detected:  return "Connected, not ready"
            }
        }
    }

    /// CRC32 of `id`'s UTF-8 bytes — same hash the extension
    /// stamps into the streaming-state slot chain. We compute
    /// once per chip per refresh, which is cheap (the bitwise
    /// implementation in `ptpwebcamCRC32` is sub-microsecond
    /// for cameraId strings of ~30 chars).
    private func crc32(of id: String) -> UInt32 {
        ptpwebcamCRC32(Array(id.utf8))
    }

    /// Cached menu-bar-style PNG, loaded once at first access. The
    /// file ships with the host app bundle (added to the project's
    /// PtpWebcamApp Resources phase). Loaded via Bundle.path
    /// rather than NSImage(named:) because the asset isn't in the
    /// xcassets catalog — keeping it as a loose PNG matches how
    /// the agent's ptpwebcam-logo-22x22 assets are shipped.
    private static let menuBarStyleIcon: NSImage = {
        if let path = Bundle.main.path(forResource: "ptpwebcam_simple_1100", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            // Mark the image as a template so AppKit/SwiftUI
            // re-tint the alpha mask with the current foreground
            // colour — identical to how the agent stages its
            // status bar icon (`isTemplate = true`).
            img.isTemplate = true
            return img
        }
        // Defensive fallback: empty NSImage rather than a crash if
        // someone reshuffles the bundle. The icon is purely
        // decorative — a missing one just leaves blank space at
        // the top of the chip.
        return NSImage()
    }()

    /// Three-tier support classification with its accompanying
    /// SwiftUI styling. Values are derived from
    /// `PtpKnownCameras.lookup(vid:pid:)`:
    ///   - returns a `PtpKnownCamera` with `confirmed=true` →
    ///     `.supported`
    ///   - returns a `PtpKnownCamera` with `confirmed=false` →
    ///     `.experimental` (we have a profile but haven't tested
    ///     against the actual hardware)
    ///   - returns nil → `.unknown` (camera connected but we
    ///     don't have an entry; could still partially work via
    ///     generic PTP)
    private enum CameraSupportStatus {
        case supported, experimental, unknown
        /// Text shown under the camera name. Nil for `.supported`
        /// so the common, no-news-is-good-news case stays
        /// uncluttered.
        var qualifierText: String? {
            switch self {
            case .supported:    return nil
            case .experimental: return "(experimental)"
            case .unknown:      return "(unsupported)"
            }
        }
        var tooltip: String {
            switch self {
            case .supported:    return "Known to work, usually."
            case .experimental: return "Experimental support, may not work."
            case .unknown:      return "Unknown camera, probably won't work."
            }
        }
    }

    private func supportStatus(for camera: ExtCamera) -> CameraSupportStatus {
        guard let known = PtpKnownCameras.lookup(vid: camera.vid, pid: camera.pid) else {
            return .unknown
        }
        return known.confirmed ? .supported : .experimental
    }

    // MARK: - Service-health warnings (extension / agent / comms)

    /// Banner copy distinguishes "not installed" from "not running"
    /// because the user-facing fix is completely different — the
    /// former needs them to walk through System Settings approval,
    /// the latter usually self-heals when QuickTime/Zoom/etc.
    /// requests the camera and macOS re-spawns the extension.
    private var extensionNotInstalledWarning: some View {
        warningBanner(
            severity: .error,
            title: "PTP Webcam camera extension isn’t installed",
            body:  "The system camera extension that exposes your PTP camera to apps like QuickTime, Zoom, and FaceTime isn’t registered with macOS, has been disabled, or is currently being uninstalled. Reinstall PTP Webcam if you removed the extension, or open System Settings → General → Login Items & Extensions → Camera Extensions and enable PTP Webcam. Without it, no PTP camera will appear in any video app.")
    }

    private var extensionNotRunningWarning: some View {
        warningBanner(
            severity: .warning,
            title: "PTP Webcam camera extension unresponsive",
            body:  "The extension is installed but its process isn’t responding. macOS sometime spawns it on demand when a video app requests a camera — opening QuickTime → New Movie Recording → PTP Webcam usually wakes it up. If the issue persists after that, restart your Mac to clear any stuck system extension state.")
    }

    private var agentNotRunningWarning: some View {
        warningBanner(
            severity: .warning,
            title: "PTP Webcam helper agent isn’t running",
            body:  "The background helper that manages camera detection and the menu bar item isn’t running. It’s installed as a Login Item and should start automatically when you log in. Open System Settings → General → Login Items & Extensions and confirm PTP Webcam is allowed to run in the background, then quit and relaunch PTP Webcam.")
    }

    private var commsBrokenWarning: some View {
        warningBanner(
            severity: .warning,
            title: "PTP Webcam helper and camera extension can’t talk to each other",
            body:  "Both pieces are running but their internal messaging channel has stalled — this can happen after a sleep/wake cycle or when system resources are very low. Quit and relaunch PTP Webcam to re-establish the connection. If it keeps coming back, restart your Mac.")
    }

    /// Two severity tiers, distinguished only by accent colour.
    /// `.error` is reserved for faults that block all functionality
    /// until the user takes action (extension not installed);
    /// `.warning` is for transient faults that may self-heal or
    /// degraded states that don't block everything.
    private enum BannerSeverity {
        case warning, error
        var tint: Color {
            switch self {
            case .warning: return .yellow
            case .error:   return .orange   // red on red would look alarming for an
                                            // app whose worst case is "camera not
                                            // showing up"; orange is the right tier.
            }
        }
        var icon: String { "exclamationmark.triangle.fill" }
    }

    /// Common chrome for all banners — same layout, padding, and
    /// stroke geometry as the original menu-bar warning, just
    /// parameterised on title/body/colour. Kept inline (not pulled
    /// into a separate file) because all the banner copy lives in
    /// this view and splitting just the chrome would scatter
    /// related code.
    private func warningBanner(severity: BannerSeverity,
                                title: String,
                                body:  String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severity.icon)
                .foregroundStyle(severity.tint)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(severity.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(severity.tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Subscription

    @ViewBuilder
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Subscription").font(.title2).bold()
                Spacer()
                entitlementBadge
            }

            switch store.entitlement {
            case .unknown:
                ProgressView("Checking your subscription…").frame(maxWidth: .infinity, alignment: .leading)

            case .subscribed(let productId, let expires):
                subscribedBody(productId: productId, expires: expires)

            case .notSubscribed:
                notSubscribedBody
            }
        }
    }

    private var entitlementBadge: some View {
        // Typed as `LocalizedStringKey` (not `String`) so `Text(_:)` treats it
        // as a localization lookup key rather than a verbatim string. With
        // `String` here, the badge text would skip the .xcstrings catalog
        // entirely no matter what locale the system is in.
        let (label, color): (LocalizedStringKey, Color) = {
            switch store.entitlement {
            case .unknown:        return ("Checking…", .secondary)
            case .subscribed:     return ("Active", .green)
            case .notSubscribed:  return ("Not subscribed", .secondary)
            }
        }()
        return Text(label)
            .font(.caption).bold()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func subscribedBody(productId: String, expires: Date?) -> some View {
        // Active subscriber still sees the full tier list so they can
        // switch tiers (StoreKit's `product.purchase()` routes through the
        // standard upgrade/downgrade flow automatically when the new
        // product is in the same subscription group). The active tier is
        // highlighted in the list, so we don't need a duplicate "Current
        // plan: …" line above it.
        VStack(alignment: .leading, spacing: 14) {
            Text("Thanks for supporting PTP Webcam.")
            if let expires {
                Text("Renews \(expires.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout).foregroundStyle(.secondary)
            }

            productList(activeProductId: productId)

            HStack(spacing: 12) {
                Button("Manage Subscription") {
                    store.showManageSubscriptions()
                }
                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
            }
        }
    }

    private var notSubscribedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PTP Webcam is free, but if you like PTP Webcam, you can support development with one of the following subscriptions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            productList(activeProductId: nil)

            HStack {
                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
                Spacer()
            }
        }
    }

    /// Render the full subscription tier list. If `activeProductId` is
    /// non-nil, the matching row is highlighted and its action button
    /// shows a non-interactive "Current" label instead of a Subscribe
    /// button — StoreKit refuses to re-purchase the same active tier and
    /// would surface an opaque error if we let the user try.
    @ViewBuilder
    private func productList(activeProductId: String?) -> some View {
        if let err = store.loadError {
            Text(err)
                .foregroundStyle(.red)
                .font(.callout)
        } else if store.products.isEmpty {
            ProgressView("Loading options…")
        } else {
            VStack(spacing: 8) {
                ForEach(store.products) { product in
                    productRow(product, isActive: product.id == activeProductId)
                }
            }
        }
    }

    @ViewBuilder
    private func productRow(_ product: Product, isActive: Bool) -> some View {
        let inProgress = store.purchaseInProgress.contains(product.id)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(product.displayName).font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                if !product.description.isEmpty {
                    Text(product.description).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(product.displayPrice).font(.headline)
                if isActive {
                    Text("Current")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await store.purchase(product) }
                    } label: {
                        if inProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(hasAnyActiveSubscription ? "Switch" : "Subscribe")
                        }
                    }
                    .disabled(inProgress)
                    .controlSize(.regular)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            // Active row gets an accent-tinted fill + a thin accent stroke
            // so the eye lands on it immediately. Inactive rows keep the
            // same quaternary fill as before.
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.6 : 0), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Explains the experimental flag in the status-bar menu and
            // points users at the issue tracker. Plain SwiftUI `Text` so
            // the string is picked up automatically by the Localizable
            // catalog — no NSLocalizedString call needed.
            Text("If you have a camera that shows up as experimental, or doesn't show up at all, you can submit a GitHub issue to request improved support.")
//                .font(.callout)
//                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            footerButtons
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button("Visit ptpwebcam.org") {
                if let url = URL(string: "https://ptpwebcam.org") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            // Help drops the user on ptpwebcam.org for now. We'll deep-link
            // to a specific help page once the site has one.
            Button {
                if let url = URL(string: "https://ptpwebcam.org") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            // Submit Issue spawns the AppDelegate's issue flow: device picker
            // → PTP dump → clipboard + pre-filled GitHub new-issue URL. The
            // dump is too large for the URL query string, so it goes via
            // the system pasteboard with instructions in the body.
            Button {
                (NSApp.delegate as? AppDelegate)?.beginIssueSubmission()
            } label: {
                Label("Submit Issue", systemImage: "exclamationmark.bubble")
            }
        }
    }
}

#Preview { MainWindowView() }

// MARK: - Wrapping layout

/// Minimal flow layout: arranges children left-to-right, wraps to
/// the next line when the proposed width is exhausted. Used by
/// the connected-cameras chip section so the chips reflow as the
/// user resizes the main window.
///
/// Why hand-roll instead of using SwiftUI's `Layout` examples
/// (HFlowLayout etc.): we need exactly this behaviour, the chip
/// children are all roughly the same height, and a focused
/// implementation keeps the math obvious — a generic flow layout
/// adds alignment / spacing knobs we don't use.
private struct WrappingHStack: Layout {
    var spacing: CGFloat = 8

    /// Pack subviews into rows of `proposal.width` and report the
    /// resulting total size. Height accumulates per row.
    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            // First child on a row never wraps; subsequent ones
            // wrap only if they wouldn't fit alongside what's
            // already there (with the inter-chip spacing).
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widestRow = max(widestRow, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widestRow = max(widestRow, rowWidth)
        return CGSize(width: widestRow, height: totalHeight)
    }

    /// Place each subview at its computed (x, y). Two-pass so we
    /// can center each row horizontally within `bounds.width`:
    ///
    ///   1. Walk subviews once to assign each to a row, recording
    ///      the row's intrinsic content width.
    ///   2. Walk the rows in order, placing their subviews
    ///      starting from a centered x offset.
    ///
    /// This isn't a generic alignment knob — the connected-cameras
    /// chip row is currently WrappingHStack's only consumer and
    /// always wants centered rows. If a future caller needs left
    /// alignment, expose an `alignment: HorizontalAlignment`
    /// parameter and branch the starting-x calculation.
    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        // Pass 1: build rows. Each row is the list of subview
        // indices on that row plus its total content width
        // (sum of sizes + inter-chip spacing).
        struct Row { var indices: [Int]; var width: CGFloat; var height: CGFloat }
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !current.indices.isEmpty &&
               current.width + spacing + size.width > bounds.width {
                rows.append(current)
                current = Row(indices: [], width: 0, height: 0)
            }
            if !current.indices.isEmpty { current.width += spacing }
            current.width += size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }

        // Pass 2: place each row's subviews starting from a
        // centered x. Vertical advance accumulates per row plus
        // the inter-row spacing.
        var y: CGFloat = bounds.minY
        for row in rows {
            // Center: leftPadding = (parentWidth - rowWidth) / 2.
            // Clamp to zero in the degenerate case where a single
            // child is wider than `bounds.width` — better to
            // overflow on the right than off the left edge.
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2)
            for (offsetIdx, idx) in row.indices.enumerated() {
                let sub = subviews[idx]
                let size = sub.sizeThatFits(.unspecified)
                sub.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
                x += size.width
                if offsetIdx < row.indices.count - 1 { x += spacing }
            }
            y += row.height + spacing
        }
    }
}
