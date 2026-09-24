import Foundation

/// Unknown server states remain visible without being mistaken for a claimable reward.
enum QuestStatus: Equatable, Sendable, Decodable {
    case available
    case rulesPending
    case notAvailable
    case ready
    case collected
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "AVAILABLE": self = .available
        case "RULES_PENDING": self = .rulesPending
        case "NOT_AVAILABLE": self = .notAvailable
        case "READY": self = .ready
        case "COLLECTED": self = .collected
        default: self = .unknown(value)
        }
    }
}

struct QuestSnapshot: Decodable, Equatable, Sendable {
    let serverTime: String
    let timezone: String
    let localDate: String
    let nextResetAt: String
    let dailyGoal: DailyGoalQuest
    let streak: StreakQuest
    let birthdays: BirthdayQuest
    let checkIns: QuestSectionAvailability
    let documents: QuestSectionAvailability

    enum CodingKeys: String, CodingKey {
        case timezone, streak, birthdays, documents
        case serverTime = "server_time"
        case localDate = "local_date"
        case nextResetAt = "next_reset_at"
        case dailyGoal = "daily_goal"
        case checkIns = "check_ins"
    }
}

struct QuestSectionAvailability: Decodable, Equatable, Sendable {
    let status: QuestStatus
    let message: String?
}

struct DailyGoalQuest: Decodable, Equatable, Sendable {
    let status: QuestStatus
    let dogs: [QuestDogGoal]
    let rewardPoints: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, dogs, message
        case rewardPoints = "reward_points"
    }
}

struct QuestDogGoal: Decodable, Equatable, Identifiable, Sendable {
    let dogID: Int
    let name: String
    let photo: String?
    let distanceMetres: Double
    let targetDistanceMetres: Double?
    let activeSeconds: Double?
    let targetActiveSeconds: Double?
    let progress: Double?
    var id: Int { dogID }

    var progressRatio: Double? {
        guard (targetDistanceMetres ?? 0) > 0 || (targetActiveSeconds ?? 0) > 0,
              let progress, progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    enum CodingKeys: String, CodingKey {
        case name, photo, progress
        case dogID = "dog_id"
        case distanceMetres = "distance_m"
        case targetDistanceMetres = "target_distance_m"
        case activeSeconds = "active_seconds"
        case targetActiveSeconds = "target_active_seconds"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dogID = try values.decode(Int.self, forKey: .dogID)
        name = try values.decode(String.self, forKey: .name)
        photo = try values.decodeIfPresent(String.self, forKey: .photo)
        distanceMetres = try values.decodeQuestNumber(forKey: .distanceMetres)
        targetDistanceMetres = try values.decodeQuestNumberIfPresent(forKey: .targetDistanceMetres)
        activeSeconds = try values.decodeQuestNumberIfPresent(forKey: .activeSeconds)
        targetActiveSeconds = try values.decodeQuestNumberIfPresent(forKey: .targetActiveSeconds)
        progress = try values.decodeQuestNumberIfPresent(forKey: .progress)
    }
}

struct StreakMilestone: Decodable, Equatable, Identifiable, Sendable {
    let days: Int
    let rewardPoints: Int
    var id: Int { days }
    enum CodingKeys: String, CodingKey {
        case days
        case rewardPoints = "reward_points"
    }
}

struct StreakQuest: Decodable, Equatable, Sendable {
    let status: QuestStatus
    let currentDays: Int
    let longestDays: Int
    let activeToday: Bool
    let milestones: [StreakMilestone]
    let nextMilestone: StreakMilestone?
    let awardStatus: String

    enum CodingKeys: String, CodingKey {
        case status, milestones
        case currentDays = "current_days"
        case longestDays = "longest_days"
        case activeToday = "active_today"
        case nextMilestone = "next_milestone"
        case awardStatus = "award_status"
    }
}

struct BirthdayQuest: Decodable, Equatable, Sendable {
    let status: QuestStatus
    let rewardPoints: Int?
    let dogs: [BirthdayQuestDog]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, dogs, message
        case rewardPoints = "reward_points"
    }
}

struct BirthdayQuestDog: Decodable, Equatable, Identifiable, Sendable {
    let dogID: Int
    let name: String
    let photo: String?
    let dateOfBirth: String?
    let nextBirthday: String?
    let isBirthdayToday: Bool
    let status: BirthdayQuestStatus
    var id: Int { dogID }

    enum CodingKeys: String, CodingKey {
        case name, photo, status
        case dogID = "dog_id"
        case dateOfBirth = "date_of_birth"
        case nextBirthday = "next_birthday"
        case isBirthdayToday = "is_birthday_today"
    }
}

extension KeyedDecodingContainer {
    func decodeQuestNumber(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return value }
        let raw = try decode(String.self, forKey: key)
        guard let value = Double(raw), value.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected a finite number.")
        }
        return value
    }

    func decodeQuestNumberIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeQuestNumber(forKey: key)
    }
}


enum BirthdayQuestStatus: Equatable, Sendable, Decodable {
    case missingBirthday
    case invalidBirthday
    case available
    case claimed
    case upcoming
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "MISSING_BIRTHDAY": self = .missingBirthday
        case "INVALID_BIRTHDAY": self = .invalidBirthday
        case "AVAILABLE": self = .available
        case "CLAIMED": self = .claimed
        case "UPCOMING": self = .upcoming
        default: self = .unknown(value)
        }
    }
}

struct BirthdayAward: Decodable, Equatable, Sendable {
    let id: Int
    let kind: String
    let dogID: Int
    let year: Int
    let points: Int
    let awardedAt: String
    enum CodingKeys: String, CodingKey {
        case id, kind, year, points
        case dogID = "dog_id"
        case awardedAt = "awarded_at"
    }
}

struct BirthdayCollectResponse: Decodable, Equatable, Sendable {
    let award: BirthdayAward
    let balance: Int
    let created: Bool
}
