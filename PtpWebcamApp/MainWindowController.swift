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

    private init() {
        let host = NSHostingController(rootView: MainWindowView())
        // Let the SwiftUI hierarchy drive the window's content size. Without
        // this the window stays at whatever `setContentSize` set it to and
        // clips taller layouts (e.g. when more subscription rows are added
        // the third one was disappearing below the title bar).
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        // Use NSLocalizedString so the title is extracted into the strings
        // catalog. Brand-name passes through unchanged in English; other
        // locales can override (e.g. for transliteration) via the catalog.
        window.title = NSLocalizedString("PTP Webcam", comment: "Main window title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
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
