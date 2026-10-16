import Foundation

protocol StatisticsServing: Sendable {
    func fetchStatistics() async throws -> UserStatistics
    func fetchLeaderboard() async throws -> LeaderboardResponse
    func updateLeaderboardVisibility(_ visible: Bool) async throws -> UserStatistics
}

actor StatisticsService: StatisticsServing {
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

    func updateLeaderboardVisibility(_ visible: Bool) async throws -> UserStatistics {
        try await apiClient.patch("/api/statistics/", body: VisibilityUpdate(leaderboardVisible: visible))
    }
}

private struct VisibilityUpdate: Encodable, Sendable {
    let leaderboardVisible: Bool
    enum CodingKeys: String, CodingKey { case leaderboardVisible = "leaderboard_visible" }
}
