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
    var dailyGoals: [DogDailyGoalProgress]? = nil
    var goalRewardsStatus: String? = nil
    enum CodingKeys: String, CodingKey {
        case timezone, tasks
        case serverTime = "server_time", localDate = "local_date"
        case dailyGoals = "daily_goals", goalRewardsStatus = "goal_rewards_status"
    }
}

struct DogDailyGoalProgress: Decodable, Equatable, Identifiable, Sendable {
    let dogID: Int
    let dogName: String
    let activeSeconds: Int
    let targetSeconds: Int?
    let completed: Bool
    let currentStreak: Int
    let days: [GoalCalendarDay]
    var id: Int { dogID }
    var timeLabel: String {
        guard let targetSeconds else { return "Daily target not configured" }
        return "\(Self.duration(activeSeconds)) / \(Self.duration(targetSeconds))"
    }
    static func duration(_ seconds: Int) -> String {
        "\(seconds / 60)m \(seconds % 60)s"
    }
    func isValid(on localDate: String) -> Bool {
        guard dogID > 0, !dogName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              currentStreak >= 0, days.count == 7, let today = DogBirthday.date(from: localDate) else { return false }
        for (index, day) in days.enumerated() {
            guard let expected = DogBirthday.calendar.date(byAdding: .day, value: index - 6, to: today),
                  day.date == QuestCalendar.dateString(expected), day.activeSeconds >= 0 else { return false }
            if let target = day.targetSeconds {
                guard target > 0 else { return false }
                let expectedState = day.activeSeconds >= target ? "COMPLETED" : index == 6 ? "INCOMPLETE" : "MISSED"
                guard day.state == expectedState else { return false }
            } else if day.state != "NOT_ELIGIBLE" || day.activeSeconds != 0 { return false }
        }
        guard let todayValue = days.last,
              activeSeconds == todayValue.activeSeconds, targetSeconds == todayValue.targetSeconds,
              completed == (todayValue.state == "COMPLETED") else { return false }
        return targetSeconds == nil ? currentStreak == 0 : (!completed || currentStreak > 0)
    }
    enum CodingKeys: String, CodingKey {
        case completed, days
        case dogID = "dog_id", dogName = "dog_name", activeSeconds = "active_seconds"
        case targetSeconds = "target_seconds", currentStreak = "current_streak"
    }
}

struct GoalCalendarDay: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let state: String
    let activeSeconds: Int
    let targetSeconds: Int?
    var id: String { date }
    var shortDateLabel: String {
        guard let value = DogBirthday.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: value)
    }
    var stateLabel: String {
        switch state {
        case "COMPLETED": "Completed"
        case "MISSED": "Missed"
        case "INCOMPLETE": "Today, incomplete"
        default: "Not eligible"
        }
    }
    var symbol: String {
        switch state {
        case "COMPLETED": "checkmark.circle.fill"
        case "MISSED": "xmark.circle"
        case "INCOMPLETE": "circle.dotted"
        default: "minus.circle"
        }
    }
    enum CodingKeys: String, CodingKey {
        case date, state
        case activeSeconds = "active_seconds", targetSeconds = "target_seconds"
    }
}

/// A presentation group built from the store's eligible, ordered tasks.
struct DogQuestGroup: Identifiable, Equatable, Sendable {
    let id: Int
    let tasks: [QuestTask]

    var name: String { tasks.first?.subjectName ?? "Dog" }
    var photo: String? { tasks.compactMap(\.photo).first }
    var readyCount: Int { tasks.filter { $0.status == .ready }.count }
    var summary: String { "\(tasks.count) \(tasks.count == 1 ? "task" : "tasks") · \(readyCount) ready" }
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
    var validTo: String? = nil
    var needsExpiry: Bool? = nil

    var documentKind: DocumentKind? { DocumentKind(rawValue: kind) }
    var isBirthday: Bool { kind == "BIRTHDAY" }
    var isStreak: Bool { kind == "STREAK" }
    var expiryLabel: String? {
        guard documentKind == .council, let validTo, DogBirthday.date(from: validTo) != nil else { return nil }
        return "Valid through \(DogBirthday.display(validTo))"
    }
    var subjectLabel: String { subjectName }
    var documentRoute: DocumentQuestRoute? {
        guard let kind = documentKind, let dogID else { return nil }
        return DocumentQuestRoute(id: id, dogID: dogID, kind: kind,
            expectedEntitlementID: kind == .council ? entitlementID : nil, needsExpiry: needsExpiry == true)
    }
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
        if documentKind == .council {
            guard let dogID, dogID > 0, !id.isEmpty, !title.isEmpty else { return false }
            if needsExpiry == true {
                return status == .inProgress && (entitlementID ?? 0) > 0 && (rewardPoints == 0 || rewardPoints == 300)
            }
            guard rewardPoints == 300 else { return false }
            switch status {
            case .inProgress: return true
            case .ready: return (entitlementID ?? 0) > 0 && validTo.flatMap(DogBirthday.date) != nil
            case .collected: return validTo.flatMap(DogBirthday.date) != nil && collectedAt.flatMap(QuestCalendar.parse) != nil
            case .unknown: return false
            }
        }
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
        case validTo = "valid_to", needsExpiry = "needs_expiry"
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

struct QuestAwardEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: String
    let receipt: QuestAwardReceipt

    init(taskID: String, receipt: QuestAwardReceipt) {
        id = UUID()
        self.taskID = taskID
        self.receipt = receipt
    }
}

struct QuestResetResponse: Decodable, Equatable, Sendable {
    let reset: Bool
    let walletBalance: Int
    let cleared: Cleared

    struct Cleared: Decodable, Equatable, Sendable {
        let questAwards: Int
        let documentSubmissions: Int
        let documentEntitlements: Int
        let evidenceFingerprints: Int
        let checkIns: Int

        var values: [Int] {
            [questAwards, documentSubmissions, documentEntitlements, evidenceFingerprints, checkIns]
        }

        enum CodingKeys: String, CodingKey {
            case questAwards = "quest_awards"
            case documentSubmissions = "document_submissions"
            case documentEntitlements = "document_entitlements"
            case evidenceFingerprints = "evidence_fingerprints"
            case checkIns = "check_ins"
        }
    }

    enum CodingKeys: String, CodingKey {
        case reset, cleared
        case walletBalance = "wallet_balance"
    }
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
