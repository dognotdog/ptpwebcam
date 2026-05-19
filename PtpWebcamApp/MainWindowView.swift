// MainWindowView.swift
// Top-level UI shown when the user opens PTP Webcam from the Dock / Finder.
// Provides app status (extension state, build version) and a place to start
// or manage an in-app subscription.

import SwiftUI
import StoreKit

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
                if menuBarVisibility.menuBarItemHidden {
                    menuBarHiddenWarning
                }
                Divider()
                subscriptionSection
                Divider()
                footer
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
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("PTP Webcam’s menu bar icon isn’t visible")
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.4), lineWidth: 1))
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
