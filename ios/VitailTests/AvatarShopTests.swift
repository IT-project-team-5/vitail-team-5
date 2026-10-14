import Foundation
import XCTest
@testable import Vitail

@MainActor
final class AvatarShopTests: XCTestCase {
    func testLegacyAndUnknownOutfitFieldsUseSafeDefaults() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DogAvatarOutfit.self, from: Data("{}".utf8)), .plain)
        let future = try decoder.decode(DogAvatarOutfit.self, from: Data(
            #"{"hat":"futureHat","bandana_style":"futurePattern","decoration":"futureExtra"}"#.utf8))
        XCTAssertEqual(future, .plain)
        let mixed = try decoder.decode(DogAvatarOutfit.self, from: Data(
            #"{"hat":"beanie","bandana_style":"unknown","decoration":"roundGlasses"}"#.utf8))
        XCTAssertEqual(mixed, .init(hat: .beanie, decoration: .roundGlasses))
        let dressed = DogAvatarOutfit(hat: .sunHat, bandanaStyle: .polkaDot, decoration: .starBadge)
        XCTAssertEqual(try decoder.decode(DogAvatarOutfit.self, from: JSONEncoder().encode(dressed)), dressed)
    }

    func testPurchaseAndClearRequestsUseServerKeysAndExplicitNull() throws {
        let request = AvatarShopPurchase(productCode: "beanie", requestID: UUID())
        let purchase = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(purchase["product_code"] as? String, "beanie")
        XCTAssertEqual(purchase["request_id"] as? String, request.requestID.uuidString)
        let clear = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AvatarShopOutfitUpdate(category: .bandanas, productCode: nil))) as? [String: Any])
        XCTAssertEqual(clear["category"] as? String, "bandanas")
        XCTAssertTrue(clear["product_code"] is NSNull)
        let outfit = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DogAvatarOutfit(bandanaStyle: .striped))) as? [String: Any])
        XCTAssertEqual(outfit["bandana_style"] as? String, "striped")
        XCTAssertNil(outfit["bandanaStyle"])
    }

    func testBalanceAndCataloguePriceComeFromServerWithoutLocalWalletSeed() async throws {
        let cap = AvatarShopProduct(code: "baseballCap", title: "Cap", description: "A cap", category: .hats, price: 17)
        let service = AvatarShopTestService(balance: 83, products: [cap])
        let store = AvatarShopStore(ownerID: 1, service: service)
        XCTAssertNil(store.balance)
        await store.load()
        XCTAssertEqual(store.balance, 83)
        XCTAssertEqual(store.products, [cap])
        let stale = AvatarShopProduct(code: cap.code, title: cap.title, description: cap.description, category: cap.category, price: 1)
        await store.purchase(stale)
        XCTAssertEqual(store.balance, 66)
        XCTAssertEqual(store.products.first?.price, 17)
        store.stop()
    }

    func testPurchaseAndWearAreIndependentAndRepeatedPurchaseDoesNotChargeAgain() async throws {
        let service = AvatarShopTestService()
        var refreshes = 0
        let store = AvatarShopStore(ownerID: 1, service: service, onOutfitChanged: { refreshes += 1 })
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await store.wear(cap)
        let unownedUpdates = await service.updates
        XCTAssertTrue(unownedUpdates.isEmpty)
        await store.purchase(cap)
        XCTAssertEqual(store.balance, 40)
        XCTAssertEqual(store.owned, [cap.code])
        XCTAssertEqual(store.outfit, .plain)
        XCTAssertNil(store.pendingPurchase)
        await store.purchase(cap)
        let purchases = await service.requests
        XCTAssertEqual(purchases.count, 1)
        await store.wear(cap)
        XCTAssertEqual(store.outfit.hat, .baseballCap)
        XCTAssertEqual(store.balance, 40)
        XCTAssertEqual(refreshes, 2)
        store.stop()
    }

    func testLostPurchaseReplyRetriesSameUUIDAndCannotBuyAnotherItemWhilePending() async throws {
        let service = AvatarShopTestService()
        let store = AvatarShopStore(ownerID: 1, service: service)
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        let beanie = try XCTUnwrap(store.products.last)
        await service.loseNextPurchaseReply()
        await store.purchase(cap)
        let pending = try XCTUnwrap(store.pendingPurchase)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.balance, 100)
        await store.purchase(beanie)
        let beforeRetry = await service.requests
        XCTAssertEqual(beforeRetry.count, 1)
        XCTAssertEqual(store.pendingPurchase, pending)
        await store.purchase(cap)
        let requests = await service.requests
        let debits = await service.debits
        XCTAssertEqual(requests.map(\.requestID), [pending.requestID, pending.requestID])
        XCTAssertEqual(debits, 1)
        XCTAssertEqual(store.balance, 40)
        XCTAssertNil(store.pendingPurchase)
        XCTAssertEqual(store.outfit, .plain)
        store.stop()
    }

    func testAuthoritativeLoadReconcilesLostReplyWithoutRepeatingPurchase() async throws {
        let service = AvatarShopTestService()
        var refreshes = 0
        let store = AvatarShopStore(ownerID: 1, service: service, onOutfitChanged: { refreshes += 1 })
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await service.loseNextPurchaseReply()
        await store.purchase(cap)
        XCTAssertNotNil(store.pendingPurchase)
        await store.load()
        await store.retryPendingPurchase()
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(store.pendingPurchase)
        XCTAssertEqual(store.owned, [cap.code])
        XCTAssertEqual(store.balance, 40)
        XCTAssertEqual(refreshes, 1)
        store.stop()
    }

    func testDefinitiveRejectedPurchaseDoesNotLockShop() async throws {
        let service = AvatarShopTestService()
        let store = AvatarShopStore(ownerID: 1, service: service)
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        let beanie = try XCTUnwrap(store.products.last)
        await service.rejectNextPurchase(.http(status: 400, message: "Not enough points"))
        await store.purchase(cap)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.pendingPurchase)
        XCTAssertEqual(store.balance, 100)
        await store.purchase(beanie)
        XCTAssertEqual(store.owned, [beanie.code])
        XCTAssertEqual(store.balance, 50)
        store.stop()
    }

    func testUnconfirmedOwnershipPreservesRetryAndNeverReportsSuccess() async throws {
        let service = AvatarShopTestService()
        var refreshes = 0
        let store = AvatarShopStore(ownerID: 1, service: service, onOutfitChanged: { refreshes += 1 })
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await service.ignoreNextPurchase()
        await store.purchase(cap)
        let requestID = try XCTUnwrap(store.pendingPurchase?.requestID)
        XCTAssertNil(store.notice)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.owned.isEmpty)
        XCTAssertEqual(refreshes, 0)
        await store.retryPendingPurchase()
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.requestID), [requestID, requestID])
        XCTAssertEqual(store.owned, [cap.code])
        store.stop()
    }

    func testIgnoredOrFailedWearRetainsOutfitAndDoesNotReportSuccess() async throws {
        let service = AvatarShopTestService()
        let store = AvatarShopStore(ownerID: 1, service: service)
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await store.purchase(cap)
        await service.ignoreNextOutfitChange()
        await store.wear(cap)
        XCTAssertEqual(store.outfit, .plain)
        XCTAssertNil(store.notice)
        XCTAssertNotNil(store.errorMessage)
        await service.rejectNextOutfitChange(.network("Offline"))
        await store.wear(cap)
        XCTAssertEqual(store.outfit, .plain)
        XCTAssertNil(store.notice)
        XCTAssertNotNil(store.errorMessage)
        await store.wear(cap)
        XCTAssertEqual(store.outfit.hat, .baseballCap)
        await service.ignoreNextOutfitChange()
        await store.clear(.hats)
        XCTAssertEqual(store.outfit.hat, .baseballCap)
        XCTAssertNil(store.notice)
        await store.clear(.hats)
        XCTAssertEqual(store.outfit.hat, .none)
        XCTAssertEqual(store.owned, [cap.code])
        XCTAssertEqual(store.balance, 40)
        store.stop()
    }

    func testInsufficientBalanceDoesNotSendPurchase() async throws {
        let service = AvatarShopTestService(balance: 20)
        let store = AvatarShopStore(ownerID: 1, service: service)
        await store.load()
        await store.purchase(try XCTUnwrap(store.products.first))
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.balance, 20)
        XCTAssertNil(store.pendingPurchase)
        XCTAssertNotNil(store.errorMessage)
        store.stop()
    }

    func testStoppedStoreDiscardsLatePurchaseAndCannotStartMoreOperations() async throws {
        let service = AvatarShopTestService()
        var refreshes = 0
        let store = AvatarShopStore(ownerID: 1, service: service, onOutfitChanged: { refreshes += 1 })
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await service.holdPurchases()
        let purchase = Task { await store.purchase(cap) }
        await service.waitForHeldPurchase()
        store.stop()
        await service.releasePurchase()
        await purchase.value
        await store.purchase(cap)
        await store.load()
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.pendingPurchase)
        XCTAssertEqual(refreshes, 0)
    }

    func testSignedOutAndNewAccountCannotReuseOldStoreOrPendingUUID() async throws {
        let auth = AvatarShopAuthService()
        let session = SessionStore(authService: auth)
        await session.restore()
        let service = AvatarShopTestService()
        let store = AvatarShopStore(ownerID: 1, session: session, service: service)
        await store.load()
        let cap = try XCTUnwrap(store.products.first)
        await service.loseNextPurchaseReply()
        await store.purchase(cap)
        XCTAssertNotNil(store.pendingPurchase)
        await session.logout()
        await auth.setOwnerID(2)
        try await session.login(email: "owner2@example.test", password: "test", expectedRole: .owner)
        await store.retryPendingPurchase()
        await store.purchase(cap)
        await store.load()
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.pendingPurchase)
    }
}

private actor AvatarShopTestService: AvatarShopServing {
    private(set) var requests: [AvatarShopPurchase] = []
    private(set) var updates: [AvatarShopOutfitUpdate] = []
    private(set) var debits = 0
    private var balance: Int
    private var products: [AvatarShopProduct]
    private var owned: Set<String> = []
    private var outfit = DogAvatarOutfit.plain
    private var completed: [UUID: String] = [:]
    private var loseReply = false
    private var ignorePurchase = false
    private var purchaseFailure: APIError?
    private var ignoreOutfit = false
    private var outfitFailure: APIError?
    private var hold = false
    private var purchaseGate: CheckedContinuation<Void, Never>?
    private var purchaseStarted: CheckedContinuation<Void, Never>?

    init(balance: Int = 100, products: [AvatarShopProduct]? = nil) {
        self.balance = balance
        self.products = products ?? [
            .init(code: "baseballCap", title: "Baseball cap", description: "A cap", category: .hats, price: 60),
            .init(code: "beanie", title: "Cosy beanie", description: "A beanie", category: .hats, price: 50)
        ]
    }
    func loseNextPurchaseReply() { loseReply = true }
    func ignoreNextPurchase() { ignorePurchase = true }
    func rejectNextPurchase(_ error: APIError) { purchaseFailure = error }
    func ignoreNextOutfitChange() { ignoreOutfit = true }
    func rejectNextOutfitChange(_ error: APIError) { outfitFailure = error }
    func holdPurchases() { hold = true }
    func waitForHeldPurchase() async {
        if purchaseGate == nil { await withCheckedContinuation { purchaseStarted = $0 } }
    }
    func releasePurchase() { hold = false; purchaseGate?.resume(); purchaseGate = nil }
    private var snapshot: AvatarShopState {
        .init(balance: balance, products: products, owned: owned.sorted(), outfit: outfit)
    }
    func load() async throws -> AvatarShopState { snapshot }
    func purchase(_ request: AvatarShopPurchase) async throws -> AvatarShopState {
        requests.append(request)
        if hold {
            await withCheckedContinuation {
                purchaseGate = $0
                purchaseStarted?.resume()
                purchaseStarted = nil
            }
        }
        if let purchaseFailure { self.purchaseFailure = nil; throw purchaseFailure }
        if ignorePurchase { ignorePurchase = false; return snapshot }
        if let code = completed[request.requestID] {
            guard code == request.productCode else { throw APIError.http(status: 409, message: "Request conflict") }
            return snapshot
        }
        guard let product = products.first(where: { $0.code == request.productCode }) else {
            throw APIError.http(status: 400, message: "Unknown product")
        }
        if !owned.contains(product.code) {
            guard balance >= product.price else { throw APIError.http(status: 400, message: "Not enough points") }
            balance -= product.price
            owned.insert(product.code)
            debits += 1
        }
        completed[request.requestID] = product.code
        if loseReply { loseReply = false; throw APIError.network("Response lost") }
        return snapshot
    }
    func updateOutfit(_ update: AvatarShopOutfitUpdate) async throws -> AvatarShopState {
        updates.append(update)
        if let outfitFailure { self.outfitFailure = nil; throw outfitFailure }
        if ignoreOutfit { ignoreOutfit = false; return snapshot }
        if let code = update.productCode {
            guard owned.contains(code), let product = products.first(where: { $0.code == code && $0.category == update.category }) else {
                throw APIError.http(status: 400, message: "Product not owned")
            }
            outfit = product.applying(to: outfit)
        } else {
            switch update.category {
            case .hats: outfit.hat = .none
            case .bandanas: outfit.bandanaStyle = .classic
            case .extras: outfit.decoration = .none
            }
        }
        return snapshot
    }
}

private actor AvatarShopAuthService: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    private var ownerID = 1
    private var user: User { .init(id: ownerID, email: "owner@example.test", displayName: "Owner", role: .owner) }
    func setOwnerID(_ value: Int) { ownerID = value }
    func login(email: String, password: String) async throws -> AuthResponse {
        .init(access: "access", refresh: "refresh", user: user)
    }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse {
        .init(access: "access", refresh: "refresh", user: user)
    }
    func persist(_ tokens: AuthTokens) async throws {}
    func restoreUser() async throws -> User? { user }
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { user }
}
