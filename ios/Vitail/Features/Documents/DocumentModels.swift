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
    var validTo: String? = nil
    var needsExpiry: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case kind, message
        case dogID = "dog_id"
        case awardsCount = "awards_count"
        case remainingThisYear = "remaining_this_year"
        case canEarn = "can_earn"
        case validTo = "valid_to", needsExpiry = "needs_expiry"
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
    var registryName: String? = nil
    var documentDogName: String? = nil
    var needsExpiry: Bool? = nil

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
        case councilName = "council_name", registryName = "registry_name", documentDogName = "document_dog_name"
        case needsExpiry = "needs_expiry"
    }
}

struct DocumentDashboard: Decodable, Sendable {
    let dogs: [DocumentDog]
    let submissions: [DocumentSubmission]
    let eligibility: [DocumentEligibility]
    var entitlements: [DocumentEntitlement]? = nil

    func latestPendingSubmission(dogID: Int, kind: DocumentKind, entitlementID: Int? = nil,
                                 today: Date = Date()) -> DocumentSubmission? {
        submissions.filter { submission in
            guard submission.dogID == dogID, submission.kind == kind,
                  entitlementID == nil || submission.entitlementID == entitlementID else { return false }
            if kind == .council && !DocumentRegistration.isCurrent(submission.validTo, on: today) { return false }
            if let entitlements {
                guard let entitlement = entitlements.first(where: { $0.id == submission.entitlementID }) else { return false }
                return entitlement.rewardStatus == .ready && entitlement.canCollect && entitlement.needsExpiry != true
            }
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

enum DocumentRewardStatus: String, Decodable, Sendable { case ready = "READY", collected = "COLLECTED", expired = "EXPIRED", inProgress = "IN_PROGRESS" }

struct DocumentEntitlement: Decodable, Identifiable, Sendable {
    let id: Int
    let dogID: Int
    let dogName: String
    let kind: DocumentKind
    let rewardStatus: DocumentRewardStatus
    let rewardPoints: Int
    let collectedAt: String?
    let canCollect: Bool
    var validTo: String? = nil
    var needsExpiry: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind
        case dogID = "dog_id", dogName = "dog_name", rewardStatus = "reward_status"
        case rewardPoints = "reward_points", collectedAt = "collected_at", canCollect = "can_collect"
        case validTo = "valid_to", needsExpiry = "needs_expiry"
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
    var validTo: String? = nil
    var needsExpiry: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case kind, points, balance, created
        case validTo = "valid_to", needsExpiry = "needs_expiry"
        case entitlementID = "entitlement_id", dogID = "dog_id", collectedAt = "collected_at"
    }
}

struct DocumentQuestRoute: Identifiable {
    let id: String
    let dogID: Int
    let kind: DocumentKind
    let expectedEntitlementID: Int?
    let needsExpiry: Bool
}

struct DocumentDraft: Equatable, Sendable {
    let dogID: Int
    let kind: DocumentKind
    let registrationNumber: String
    let eventDate: String?
    let filename: String?
    let fileData: Data?
    var councilName: String? = nil
    var validTo: String? = nil
    var registryName: String? = nil
    var documentDogName: String? = nil
    var expectedEntitlementID: Int? = nil
    var documentReading: DocumentReadingAudit? = nil

    static func registration(dogID: Int, kind: DocumentKind, method: DocumentEvidenceMethod,
                             number: String, councilName: String, validTo: String = "", registryName: String = "",
                             documentDogName: String? = nil, filename: String?, fileData: Data?,
                             expectedEntitlementID: Int? = nil, needsExpiry: Bool = false,
                             documentReading: DocumentReadingAudit? = nil, today: Date = Date()) throws -> DocumentDraft {
        guard kind != .vet else { throw DocumentInputError.invalidKind }
        if method == .upload {
            guard let fileData, !fileData.isEmpty, let filename, !filename.isEmpty else {
                throw DocumentInputError.attachmentRequired
            }
        }
        let number = kind == .microchip && method == .details ? DocumentRegistration.normalizedMicrochip(number)
            : number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DocumentRegistration.isPrintable(number, required: true) else {
            throw kind == .council ? DocumentInputError.councilNumber : DocumentInputError.microchipNumber
        }
        if kind == .microchip && method == .details {
            guard number.utf8.count == 15, number.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw DocumentInputError.microchipNumber
            }
        }
        let council = councilName.trimmingCharacters(in: .whitespacesAndNewlines)
        let registry = registryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dogName = documentDogName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DocumentRegistration.isPrintable(registry), dogName.map({ DocumentRegistration.isPrintable($0) }) ?? true else {
            throw DocumentInputError.invalidDetails
        }
        var expiry: String?
        if kind == .council {
            guard DocumentRegistration.isPrintable(council, required: true) else { throw DocumentInputError.councilName }
            if method == .details {
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
                guard number.unicodeScalars.allSatisfy(allowed.contains),
                      number.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
                    throw DocumentInputError.councilNumber
                }
            }
            guard let parsed = DocumentRegistration.normalizedExpiry(validTo) else { throw DocumentInputError.expiryRequired }
            guard DocumentRegistration.isCurrent(parsed, on: today) || (needsExpiry && expectedEntitlementID != nil) else {
                throw DocumentInputError.expired
            }
            expiry = parsed
        }
        return DocumentDraft(dogID: dogID, kind: kind, registrationNumber: number, eventDate: nil,
            filename: method == .upload ? filename : nil, fileData: method == .upload ? fileData : nil,
            councilName: kind == .council ? council : nil, validTo: expiry,
            registryName: kind == .microchip && !registry.isEmpty ? registry : nil,
            documentDogName: dogName?.isEmpty == false ? dogName : nil,
            expectedEntitlementID: expectedEntitlementID, documentReading: method == .upload ? documentReading : nil)
    }
}

enum DocumentEvidenceMethod: String, CaseIterable, Identifiable {
    case upload = "Upload proof", details = "Enter details"
    var id: Self { self }
}

enum DocumentRegistration {
    static func normalizedMicrochip(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != "-" }
    }
    static func isPrintable(_ value: String, required: Bool = false) -> Bool {
        (!required || !value.isEmpty) && value.count <= 100
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func normalizedExpiry(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if DogBirthday.date(from: value) != nil { return value }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]) else { return nil }
        let result = String(format: "%04d-%02d-%02d", year, month, day)
        return DogBirthday.date(from: result) == nil ? nil : result
    }
    static func expiryInputText(_ value: String) -> String {
        guard let date = DogBirthday.date(from: value) else { return "" }
        let parts = DogBirthday.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%04d", parts.day!, parts.month!, parts.year!)
    }
    static func isCurrent(_ validTo: String?, on date: Date = Date()) -> Bool {
        guard let validTo, DogBirthday.date(from: validTo) != nil else { return false }
        return validTo >= DogBirthday.string(from: date)
    }
}

enum DocumentInputError: LocalizedError {
    case invalidKind, attachmentRequired, microchipNumber, councilNumber, councilName, expiryRequired, expired, invalidDetails, confirmationRequired
    var errorDescription: String? {
        switch self {
        case .invalidKind: return "Choose the document Quest again."
        case .attachmentRequired: return "Choose a PDF, JPG or PNG as proof."
        case .microchipNumber: return "Enter the chip number shown on your certificate. Manual entry uses 15 digits; upload proof for older or overseas formats."
        case .councilNumber: return "Enter the Animal ID or registration number shown on the document (up to 100 characters)."
        case .councilName: return "Enter the council name (up to 100 characters)."
        case .expiryRequired: return "Enter the expiry date printed on the document as DD/MM/YYYY."
        case .expired: return "This registration has expired. Use your renewed registration document."
        case .invalidDetails: return "Keep each document detail to 100 characters without line breaks."
        case .confirmationRequired: return "Check the document details, then confirm they are correct."
        }
    }
}

struct DocumentReadingAudit: Encodable, Equatable, Sendable {
    struct Candidate: Encodable, Equatable, Sendable { let value: String; let page: Int; let source: String }
    let source: String
    let pagesRead: Int
    let candidates: [String: [Candidate]]
    enum CodingKeys: String, CodingKey { case source, candidates; case pagesRead = "pages_read" }

    init?(result: DocumentReadResult) {
        guard (1...20).contains(result.pagesRead) else { return nil }
        func sourceName(_ source: DocumentReadSource) -> String {
            switch source { case .pdfText: "PDF_TEXT"; case .vision: "APPLE_VISION"; case .mixed: "MIXED" }
        }
        source = sourceName(result.source)
        pagesRead = result.pagesRead
        var values: [String: [Candidate]] = [:]
        for candidate in result.candidates where (1...result.pagesRead).contains(candidate.page) {
            let key: String
            switch candidate.field {
            case .registrationNumber: key = "registration_number"
            case .councilName: key = "council_name"
            case .registryName: key = "registry_name"
            case .dogName: key = "document_dog_name"
            case .validTo: key = "valid_to"
            }
            guard candidate.source != .mixed, values[key, default: []].count < 3,
                  DocumentRegistration.isPrintable(candidate.value, required: true) else { continue }
            values[key, default: []].append(Candidate(value: candidate.value, page: candidate.page, source: sourceName(candidate.source)))
        }
        candidates = values
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
    let validTo: String?
    let registryName: String?
    let documentDogName: String?
    let expectedEntitlementID: Int?
    let documentReading: DocumentReadingAudit?

    init(draft: DocumentDraft, requestID: UUID = UUID()) {
        self.requestID = requestID
        dogID = draft.dogID
        kind = draft.kind
        registrationNumber = draft.registrationNumber.isEmpty ? nil : draft.registrationNumber
        eventDate = draft.eventDate
        filename = draft.filename
        fileBase64 = draft.fileData?.base64EncodedString()
        councilName = draft.councilName
        validTo = draft.validTo
        registryName = draft.registryName
        documentDogName = draft.documentDogName
        expectedEntitlementID = draft.expectedEntitlementID
        documentReading = draft.documentReading
    }
    enum CodingKeys: String, CodingKey {
        case kind, filename
        case requestID = "request_id", dogID = "dog_id", registrationNumber = "registration_number"
        case eventDate = "event_date", fileBase64 = "file_base64", councilName = "council_name", validTo = "valid_to"
        case registryName = "registry_name", documentDogName = "document_dog_name"
        case expectedEntitlementID = "expected_entitlement_id", documentReading = "document_reading"
    }
}
