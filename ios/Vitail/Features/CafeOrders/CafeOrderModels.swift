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
    let ownerDogNames: [String]
    let status: String
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case referenceNumber = "reference_number"
        case ownerName = "owner_name"
        case items
        case orderedAt = "ordered_at"
        case ownerDogNames = "owner_dog_names"
        case status
        case expiresAt = "expires_at"
    }

    init(
        id: Int,
        referenceNumber: String,
        ownerName: String,
        items: [CafeOrderItem],
        orderedAt: Date,
        ownerDogNames: [String] = [],
        status: String = "PENDING",
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.referenceNumber = referenceNumber
        self.ownerName = ownerName
        self.items = items
        self.orderedAt = orderedAt
        self.ownerDogNames = ownerDogNames
        self.status = status
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        referenceNumber = try container.decode(String.self, forKey: .referenceNumber)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        items = try container.decode([CafeOrderItem].self, forKey: .items)
        ownerDogNames = try container.decodeIfPresent([String].self, forKey: .ownerDogNames) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "PENDING"
        if let value = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = Self.parseISO8601(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt, in: container,
                    debugDescription: "Expected an ISO-8601 expiry timestamp."
                )
            }
            expiresAt = date
        } else {
            expiresAt = nil
        }

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

    var itemTitle: String {
        guard !items.isEmpty else { return "Order" }
        return items.map { item in
            item.quantity == 1 ? item.name : "\(item.quantity) × \(item.name)"
        }.joined(separator: " · ")
    }

    var customerSummary: String {
        guard !ownerDogNames.isEmpty else { return ownerName }
        return "\(ownerName) · Dogs: \(ownerDogNames.joined(separator: ", "))"
    }

    var statusLabel: String {
        switch status {
        case "PENDING": return "Awaiting collection"
        case "COLLECTED": return "Collected"
        case "EXPIRED": return "Expired"
        case "CANCELLED": return "Cancelled"
        default: return status.capitalized
        }
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
