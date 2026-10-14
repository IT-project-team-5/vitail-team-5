import CoreLocation
import Foundation

enum DogMapBreed: String, Codable, CaseIterable, Identifiable, Sendable {
    case goldenRetriever, corgi, husky, dalmatian, beagle, shiba, poodle, dachshund, cat
    var id: String { rawValue }
    var isEasterEgg: Bool { self == .cat }
    var title: String {
        switch self {
        case .goldenRetriever: return "Golden Retriever"
        case .corgi: return "Corgi"
        case .husky: return "Husky"
        case .dalmatian: return "Dalmatian"
        case .beagle: return "Beagle"
        case .shiba: return "Shiba Inu"
        case .poodle: return "Poodle"
        case .dachshund: return "Dachshund"
        case .cat: return "Cat · Easter egg"
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .goldenRetriever
    }
}

enum DogBandanaColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, yellow, green
    var id: String { rawValue }
    var title: String { self == .none ? "No bandana" : rawValue.capitalized }
    var guidance: String? {
        switch self {
        case .none: return nil
        case .red: return "My dog is reactive"
        case .yellow: return "Please give space, nervous dog"
        case .green: return "Friendly"
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Unknown colours carry no handling guidance.
        self = Self(rawValue: value) ?? .none
    }
}

struct PublicDogProfile: Codable, Equatable, Sendable {
    let name: String
    let breedName: String
    let ageMonths: Int
    let size: String
    enum CodingKeys: String, CodingKey {
        case name, size, breedName = "breed_name", ageMonths = "age_months"
    }
    var ageDescription: String {
        let months = max(0, ageMonths)
        let years = months / 12
        if years == 0 { return "\(months) mo" }
        return months % 12 == 0 ? "\(years) yr" : "\(years) yr \(months % 12) mo"
    }
    init(name: String, breedName: String, ageMonths: Int, size: String) {
        self.name = name; self.breedName = breedName; self.ageMonths = ageMonths; self.size = size
    }
    init(_ dog: Dog) {
        self.init(name: dog.name, breedName: dog.breed.name,
                  ageMonths: dog.currentAgeMonths(), size: dog.size.rawValue)
    }
}

struct SocialProfile: Codable, Identifiable, Equatable, Sendable {
    let publicID: String
    let displayName: String
    let photoURL: String?
    let avatarKey: String?
    let dogAvatarBreed: DogMapBreed
    let bandanaColor: DogBandanaColor
    let dog: PublicDogProfile?
    let avatarOutfit: DogAvatarOutfit
    var id: String { publicID }

    init(publicID: String, displayName: String, photoURL: String?, avatarKey: String? = nil,
         dogAvatarBreed: DogMapBreed = .goldenRetriever, bandanaColor: DogBandanaColor = .none,
         dog: PublicDogProfile? = nil, avatarOutfit: DogAvatarOutfit = .plain) {
        self.publicID = publicID
        self.displayName = displayName
        self.photoURL = photoURL
        self.avatarKey = avatarKey
        self.dogAvatarBreed = dogAvatarBreed
        self.bandanaColor = bandanaColor
        self.dog = dog
        self.avatarOutfit = avatarOutfit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publicID = try values.decode(String.self, forKey: .publicID)
        displayName = try values.decode(String.self, forKey: .displayName)
        photoURL = try values.decodeIfPresent(String.self, forKey: .photoURL)
        avatarKey = try values.decodeIfPresent(String.self, forKey: .avatarKey)
        dogAvatarBreed = try values.decodeIfPresent(DogMapBreed.self, forKey: .dogAvatarBreed) ?? .goldenRetriever
        bandanaColor = try values.decodeIfPresent(DogBandanaColor.self, forKey: .bandanaColor) ?? .none
        dog = try values.decodeIfPresent(PublicDogProfile.self, forKey: .dog)
        avatarOutfit = try values.decodeIfPresent(DogAvatarOutfit.self, forKey: .avatarOutfit) ?? .plain
    }

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id", displayName = "display_name", photoURL = "photo_url", avatarKey = "avatar_key"
        case dogAvatarBreed = "dog_avatar_breed", bandanaColor = "bandana_color"
        case dog, avatarOutfit = "avatar_outfit"
    }
}

struct SocialPreferences: Codable, Equatable, Sendable {
    let publicID: String
    let displayName: String
    let photoURL: String?
    let avatarKey: String?
    let dogAvatarBreed: DogMapBreed
    let bandanaColor: DogBandanaColor
    let locationVisibility: String
    let netMatchingEnabled: Bool
    let publicDogID: Int?
    let dog: PublicDogProfile?
    let avatarOutfit: DogAvatarOutfit

    init(publicID: String, displayName: String, photoURL: String?, avatarKey: String? = nil,
         locationVisibility: String, netMatchingEnabled: Bool,
         dogAvatarBreed: DogMapBreed = .goldenRetriever, bandanaColor: DogBandanaColor = .none,
         publicDogID: Int? = nil, dog: PublicDogProfile? = nil, avatarOutfit: DogAvatarOutfit = .plain) {
        self.publicID = publicID
        self.displayName = displayName
        self.photoURL = photoURL
        self.avatarKey = avatarKey
        self.dogAvatarBreed = dogAvatarBreed
        self.bandanaColor = bandanaColor
        self.locationVisibility = locationVisibility
        self.netMatchingEnabled = netMatchingEnabled
        self.publicDogID = publicDogID
        self.dog = dog
        self.avatarOutfit = avatarOutfit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publicID = try values.decode(String.self, forKey: .publicID)
        displayName = try values.decode(String.self, forKey: .displayName)
        photoURL = try values.decodeIfPresent(String.self, forKey: .photoURL)
        avatarKey = try values.decodeIfPresent(String.self, forKey: .avatarKey)
        locationVisibility = try values.decode(String.self, forKey: .locationVisibility)
        netMatchingEnabled = try values.decode(Bool.self, forKey: .netMatchingEnabled)
        dogAvatarBreed = try values.decodeIfPresent(DogMapBreed.self, forKey: .dogAvatarBreed) ?? .goldenRetriever
        bandanaColor = try values.decodeIfPresent(DogBandanaColor.self, forKey: .bandanaColor) ?? .none
        publicDogID = try values.decodeIfPresent(Int.self, forKey: .publicDogID)
        dog = try values.decodeIfPresent(PublicDogProfile.self, forKey: .dog)
        avatarOutfit = try values.decodeIfPresent(DogAvatarOutfit.self, forKey: .avatarOutfit) ?? .plain
    }

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id", displayName = "display_name", photoURL = "photo_url", avatarKey = "avatar_key"
        case locationVisibility = "location_visibility", netMatchingEnabled = "net_matching_enabled"
        case dogAvatarBreed = "dog_avatar_breed", bandanaColor = "bandana_color"
        case publicDogID = "public_dog_id", dog, avatarOutfit = "avatar_outfit"
    }
    var profile: SocialProfile {
        SocialProfile(publicID: publicID, displayName: displayName, photoURL: photoURL, avatarKey: avatarKey,
                      dogAvatarBreed: dogAvatarBreed, bandanaColor: bandanaColor,
                      dog: dog, avatarOutfit: avatarOutfit)
    }
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

    enum CodingKeys: String, CodingKey {
        case id, state, requestID = "request_id", netConsent = "net_consent"
        case sharedDistanceM = "shared_distance_m"
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
    enum CodingKeys: String, CodingKey {
        case id, user, status, isIncoming = "is_incoming"
    }
}

struct NetWalkInvitations: Decodable, Equatable, Sendable {
    let incoming: [NetWalkInvitation]
    let outgoing: [NetWalkInvitation]
    let active: NetWalkInvitation?
    static let empty = NetWalkInvitations(incoming: [], outgoing: [], active: nil)
}

enum PublicDogSelection: Equatable, Sendable {
    case hidden
    case selected(Int)
    var dogID: Int? { if case let .selected(id) = self { return id }; return nil }
}

struct SocialPreferenceUpdate: Encodable, Equatable, Sendable {
    let locationVisibility: String?
    let netMatchingEnabled: Bool?
    let avatarKey: String
    var dogAvatarBreed: DogMapBreed = .goldenRetriever
    var bandanaColor: DogBandanaColor = .none
    var publicDogSelection: PublicDogSelection? = nil
    enum CodingKeys: String, CodingKey {
        case locationVisibility = "location_visibility", netMatchingEnabled = "net_matching_enabled", avatarKey = "virtual_avatar_key"
        case dogAvatarBreed = "dog_avatar_breed", bandanaColor = "bandana_color"
        case publicDogID = "public_dog_id"
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(locationVisibility, forKey: .locationVisibility)
        try values.encodeIfPresent(netMatchingEnabled, forKey: .netMatchingEnabled)
        try values.encode(avatarKey, forKey: .avatarKey)
        try values.encode(dogAvatarBreed, forKey: .dogAvatarBreed)
        try values.encode(bandanaColor, forKey: .bandanaColor)
        if let publicDogSelection {
            if let id = publicDogSelection.dogID { try values.encode(id, forKey: .publicDogID) }
            else { try values.encodeNil(forKey: .publicDogID) }
        }
    }
}

enum SocialAvatarOption: String, CaseIterable, Identifiable, Sendable {
    case photo = ""
    case walker
    case paw
    case dog
    case coffee

    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: return "Profile photo"
        case .walker: return "Walker"
        case .paw: return "Paw"
        case .dog: return "Dog"
        case .coffee: return "Coffee"
        }
    }
    var systemImage: String {
        switch self {
        case .photo, .walker: return "person.fill"
        case .paw: return "pawprint.fill"
        case .dog: return "dog.fill"
        case .coffee: return "cup.and.saucer.fill"
        }
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
