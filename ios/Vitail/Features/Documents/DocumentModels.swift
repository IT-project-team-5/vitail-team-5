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
    var guidance: String {
        switch self {
        case .council: return "300 points once per dog. Enter the registration number or attach a PDF."
        case .microchip: return "300 points per annual registration period. Enter the registration number or attach a PDF and the dates printed on the registration."
        case .vet: return "200 points per check-up, up to twice per calendar year. Rewarded visits must be at least 60 days apart. Add a photo of the visit evidence."
        }
    }
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

    enum CodingKeys: String, CodingKey {
        case kind, message
        case dogID = "dog_id"
        case awardsCount = "awards_count"
        case remainingThisYear = "remaining_this_year"
        case canEarn = "can_earn"
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
    }
}

struct DocumentDashboard: Decodable, Sendable {
    let dogs: [DocumentDog]
    let submissions: [DocumentSubmission]
    let eligibility: [DocumentEligibility]
}

struct DocumentReceipt: Decodable, Sendable {
    let submission: DocumentSubmission
    let balance: Int
    let awardedPoints: Int
    let created: Bool

    enum CodingKeys: String, CodingKey {
        case submission, balance, created
        case awardedPoints = "awarded_points"
    }
}

struct DocumentDraft: Equatable, Sendable {
    let dogID: Int
    let kind: DocumentKind
    let registrationNumber: String
    let eventDate: String?
    let validFrom: String?
    let validTo: String?
    let filename: String?
    let fileData: Data?
}

struct DocumentRequest: Encodable, Sendable {
    let requestID: UUID
    let dogID: Int
    let kind: DocumentKind
    let registrationNumber: String?
    let eventDate: String?
    let validFrom: String?
    let validTo: String?
    let filename: String?
    let fileBase64: String?

    init(draft: DocumentDraft, requestID: UUID = UUID()) {
        self.requestID = requestID
        dogID = draft.dogID
        kind = draft.kind
        registrationNumber = draft.registrationNumber.isEmpty ? nil : draft.registrationNumber
        eventDate = draft.eventDate
        validFrom = draft.validFrom
        validTo = draft.validTo
        filename = draft.filename
        fileBase64 = draft.fileData?.base64EncodedString()
    }

    enum CodingKeys: String, CodingKey {
        case kind, filename
        case requestID = "request_id"
        case dogID = "dog_id"
        case registrationNumber = "registration_number"
        case eventDate = "event_date"
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case fileBase64 = "file_base64"
    }
}
