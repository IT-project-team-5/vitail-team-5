import XCTest
@testable import Vitail

@MainActor
final class RedemptionTests: XCTestCase {
    func testCafeGroupingUsesIdentityRatherThanNameAndKeepsEachMenuSeparate() {
        let offers = [
            Reward(id: 1, name: "Coffee", description: "", pointCost: 60, cafeName: "Same Name", cafeID: 10),
            Reward(id: 2, name: "Tea", description: "", pointCost: 40, cafeName: "Same Name", cafeID: 10),
            Reward(id: 3, name: "Latte", description: "", pointCost: 70, cafeName: "Same Name", cafeID: 20)
        ]
        let cafes = CafeRewardGroup.grouped(offers)
        XCTAssertEqual(cafes.count, 2)
        XCTAssertEqual(cafes.first { $0.id == "cafe-10" }?.rewards.map(\.id), [2, 1])
        XCTAssertEqual(cafes.first { $0.id == "cafe-20" }?.rewards.map(\.id), [3])
    }

    func testVenueResponseDecodesPhotoMapAndOpeningHoursWithoutBreakingOldResponses() throws {
        let data = Data(#"{"id":1,"name":"Coffee","description":"","point_cost":60,"cafe_name":"Paws","cafe_id":9,"cafe_photo":"https://example.com/photo.jpg","cafe_opening_hours":"7–3","cafe_google_maps_url":"https://maps.google.com/?q=Paws"}"#.utf8)
        let reward = try JSONDecoder().decode(Reward.self, from: data)
        XCTAssertEqual(reward.cafeID, 9)
        XCTAssertEqual(reward.cafePhoto, "https://example.com/photo.jpg")
        XCTAssertEqual(CafeRewardGroup.grouped([reward]).first?.openingHours, "7–3")
        let old = Data(#"{"id":2,"name":"Tea","description":"","point_cost":40,"cafe_name":"Legacy"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Reward.self, from: old).cafeID)
    }

    func testCoffeeEstimateUsesAgreedSixtyPointReference() {
        XCTAssertEqual(CoffeeEstimate.pointsPerCup, 60)
        XCTAssertEqual(CoffeeEstimate.text(for: 60), "≈ 1 cup of coffee")
        XCTAssertEqual(CoffeeEstimate.text(for: 120), "≈ 2 cups of coffee")
        XCTAssertEqual(CoffeeEstimate.text(for: 0), "≈ 0 cups of coffee")
    }

    func testCollectionDeadlineUsesMelbourneMidnightAcrossDaylightSaving() throws {
        let parser = ISO8601DateFormatter()
        for (now, expected) in [
            ("2026-09-23T14:30:00Z", "2026-09-24T14:00:00Z"),
            ("2026-10-03T15:30:00Z", "2026-10-04T13:00:00Z"),
            ("2026-04-04T14:30:00Z", "2026-04-05T14:00:00Z")
        ] {
            XCTAssertEqual(CollectionDeadline.nextDeadline(after: try XCTUnwrap(parser.date(from: now))),
                           try XCTUnwrap(parser.date(from: expected)))
        }
    }

    func testSuccessfulPurchasePresentsReceiptEvenWhenFollowupRefreshFails() async {
        let model = RedemptionViewModel(service: RedemptionStub(failReloadAfterCreate: true))
        await model.refresh()
        await model.redeem(rewardID: 1)

        XCTAssertEqual(model.purchasedReceipt?.referenceNumber, "VIT-TEST")
        XCTAssertEqual(model.pendingRedemptions.count, 1)
        XCTAssertNil(model.retryRewardID, "A confirmed order must not be purchased again after a refresh failure.")
        XCTAssertNotNil(model.errorMessage)
        model.acknowledgePurchasedReceipt()
        XCTAssertNil(model.purchasedReceipt, "Returning to the menu must not reopen an old receipt.")
    }

    func testCollectionRequiresCompleteEnabledSlideAndCannotConfirmTwice() {
        var slide = SlideConfirmationState()
        slide.offset = 100
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: true))
        XCTAssertEqual(slide.offset, 0)
        slide.offset = 250
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: false))
        slide.offset = 250
        XCTAssertTrue(slide.finish(travel: 250, isEnabled: true))
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: true))
        slide.reset()
        slide.offset = 250
        XCTAssertTrue(slide.finish(travel: 250, isEnabled: true))
    }

    func testAmbiguousRetryUsesSameIDAndDoesNotSubtractPointsTwice() async {
        let service = RedemptionStub(failFirstCreate: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.balance, 60)

        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.retryRewardID, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.purchasedReceipt, "An uncertain purchase cannot show an unconfirmed receipt.")
        await model.redeem(rewardID: 1)

        let ids = await service.requestIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNil(model.retryRewardID)
        XCTAssertEqual(model.balance, 50)
        XCTAssertEqual(model.pendingRedemptions.count, 1)
        XCTAssertEqual(model.purchasedReceipt?.id, model.pendingRedemptions.first?.id)
    }

    func testUncertainPurchaseCanRetryEvenWhenItsCafeLeavesTheCatalogue() async {
        let service = RedemptionStub(failFirstCreate: true, hidePurchasedReward: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await model.redeem(rewardID: 1)
        await model.refresh()
        XCTAssertTrue(model.cafes.isEmpty)
        XCTAssertEqual(model.retryRewardID, 1)
        XCTAssertEqual(model.retryReward?.name, "Coffee")
        await model.redeem(rewardID: 1)
        let ids = await service.requestIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNil(model.retryRewardID)
        XCTAssertNil(model.retryReward)
        XCTAssertEqual(model.balance, 50)
    }

    func testExpiredCollectRefreshesRefundAndHistory() async {
        let service = RedemptionStub(expireOnCollect: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.balance, 50)
        await model.collect(redemptionID: 1)

        XCTAssertEqual(model.balance, 60)
        XCTAssertTrue(model.pendingRedemptions.isEmpty)
        XCTAssertEqual(model.history.first?.status, .expired)
        XCTAssertNotNil(model.errorMessage)
    }

    func testCollectedOrderMovesToHistoryAndServerBalanceRemainsCorrect() async {
        let model = RedemptionViewModel(service: RedemptionStub())
        await model.refresh()
        await model.redeem(rewardID: 1)
        await model.collect(redemptionID: 1)
        XCTAssertEqual(model.balance, 50)
        XCTAssertTrue(model.pendingRedemptions.isEmpty)
        XCTAssertEqual(model.history.first?.status, .collected)
    }

    func testCannotStartDifferentRewardWhileCreateOutcomeIsUnknown() async {
        let service = RedemptionStub(failFirstCreate: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await model.redeem(rewardID: 1)
        await model.redeem(rewardID: 2)
        let calls = await service.requestIDs.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.retryRewardID, 1)
    }

    func testRequestEncodesRewardAndIdempotencyKey() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(CreateRedemptionRequest(rewardId: 4, requestId: id))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reward_id"] as? Int, 4)
        XCTAssertEqual(object["request_id"] as? String, id.uuidString)
    }
}

private actor RedemptionStub: RedemptionServing {
    var requestIDs: [UUID] = []
    private var balance = 60
    private var orders: [Redemption] = []
    private let failFirstCreate: Bool
    private let expireOnCollect: Bool
    private let hidePurchasedReward: Bool
    private let failReloadAfterCreate: Bool

    init(failFirstCreate: Bool = false, expireOnCollect: Bool = false, hidePurchasedReward: Bool = false,
         failReloadAfterCreate: Bool = false) {
        self.failFirstCreate = failFirstCreate
        self.expireOnCollect = expireOnCollect
        self.hidePurchasedReward = hidePurchasedReward
        self.failReloadAfterCreate = failReloadAfterCreate
    }

    func fetchBalance() async throws -> WalletBalance { WalletBalance(balance: balance) }
    func fetchRewards() async throws -> [Reward] {
        if hidePurchasedReward && !orders.isEmpty { return [] }
        return [Reward(id: 1, name: "Coffee", description: "", pointCost: 10, cafeName: "Cafe")]
    }
    func fetchRedemptions() async throws -> [Redemption] {
        if failReloadAfterCreate && !orders.isEmpty { throw APIError.network("Refresh unavailable") }
        return orders
    }

    func createRedemption(rewardID: Int, requestID: UUID) async throws -> Redemption {
        requestIDs.append(requestID)
        if orders.isEmpty {
            orders = [order(status: .pending)]
            balance -= 10
        }
        if failFirstCreate && requestIDs.count == 1 { throw APIError.network("Offline") }
        return orders[0]
    }

    func collectRedemption(id: Int) async throws -> Redemption {
        if expireOnCollect {
            orders = [order(status: .expired)]
            balance += 10
            throw APIError.http(status: 409, message: "This redemption has expired.")
        }
        orders = [order(status: .collected)]
        return orders[0]
    }

    private func order(status: RedemptionStatus) -> Redemption {
        Redemption(
            id: 1, referenceNumber: "VIT-TEST", rewardNameSnapshot: "Coffee",
            pointCostSnapshot: 10, status: status
        )
    }
}
