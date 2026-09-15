import Foundation

struct CafeOrderItem: Decodable, Equatable, Sendable {
    let name: String
    let quantity: Int
}

struct CafeOrder: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let referenceNumber: String
    let ownerName: String
    let items: [CafeOrderItem]
    let orderedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case referenceNumber = "reference_number"
        case ownerName = "owner_name"
        case items
        case orderedAt = "ordered_at"
    }

    init(
        id: Int,
        referenceNumber: String,
        ownerName: String,
        items: [CafeOrderItem],
        orderedAt: Date
    ) {
        self.id = id
        self.referenceNumber = referenceNumber
        self.ownerName = ownerName
        self.items = items
        self.orderedAt = orderedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        referenceNumber = try container.decode(String.self, forKey: .referenceNumber)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        items = try container.decode([CafeOrderItem].self, forKey: .items)

        let orderedAtValue = try container.decode(String.self, forKey: .orderedAt)
        guard let parsedDate = Self.parseISO8601(orderedAtValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .orderedAt,
                in: container,
                debugDescription: "Expected an ISO-8601 order timestamp."
            )
        }
        orderedAt = parsedDate
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct CafeOrdersFeed: Decodable, Equatable, Sendable {
    let cursor: Int
    let orders: [CafeOrder]
    let removedOrderIDs: [Int]
    let reset: Bool

    private enum CodingKeys: String, CodingKey {
        case cursor
        case orders = "upserts"
        case removedOrderIDs = "removed_ids"
        case reset
    }

    init(
        cursor: Int,
        orders: [CafeOrder],
        removedOrderIDs: [Int],
        reset: Bool = false
    ) {
        self.cursor = cursor
        self.orders = orders
        self.removedOrderIDs = removedOrderIDs
        self.reset = reset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(Int.self, forKey: .cursor)
        orders = try container.decode([CafeOrder].self, forKey: .orders)
        removedOrderIDs = try container.decode([Int].self, forKey: .removedOrderIDs)
        reset = try container.decodeIfPresent(Bool.self, forKey: .reset) ?? false
    }
}

enum CafeOrdersFetchResult: Equatable, Sendable {
    case updated(CafeOrdersFeed)
    case notModified(cursor: Int?)
}
