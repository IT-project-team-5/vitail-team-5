import XCTest
@testable import Vitail

@MainActor
final class RedemptionTests: XCTestCase {
    func testAmbiguousRetryUsesSameIDAndDoesNotSubtractPointsTwice() async {
        let service = RedemptionStub(failFirstCreate: true)
        let model = RedemptionViewModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.balance, 60)

        await model.redeem(rewardID: 1)
        XCTAssertEqual(model.retryRewardID, 1)
        XCTAssertNotNil(model.errorMessage)
        await model.redeem(rewardID: 1)

        let ids = await service.requestIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNil(model.retryRewardID)
        XCTAssertEqual(model.balance, 50)
        XCTAssertEqual(model.pendingRedemptions.count, 1)
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

    init(failFirstCreate: Bool = false, expireOnCollect: Bool = false) {
        self.failFirstCreate = failFirstCreate
        self.expireOnCollect = expireOnCollect
    }

    func fetchBalance() async throws -> WalletBalance { WalletBalance(balance: balance) }
    func fetchRewards() async throws -> [Reward] {
        [Reward(id: 1, name: "Coffee", description: "", pointCost: 10, cafeName: "Cafe")]
    }
    func fetchRedemptions() async throws -> [Redemption] { orders }

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
