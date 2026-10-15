import Foundation

// MARK: - Statistics

struct UserStatistics: Codable, Sendable {
    let todayWalkingMinutes: Int
    let todayDistanceKm: Double
    let dailyGoalMinutes: Int
    let sevenDayGoals: [DailyGoalResult]

    var goalProgress: Double {
        guard dailyGoalMinutes > 0 else { return 0 }

        return min(
            Double(todayWalkingMinutes) / Double(dailyGoalMinutes),
            1.0
        )
    }

    var completedGoals: Int {
        sevenDayGoals.filter { $0.completed }.count
    }

    enum CodingKeys: String, CodingKey {
        case todayWalkingMinutes = "today_walking_minutes"
        case todayDistanceKm = "today_distance_km"
        case dailyGoalMinutes = "daily_goal_minutes"
        case sevenDayGoals = "seven_day_goals"
    }
}

struct DailyGoalResult: Codable, Identifiable, Sendable {
    let date: String
    let completed: Bool

    var id: String {
        date
    }
}


// MARK: - Leaderboard

struct LeaderboardResponse: Codable, Sendable {
    let metric: String
    let period: String
    let myRank: Int?
    let entries: [LeaderboardEntry]

    enum CodingKeys: String, CodingKey {
        case metric
        case period
        case myRank = "my_rank"
        case entries
    }
}

struct LeaderboardEntry: Codable, Identifiable, Sendable {
    let userId: Int
    let displayName: String
    let rank: Int
    let value: Double
    let isCurrentUser: Bool

    var id: Int {
        userId
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case rank
        case value
        case isCurrentUser = "is_current_user"
    }
}