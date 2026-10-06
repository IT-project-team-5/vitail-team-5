import CoreLocation
import Foundation

struct SocialProfile: Codable, Identifiable, Equatable, Sendable {
    let publicID: String
    let displayName: String
    let photoURL: String?
    var id: String { publicID }

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id", displayName = "display_name", photoURL = "photo_url"
    }
}

struct SocialPreferences: Codable, Equatable, Sendable {
    let publicID: String
    let displayName: String
    let photoURL: String?
    let locationVisibility: String
    let netMatchingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id", displayName = "display_name", photoURL = "photo_url"
        case locationVisibility = "location_visibility", netMatchingEnabled = "net_matching_enabled"
    }
    var profile: SocialProfile { SocialProfile(publicID: publicID, displayName: displayName, photoURL: photoURL) }
}

struct SocialRelationship: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let user: SocialProfile
    let status: String
    let isIncoming: Bool
    enum CodingKeys: String, CodingKey { case id, user, status, isIncoming = "is_incoming" }
}

struct SocialWalkSession: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let requestID: UUID
    let state: String
    let netConsent: Bool
    let sharedDistanceM: Double
    let estimatedBonusPoints: Double
    let bonusPoints: Int
    let bonusStatus: String
    let partner: SocialProfile?

    enum CodingKeys: String, CodingKey {
        case id, state, partner, requestID = "request_id", netConsent = "net_consent"
        case sharedDistanceM = "shared_distance_m", estimatedBonusPoints = "estimated_bonus_points"
        case bonusPoints = "bonus_points", bonusStatus = "bonus_status"
    }
}

struct SocialOverview: Decodable, Equatable, Sendable {
    let me: SocialPreferences
    let friends: [SocialRelationship]
    let incomingRequests: [SocialRelationship]
    let outgoingRequests: [SocialRelationship]
    let blockedUsers: [SocialProfile]
    let currentSession: SocialWalkSession?
    enum CodingKeys: String, CodingKey {
        case me, friends, incomingRequests = "incoming_requests", outgoingRequests = "outgoing_requests"
        case blockedUsers = "blocked_users", currentSession = "current_session"
    }
}

struct SocialMapPeer: Decodable, Identifiable, Equatable, Sendable {
    let user: SocialProfile
    let latitude: Double
    let longitude: Double
    let recordedAt: String
    let expiresAt: String
    let isApproximate: Bool
    let isNetPartner: Bool
    let distanceM: Double?
    var id: String { user.publicID }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    enum CodingKeys: String, CodingKey {
        case user, latitude, longitude, recordedAt = "recorded_at", expiresAt = "expires_at"
        case isApproximate = "is_approximate", isNetPartner = "is_net_partner", distanceM = "distance_m"
    }
    func isFresh(at date: Date) -> Bool {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude),
              let recorded = SocialDate.parse(recordedAt), let expiry = SocialDate.parse(expiresAt) else { return false }
        let age = date.timeIntervalSince(recorded)
        return age >= -5 && age <= 90 && date < expiry
    }
}

struct SocialMapSnapshot: Decodable, Equatable, Sendable {
    let friends: [SocialMapPeer]
    let nearby: [SocialMapPeer]
    let partner: SocialMapPeer?
    static let empty = SocialMapSnapshot(friends: [], nearby: [], partner: nil)
    func fresh(at date: Date) -> SocialMapSnapshot {
        .init(friends: friends.filter { $0.isFresh(at: date) }, nearby: nearby.filter { $0.isFresh(at: date) },
              partner: partner.flatMap { $0.isFresh(at: date) ? $0 : nil })
    }
}

struct NetWalkInvitation: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let user: SocialProfile
    let status: String
    let isIncoming: Bool
    let createdAt: String
    let sessionID: Int
    let partnerSessionID: Int
    enum CodingKeys: String, CodingKey {
        case id, user, status, isIncoming = "is_incoming", createdAt = "created_at"
        case sessionID = "session_id", partnerSessionID = "partner_session_id"
    }
}

struct NetWalkInvitations: Decodable, Equatable, Sendable {
    let incoming: [NetWalkInvitation]
    let outgoing: [NetWalkInvitation]
    let active: NetWalkInvitation?
    static let empty = NetWalkInvitations(incoming: [], outgoing: [], active: nil)
}

struct SocialPreferenceUpdate: Encodable, Equatable, Sendable {
    let locationVisibility: String
    let netMatchingEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case locationVisibility = "location_visibility", netMatchingEnabled = "net_matching_enabled"
    }
}

struct SocialLocationSample: Encodable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double
    let recordedAt: String
    let isSimulated: Bool
    enum CodingKeys: String, CodingKey {
        case latitude, longitude, accuracyM = "accuracy_m", recordedAt = "recorded_at", isSimulated = "is_simulated"
    }
    init?(_ location: CLLocation, now: Date) {
        let age = now.timeIntervalSince(location.timestamp)
        guard age >= -5, age <= 15, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 30,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.sourceInformation?.isSimulatedBySoftware != true else { return nil }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracyM = location.horizontalAccuracy
        recordedAt = SocialDate.string(location.timestamp)
        isSimulated = false
    }
}

enum SocialDate {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
