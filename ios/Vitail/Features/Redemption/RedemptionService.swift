import Foundation

/// Talks to /api/wallet and /api/redemptions. Every call goes through
/// AuthService.performAuthorized so a stale access token is refreshed once
/// and retried instead of failing the request.
actor RedemptionService {
    private let apiClient: APIClient
    private let authService: AuthService

    init(apiClient: APIClient = APIClient(), authService: AuthService = AuthService()) {
        self.apiClient = apiClient
        self.authService = authService
    }

    func fetchBalance() async throws -> WalletBalance {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/wallet/", bearerToken: token)
        }
    }

    func fetchRewards() async throws -> [Reward] {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/redemptions/rewards", bearerToken: token)
        }
    }

    func fetchRedemptions() async throws -> [Redemption] {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/redemptions/", bearerToken: token)
        }
    }

    func createRedemption(rewardId: Int) async throws -> Redemption {
        try await authService.performAuthorized { token in
            try await self.apiClient.post(
                "/api/redemptions/",
                body: CreateRedemptionRequest(rewardId: rewardId),
                bearerToken: token
            )
        }
    }

    func collectRedemption(id: Int) async throws -> Redemption {
        try await authService.performAuthorized { token in
            try await self.apiClient.post(
                "/api/redemptions/\(id)/collect",
                body: EmptyRequestBody(),
                bearerToken: token
            )
        }
    }
}
