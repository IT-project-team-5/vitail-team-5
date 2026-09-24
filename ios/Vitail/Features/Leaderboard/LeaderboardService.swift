import Foundation

protocol LeaderboardServing: Sendable {
    func fetchLeaderboard(period: LeaderboardPeriod) async throws -> LeaderboardSnapshot
}

actor LeaderboardService: LeaderboardServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchLeaderboard(period: LeaderboardPeriod) async throws -> LeaderboardSnapshot {
        try await apiClient.get("/api/leaderboard/", queryItems: [URLQueryItem(name: "period", value: period.rawValue)])
    }
}
