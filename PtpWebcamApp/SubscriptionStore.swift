// SubscriptionStore.swift
// StoreKit 2 product loading + entitlement tracking for the in-app subscription.

import Foundation
import StoreKit
import OSLog

/// Product identifiers configured in App Store Connect. Adjust these to match
/// the products you create in the subscription group there. Two tiers is a
/// sensible starting shape (monthly trial + discounted annual) but you can
/// add more by appending here; the UI iterates whatever this list contains.
enum SubscriptionProductID {
    static let snack = "ptptwebcam_patron_monthly_0"
	static let sandwich  = "ptpwebcam_patron_monthly_1"
	static let dinner  = "ptpwebcam_patron_monthly_2"
    static let all: [String] = [snack, sandwich, dinner]
}

/// Observable wrapper around StoreKit 2 that the SwiftUI views bind to.
/// Owns three pieces of state:
///   - `products`: the Product objects fetched from the App Store, used to
///     render localized titles, descriptions, and prices.
///   - `entitlement`: whether the user currently has an active subscription
///     (any product in the group). Drives the "subscribed / not subscribed"
///     header in the main window.
///   - `purchaseState`: per-product purchase-in-progress flag for the
///     buttons, so they can show a spinner during the StoreKit dialog.
///
/// Refreshes itself on `init` and re-checks entitlements whenever StoreKit
/// posts a transaction update (purchase, renewal, refund, etc.).
@MainActor
final class SubscriptionStore: ObservableObject {

    private static let log = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp", category: "SubscriptionStore")

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement: Entitlement = .unknown
    @Published private(set) var purchaseInProgress: Set<Product.ID> = []
    @Published private(set) var loadError: String? = nil

    enum Entitlement: Equatable {
        case unknown               // still loading
        case notSubscribed
        case subscribed(productId: String, expires: Date?)
        var isActive: Bool { if case .subscribed = self { return true } else { return false } }
    }

    private var transactionUpdateTask: Task<Void, Never>?

    init() {
        // Listen for transactions posted outside of an explicit purchase()
        // call — renewals, family-sharing changes, subscription resumes
        // after a refund, all arrive here.
        transactionUpdateTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let txn) = update {
                    await txn.finish()
                    await self?.refreshEntitlement()
                }
            }
        }
        Task { await refresh() }
    }

    deinit { transactionUpdateTask?.cancel() }

    // MARK: - Public API

    /// Reload products and current entitlement. Safe to call repeatedly; the
    /// UI invokes it on appear and after a manual "restore purchases".
    func refresh() async {
        await loadProducts()
        await refreshEntitlement()
    }

    func purchase(_ product: Product) async {
        purchaseInProgress.insert(product.id)
        defer { purchaseInProgress.remove(product.id) }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await txn.finish()
                    Self.log.info("Purchase succeeded: \(product.id, privacy: .public)")
                } else {
                    Self.log.error("Purchase verification failed for \(product.id, privacy: .public)")
                }
            case .userCancelled:
                Self.log.info("Purchase cancelled by user: \(product.id, privacy: .public)")
            case .pending:
                Self.log.info("Purchase pending (e.g. Ask to Buy): \(product.id, privacy: .public)")
            @unknown default:
                Self.log.error("Unknown purchase result for \(product.id, privacy: .public)")
            }
            await refreshEntitlement()
        } catch {
            Self.log.error("Purchase threw for \(product.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-sync transactions from the App Store. The user's existing
    /// subscription (made on another device, or before reinstall) shows up
    /// here even if no local Apple-ID change has triggered an automatic
    /// transaction update.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            Self.log.info("AppStore.sync completed")
        } catch {
            Self.log.error("AppStore.sync failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshEntitlement()
    }

    /// Open the system Manage Subscriptions UI. On macOS there's no in-app
    /// sheet equivalent to `showManageSubscriptions(in:)` on iOS, so we hand
    /// the user off to the App Store via Apple's stable subscriptions URL.
    /// `itms-apps://` opens directly in App Store.app without a Safari hop.
    @MainActor
    func showManageSubscriptions() {
        if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Internals

    private func loadProducts() async {
        do {
            let requested = SubscriptionProductID.all
            let fetched = try await Product.products(for: requested)
            // Sort by price ascending so monthly appears before yearly when
            // pricing is what you'd expect. App Store Connect ordering is
            // not guaranteed; sort defensively.
            products = fetched.sorted { $0.price < $1.price }
            loadError = nil
            // Diagnostic: list which requested IDs the backend returned, and
            // which it dropped silently. `Product.products(for:)` only emits
            // products the backend recognizes — IDs missing from the local
            // .storekit config (or App Store Connect listing) just disappear
            // with no error. The "missing" line tells you exactly which ones.
            let got     = Set(fetched.map(\.id))
            let missing = requested.filter { !got.contains($0) }
            Self.log.info("Loaded \(self.products.count, privacy: .public)/\(requested.count, privacy: .public) products. got=\(Array(got).sorted().joined(separator: ","), privacy: .public) missing=\(missing.joined(separator: ","), privacy: .public)")
        } catch {
            products = []
            loadError = error.localizedDescription
            Self.log.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshEntitlement() async {
        // Walk all current entitlements and pick the most-recently-renewed
        // auto-renewable subscription. `currentEntitlements` filters out
        // expired/refunded transactions automatically.
        var best: (txn: Transaction, productId: String)? = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result else { continue }
            guard txn.productType == .autoRenewable else { continue }
            if best == nil || (best!.txn.purchaseDate < txn.purchaseDate) {
                best = (txn, txn.productID)
            }
        }
        if let best {
            entitlement = .subscribed(productId: best.productId, expires: best.txn.expirationDate)
        } else {
            entitlement = .notSubscribed
        }
    }
}

