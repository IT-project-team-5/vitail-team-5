import Foundation
import CoreLocation

struct WalkSample: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let recordedAt: String
    let accuracyM: Double
    let isSimulated: Bool

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case recordedAt = "recorded_at"
        case accuracyM = "accuracy_m"
        case isSimulated = "is_simulated"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct WalkRequest: Encodable, Equatable, Sendable {
    let requestID: UUID
    let startedAt: String
    let endedAt: String
    let dogIDs: [Int]
    let samples: [WalkSample]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case dogIDs = "dog_ids"
        case samples
    }
}

struct WalkSummary: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let requestID: UUID
    let startedAt: String
    let endedAt: String
    let distanceM: Double
    let pointsAwarded: Int
    let pointDate: String
    let dogIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceM = "distance_m"
        case pointsAwarded = "points_awarded"
        case pointDate = "point_date"
        case dogIDs = "dog_ids"
    }
}

enum WalkTimestamp {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct WalkCapture {
    let startedAt: Date
    let endedAt: Date
    let samples: [WalkSample]
}
