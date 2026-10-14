import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class RedemptionTests: XCTestCase {
    func testFivePointRewardBalanceBoundariesAndHandlerGuards() async {
        for balance in [0, 4, 5, 12] {
            let service = RedemptionStub(initialBalance: balance, pointCost: 5)
            let model = RedemptionViewModel(service: service)
            await model.refresh()
            XCTAssertEqual(model.canPurchase(rewardID: 1), balance >= 5)
            await model.redeem(rewardID: 1)
            let calls = await service.requestIDs.count
            XCTAssertEqual(calls, balance >= 5 ? 1 : 0)
            XCTAssertEqual(model.balance, balance >= 5 ? balance - 5 : balance)
            XCTAssertEqual(model.pendingRedemptions.count, balance >= 5 ? 1 : 0)
            if balance < 5 { XCTAssertEqual(model.errorMessage, "You need \(5 - balance) more points.") }
        }
    }

    func testRewardRemovedAfterScreenLoadCannotBePurchased() async {
        let service = RedemptionStub(pointCost: 5)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await service.setOffersAvailable(false)
        await model.redeem(rewardID: 1)
        XCTAssertFalse(model.canPurchase(rewardID: 1))
        XCTAssertTrue(model.rewards.isEmpty)
        XCTAssertEqual(model.errorMessage, "This reward is no longer available. Refresh to see current rewards.")
        let calls = await service.requestIDs.count
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.retryRewardID)
    }

    func testRegistrationFailureClearsOldEligibilityAndNeverCreatesRetryPurchase() async {
        let service = RedemptionStub()
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        XCTAssertTrue(model.canPurchase(rewardID: 1))
        await service.setEligibilityUnavailable(true)
        await model.refreshEligibility()
        XCTAssertNil(model.eligibility)
        XCTAssertFalse(model.canPurchase(rewardID: 1))
        await model.redeem(rewardID: 1)
        XCTAssertNil(model.retryRewardID)
        let calls = await service.requestIDs.count
        XCTAssertEqual(calls, 0)
    }

    func testRepeatedClicksOnlyPurchaseOnce() async {
        let service = RedemptionStub(initialBalance: 12, pointCost: 5)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await model.redeem(rewardID: 1) } }
        }
        let calls = await service.requestIDs.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.balance, 7)
        XCTAssertEqual(model.pendingRedemptions.count, 1)
    }

    func testRegistrationBlocksPurchaseAndPreservesProductUntilBothDogsRegister() async {
        let service = RedemptionStub()
        await service.setIncompleteDogs([.init(id: 1, name: "Milo"), .init(id: 2, name: "Pip")])
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        XCTAssertFalse(model.canPurchase(rewardID: 1))
        XCTAssertEqual(model.purchaseBlockReason(rewardID: 1), "Complete microchip registration for every dog before redeeming.")
        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.registrationRewardID, 1)
        XCTAssertEqual(model.eligibility?.incompleteDogs.count, 2)
        var calls = await service.requestIDs
        XCTAssertTrue(calls.isEmpty)
        await service.setIncompleteDogs([.init(id: 2, name: "Pip")])
        await model.refreshEligibility()
        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.eligibility?.incompleteDogs.first?.id, 2)
        await service.setIncompleteDogs([])
        await model.refreshEligibility()
        XCTAssertEqual(model.registrationRewardID, 1)
        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.balance, 50)
        XCTAssertNotNil(model.purchasedReceipt)
        XCTAssertNil(model.registrationRewardID)
        calls = await service.requestIDs
        XCTAssertEqual(calls.count, 1)
    }

    func testLostPurchaseResponseStillReplaysAfterAnotherDogNeedsRegistration() async {
        let service = RedemptionStub(failFirstCreate: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        await model.redeem(rewardID: 1)
        await service.setIncompleteDogs([.init(id: 2, name: "Pip")])
        await model.redeem(rewardID: 1)
        let ids = await service.requestIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNotNil(model.purchasedReceipt)
        XCTAssertEqual(model.balance, 50)
    }
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

    func testCafeGroupingPreservesMenuPrices() {
        let offer = Reward(id: 1, name: "Coffee", description: "", pointCost: 60, cafeName: "Paws")
        XCTAssertEqual(CafeRewardGroup.grouped([offer]).first?.rewards.first?.pointCost, 60)
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
        XCTAssertEqual(model.balance, 50, "History failure must not leave either page showing the pre-purchase balance.")
        XCTAssertEqual(model.pendingRedemptions.count, 1)
        XCTAssertNil(model.retryRewardID, "A confirmed order must not be purchased again after a refresh failure.")
        XCTAssertNotNil(model.errorMessage)
        model.acknowledgePurchasedReceipt()
        XCTAssertNil(model.purchasedReceipt, "Returning to the menu must not reopen an old receipt.")
    }

    func testCollectionRequiresCompleteEnabledSlideAndCannotConfirmTwice() {
        var slide = SlideConfirmationState()
        slide.offset = 100
        XCTAssertEqual(slide.progress(travel: 250), 0.4, accuracy: 0.001)
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: true))
        XCTAssertEqual(slide.offset, 0)
        XCTAssertEqual(slide.progress(travel: 250), 0)
        slide.offset = 250
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: false))
        slide.offset = 250
        XCTAssertTrue(slide.finish(travel: 250, isEnabled: true))
        XCTAssertEqual(slide.progress(travel: 250), 1)
        XCTAssertFalse(slide.finish(travel: 250, isEnabled: true))
        XCTAssertEqual(slide.progress(travel: 250), 1, "Repeated gestures must not empty the fill while collection is pending.")
        slide.reset()
        XCTAssertEqual(slide.progress(travel: 250), 0)
        slide.offset = 250
        XCTAssertTrue(slide.finish(travel: 250, isEnabled: true))
    }

    func testCollectionSlideFillSnapshots() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for dark in [false, true] {
            let page = VStack(spacing: 24) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { progress in
                    CollectionSlideBackground(progress: progress, isLoading: progress == 1)
                        .frame(height: 64)
                }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .vitailAppearance().preferredColorScheme(dark ? .dark : .light)
            let host = UIHostingController(rootView: page)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Collection fill - \(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
    private var incompleteDogs: [RedemptionEligibility.IncompleteDog] = []
    func setIncompleteDogs(_ dogs: [RedemptionEligibility.IncompleteDog]) { incompleteDogs = dogs }
    private var eligibilityUnavailable = false
    private var offersAvailable = true
    func setEligibilityUnavailable(_ value: Bool) { eligibilityUnavailable = value }
    func setOffersAvailable(_ value: Bool) { offersAvailable = value }
    func fetchEligibility() async throws -> RedemptionEligibility {
        if eligibilityUnavailable { throw APIError.network("Eligibility unavailable") }
        return RedemptionEligibility(eligible: incompleteDogs.isEmpty, incompleteDogs: incompleteDogs)
    }
    var requestIDs: [UUID] = []
    private var balance: Int
    private let pointCost: Int
    private var orders: [Redemption] = []
    private let failFirstCreate: Bool
    private let expireOnCollect: Bool
    private let hidePurchasedReward: Bool
    private let failReloadAfterCreate: Bool

    init(failFirstCreate: Bool = false, expireOnCollect: Bool = false, hidePurchasedReward: Bool = false,
         failReloadAfterCreate: Bool = false, initialBalance: Int = 60, pointCost: Int = 10) {
        self.balance = initialBalance
        self.pointCost = pointCost
        self.failFirstCreate = failFirstCreate
        self.expireOnCollect = expireOnCollect
        self.hidePurchasedReward = hidePurchasedReward
        self.failReloadAfterCreate = failReloadAfterCreate
    }

    func fetchBalance() async throws -> WalletBalance { WalletBalance(balance: balance) }
    func fetchRewards() async throws -> [Reward] {
        if !offersAvailable || (hidePurchasedReward && !orders.isEmpty) { return [] }
        return [Reward(id: 1, name: "Coffee", description: "", pointCost: pointCost, cafeName: "Cafe")]
    }
    func fetchRedemptions() async throws -> [Redemption] {
        if failReloadAfterCreate && !orders.isEmpty { throw APIError.network("Refresh unavailable") }
        return orders
    }

    func createRedemption(rewardID: Int, requestID: UUID) async throws -> Redemption {
        requestIDs.append(requestID)
        if orders.isEmpty {
            orders = [order(status: .pending)]
            balance -= pointCost
        }
        if failFirstCreate && requestIDs.count == 1 { throw APIError.network("Offline") }
        return orders[0]
    }

    func collectRedemption(id: Int) async throws -> Redemption {
        if expireOnCollect {
            orders = [order(status: .expired)]
            balance += pointCost
            throw APIError.http(status: 409, message: "This redemption has expired.")
        }
        orders = [order(status: .collected)]
        return orders[0]
    }

    private func order(status: RedemptionStatus) -> Redemption {
        Redemption(
            id: 1, referenceNumber: "VIT-TEST", rewardNameSnapshot: "Coffee",
            pointCostSnapshot: pointCost, status: status
        )
    }
}
