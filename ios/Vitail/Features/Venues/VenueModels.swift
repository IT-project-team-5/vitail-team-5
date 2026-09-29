import CoreLocation
import Foundation

enum VenueType: String, Sendable {
    case vet = "VET"
    case dogPark = "DOG_PARK"
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

struct Venue: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let venueTypeRaw: String
    let description: String
    let address: String
    let openingHours: String
    let latitude: Double
    let longitude: Double
    let checkinRadiusM: Int
    let requiredDwellS: Int
    let checkedInToday: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, address, latitude, longitude
        case venueTypeRaw = "venue_type"
        case openingHours = "opening_hours"
        case checkinRadiusM = "checkin_radius_m"
        case requiredDwellS = "required_dwell_s"
        case checkedInToday = "checked_in_today"
    }

    var venueType: VenueType { VenueType(rawValue: venueTypeRaw) ?? .other }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var dwellText: String { DwellFormat.text(seconds: requiredDwellS) }
}

enum CheckInStatus: String, Decodable, Sendable {
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case abandoned = "ABANDONED"
}

struct CheckIn: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let venueID: Int
    let venueName: String
    let status: CheckInStatus
    let abandonReason: String
    let requiredDwellS: Int
    let verifiedSeconds: Int
    let awardedPoints: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case venueID = "venue_id"
        case venueName = "venue_name"
        case abandonReason = "abandon_reason"
        case requiredDwellS = "required_dwell_s"
        case verifiedSeconds = "verified_seconds"
        case awardedPoints = "awarded_points"
    }

    /// Plain-language reason shown after an unsuccessful check-in. Nothing is lost or penalised.
    var abandonMessage: String {
        switch abandonReason {
        case "LEFT_RADIUS": return "You left the venue before the time was up. No points this time — you can try again today."
        case "SIGNAL_LOST": return "We stopped receiving your location. No points this time — you can try again today."
        case "SIMULATED": return "Simulated locations can't earn check-in points."
        case "CANCELLED": return "Check-in cancelled."
        default: return "Check-in ended. You can try again today."
        }
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
