import Cocoa
import AVFoundation
import Combine
import SwiftUI
import os.log

private class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    /// Invoked when the user clicks (NOT drags) the preview area.
    /// Wired up by `CameraPreviewWindowController` to toggle the
    /// HUD overlay's visibility. Renamed from `onMouseDown` to
    /// reflect the new gesture semantics — the trigger is now a
    /// completed click (down → up without drag), not the raw
    /// mouseDown event.
    var onClick: (() -> Void)?

    /// Where the current mouseDown landed, in this view's
    /// coordinate space. Nil between drags. Read in mouseDragged
    /// to decide whether the gesture has crossed the "this is a
    /// drag, not a click" threshold, and in mouseUp to fire the
    /// onClick closure.
    private var pressOrigin: NSPoint?
    /// Latched when the cursor moves more than `dragThreshold`
    /// pixels from `pressOrigin` between mouseDown and mouseUp.
    /// Once latched, the upcoming mouseUp is treated as a drag
    /// completion and `onClick` does NOT fire. Reset to false on
    /// the next mouseDown.
    private var didDrag = false
    /// Movement (in points) from the press origin that
    /// reclassifies the gesture as a drag rather than a click.
    /// 4 pt matches macOS's `kAEXAlgoSlopValue` / common
    /// AppKit-internal threshold for distinguishing the two —
    /// small enough that a deliberate click isn't reclassified
    /// by a shaky hand, large enough that the window's natural
    /// drag-to-move gesture is reliably caught.
    private let dragThreshold: CGFloat = 4

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = convert(event.locationInWindow, from: nil)
        didDrag = false
        // Don't fire `onClick` here — wait for mouseUp so we can
        // distinguish click from drag. Without this gating, the
        // window's movable-by-background drag fires the same
        // mouseDown the click-to-toggle gesture uses, and the
        // HUD flickers visible / hidden on every window
        // reposition.
        //
        // We also don't call super so the system's default
        // mouseDown handling doesn't run; the window's drag
        // behavior is driven by AppKit higher up the responder
        // chain via `isMovableByWindowBackground` and operates
        // independently of whether we forward this event.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - origin.x
        let dy = p.y - origin.y
        if (dx * dx + dy * dy) >= (dragThreshold * dragThreshold) {
            didDrag = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = (pressOrigin != nil) && !didDrag
        pressOrigin = nil
        didDrag = false
        if shouldFire { onClick?() }
    }
}

private let previewLogger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp", category: "CameraPreview")
private func log(_ msg: String) { previewLogger.fault("\(msg, privacy: .public)") }

/// View-model for the preview HUD overlay. Lives as long as the
/// `CameraPreviewWindowController` and feeds the SwiftUI `PreviewHud`
/// the current camera + visibility toggle. Keeping this as a tiny
/// ObservableObject (rather than driving the HUD directly off the
/// store + an Optional binding) means we can extend it later for
/// phase-2 interactivity (drag to rearrange chips, per-window layout
/// overrides, etc.) without restructuring the view tree.
final class PreviewHudViewModel: ObservableObject {
    /// User-visible label from `AVCaptureDevice.localizedName`. The
    /// view looks the matching `ExtCamera` up in the store by name
    /// each render — cheap (it's a dictionary lookup with substring
    /// fallback) and avoids stale references when the camera
    /// disconnects and reconnects with a different cameraId.
    let cameraName: String
    @Published var visible: Bool
    /// Republishes the `CameraPropertyStore.shared.cameras` change
    /// stream so SwiftUI re-renders the chips whenever the agent
    /// pushes a new property snapshot. We don't try to filter to
    /// just our camera here — the chip view does that lookup at
    /// render time and SwiftUI's diffing absorbs irrelevant updates.
    @Published var camerasSnapshot: [String: ExtCamera] = [:]

    private var subscription: AnyCancellable?

    init(cameraName: String, initiallyVisible: Bool) {
        self.cameraName = cameraName
        self.visible = initiallyVisible
        subscription = CameraPropertyStore.shared.$cameras
            .receive(on: DispatchQueue.main)
            .assign(to: \.camerasSnapshot, on: self)
    }

    func toggle() { visible.toggle() }
}

/// SwiftUI wrapper that resolves the camera + renders `PreviewHud`.
/// Sits inside an NSHostingView pinned over the preview area.
/// Also layers `CameraDisconnectedOverlay` over the preview when no
/// matching `ExtCamera` is in the store — the natural signal for
/// "camera is not present right now" since the same store backs
/// the rebind-on-reconnect logic above.
private struct PreviewHudContainer: View {
    @ObservedObject var viewModel: PreviewHudViewModel

    var body: some View {
        // Re-derive the matching camera each render. SwiftUI's
        // dependency tracking via the view-model's
        // `camerasSnapshot` publisher rebuilds the body on
        // every store update, so the connected/disconnected
        // flip animates smoothly with the publish.
        let camera = CameraPropertyStore.shared.camera(matchingName: viewModel.cameraName)
        ZStack {
            // HUD stays in the tree even while disconnected so its
            // chip state survives the round trip — `PreviewHud`
            // already handles `camera == nil` gracefully (no chips
            // rendered). Drawing it underneath the overlay also
            // keeps Z-order consistent across the transitions.
            PreviewHud(
                camera: camera,
                layout: .default,
                visible: viewModel.visible,
                cameraName: viewModel.cameraName)
            if camera == nil {
                CameraDisconnectedOverlay()
            }
        }
    }
}

/// Center-screen indicator shown over the preview when the camera
/// can't be found in `CameraPropertyStore`. Uses the same
/// silhouette artwork the About window shows for connected cameras
/// (`ptpwebcam_simple_1100.png`), overlaid with an SF Symbol
/// `nosign` (the "prohibited" diagonal-slash-through-circle) to
/// signal "this slot is currently absent." Below it, a caption
/// reassures the user that reconnecting will pick up where they
/// left off — the rebind logic in `CameraPreviewWindowController`
/// runs automatically when the camera reappears, so they don't
/// need to do anything else.
private struct CameraDisconnectedOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // Camera silhouette. The preview backdrop is
                // permanent solid black (AVCaptureVideoPreviewLayer
                // when there's no signal), and SwiftUI's `.tertiary`
                // / `.secondary` / `.primary` styles resolve against
                // the system appearance — under a light system
                // theme they become near-black, leaving the
                // template-rendered silhouette invisible on the
                // black backdrop. Lock to an explicit light tint
                // so the icon reads regardless of OS appearance.
                Image(nsImage: Self.menuBarStyleIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.white.opacity(0.55))
                    // Shrunk so the prohibited mark dominates the
                    // composition — the nosign should read as the
                    // primary signal, with the camera silhouette
                    // sitting comfortably inside its ring rather
                    // than crowding it.
                    .frame(width: 72, height: 72)
                // Prohibited mark — `nosign` is exactly the
                // circle-with-diagonal-line we want, drawn as
                // line art so the silhouette behind it stays
                // visible. Sized slightly larger than the
                // silhouette so the circle visually contains
                // the icon rather than crowding into it. Red
                // stays vivid on black — no inversion needed.
                Image(systemName: "nosign")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: 116, height: 116)
            }
            VStack(spacing: 2) {
                // Same reasoning as the icon: text tints have to
                // be locked light, not appearance-derived, because
                // the backdrop is permanent black.
                Text("Camera disconnected")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Preview will resume automatically when the camera reconnects.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        }
        // Pin to the centre of whatever space the overlay's
        // hosting view occupies. `.allowsHitTesting(false)` keeps
        // clicks falling through to PreviewView so the HUD
        // toggle still works (and a user click on a disconnected
        // preview doesn't get swallowed by an invisible overlay).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera disconnected. Preview will resume automatically when the camera reconnects.")
    }

    /// Local copy of the loader used in `MainWindowView`. Loaded
    /// once per process and cached. Loose PNG rather than
    /// `xcassets` because the asset already ships at the bundle
    /// root (added when the chips on the main window started
    /// using the same artwork).
    private static let menuBarStyleIcon: NSImage = {
        if let path = Bundle.main.path(forResource: "ptpwebcam_simple_1100", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.isTemplate = true
            return img
        }
        return NSImage()
    }()
}

class CameraPreviewWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let cameraName: String
    private var videoOutput: AVCaptureVideoDataOutput?
    private var aspectSet = false
    var onClose: (() -> Void)?
    /// View-model for the HUD overlay. Created once per preview window
    /// so `visible` toggles are per-window (closing/reopening resets
    /// to the default "visible on open" behavior).
    private var hudViewModel: PreviewHudViewModel?
    /// Preview-view + sample-buffer queue label live as properties
    /// because `attemptBindCaptureDevice` may run multiple times
    /// (initial bind + every disconnect→reconnect cycle) and needs
    /// stable references.
    private var previewView: PreviewView?
    private let sampleBufferQueueLabel = "org.ptpwebcam.preview.frameq"
    /// Cancellable for the `CameraPropertyStore.shared.$cameras`
    /// subscription that drives reconnect-rebind. Held strong so
    /// the subscription survives for the controller's lifetime.
    private var camerasSubscription: AnyCancellable?
    /// Last-observed presence of the matching camera in
    /// `CameraPropertyStore`. Tracked so we only react to actual
    /// transitions; every property publish would otherwise trigger
    /// a spurious "still connected" event.
    private var matchingCameraWasPresent: Bool = false
    /// Pending rebind work item. Tracked so a rapid disconnect →
    /// reconnect → disconnect doesn't pile up redundant binds.
    private var pendingRebindWorkItem: DispatchWorkItem?
    /// Brief delay between observing the extension's "camera back"
    /// publish and attempting to find the AVCaptureDevice. The CMIO
    /// extension publishes its property snapshot the instant the
    /// PTP session opens, but the AVCaptureDevice registration
    /// goes through a separate CoreMedia path that usually lags
    /// by a few hundred ms. Polling without this delay reliably
    /// finds zero devices on the first try.
    private static let rebindSettleDelay: TimeInterval = 0.5

    /// Counter for in-flight rebind retries. Reset whenever a
    /// bind succeeds or a fresh trigger (presence change, runtime
    /// error) starts a new attempt cycle. Used to implement
    /// linear backoff up to `maxRebindRetries`.
    private var rebindRetryAttempt = 0
    /// Maximum number of consecutive rebind retries before
    /// giving up and waiting for the next external trigger.
    /// With the 0.5 → 5 s linear backoff this covers ~15
    /// seconds. A simple extension respawn usually completes
    /// in ~1–2 s (observed: 1.1 s in the in-the-wild case
    /// that motivated this code); the wider budget covers
    /// slower scenarios — an in-place version upgrade
    /// (3–5 s including codesign re-validation), a system
    /// extension manager re-approval, or a brief USB stall.
    /// Going further than this risks polling against a
    /// genuinely-gone camera forever.
    private static let maxRebindRetries = 8

    init(cameraName: String) {
        self.cameraName = cameraName
        // Borderless-look preview window: keep the standard
        // `.titled` style mask (so the window still gets a
        // traffic-light button cluster and standard
        // accessibility/window-manager treatment) but pull the
        // titlebar visually out of the way so the preview reaches
        // the top of the window. The chips in `PreviewHud` reserve
        // their own clearance from the top edge to avoid colliding
        // with the traffic-light buttons.
        // Default content rect: 800 × 600. The window resnaps to
        // the actual stream aspect once frames arrive (see the
        // `firstFrame` handler) — this rect is only the
        // pre-frame placeholder, so its aspect ratio doesn't
        // need to match the camera. 800 × 600 is roomy enough
        // that the HUD chips don't crowd each other on first
        // open while still fitting comfortably on a 1366 × 768
        // laptop screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title is still set for VoiceOver and the Window menu, but
        // hidden in the titlebar itself.
        window.title = cameraName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        window.delegate = self

        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        log("CameraPreview: auth=\(auth.rawValue) for '\(cameraName)'")
        switch auth {
        case .authorized:
            startup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                log("CameraPreview: access request result=\(granted)")
                if granted { DispatchQueue.main.async { self?.startup() } }
            }
        case .denied, .restricted:
            log("CameraPreview: camera access denied/restricted")
        @unknown default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Run the one-time setup work after auth is granted. Splits
    /// what used to be `setupCapture` into three independently
    /// re-callable phases:
    ///   • UI chrome (preview NSView + HUD) — once.
    ///   • Session-error observer — once.
    ///   • Camera-presence subscription — once.
    /// Then it kicks off the first device bind. Subsequent rebinds
    /// (on disconnect/reconnect cycles) re-enter only
    /// `attemptBindCaptureDevice`.
    private func startup() {
        setupPreviewUI()
        installSessionErrorObserver()
        observeCameraPresence()
        attemptBindCaptureDevice()
    }

    /// Build the preview NSView + HUD overlay. Idempotent guard
    /// prevents double-installation if the path is somehow re-
    /// entered. The preview NSView holds the AVCaptureVideoPreviewLayer
    /// bound to `captureSession`; that binding survives
    /// disconnect/reconnect cycles because we only swap the
    /// session's *inputs*, never the session itself.
    private func setupPreviewUI() {
        guard previewView == nil else { return }
        let view = PreviewView(session: captureSession)
        view.autoresizingMask = [.width, .height]
        view.frame = window!.contentView!.bounds
        window!.contentView!.addSubview(view)
        previewView = view

        // HUD overlay: SwiftUI view in an NSHostingView pinned to
        // the preview's bounds. The view-model controls its
        // visibility; clicking the preview area toggles it. Visible
        // on first open (per the design discussion) so users
        // discover the feature immediately rather than having to
        // find it.
        let hudVM = PreviewHudViewModel(cameraName: cameraName, initiallyVisible: true)
        self.hudViewModel = hudVM
        let hudHost = NSHostingView(rootView: PreviewHudContainer(viewModel: hudVM))
        hudHost.autoresizingMask = [.width, .height]
        hudHost.frame = view.bounds
        // Hosting view added on top of the preview layer so the
        // chips draw above the video. Hit-testing on the SwiftUI
        // side is disabled (see PreviewHud.allowsHitTesting), so
        // clicks pass through to PreviewView, which fires `onClick`
        // on a mouseDown→mouseUp that didn't drag the window.
        view.addSubview(hudHost)
        view.onClick = { [weak hudVM] in hudVM?.toggle() }
    }

    /// Observe `AVCaptureSessionRuntimeError`. The notification
    /// fires whenever the underlying device goes away or the
    /// session is otherwise interrupted. Treating every runtime
    /// error as a rebind trigger is safe because:
    ///   • If the device is still bindable, `attemptBindCaptureDevice`
    ///     is idempotent (swap atomically inside begin/commit).
    ///   • If the device is gone, the retry backoff polls every
    ///     ~1 s until either it shows up or we hit
    ///     `maxRebindRetries` and yield back to the presence
    ///     observer.
    ///
    /// Concrete scenario this exists for: the CMIO extension
    /// process gets terminated and respawned (any cause —
    /// macOS reaping it for idleness, an OS-level kill, an
    /// in-place version upgrade, etc.). The host app sees an
    /// `AVCaptureSessionRuntimeError: Recording Stopped` and
    /// the matching AVCaptureDevice briefly drops out of
    /// DiscoverySession, but the camera entry STAYS in
    /// `CameraPropertyStore` — the extension republishes its
    /// snapshot as soon as it's back up. The presence
    /// observer therefore sees no transition and wouldn't
    /// rebind on its own. Without the runtime-error trigger
    /// the preview would stay black indefinitely until the
    /// user manually closed and reopened the window. Observed
    /// 11:04:38 today: extension PID 7266 died silently mid
    /// `ChangeCameraMode`, PID 8007 came up 1.1 s later at the
    /// same build, but CMIO didn't re-invoke `onStreamingStarted`
    /// on the new process so live view never restarted on its
    /// own — only the host-side rebind here can recover.
    private func installSessionErrorObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: captureSession,
            queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            log("CameraPreview: runtime error: \(err?.localizedDescription ?? "nil") — scheduling rebind")
            self?.rebindRetryAttempt = 0
            self?.scheduleRebind()
        }
    }

    /// Watch `CameraPropertyStore.shared.cameras` for the matching
    /// camera's connect/disconnect transitions. The store is the
    /// authoritative signal: it reflects what the CMIO extension
    /// has published, which is the same path the AVCaptureDevice
    /// goes through. When the store flips from "matching camera
    /// absent" to "matching camera present", we schedule a rebind
    /// after `rebindSettleDelay` to let AVCaptureDevice registration
    /// catch up.
    private func observeCameraPresence() {
        // Seed the last-known state to "present" if a match
        // already exists at subscription time — otherwise the
        // first publish during initial bind would be misread as
        // a connect transition and trigger a redundant rebind.
        matchingCameraWasPresent = findMatchingCamera(
            in: CameraPropertyStore.shared.cameras) != nil
        camerasSubscription = CameraPropertyStore.shared.$cameras
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cameras in
                self?.handleCamerasChange(cameras)
            }
    }

    /// Find the ExtCamera that backs this preview, if any. Uses the
    /// same exact-then-substring fallback as
    /// `CameraPropertyStore.camera(matchingName:)` for consistency
    /// with HUD lookups.
    private func findMatchingCamera(in cameras: [String: ExtCamera]) -> ExtCamera? {
        if let exact = cameras.values.first(where: { $0.name == cameraName }) {
            return exact
        }
        return cameras.values.first(where: {
            $0.name.contains(cameraName) || cameraName.contains($0.name)
        })
    }

    /// Decide whether a published change represents a transition
    /// we should react to. The CameraPropertyStore publishes on
    /// every property update, so the bulk of these are no-ops at
    /// presence level.
    private func handleCamerasChange(_ cameras: [String: ExtCamera]) {
        let isPresent = findMatchingCamera(in: cameras) != nil
        guard isPresent != matchingCameraWasPresent else { return }
        matchingCameraWasPresent = isPresent
        if isPresent {
            log("CameraPreview: '\(cameraName)' reappeared — scheduling rebind")
            // Fresh transition → fresh retry budget. Without
            // this, a sequence of reappear-but-AVCaptureDevice-
            // not-ready cycles would exhaust the budget
            // permanently.
            rebindRetryAttempt = 0
            scheduleRebind()
        } else {
            log("CameraPreview: '\(cameraName)' disappeared — preview will go black until reconnect")
        }
    }

    /// Coalesced reconnect rebind. Cancels any pending work item
    /// before scheduling a new one — back-to-back reconnect
    /// transitions (which can happen when the extension restarts
    /// mid-USB-event) collapse into a single attempt.
    private func scheduleRebind() {
        scheduleRebindAttempt(after: Self.rebindSettleDelay)
    }

    /// Same coalescing semantics as `scheduleRebind` but accepts
    /// an explicit delay — used by the backoff retry loop in
    /// `attemptBindCaptureDevice` to space out retries when the
    /// device hasn't shown up yet.
    private func scheduleRebindAttempt(after delay: TimeInterval) {
        pendingRebindWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.attemptBindCaptureDevice()
        }
        pendingRebindWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Locate the AVCaptureDevice matching our camera name and
    /// swap it into `captureSession` as the current input. Safe to
    /// call multiple times: existing inputs are removed inside the
    /// session's `beginConfiguration` / `commitConfiguration`
    /// transaction, so the swap is atomic and the previewLayer
    /// keeps its surface across the switch.
    private func attemptBindCaptureDevice() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.externalUnknown, .builtInWideAngleCamera]
        if #available(macOS 14.0, *) { deviceTypes.append(.external) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified)
        let allDevices = discovery.devices
        log("CameraPreview: \(allDevices.count) device(s): \(allDevices.map(\.localizedName).joined(separator: ", "))")

        guard let device = allDevices.first(where: { $0.localizedName == cameraName })
                        ?? allDevices.first(where: {
                            $0.localizedName.contains(cameraName) || cameraName.contains($0.localizedName)
                        }) else {
            // Retry with linear backoff. The two scenarios that
            // hit this branch:
            //   1. Camera physically absent — store presence
            //      observer is the right re-trigger, but we
            //      still try a few times in case the AVCaptureDevice
            //      registration is just lagging the store update.
            //   2. Extension upgrade in progress — store
            //      presence stays true (camera entry isn't
            //      removed), but the AVCaptureDevice goes away
            //      while the old extension dies and the new one
            //      starts up. The presence observer never fires,
            //      so retries here are the ONLY thing that
            //      brings the preview back.
            if rebindRetryAttempt < Self.maxRebindRetries {
                rebindRetryAttempt += 1
                let delay = min(0.5 + 0.5 * Double(rebindRetryAttempt - 1), 5.0)
                log("CameraPreview: no device matching '\(cameraName)' — retry \(rebindRetryAttempt)/\(Self.maxRebindRetries) in \(delay)s")
                scheduleRebindAttempt(after: delay)
            } else {
                log("CameraPreview: no device matching '\(cameraName)' after \(Self.maxRebindRetries) retries — waiting for next presence or runtime event")
                rebindRetryAttempt = 0
            }
            return
        }
        log("CameraPreview: matched '\(device.localizedName)' uid=\(device.uniqueID)")

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            log("CameraPreview: AVCaptureDeviceInput failed")
            return
        }
        // Successful bind path — reset the retry budget so the
        // next disconnect cycle starts from zero.
        rebindRetryAttempt = 0

        // Atomically swap inputs/outputs. Wrapping the changes in
        // begin/commit avoids the brief "no input" window the
        // session would otherwise drop into between removeInput
        // and addInput — that window emits its own runtime error.
        captureSession.beginConfiguration()
        for old in captureSession.inputs { captureSession.removeInput(old) }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            log("CameraPreview: canAddInput returned false")
            captureSession.commitConfiguration()
            return
        }

        // Output stays attached across rebinds — it's bound to the
        // session, not to any specific device. We only create one
        // on first bind; on subsequent rebinds we re-attach our
        // sample-buffer delegate so the first-frame aspect-set
        // logic re-runs for the new device's stream dimensions.
        if videoOutput == nil {
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            if captureSession.canAddOutput(output) {
                output.setSampleBufferDelegate(self,
                    queue: DispatchQueue(label: sampleBufferQueueLabel))
                captureSession.addOutput(output)
                videoOutput = output
            }
        } else {
            videoOutput?.setSampleBufferDelegate(self,
                queue: DispatchQueue(label: sampleBufferQueueLabel))
        }
        // Re-arm the first-frame handler so a reconnected camera
        // with different stream dimensions reshapes the window.
        aspectSet = false
        captureSession.commitConfiguration()

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
        log("CameraPreview: bind complete isRunning=\(captureSession.isRunning)")
    }

    // Called on every frame — read dimensions from the first one, then detach.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !aspectSet, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        aspectSet = true
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        log("CameraPreview: first frame \(w)×\(h)")
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window, w > 0, h > 0 else { return }
            win.contentAspectRatio = NSSize(width: w, height: h)
            let currentW = win.contentRect(forFrameRect: win.frame).size.width
            win.setContentSize(NSSize(width: currentW, height: currentW * CGFloat(h) / CGFloat(w)))
        }
        // Detach delegate — no need to process further frames just for sizing.
        DispatchQueue.main.async { [weak self] in
            self?.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        captureSession.stopRunning()
        onClose?()
    }
}
