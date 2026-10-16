import Foundation

struct UserStatistics: Codable, Sendable {
    let todayWalkingMinutes: Int
    let todayDistanceKm: Double
    let dailyGoalMinutes: Int
    let sevenDayGoals: [DailyGoalResult]
    let leaderboardVisible: Bool
    let dailyGoalActiveSeconds: Int
    let dailyGoalTargetSeconds: Int
    let dailyGoalProgress: Double
    let dogDailyGoals: [StatisticsDogGoal]

    // The server counts each dog's participation and caps progress at its own target.
    var goalProgress: Double { min(max(dailyGoalProgress, 0), 1) }
    var completedGoals: Int { sevenDayGoals.filter(\.completed).count }

    enum CodingKeys: String, CodingKey {
        case todayWalkingMinutes = "today_walking_minutes"
        case todayDistanceKm = "today_distance_km"
        case dailyGoalMinutes = "daily_goal_minutes"
        case sevenDayGoals = "seven_day_goals"
        case leaderboardVisible = "leaderboard_visible"
        case dailyGoalActiveSeconds = "daily_goal_active_seconds"
        case dailyGoalTargetSeconds = "daily_goal_target_seconds"
        case dailyGoalProgress = "daily_goal_progress"
        case dogDailyGoals = "dog_daily_goals"
    }
}

struct StatisticsDogGoal: Codable, Identifiable, Sendable {
    let dogID: Int
    let dogName: String
    let activeSeconds: Int
    let targetSeconds: Int?
    let completed: Bool
    var id: Int { dogID }

    enum CodingKeys: String, CodingKey {
        case dogID = "dog_id", dogName = "dog_name", activeSeconds = "active_seconds"
        case targetSeconds = "target_seconds", completed
    }
}

struct DailyGoalResult: Codable, Identifiable, Sendable {
    let date: String
    let completed: Bool
    var id: String { date }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: date)
    }

    func dateLabel(template: String) -> String {
        guard let parsedDate else { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: parsedDate)
    }
}

struct LeaderboardResponse: Codable, Sendable {
    let metric: String
    let period: String
    let unit: String
    let startDate: String
    let endDate: String
    let timezone: String
    let myRank: Int?
    let entries: [LeaderboardEntry]

    enum CodingKeys: String, CodingKey {
        case metric, period, unit, timezone, entries
        case startDate = "start_date", endDate = "end_date", myRank = "my_rank"
    }
}

struct LeaderboardEntry: Codable, Identifiable, Sendable {
    let publicID: String
    let displayName: String
    let rank: Int
    let value: Double
    let isCurrentUser: Bool
    var id: String { publicID }
    // An empty public name never falls back to an email address or database ID.
    var name: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Walker" : displayName }

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id", displayName = "display_name", rank, value
        case isCurrentUser = "is_current_user"
    }
}
