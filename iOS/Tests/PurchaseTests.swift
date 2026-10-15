import StoreKitTest
import XCTest
@testable import Rekeep

/// End-to-end StoreKit checks against the local App Store configuration (no real charges).
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Rekeep")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        SharedStorage.defaults.removeObject(forKey: "rekeep.pro")
        await PurchaseManager.shared.refreshEntitlement()
    }

    func testFreeLimits() {
        let store = PurchaseManager.shared
        XCTAssertFalse(store.isPro)
        XCTAssertTrue(store.allows(.collections, count: FreeTier.collections - 1))
        XCTAssertFalse(store.allows(.collections, count: FreeTier.collections))
        XCTAssertEqual(store.paywallReason, .collections)
        XCTAssertTrue(store.allows(.snippets, count: 0))
        XCTAssertFalse(store.allows(.compose))
        XCTAssertFalse(store.allows(.queue))
        XCTAssertEqual(store.historyLimit, FreeTier.visibleHistory)
    }

    func testProductLoadsWithLocalizedPrice() async {
        await PurchaseManager.shared.loadProduct()
        XCTAssertEqual(PurchaseManager.shared.product?.id, PurchaseManager.productID)
        XCTAssertEqual(PurchaseManager.shared.product?.displayPrice, "$9.99")
    }

    func testPurchaseRefundAndRestore() async throws {
        let store = PurchaseManager.shared
        await store.loadProduct()
        await store.purchase()
        XCTAssertTrue(store.isPro, "purchase unlocks Pro")
        XCTAssertNil(store.historyLimit)
        XCTAssertTrue(store.allows(.compose))
        XCTAssertTrue(SharedStorage.defaults.bool(forKey: "rekeep.pro"), "entitlement cached for offline use and extensions")

        // Refund → access removed (data is untouched; limits only affect what's shown).
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        // Revocations arrive asynchronously through Transaction.updates, which the manager listens to.
        for _ in 0..<40 where store.isPro {
            try await Task.sleep(for: .milliseconds(100))
            await store.refreshEntitlement()
        }
        XCTAssertFalse(store.isPro, "refund revokes Pro")

        // Buy again, wipe the local cache, restore.
        await store.purchase()
        SharedStorage.defaults.removeObject(forKey: "rekeep.pro")
        await store.restore()
        XCTAssertTrue(store.isPro, "restore recovers the entitlement")
    }

    func testAskToBuyStaysPending() async {
        session.askToBuyEnabled = true
        let store = PurchaseManager.shared
        await store.loadProduct()
        await store.purchase()
        XCTAssertFalse(store.isPro)
        XCTAssertTrue(store.isPending, "pending purchases are shown as waiting, not as failures")
        session.askToBuyEnabled = false
    }
}
