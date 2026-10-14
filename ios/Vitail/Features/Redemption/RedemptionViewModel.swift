import Combine
import Foundation

@MainActor
final class RedemptionViewModel: ObservableObject {
    @Published private(set) var balance: Int?
    @Published private(set) var rewards: [Reward] = []
    @Published private(set) var redemptions: [Redemption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var redeemingRewardID: Int?
    @Published private(set) var collectingRedemptionID: Int?
    @Published private(set) var retryRewardID: Int?
    @Published private(set) var retryReward: Reward?
    @Published var errorMessage: String?
    @Published private(set) var purchasedReceipt: Redemption?
    @Published private(set) var eligibility: RedemptionEligibility?
    @Published private(set) var registrationRewardID: Int?
    private var eligibilityGeneration = 0

    func refreshEligibility() async {
        eligibilityGeneration += 1
        let generation = eligibilityGeneration
        eligibility = nil
        do {
            let result = try await service.fetchEligibility()
            guard !Task.isCancelled, generation == eligibilityGeneration else { return }
            eligibility = result
        } catch {
            guard !Task.isCancelled, generation == eligibilityGeneration else { return }
            eligibility = nil; errorMessage = error.localizedDescription
        }
    }

    private let service: any RedemptionServing
    private var pendingRequestID: UUID?
    private var refreshRequested = false

    init(service: any RedemptionServing = RedemptionService()) {
        self.service = service
    }

    var isMutating: Bool { redeemingRewardID != nil || collectingRedemptionID != nil }
    var pendingRedemptions: [Redemption] { redemptions.filter { $0.status == .pending } }
    var history: [Redemption] { redemptions.filter { $0.status != .pending } }
    var cafes: [CafeRewardGroup] { CafeRewardGroup.grouped(rewards) }

    // One explanation drives both disabled controls and the purchase handler.
    func purchaseBlockReason(rewardID: Int) -> String? {
        guard let eligibility else { return "Unable to confirm microchip registration. Refresh to try again." }
        guard eligibility.eligible else { return "Complete microchip registration for every dog before redeeming." }
        guard let reward = rewards.first(where: { $0.id == rewardID }) else {
            return "This reward is no longer available. Refresh to see current rewards."
        }
        guard let balance else { return "Unable to confirm your points. Refresh to try again." }
        guard balance >= reward.pointCost else { return "You need \(reward.pointCost - balance) more points." }
        return nil
    }

    func canPurchase(rewardID: Int) -> Bool {
        !isLoading && !isMutating && retryRewardID == nil && purchaseBlockReason(rewardID: rewardID) == nil
    }

    func refresh() async {
        guard !isLoading, !isMutating else { refreshRequested = true; return }
        isLoading = true
        defer { isLoading = false; drainRequestedRefresh() }
        repeat {
            refreshRequested = false
            do {
                try await reload()
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        } while refreshRequested && !Task.isCancelled
    }

    private func drainRequestedRefresh() {
        guard refreshRequested, !isLoading, !isMutating else { return }
        refreshRequested = false
        Task { [weak self] in await self?.refresh() }
    }

    private func reload() async throws {
        eligibility = nil
        // Fetch history first so any expired orders/refunds are reflected in the balance.
        let orders = try await service.fetchRedemptions()
        async let wallet = service.fetchBalance()
        async let offers = service.fetchRewards()
        let (fetchedWallet, fetchedOffers) = try await (wallet, offers)
        try Task.checkCancellation()
        redemptions = orders
        balance = fetchedWallet.balance
        rewards = fetchedOffers
        eligibilityGeneration += 1
        let generation = eligibilityGeneration
        let fetchedEligibility = try await service.fetchEligibility()
        try Task.checkCancellation()
        if generation == eligibilityGeneration { eligibility = fetchedEligibility }
    }

    func redeem(rewardID: Int) async {
        guard !isMutating, !isLoading,
              retryRewardID == nil || retryRewardID == rewardID else { return }
        guard purchasedReceipt == nil else { return }
        let isRetry = pendingRequestID != nil
        let requestID = pendingRequestID ?? UUID()
        redeemingRewardID = rewardID
        errorMessage = nil
        defer { redeemingRewardID = nil; drainRequestedRefresh() }
        do {
            // A retry recovers an existing purchase using its original key. The
            // server still checks all rules if that request never committed.
            if !isRetry {
                eligibilityGeneration += 1
                eligibility = nil
                let checkedEligibility = try await service.fetchEligibility()
                try Task.checkCancellation()
                eligibility = checkedEligibility
                if !checkedEligibility.eligible {
                    registrationRewardID = rewardID
                    errorMessage = purchaseBlockReason(rewardID: rewardID)
                    return
                }
                async let offers = service.fetchRewards()
                async let wallet = service.fetchBalance()
                let (currentOffers, currentWallet) = try await (offers, wallet)
                try Task.checkCancellation()
                rewards = currentOffers
                balance = currentWallet.balance
                if let reason = purchaseBlockReason(rewardID: rewardID) {
                    errorMessage = reason
                    return
                }
                retryReward = rewards.first { $0.id == rewardID }
                pendingRequestID = requestID
                retryRewardID = rewardID
            }
            let order = try await service.createRedemption(rewardID: rewardID, requestID: requestID)
            try Task.checkCancellation()
            redemptions.removeAll { $0.id == order.id }
            redemptions.insert(order, at: 0)
            pendingRequestID = nil
            retryRewardID = nil
            retryReward = nil
            // Open the server-confirmed receipt immediately, even if refreshing
            // the balance or catalogue is slow or fails after a successful order.
            purchasedReceipt = order
            registrationRewardID = nil
            // Always use the server balance; never subtract twice on an idempotent retry.
            try await reload()
        } catch {
            guard !Task.isCancelled else { return }
            if case let APIError.http(status, _) = error, status == 403 {
                registrationRewardID = rewardID
                await refreshEligibility()
            }
            if case let APIError.http(status, _) = error,
               [400, 403, 404, 409, 422].contains(status) {
                pendingRequestID = nil
                retryRewardID = nil
                retryReward = nil
            }
            errorMessage = error.localizedDescription
        }
    }

    func acknowledgePurchasedReceipt() {
        purchasedReceipt = nil
    }

    func collect(redemptionID: Int) async {
        guard !isMutating, !isLoading else { return }
        collectingRedemptionID = redemptionID
        errorMessage = nil
        defer { collectingRedemptionID = nil; drainRequestedRefresh() }
        do {
            let order = try await service.collectRedemption(id: redemptionID)
            try Task.checkCancellation()
            if let index = redemptions.firstIndex(where: { $0.id == order.id }) {
                redemptions[index] = order
            }
            try await reload()
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            // A conflict may mean the order expired and its points were refunded.
            try? await reload()
            errorMessage = message
        }
    }
}
