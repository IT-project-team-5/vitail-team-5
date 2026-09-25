import Foundation

/// Presentation only: the server will decide the current streak and its next milestone.
struct StreakProgressValue: Equatable, Sendable {
    let currentDays: Int
    let targetDays: Int

    init?(currentDays: Int, targetDays: Int) {
        guard targetDays == 7 || (targetDays >= 30 && targetDays.isMultiple(of: 30)) else { return nil }
        self.currentDays = min(max(currentDays, 0), targetDays)
        self.targetDays = targetDays
    }

    var label: String { "\(currentDays) / \(targetDays)" }
    var fraction: Double { Double(currentDays) / Double(targetDays) }
    var accessibilityValue: String { "\(currentDays) of \(targetDays) days" }
}

enum QuestTaskStatus: Equatable, Sendable, Decodable {
    case inProgress, ready, collected, unknown(String)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "IN_PROGRESS": self = .inProgress
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
    let tasks: [QuestTask]
    enum CodingKeys: String, CodingKey {
        case timezone, tasks
        case serverTime = "server_time", localDate = "local_date"
    }
}

struct QuestTask: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    var status: QuestTaskStatus
    let title: String
    let subjectName: String
    let photo: String?
    let icon: String
    let detail: String
    let rewardPoints: Int
    let progress: Double?
    let dogID: Int?
    let entitlementID: Int?
    var collectedAt: String?
    var currentDays: Int? = nil
    var milestoneDays: Int? = nil
    var runStartDate: String? = nil

    var documentKind: DocumentKind? { DocumentKind(rawValue: kind) }
    var isBirthday: Bool { kind == "BIRTHDAY" }
    var isStreak: Bool { kind == "STREAK" }
    var streakProgress: StreakProgressValue? {
        guard isStreak, let currentDays, let milestoneDays else { return nil }
        return StreakProgressValue(currentDays: currentDays, targetDays: milestoneDays)
    }
    var progressRatio: Double? {
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return nil }
        return progress
    }
    var isSupported: Bool {
        if isStreak { return isSupportedStreak }
        guard !id.isEmpty, !title.isEmpty, let dogID, dogID > 0,
              rewardPoints > 0, isBirthday || documentKind != nil else { return false }
        switch status {
        case .ready: return isBirthday || (entitlementID ?? 0) > 0
        case .inProgress: return documentKind != nil
        case .collected: return collectedAt.flatMap(QuestCalendar.parse) != nil
        case .unknown: return false
        }
    }
    private var isSupportedStreak: Bool {
        guard !title.isEmpty, dogID == nil, entitlementID == nil,
              let currentDays, currentDays >= 0, let milestoneDays, streakProgress != nil,
              rewardPoints == (milestoneDays == 7 ? 20 : 100) else { return false }
        guard let runStartDate else {
            return id == "streak:idle:7" && status == .inProgress && currentDays == 0 && milestoneDays == 7
        }
        guard DogBirthday.date(from: runStartDate) != nil, currentDays > 0,
              id == "streak:\(runStartDate):\(milestoneDays)" else { return false }
        switch status {
        case .inProgress: return currentDays < milestoneDays
        case .ready: return currentDays >= milestoneDays
        case .collected: return currentDays >= milestoneDays && collectedAt.flatMap(QuestCalendar.parse) != nil
        case .unknown: return false
        }
    }
    func collected(at timestamp: String) -> QuestTask {
        var copy = self
        copy.status = .collected
        copy.collectedAt = timestamp
        return copy
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, status, title, photo, icon, detail, progress
        case subjectName = "subject_name", rewardPoints = "reward_points"
        case dogID = "dog_id", entitlementID = "entitlement_id", collectedAt = "collected_at"
        case currentDays = "current_days", milestoneDays = "milestone_days", runStartDate = "run_start_date"
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
        case dogID = "dog_id", awardedAt = "awarded_at"
    }
}

struct BirthdayCollectResponse: Decodable, Equatable, Sendable {
    let award: BirthdayAward
    let balance: Int
    let created: Bool
}

struct StreakCollectRequest: Encodable, Equatable, Sendable {
    let runStartDate: String
    let milestoneDays: Int
    enum CodingKeys: String, CodingKey {
        case runStartDate = "run_start_date", milestoneDays = "milestone_days"
    }
}

struct StreakAward: Decodable, Equatable, Sendable {
    let id: Int
    let kind: String
    let runStartDate: String
    let milestoneDays: Int
    let points: Int
    let awardedAt: String
    enum CodingKeys: String, CodingKey {
        case id, kind, points
        case runStartDate = "run_start_date", milestoneDays = "milestone_days", awardedAt = "awarded_at"
    }
}

struct StreakCollectResponse: Decodable, Equatable, Sendable {
    let award: StreakAward
    let balance: Int
    let created: Bool
}

struct QuestAwardReceipt: Equatable, Sendable {
    let kind: String
    let dogID: Int?
    let points: Int
    let balance: Int
    let collectedAt: String
    let created: Bool
}

enum QuestCalendar {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
