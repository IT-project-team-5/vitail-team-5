import Foundation

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
    let nextResetAt: String
    let tasks: [QuestTask]
    enum CodingKeys: String, CodingKey {
        case timezone, tasks
        case serverTime = "server_time", localDate = "local_date", nextResetAt = "next_reset_at"
    }
}

struct QuestTask: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    var status: QuestTaskStatus
    let title: String
    let subtitle: String
    let subjectName: String
    let photo: String?
    let icon: String
    let detail: String
    let rewardPoints: Int
    let progress: Double?
    let dogID: Int?
    let entitlementID: Int?
    var collectedAt: String?

    var documentKind: DocumentKind? { DocumentKind(rawValue: kind) }
    var isBirthday: Bool { kind == "BIRTHDAY" }
    var progressRatio: Double? {
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return nil }
        return progress
    }
    var isSupported: Bool {
        guard !id.isEmpty, !title.isEmpty, let dogID, dogID > 0,
              rewardPoints > 0, isBirthday || documentKind != nil else { return false }
        switch status {
        case .ready: return isBirthday || (entitlementID ?? 0) > 0
        case .inProgress: return documentKind != nil
        case .collected: return collectedAt.flatMap(QuestCalendar.parse) != nil
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
        case id, kind, status, title, subtitle, photo, icon, detail, progress
        case subjectName = "subject_name", rewardPoints = "reward_points"
        case dogID = "dog_id", entitlementID = "entitlement_id", collectedAt = "collected_at"
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

struct QuestDocumentCollection: Decodable, Equatable, Sendable {
    let entitlementID: Int
    let kind: String
    let dogID: Int
    let points: Int
    let balance: Int
    let collectedAt: String
    let created: Bool
    enum CodingKeys: String, CodingKey {
        case kind, points, balance, created
        case entitlementID = "entitlement_id", dogID = "dog_id", collectedAt = "collected_at"
    }
}

struct QuestAwardReceipt: Equatable, Sendable {
    let kind: String
    let dogID: Int
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
