import Foundation

actor StatisticsService {  
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchStatistics() async throws -> UserStatistics {
        try await apiClient.get("/api/statistics/")
    }

    func fetchLeaderboard() async throws -> LeaderboardResponse {
        try await apiClient.get("/api/statistics/leaderboard/")
    }
}
