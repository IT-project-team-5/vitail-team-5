import Foundation

struct WalletBalance: Decodable, Sendable {
    let balance: Int
}

struct Venue: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let venueType: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case venueType = "venue_type"
        case description
    }
}

struct VenueOffer: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let pointPrice: Int
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case pointPrice = "point_price"
        case isAvailable = "is_available"
    }
}

struct VenueDetail: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let offers: [VenueOffer]
}

enum RedemptionOrderStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case collected = "COLLECTED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
}

struct RedemptionOrderItem: Codable, Identifiable, Sendable {
    let id: Int
    let itemNameSnapshot: String
    let pointPriceSnapshot: Int
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case id
        case itemNameSnapshot = "item_name_snapshot"
        case pointPriceSnapshot = "point_price_snapshot"
        case quantity
    }
}

struct RedemptionOrder: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let referenceNumber: String
    let status: RedemptionOrderStatus
    let totalPoints: Int
    let venueName: String
    let items: [RedemptionOrderItem]

    enum CodingKeys: String, CodingKey {
        case id
        case referenceNumber = "reference_number"
        case status
        case totalPoints = "total_points"
        case venueName = "venue_name"
        case items
    }

    static func == (lhs: RedemptionOrder, rhs: RedemptionOrder) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

struct CreateOrderItemRequest: Encodable, Sendable {
    let offerId: Int
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case offerId = "offer_id"
        case quantity
    }
}

struct CreateOrderRequest: Encodable, Sendable {
    let venueId: Int
    let items: [CreateOrderItemRequest]

    enum CodingKeys: String, CodingKey {
        case venueId = "venue_id"
        case items
    }
}

/// Django's collect endpoint takes no fields; POST still needs an Encodable
/// body to satisfy APIClient.post's generic signature.
struct EmptyRequestBody: Encodable, Sendable {}
