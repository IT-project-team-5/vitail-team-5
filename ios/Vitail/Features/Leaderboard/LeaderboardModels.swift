import Foundation

enum LeaderboardPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case allTime = "all_time"
    var id: Self { self }
    var label: String { self == .week ? "This week" : "All time" }
}

struct LeaderboardSnapshot: Decodable, Equatable, Sendable {
    let serverTime: String
    let timezone: String
    let period: String
    let startsAt: String?
    let endsAt: String
    let scope: String
    let friendsAvailable: Bool
    let message: String?
    let entries: [LeaderboardEntry]

    enum CodingKeys: String, CodingKey {
        case timezone, period, scope, message, entries
        case serverTime = "server_time"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case friendsAvailable = "friends_available"
    }
}

struct LeaderboardEntry: Decodable, Equatable, Identifiable, Sendable {
    let rank: Int
    let userID: Int
    let displayName: String
    let photo: String?
    let isCurrentUser: Bool
    let distanceMetres: Double
    let walkCount: Int
    let walkingPoints: Int
    var id: Int { userID }

    enum CodingKeys: String, CodingKey {
        case rank, photo
        case userID = "user_id"
        case displayName = "display_name"
        case isCurrentUser = "is_current_user"
        case distanceMetres = "distance_m"
        case walkCount = "walk_count"
        case walkingPoints = "walking_points"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rank = try values.decode(Int.self, forKey: .rank)
        userID = try values.decode(Int.self, forKey: .userID)
        displayName = try values.decode(String.self, forKey: .displayName)
        photo = try values.decodeIfPresent(String.self, forKey: .photo)
        isCurrentUser = try values.decode(Bool.self, forKey: .isCurrentUser)
        distanceMetres = try values.decodeQuestNumber(forKey: .distanceMetres)
        walkCount = try values.decode(Int.self, forKey: .walkCount)
        walkingPoints = try values.decode(Int.self, forKey: .walkingPoints)
    }
}
