import Foundation

struct CafeProfile: Codable, Equatable, Sendable {
    let name: String
    let email: String
    let address: String
    let description: String
    let openingHours: String
    var googleMapsURL: String? = nil
    var mapsLink: String? = nil
    var photo: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, email, address, description, photo
        case openingHours = "opening_hours"
        case googleMapsURL = "google_maps_url"
        case mapsLink = "maps_link"
    }
}

struct CafeProfileRequest: Encodable, Sendable {
    let name: String
    let address: String
    let description: String
    let openingHours: String
    var googleMapsURL: String = ""

    enum CodingKeys: String, CodingKey {
        case name, address, description
        case openingHours = "opening_hours"
        case googleMapsURL = "google_maps_url"
    }
}
