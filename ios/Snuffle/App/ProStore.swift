import Observation
import SnuffleKit
import StoreKit

/// Snuffle Pro through StoreKit 2: monthly, yearly (7-day free trial) and lifetime.
@MainActor
@Observable
final class ProStore {
    static let monthly = "ai.snuffle.pro.monthly"
    static let yearly = "ai.snuffle.pro.yearly"
    static let lifetime = "ai.snuffle.pro.lifetime"
    static let productIds = [monthly, yearly, lifetime]
    /// The widget extension reads this to decide whether to draw numbers or the upgrade note.
    static let sharedFlag = "isPro"

    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var activeProductId: String?
    private(set) var loadError: String?
    /// Whether this Apple account can still start the yearly plan's free trial. Someone who already had it,
    /// or any subscription in the group, pays from day one.
    private(set) var trialEligible = false

    private var updates: Task<Void, Never>?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forcePro") { isPro = true }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// Length of the yearly plan's free trial, read from App Store Connect rather than assumed.
    var trialDays: Int? {
        guard let offer = product(Self.yearly)?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return Self.days(in: offer.period)
    }

    /// The trial this person would actually get: offered on the plan and not used before.
    var availableTrialDays: Int? { trialEligible ? trialDays : nil }

    /// "$1.67" for $19.99 a year: the per-month figure shown in small print next to the yearly price.
    func monthlyEquivalent(of product: Product) -> String {
        (product.price / 12).formatted(product.priceFormatStyle)
    }

    nonisolated static func days(in period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day: period.value
        case .week: period.value * 7
        case .month: period.value * 30
        case .year: period.value * 365
        @unknown default: period.value
        }
    }

    func loadProducts() async {
        loadError = nil
        do {
            products = try await Product.products(for: Self.productIds)
            loadError = products.isEmpty ? "暂时拿不到价格，请稍后再试" : nil
        } catch {
            loadError = "暂时拿不到价格：\(error.localizedDescription)"
        }
        await refreshTrialEligibility()
    }

    private func refreshTrialEligibility() async {
        trialEligible = await product(Self.yearly)?.subscription?.isEligibleForIntroOffer ?? false
    }

    /// Returns true when the purchase went through (not when it is pending or cancelled).
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            await refreshEntitlements()
            return true
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var active: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIds.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            active = transaction.productID
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forcePro") { active = active ?? Self.lifetime }
        #endif
        activeProductId = active
        isPro = active != nil
        UserDefaults(suiteName: SharedContainer.appGroup)?.set(isPro, forKey: Self.sharedFlag)
        await refreshTrialEligibility()
    }

    /// The signed transaction the server checks before drafting a reply.
    func entitlementProof() async -> String? {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.productIds.contains(transaction.productID) {
                return result.jwsRepresentation
            }
        }
        return nil
    }
}
