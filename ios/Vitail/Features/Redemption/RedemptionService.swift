import Foundation

protocol RedemptionServing: Sendable {
    func fetchEligibility() async throws -> RedemptionEligibility
    func fetchBalance() async throws -> WalletBalance
    func fetchRewards() async throws -> [Reward]
    func fetchRedemptions() async throws -> [Redemption]
    func createRedemption(rewardID: Int, requestID: UUID) async throws -> Redemption
    func collectRedemption(id: Int) async throws -> Redemption
}

extension RedemptionServing {
    func fetchEligibility() async throws -> RedemptionEligibility { throw APIError.invalidResponse }
}

actor RedemptionService: RedemptionServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchBalance() async throws -> WalletBalance {
        try await apiClient.get("/api/wallet/")
    }

    func fetchEligibility() async throws -> RedemptionEligibility {
        try await apiClient.get("/api/redemptions/eligibility")
    }

    func fetchRewards() async throws -> [Reward] {
        try await apiClient.get("/api/redemptions/rewards")
    }

    func fetchRedemptions() async throws -> [Redemption] {
        try await apiClient.get("/api/redemptions/")
    }

    func createRedemption(rewardID: Int, requestID: UUID) async throws -> Redemption {
        try await apiClient.post(
            "/api/redemptions/",
            body: CreateRedemptionRequest(rewardId: rewardID, requestId: requestID)
        )
    }

    func collectRedemption(id: Int) async throws -> Redemption {
        try await apiClient.post(
            "/api/redemptions/\(id)/collect", body: EmptyRequestBody()
        )
    }
}
