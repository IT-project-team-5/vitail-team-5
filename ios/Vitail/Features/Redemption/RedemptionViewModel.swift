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
        let isRetry = pendingRequestID != nil
        let requestID = pendingRequestID ?? UUID()
        pendingRequestID = requestID
        if retryRewardID == nil { retryReward = rewards.first { $0.id == rewardID } }
        retryRewardID = rewardID
        redeemingRewardID = rewardID
        errorMessage = nil
        defer { redeemingRewardID = nil; drainRequestedRefresh() }
        do {
            // Recheck at purchase time; the backend also checks under the owner lock.
            if !isRetry {
                eligibilityGeneration += 1
                let eligibility = try await service.fetchEligibility()
                self.eligibility = eligibility
                if !eligibility.eligible {
                    registrationRewardID = rewardID
                    pendingRequestID = nil; retryRewardID = nil; retryReward = nil
                    errorMessage = "Register every dog's microchip to continue. You can collect registration points separately."
                    return
                }
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
