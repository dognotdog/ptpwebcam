// MainWindowView.swift
// Top-level UI shown when the user opens PTP Webcam from the Dock / Finder.
// Provides app status (extension state, build version) and a place to start
// or manage an in-app subscription.

import SwiftUI
import StoreKit

struct MainWindowView: View {
    @StateObject private var store = SubscriptionStore()

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
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            subscriptionSection
            Divider()
            footer
        }
        .padding(28)
        .frame(width: 520, alignment: .topLeading)
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
