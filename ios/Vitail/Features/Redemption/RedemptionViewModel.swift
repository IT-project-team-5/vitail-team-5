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
    @Published var errorMessage: String?

    private let service: any RedemptionServing
    private var pendingRequestID: UUID?

    init(service: any RedemptionServing = RedemptionService()) {
        self.service = service
    }

    var isMutating: Bool { redeemingRewardID != nil || collectingRedemptionID != nil }
    var pendingRedemptions: [Redemption] { redemptions.filter { $0.status == .pending } }
    var history: [Redemption] { redemptions.filter { $0.status != .pending } }

    func refresh() async {
        guard !isLoading, !isMutating else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await reload()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
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
    }

    func redeem(rewardID: Int) async {
        guard !isMutating, !isLoading,
              retryRewardID == nil || retryRewardID == rewardID else { return }
        let requestID = pendingRequestID ?? UUID()
        pendingRequestID = requestID
        retryRewardID = rewardID
        redeemingRewardID = rewardID
        errorMessage = nil
        defer { redeemingRewardID = nil }
        do {
            let order = try await service.createRedemption(rewardID: rewardID, requestID: requestID)
            try Task.checkCancellation()
            redemptions.removeAll { $0.id == order.id }
            redemptions.insert(order, at: 0)
            pendingRequestID = nil
            retryRewardID = nil
            // Always use the server balance; never subtract twice on an idempotent retry.
            try await reload()
        } catch {
            guard !Task.isCancelled else { return }
            if case let APIError.http(status, _) = error,
               [400, 403, 404, 409, 422].contains(status) {
                pendingRequestID = nil
                retryRewardID = nil
            }
            errorMessage = error.localizedDescription
        }
    }

    func collect(redemptionID: Int) async {
        guard !isMutating, !isLoading else { return }
        collectingRedemptionID = redemptionID
        errorMessage = nil
        defer { collectingRedemptionID = nil }
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
