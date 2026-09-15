import Foundation

struct WalletBalance: Decodable, Sendable {
    let balance: Int
}

struct Reward: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let description: String
    let pointCost: Int
    let cafeName: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case pointCost = "point_cost"
        case cafeName = "cafe_name"
    }
}

enum RedemptionStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case collected = "COLLECTED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
}

struct Redemption: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let referenceNumber: String
    let rewardNameSnapshot: String
    let pointCostSnapshot: Int
    let status: RedemptionStatus
    var cafeNameSnapshot: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case referenceNumber = "reference_number"
        case rewardNameSnapshot = "reward_name_snapshot"
        case pointCostSnapshot = "point_cost_snapshot"
        case status
        case cafeNameSnapshot = "cafe_name_snapshot"
    }

    static func == (lhs: Redemption, rhs: Redemption) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

struct CreateRedemptionRequest: Encodable, Sendable {
    let rewardId: Int
    let requestId: UUID

    enum CodingKeys: String, CodingKey {
        case rewardId = "reward_id"
        case requestId = "request_id"
    }
}

/// Django's collect endpoint takes no fields; POST still needs an Encodable
/// body to satisfy APIClient.post's generic signature.
struct EmptyRequestBody: Encodable, Sendable {}
