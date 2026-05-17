// MainWindowController.swift
// NSWindowController shell that hosts the SwiftUI MainWindowView. We use an
// NSWindow (not a SwiftUI `Window` scene) because PTP Webcam's lifecycle is
// AppKit-rooted — agent registration, system-extension activation, and URL
// scheme handling all live in the AppDelegate, and adding a SwiftUI App
// scene would force a bigger restructure than this single window justifies.

import AppKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()
    /// Latest natural content height reported by MainWindowView. Used by
    /// `windowWillResize(_:to:)` to clamp the user's drag so the window
    /// can't grow past where empty space would start showing below the
    /// footer buttons. Defaults to 720 so the cap is sane before SwiftUI
    /// has had a chance to measure.
    private var naturalContentHeight: CGFloat = 720

    private init() {
        let host = NSHostingController(rootView: MainWindowView())
        // Don't auto-size from the SwiftUI intrinsic content — the view is
        // now wrapped in a ScrollView whose `idealHeight` is conceptually
        // unbounded, so `.preferredContentSize` would either pick a tiny
        // size or blow past the screen. We set an explicit content size
        // below that fits within `NSScreen.main.visibleFrame`, and the
        // ScrollView handles overflow gracefully.
        let window = NSWindow(contentViewController: host)
        // Brand-name + version in the title bar so users (and bug reports)
        // can identify the build without opening About. Catalog uses
        // NSLocalizedString for the brand half; the version suffix is
        // appended verbatim. Reads the Info.plist values rather than
        // depending on SwiftUI's view-level lookup so it stays accurate
        // even before the view first renders.
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "?"
        let brand = NSLocalizedString("PTP Webcam", comment: "Main window title")
        window.title = "\(brand) v\(short) (\(build))"
        // Resizable so users on small screens can shrink the window and
        // scroll the content (the SwiftUI view wraps itself in a
        // ScrollView). The fixed 520pt content width is enforced via
        // contentMinSize / contentMaxSize below so the layout doesn't
        // become wonky if the user grabs the resize handle.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        // Initial bounds before SwiftUI has measured the content. The min
        // is the user-facing "how small can I make it" floor; the max is
        // a placeholder pinned to the screen so we never accidentally
        // open larger than the display. Both get refined once the inner
        // VStack reports its natural height via `ContentHeightKey` —
        // see `applyNaturalContentHeight` below.
        let titleBar: CGFloat = 28
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let screenCap = max(360, screenH - titleBar - 16)
        window.contentMinSize = NSSize(width: 520, height: 200)
        window.contentMaxSize = NSSize(width: 520, height: screenCap)
        window.setContentSize(NSSize(width: 520, height: min(720, screenCap)))

        window.center()
        super.init(window: window)
        window.delegate = self

        // Listen for natural-height reports from MainWindowView. Once
        // SwiftUI has laid out the content stack we pin contentMaxSize
        // to that value — so the user can shrink the window (the
        // ScrollView handles overflow) but cannot grow it past where
        // empty space would start showing below the buttons.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(naturalHeightChanged(_:)),
            name: .mainWindowNaturalHeightChanged,
            object: nil)
    }

    /// Reported natural content height from the SwiftUI side. Clamped to
    /// what the screen can actually display before being applied as the
    /// window's contentMaxSize. We also tighten the current frame on the
    /// first report so the initial window opens at exactly the natural
    /// height instead of the conservative 720pt placeholder used in init.
    private var hasAppliedNaturalHeight = false
    @objc private func naturalHeightChanged(_ note: Notification) {
        guard let window,
              let h = note.userInfo?["height"] as? CGFloat,
              h > 100 else { return }
        let screenH = window.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 800
        let titleBarH = window.frame.height - window.contentLayoutRect.height
        let screenCap = max(200, screenH - titleBarH - 16)
        let target = min(h, screenCap)
        // Avoid thrashing on rounding noise — SwiftUI emits a small flurry
        // of preference updates as views settle during transitions.
        if abs(naturalContentHeight - target) < 0.5 { return }
        naturalContentHeight = target
        if !hasAppliedNaturalHeight {
            hasAppliedNaturalHeight = true
            window.setContentSize(NSSize(width: 520, height: target))
        } else if window.contentLayoutRect.height > target {
            // The content stack got shorter (e.g. subscription state went
            // from .notSubscribed to .subscribed and dropped some rows).
            // Shrink the window to match, so we don't strand empty space
            // below the footer.
            window.setContentSize(NSSize(width: 520, height: target))
        }
    }

    // MARK: - NSWindowDelegate (live-resize clamp)

    /// Clamp the user's drag-resize so the window can't grow past the
    /// SwiftUI content's natural height (would strand empty space below
    /// the footer) and can't shrink below 200pt of content (would hide
    /// even the header). `windowWillResize` is called for every drag
    /// step, which is more reliable than `minSize` / `maxSize` after
    /// init — AppKit's enforcement of those properties is inconsistent
    /// when they're mutated post-creation, but the delegate hook fires
    /// every time without fail.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let titleBarH = sender.frame.height - sender.contentLayoutRect.height
        let frameWidth = 520 + (sender.frame.width - sender.contentLayoutRect.width)
        let maxH = naturalContentHeight + titleBarH
        let minH = 200 + titleBarH
        return NSSize(width: frameWidth,
                       height: min(max(frameSize.height, minH), maxH))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Bring the window to the front, creating it lazily on first call.
    ///
    /// Also touches the "last subscription reminder shown" timestamp so that
    /// AppDelegate's preview-close auto-prompt respects the same 24-hour
    /// window regardless of how the window got opened (auto-after-preview,
    /// About menu from the app or agent, Dock click, Finder launch). We
    /// don't want to nag a user who already looked at the page this morning.
    func present() {
        UserDefaults.standard.set(Date(), forKey: "lastSubscriptionReminderAt")
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
