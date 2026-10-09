import Foundation

struct WalkSample: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let recordedAt: String
    let accuracyM: Double
    let isSimulated: Bool
    var segmentID: Int = 0

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case recordedAt = "recorded_at"
        case accuracyM = "accuracy_m"
        case isSimulated = "is_simulated"
        case segmentID = "segment_id"
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

struct WalkSummary: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let requestID: UUID
    let startedAt: String
    let endedAt: String
    let distanceM: Double
    let pointsAwarded: Int
    let pointDate: String
    let dogIDs: [Int]
    var checkInAwards: [WalkVenueAward] = []
    var checkInPointsAwarded: Int = 0
    var netPointsAwarded: Int = 0
    var totalPointsAwarded: Int? = nil
    var walletBalance: Int? = nil

    var settledTotalPoints: Int { totalPointsAwarded ?? pointsAwarded + checkInPointsAwarded + netPointsAwarded }

    init(id: Int, requestID: UUID, startedAt: String, endedAt: String, distanceM: Double,
         pointsAwarded: Int, pointDate: String, dogIDs: [Int], checkInAwards: [WalkVenueAward] = [],
         checkInPointsAwarded: Int = 0, netPointsAwarded: Int = 0, totalPointsAwarded: Int? = nil,
         walletBalance: Int? = nil) {
        self.id = id; self.requestID = requestID; self.startedAt = startedAt; self.endedAt = endedAt
        self.distanceM = distanceM; self.pointsAwarded = pointsAwarded; self.pointDate = pointDate; self.dogIDs = dogIDs
        self.checkInAwards = checkInAwards; self.checkInPointsAwarded = checkInPointsAwarded
        self.netPointsAwarded = netPointsAwarded; self.totalPointsAwarded = totalPointsAwarded; self.walletBalance = walletBalance
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceM = "distance_m"
        case pointsAwarded = "points_awarded"
        case pointDate = "point_date"
        case dogIDs = "dog_ids"
        case checkInAwards = "check_in_awards"
        case checkInPointsAwarded = "check_in_points_awarded"
        case netPointsAwarded = "net_points_awarded"
        case totalPointsAwarded = "total_points_awarded"
        case walletBalance = "wallet_balance"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        endedAt = try values.decode(String.self, forKey: .endedAt)
        distanceM = try values.decode(Double.self, forKey: .distanceM)
        pointsAwarded = try values.decode(Int.self, forKey: .pointsAwarded)
        pointDate = try values.decode(String.self, forKey: .pointDate)
        dogIDs = try values.decode([Int].self, forKey: .dogIDs)
        checkInAwards = try values.decodeIfPresent([WalkVenueAward].self, forKey: .checkInAwards) ?? []
        checkInPointsAwarded = try values.decodeIfPresent(Int.self, forKey: .checkInPointsAwarded) ?? 0
        netPointsAwarded = try values.decodeIfPresent(Int.self, forKey: .netPointsAwarded) ?? 0
        totalPointsAwarded = try values.decodeIfPresent(Int.self, forKey: .totalPointsAwarded)
        walletBalance = try values.decodeIfPresent(Int.self, forKey: .walletBalance)
    }
}

struct WalkVenueAward: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let venueID: Int
    let venueName: String
    let kind: String
    let rewardCategory: String
    let awardedPoints: Int
    enum CodingKeys: String, CodingKey {
        case id, kind
        case venueID = "venue_id", venueName = "venue_name"
        case rewardCategory = "reward_category", awardedPoints = "awarded_points"
    }
    var categoryTitle: String {
        if let category = CheckInVenueKind(rawValue: kind), category != .other { return category.title }
        switch rewardCategory {
        case "VET": return "Vet"
        case "PARK": return "Park"
        case "PARTNER": return "Partner"
        default: return "Venue"
        }
    }
}

enum WalkTimestamp {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
