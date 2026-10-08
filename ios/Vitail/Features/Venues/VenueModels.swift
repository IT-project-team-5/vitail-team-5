import CoreLocation
import Foundation

enum CheckInVenueKind: String, Sendable {
    case vet = "VET"
    case dogPark = "PARK"
    case cafe = "CAFE"
    case restaurant = "RESTAURANT"
    case other = "OTHER"

    var title: String {
        switch self {
        case .vet: return "Vet"
        case .dogPark: return "Dog park"
        case .cafe: return "Café"
        case .restaurant: return "Restaurant"
        case .other: return "Venue"
        }
    }

    var icon: String {
        switch self {
        case .vet: return "cross.case.fill"
        case .dogPark: return "tree.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .restaurant: return "fork.knife"
        case .other: return "mappin"
        }
    }
}

enum CheckInVenueAvailability: String, Sendable {
    case available = "AVAILABLE"
    case inProgress = "IN_PROGRESS"
    case ready = "READY"
    case collected = "COLLECTED"
    case unavailable = "UNAVAILABLE"

    init(serverValue: String) {
        self = Self(rawValue: serverValue) ?? .unavailable
    }

    var title: String {
        switch self {
        case .available: return "Available"
        case .inProgress: return "In progress"
        case .ready: return "Ready to collect"
        case .collected: return "Collected today"
        case .unavailable: return "Unavailable today"
        }
    }

    var canStart: Bool { self == .available || self == .inProgress }

    /// A collected visit is final. Otherwise the latest venue response is the
    /// authority for server-side flags and daily-cap availability.
    static func resolved(
        server: Self,
        local: Self? = nil,
        shared: Self? = nil
    ) -> Self {
        if server == .collected || local == .collected || shared == .collected { return .collected }
        if server == .unavailable { return .unavailable }
        return shared ?? local ?? server
    }
}

struct CheckInVenue: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let kindRaw: String
    let description: String
    let address: String
    let openingHours: String
    let latitude: Double
    let longitude: Double
    let checkinRadiusM: Int
    let requiredSeconds: Int
    let checkInStatus: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, address, latitude, longitude
        case kindRaw = "kind"
        case openingHours = "opening_hours"
        case checkinRadiusM = "checkin_radius_m"
        case requiredSeconds = "required_seconds"
        case checkInStatus = "checkin_status"
    }

    var venueType: CheckInVenueKind { CheckInVenueKind(rawValue: kindRaw) ?? .other }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var dwellText: String { DwellFormat.text(seconds: requiredSeconds) }
    var availability: CheckInVenueAvailability { CheckInVenueAvailability(serverValue: checkInStatus) }
}

enum VenueCheckInSessionStatus: String, Decodable, Sendable {
    case inProgress = "IN_PROGRESS"
    case ready = "READY"
    case collected = "COLLECTED"
}

struct VenueCheckInSession: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let venueID: Int
    let venueName: String
    let status: VenueCheckInSessionStatus
    let requiredSeconds: Int
    let verifiedSeconds: Int
    let rewardPoints: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case venueID = "venue_id"
        case venueName = "venue_name"
        case requiredSeconds = "required_seconds"
        case verifiedSeconds = "verified_seconds"
        case rewardPoints = "reward_points"
    }

}

struct LocationSample: Encodable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyM: Double
    let isSimulated: Bool

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyM = "accuracy_m"
        case isSimulated = "is_simulated"
    }

    init(latitude: Double, longitude: Double, accuracyM: Double, isSimulated: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM
        self.isSimulated = isSimulated
    }

    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyM: max(0, location.horizontalAccuracy),
            isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false
        )
    }
}

enum DwellFormat {
    static func text(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let remainder = max(0, seconds) % 60
        if minutes == 0 { return "\(remainder) sec" }
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }

    static func clock(seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
