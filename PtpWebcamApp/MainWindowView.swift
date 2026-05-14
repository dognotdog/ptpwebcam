// MainWindowView.swift
// Top-level UI shown when the user opens PTP Webcam from the Dock / Finder.
// Provides app status (extension state, build version) and a place to start
// or manage an in-app subscription.

import SwiftUI
import StoreKit

struct MainWindowView: View {
    @StateObject private var store = SubscriptionStore()

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "?"
        return "\(short) (\(build))"
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
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("PTP Webcam").font(.title).bold()
                Text("Turn your PTP-tethered camera into a webcam.")
                    .foregroundStyle(.secondary)
                Text("Version \(appVersion)").font(.caption).foregroundStyle(.tertiary)
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
        let (label, color): (String, Color) = {
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
        // Show the localized name of the active subscription tier, falling
        // back to the raw product ID if products haven't loaded yet (e.g. on
        // a cold launch the entitlement check resolves before the StoreKit
        // catalog round-trip finishes).
        let tierName: String = store.products.first(where: { $0.id == productId })?.displayName ?? productId
        return VStack(alignment: .leading, spacing: 12) {
            Text("Thanks for supporting PTP Webcam.")
            HStack(spacing: 6) {
                Text("Current plan:").foregroundStyle(.secondary)
                Text(tierName).bold()
            }
            .font(.callout)
            if let expires {
                Text("Renews \(expires.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout).foregroundStyle(.secondary)
            }
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

            if let err = store.loadError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if store.products.isEmpty {
                ProgressView("Loading options…")
            } else {
                ForEach(store.products) { product in
                    productRow(product)
                }
            }

            HStack {
                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func productRow(_ product: Product) -> some View {
        let inProgress = store.purchaseInProgress.contains(product.id)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName).font(.headline)
                if !product.description.isEmpty {
                    Text(product.description).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(product.displayPrice).font(.headline)
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    if inProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Subscribe")
                    }
                }
                .disabled(inProgress)
                .controlSize(.regular)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Visit ptpwebcam.org") {
                if let url = URL(string: "https://ptpwebcam.org") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
        }
    }
}

#Preview { MainWindowView() }
