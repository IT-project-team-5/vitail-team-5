import Combine
import Foundation

@MainActor
final class RedemptionViewModel: ObservableObject {
    @Published private(set) var balance: Int?
    @Published private(set) var rewards: [Reward] = []
    @Published private(set) var redemptions: [Redemption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var redeemingRewardID: Int?
    @Published var errorMessage: String?

    var pendingRedemptions: [Redemption] {
        redemptions.filter { $0.status == .pending }
    }

    var recentlyCollectedRedemptions: [Redemption] {
        Array(redemptions.filter { $0.status == .collected }.prefix(5))
    }

    private let service: RedemptionService

    init(service: RedemptionService = RedemptionService()) {
        self.service = service
    }

    func loadInitialData() async {
        guard rewards.isEmpty else { return }
        await load(showsLoading: true)
    }

    func refresh() async {
        await load(showsLoading: false)
    }

    private func load(showsLoading: Bool) async {
        if showsLoading { isLoading = true }
        errorMessage = nil
        defer { if showsLoading { isLoading = false } }

        do {
            async let balanceTask = service.fetchBalance()
            async let rewardsTask = service.fetchRewards()
            async let redemptionsTask = service.fetchRedemptions()
            let (fetchedBalance, fetchedRewards, fetchedRedemptions) = try await (
                balanceTask, rewardsTask, redemptionsTask
            )
            balance = fetchedBalance.balance
            rewards = fetchedRewards
            redemptions = fetchedRedemptions
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func redeem(rewardID: Int) async {
        errorMessage = nil
        redeemingRewardID = rewardID
        defer { redeemingRewardID = nil }

        do {
            let redemption = try await service.createRedemption(rewardId: rewardID)
            redemptions.insert(redemption, at: 0)
            if let currentBalance = balance {
                balance = currentBalance - redemption.pointCostSnapshot
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func collect(redemptionID: Int) async {
        errorMessage = nil
        do {
            let updated = try await service.collectRedemption(id: redemptionID)
            if let index = redemptions.firstIndex(where: { $0.id == updated.id }) {
                redemptions[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
