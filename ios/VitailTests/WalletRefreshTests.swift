import Combine
import XCTest
@testable import Vitail

@MainActor
final class WalletRefreshTests: XCTestCase {
    func testQuestAwardDuringWalletLoadQueuesAuthoritativeRefresh() async {
        let service = DelayedWalletFixture()
        let model = RedemptionViewModel(service: service)
        let initialRefresh = Task { await model.refresh() }
        await service.waitForInitialBalance()
        await service.awardBirthday()
        // This callback used to be dropped while the old wallet request was running.
        await model.refresh()
        await service.finishInitialBalance()
        await initialRefresh.value
        XCTAssertEqual(model.balance, 60)
        let balanceRequests = await service.balanceRequests
        XCTAssertEqual(balanceRequests, 2)
    }

    func testQueuedAwardRefreshSurvivesCancellationOfPreviousTabLoad() async {
        let service = DelayedWalletFixture()
        let model = RedemptionViewModel(service: service)
        let updated = expectation(description: "Queued refresh publishes the new balance")
        let subscription = model.$balance.sink { balance in
            if balance == 60 { updated.fulfill() }
        }
        defer { subscription.cancel() }
        let previousTab = Task { await model.refresh() }
        await service.waitForInitialBalance()
        await service.awardBirthday()
        await model.refresh()
        // OwnerHome cancels its previous .task when the selected tab changes.
        previousTab.cancel()
        await service.finishInitialBalance()
        await previousTab.value
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(model.balance, 60)
        let requests = await service.balanceRequests
        XCTAssertEqual(requests, 2)
    }
}

private actor DelayedWalletFixture: RedemptionServing {
    func fetchEligibility() async throws -> RedemptionEligibility { .init(eligible: true, incompleteDogs: []) }
    private(set) var balanceRequests = 0
    private var balance = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetchBalance() async throws -> WalletBalance {
        balanceRequests += 1
        let capturedBalance = balance
        if balanceRequests == 1 {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume(); started = nil
            }
        }
        return WalletBalance(balance: capturedBalance)
    }
    func waitForInitialBalance() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func awardBirthday() { balance = 60 }
    func finishInitialBalance() { pending?.resume(); pending = nil }
    func fetchRewards() async throws -> [Reward] { [] }
    func fetchRedemptions() async throws -> [Redemption] { [] }
    func createRedemption(rewardID: Int, requestID: UUID) async throws -> Redemption { throw APIError.invalidResponse }
    func collectRedemption(id: Int) async throws -> Redemption { throw APIError.invalidResponse }
}
