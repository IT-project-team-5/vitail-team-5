import Foundation

enum CafePhotoURL {
    static func resolve(_ value: String?, baseURL: URL?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }

        // TLS may terminate at ngrok/a reverse proxy while Django sees HTTP.
        // Use the already-configured HTTPS API origin for its own media only;
        // unrelated image hosts and explicitly different ports stay untouched.
        let samePort = components.port == baseURL?.port
            || (components.port == 80 && (baseURL?.port == nil || baseURL?.port == 443))
        if scheme == "http", baseURL?.scheme?.lowercased() == "https",
           host.caseInsensitiveCompare(baseURL?.host ?? "") == .orderedSame, samePort {
            components.scheme = "https"
            components.port = baseURL?.port
        }
        return components.url
    }
}

struct RedemptionEligibility: Decodable, Sendable {
    struct IncompleteDog: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
    }
    let eligible: Bool
    let incompleteDogs: [IncompleteDog]
    enum CodingKeys: String, CodingKey { case eligible, incompleteDogs = "incomplete_dogs" }
}

struct WalletBalance: Decodable, Sendable {
    let balance: Int
}

struct Reward: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let description: String
    let pointCost: Int
    let cafeName: String
    var cafeID: Int? = nil
    var cafePhoto: String? = nil
    var cafeAddress: String? = nil
    var cafeDescription: String? = nil
    var cafeOpeningHours: String? = nil
    var cafeGoogleMapsURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case pointCost = "point_cost"
        case cafeName = "cafe_name"
        case cafeID = "cafe_id"
        case cafePhoto = "cafe_photo"
        case cafeAddress = "cafe_address"
        case cafeDescription = "cafe_description"
        case cafeOpeningHours = "cafe_opening_hours"
        case cafeGoogleMapsURL = "cafe_google_maps_url"
    }

    var venueKey: String { cafeID.map { "cafe-\($0)" } ?? "legacy-\(cafeName)" }
}

struct CafeRewardGroup: Identifiable {
    let id: String
    let name: String
    let photo: String?
    let address: String
    let description: String
    let openingHours: String
    let googleMapsURL: String?
    let rewards: [Reward]

    static func grouped(_ rewards: [Reward]) -> [CafeRewardGroup] {
        Dictionary(grouping: rewards, by: \.venueKey).compactMap { key, items in
            guard let first = items.first else { return nil }
            return CafeRewardGroup(
                id: key, name: first.cafeName, photo: first.cafePhoto,
                address: first.cafeAddress ?? "", description: first.cafeDescription ?? "",
                openingHours: first.cafeOpeningHours ?? "", googleMapsURL: first.cafeGoogleMapsURL,
                rewards: items.sorted { $0.pointCost == $1.pointCost ? $0.id < $1.id : $0.pointCost < $1.pointCost }
            )
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum CollectionDeadline {
    // The café pilot's collection window ends at Melbourne midnight. Use
    // calendar days so daylight-saving changes do not move the displayed cutoff.
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return value
    }

    static func nextDeadline(after now: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    }

    static func purchaseText(now: Date = Date()) -> String {
        receiptText(nextDeadline(after: now))
    }

    static func receiptText(_ deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Collect before \(formatter.string(from: deadline)) (Melbourne)"
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
    var cafeID: Int? = nil
    var cafePhoto: String? = nil
    var cafeAddress: String? = nil
    var cafeOpeningHours: String? = nil
    var cafeGoogleMapsURL: String? = nil
    var expiresAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case referenceNumber = "reference_number"
        case rewardNameSnapshot = "reward_name_snapshot"
        case pointCostSnapshot = "point_cost_snapshot"
        case status
        case cafeNameSnapshot = "cafe_name_snapshot"
        case cafeID = "cafe_id"
        case cafePhoto = "cafe_photo"
        case cafeAddress = "cafe_address"
        case cafeOpeningHours = "cafe_opening_hours"
        case cafeGoogleMapsURL = "cafe_google_maps_url"
        case expiresAt = "expires_at"
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
