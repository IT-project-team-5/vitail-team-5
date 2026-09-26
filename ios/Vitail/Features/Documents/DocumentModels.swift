import Foundation

enum DocumentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case council = "COUNCIL_REGISTRATION"
    case microchip = "MICROCHIP_REGISTRATION"
    case vet = "VET_CHECKUP"

    var id: Self { self }
    var title: String {
        switch self {
        case .council: return "Council registration"
        case .microchip: return "Microchip registration"
        case .vet: return "Vet check-up"
        }
    }
    var points: Int { self == .vet ? 200 : 300 }
}

struct DocumentDog: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let photo: String?
}

struct DocumentEligibility: Decodable, Sendable {
    let dogID: Int
    let kind: DocumentKind
    let awardsCount: Int
    let remainingThisYear: Int?
    let canEarn: Bool?
    let message: String
    var registrationYear: Int? = nil

    enum CodingKeys: String, CodingKey {
        case kind, message
        case dogID = "dog_id"
        case awardsCount = "awards_count"
        case remainingThisYear = "remaining_this_year"
        case canEarn = "can_earn"
        case registrationYear = "registration_year"
    }
}

struct DocumentSubmission: Decodable, Identifiable, Sendable {
    let id: Int
    let requestID: UUID
    let dogID: Int
    let dogName: String
    let kind: DocumentKind
    let status: String
    let registrationNumber: String
    let eventDate: String?
    let validFrom: String?
    let validTo: String?
    let filename: String
    let fileURL: String?
    let awardedPoints: Int
    let submittedAt: String
    var entitlementID: Int? = nil
    var rewardStatus: DocumentRewardStatus? = nil
    var rewardPoints: Int? = nil
    var collectedAt: String? = nil
    var councilName: String? = nil
    var registrationYear: Int? = nil
    var rewardRegistrationYear: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, status, filename
        case requestID = "request_id"
        case dogID = "dog_id"
        case dogName = "dog_name"
        case registrationNumber = "registration_number"
        case eventDate = "event_date"
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case fileURL = "file_url"
        case awardedPoints = "awarded_points"
        case submittedAt = "submitted_at"
        case entitlementID = "entitlement_id", rewardStatus = "reward_status"
        case rewardPoints = "reward_points", collectedAt = "collected_at"
        case councilName = "council_name", registrationYear = "registration_year"
        case rewardRegistrationYear = "reward_registration_year"
    }
}

struct DocumentDashboard: Decodable, Sendable {
    let dogs: [DocumentDog]
    let submissions: [DocumentSubmission]
    let eligibility: [DocumentEligibility]
    var entitlements: [DocumentEntitlement]? = nil

    func rewardRegistrationYear(for submission: DocumentSubmission) -> Int? {
        submission.rewardRegistrationYear
            ?? entitlements?.first(where: { $0.id == submission.entitlementID })?.registrationYear
            ?? submission.registrationYear
    }

    func latestPendingSubmission(dogID: Int, kind: DocumentKind, registrationYear: Int? = nil) -> DocumentSubmission? {
        submissions.filter { submission in
            guard submission.dogID == dogID, submission.kind == kind else { return false }
            if kind == .council, let registrationYear,
               rewardRegistrationYear(for: submission) != registrationYear { return false }
            if let entitlements {
                guard let entitlement = entitlements.first(where: { $0.id == submission.entitlementID }) else {
                    return false
                }
                return entitlement.rewardStatus == .ready && entitlement.canCollect
            }
            // Compatibility with snapshots from before the entitlement list was added.
            return submission.rewardStatus == .ready
        }.max { $0.id < $1.id }
    }
}

struct DocumentReceipt: Decodable, Sendable {
    let submission: DocumentSubmission
    let balance: Int
    let awardedPoints: Int
    let created: Bool
    var entitlementID: Int? = nil
    var rewardStatus: DocumentRewardStatus? = nil
    var rewardPoints: Int? = nil
    var collectedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case submission, balance, created
        case awardedPoints = "awarded_points"
        case entitlementID = "entitlement_id", rewardStatus = "reward_status"
        case rewardPoints = "reward_points", collectedAt = "collected_at"
    }
}

enum DocumentRewardStatus: String, Decodable, Sendable { case ready = "READY", collected = "COLLECTED" }

struct DocumentEntitlement: Decodable, Identifiable, Sendable {
    let id: Int
    let dogID: Int
    let dogName: String
    let kind: DocumentKind
    let rewardStatus: DocumentRewardStatus
    let rewardPoints: Int
    let collectedAt: String?
    let canCollect: Bool
    var registrationYear: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind
        case dogID = "dog_id", dogName = "dog_name", rewardStatus = "reward_status"
        case rewardPoints = "reward_points", collectedAt = "collected_at", canCollect = "can_collect"
        case registrationYear = "registration_year"
    }
}

struct DocumentCollectionReceipt: Decodable, Sendable {
    let entitlementID: Int
    let kind: DocumentKind
    let dogID: Int
    let points: Int
    let balance: Int
    let collectedAt: String
    let created: Bool
    var registrationYear: Int? = nil

    enum CodingKeys: String, CodingKey {
        case kind, points, balance, created
        case entitlementID = "entitlement_id", dogID = "dog_id", collectedAt = "collected_at"
        case registrationYear = "registration_year"
    }
}

struct DocumentDraft: Equatable, Sendable {
    let dogID: Int
    let kind: DocumentKind
    let registrationNumber: String
    let eventDate: String?
    let filename: String?
    let fileData: Data?
    var councilName: String? = nil
    var registrationYear: Int? = nil

    static func registration(dogID: Int, kind: DocumentKind, method: DocumentEvidenceMethod,
                             number: String, councilName: String, registrationYear: Int,
                             filename: String?, fileData: Data?, today: Date = Date(),
                             questRegistrationYear: Int? = nil) throws -> DocumentDraft {
        guard kind != .vet else { throw DocumentInputError.invalidKind }
        if kind == .council, let questRegistrationYear,
           questRegistrationYear != DocumentRegistration.currentCouncilYear(on: today) {
            throw DocumentInputError.councilQuestExpired
        }
        if method == .upload {
            guard let fileData, !fileData.isEmpty, let filename, !filename.isEmpty else {
                throw DocumentInputError.attachmentRequired
            }
            // Switching methods must not submit hidden, stale text fields.
            return DocumentDraft(dogID: dogID, kind: kind, registrationNumber: "", eventDate: nil,
                                 filename: filename, fileData: fileData)
        }
        let normalized = kind == .microchip ? DocumentRegistration.normalizedMicrochip(number)
            : number.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .microchip {
            guard normalized.utf8.count == 15,
                  normalized.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw DocumentInputError.microchipNumber
            }
        } else {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
            guard !normalized.isEmpty, normalized.count <= 100,
                  normalized.unicodeScalars.allSatisfy(allowed.contains),
                  normalized.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
                throw DocumentInputError.councilNumber
            }
            let council = councilName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !council.isEmpty, council.count <= 100,
                  !council.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DocumentInputError.councilName
            }
            guard registrationYear == DocumentRegistration.currentCouncilYear(on: today) else {
                throw DocumentInputError.councilYear
            }
            return DocumentDraft(dogID: dogID, kind: kind, registrationNumber: normalized, eventDate: nil,
                                 filename: nil, fileData: nil, councilName: council, registrationYear: registrationYear)
        }
        return DocumentDraft(dogID: dogID, kind: kind, registrationNumber: normalized,
                             eventDate: nil, filename: nil, fileData: nil)
    }
}

enum DocumentEvidenceMethod: String, CaseIterable, Identifiable {
    case details = "Enter details", upload = "Upload proof"
    var id: Self { self }
}

enum DocumentRegistration {
    static func normalizedMicrochip(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Victorian council registration years end on 9 April, in Melbourne time.
    static func currentCouncilYear(on date: Date = Date()) -> Int {
        let parts = DogBirthday.calendar.dateComponents([.year, .month, .day], from: date)
        let hasRenewed = parts.month! > 4 || (parts.month! == 4 && parts.day! >= 10)
        return parts.year! + (hasRenewed ? 1 : 0)
    }

    static func councilYearLabel(_ endYear: Int) -> String {
        "\(endYear - 1)–\(String(format: "%02d", endYear % 100))"
    }

    static func isValidCouncilYear(_ endYear: Int) -> Bool { (2...9999).contains(endYear) }

    static func matchesCouncilRewardYear(received: Int?, expected: Int?) -> Bool {
        guard received.map(isValidCouncilYear) ?? true, expected.map(isValidCouncilYear) ?? true else { return false }
        // Exact legacy receipts may omit the new field; callers still require the same entitlement ID.
        guard let received, let expected else { return true }
        return received == expected
    }
}

enum DocumentInputError: LocalizedError {
    case invalidKind, attachmentRequired, microchipNumber, councilNumber, councilName, councilYear, councilQuestExpired
    var errorDescription: String? {
        switch self {
        case .invalidKind: return "Choose the document Quest again."
        case .attachmentRequired: return "Choose a PDF, JPG or PNG as proof."
        case .microchipNumber: return "Enter the 15-digit microchip number. For an older or overseas format, upload your registry certificate."
        case .councilNumber: return "Enter the Animal ID or registration number using letters, digits, spaces or hyphens (up to 100 characters). For another format, upload your proof."
        case .councilName: return "Enter the council name (up to 100 characters)."
        case .councilYear: return "Use your current registration year, or upload your proof."
        case .councilQuestExpired: return "The registration year has changed. Close this page and refresh Quests to submit for the current year."
        }
    }
}

struct DocumentRequest: Encodable, Sendable {
    let requestID: UUID
    let dogID: Int
    let kind: DocumentKind
    let registrationNumber: String?
    let eventDate: String?
    let filename: String?
    let fileBase64: String?
    let councilName: String?
    let registrationYear: Int?

    init(draft: DocumentDraft, requestID: UUID = UUID()) {
        self.requestID = requestID
        dogID = draft.dogID
        kind = draft.kind
        registrationNumber = draft.registrationNumber.isEmpty ? nil : draft.registrationNumber
        eventDate = draft.eventDate
        filename = draft.filename
        fileBase64 = draft.fileData?.base64EncodedString()
        councilName = draft.councilName
        registrationYear = draft.registrationYear
    }

    enum CodingKeys: String, CodingKey {
        case kind, filename
        case requestID = "request_id"
        case dogID = "dog_id"
        case registrationNumber = "registration_number"
        case eventDate = "event_date"
        case fileBase64 = "file_base64"
        case councilName = "council_name", registrationYear = "registration_year"
    }
}
