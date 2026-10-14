import Foundation

actor StatisticsService {
    private let apiClient: APIClient
    private let authService: AuthService

    init(
        apiClient: APIClient = APIClient(),
        authService: AuthService = AuthService()
    ) {
        self.apiClient = apiClient
        self.authService = authService
    }

    func fetchStatistics() async throws -> UserStatistics {
        try await authService.performAuthorized { token in
            try await self.apiClient.get(
                "/api/statistics",
                bearerToken: token
            )
        }
    }

    func fetchLeaderboard() async throws -> LeaderboardResponse {
        try await authService.performAuthorized { token in
            try await self.apiClient.get(
                "/api/statistics/leaderboard",
                bearerToken: token
            )
        }
    }
}