import StoreKitTest
import XCTest
@testable import Snuffle

/// Buys Pro against the local StoreKit configuration and checks what the server will be shown.
@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        #if targetEnvironment(simulator)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try XCTSkipIf(os.majorVersion == 26 && os.minorVersion == 5,
                      "StoreKitTest fails on the iOS 26.5 simulator (SKInternalErrorDomain 3); run on iOS 18 or 26.6+.")
        #endif
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    func testYearlyTrialUnlocksProUntilItExpires() async throws {
        let store = ProStore()
        await store.loadProducts()
        XCTAssertEqual(Set(store.products.map(\.id)), Set(ProStore.productIds))
        let yearly = try XCTUnwrap(store.product(ProStore.yearly))
        XCTAssertEqual(yearly.displayPrice, "$19.99")
        XCTAssertEqual(yearly.subscription?.introductoryOffer?.paymentMode, .freeTrial)
        XCTAssertEqual(store.product(ProStore.monthly)?.displayPrice, "$1.99")
        XCTAssertEqual(store.product(ProStore.lifetime)?.displayPrice, "$29.99")
        XCTAssertEqual(store.trialDays, 7, "the trial length comes from the product, not the UI")
        XCTAssertTrue(store.trialEligible)
        XCTAssertEqual(store.availableTrialDays, 7)
        XCTAssertEqual(store.monthlyEquivalent(of: yearly), "$1.67")

        let bought = try await store.purchase(yearly)
        XCTAssertTrue(bought)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.activeProductId, ProStore.yearly)

        let maybeProof = await store.entitlementProof()
        let proof = try XCTUnwrap(maybeProof)
        let payload = try Self.payload(of: proof)
        XCTAssertEqual(payload["bundleId"] as? String, "ai.snuffle.app")
        XCTAssertEqual(payload["productId"] as? String, ProStore.yearly)
        XCTAssertEqual(payload["environment"] as? String, "Xcode")
        XCTAssertNotNil(payload["originalTransactionId"])
        XCTAssertNotNil(payload["expiresDate"])
        // Hand the signed transaction to the server's verifier when asked (see server/scripts/verify-jws.ts).
        if let path = ProcessInfo.processInfo.environment["SNUFFLE_JWS_OUT"] {
            try proof.write(toFile: path, atomically: true, encoding: .utf8)
        }

        try session.expireSubscription(productIdentifier: ProStore.yearly)
        await Self.waitUntilNotPro(store)
        XCTAssertFalse(store.isPro, "an expired subscription takes Pro away")
        XCTAssertFalse(store.trialEligible, "the trial is offered once per Apple account")
        XCTAssertNil(store.availableTrialDays)
    }

    func testLifetimePurchaseIsPro() async throws {
        let store = ProStore()
        await store.loadProducts()
        let lifetime = try XCTUnwrap(store.product(ProStore.lifetime))
        let bought = try await store.purchase(lifetime)
        XCTAssertTrue(bought)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.activeProductId, ProStore.lifetime)
    }

    func testRefundTakesProAway() async throws {
        let store = ProStore()
        await store.loadProducts()
        let bought = try await store.purchase(try XCTUnwrap(store.product(ProStore.monthly)))
        XCTAssertTrue(bought)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProStore.monthly })
        try session.refundTransaction(identifier: transaction.identifier)
        await Self.waitUntilNotPro(store)
        XCTAssertFalse(store.isPro, "a refund takes Pro away")
    }

    /// StoreKit's local entitlement cache catches up a moment after expiry or refund.
    private static func waitUntilNotPro(_ store: ProStore) async {
        for _ in 0..<40 where store.isPro {
            try? await Task.sleep(for: .milliseconds(100))
            await store.refreshEntitlements()
        }
    }

    private static func payload(of jws: String) throws -> [String: Any] {
        let parts = jws.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: text))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
