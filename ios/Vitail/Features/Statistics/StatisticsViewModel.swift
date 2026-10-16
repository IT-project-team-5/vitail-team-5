import Foundation

@MainActor
final class StatisticsViewModel: ObservableObject {
    @Published private(set) var statistics: UserStatistics?
    @Published private(set) var leaderboard: LeaderboardResponse?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: StatisticsService

    init(service: StatisticsService = StatisticsService()) {
        self.service = service
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            async let statisticsResult = service.fetchStatistics()
            async let leaderboardResult = service.fetchLeaderboard()

            let (statistics, leaderboard) = try await (
                statisticsResult,
                leaderboardResult
            )

            self.statistics = statistics
            self.leaderboard = leaderboard
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}