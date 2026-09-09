import Foundation

struct CafeProfile: Codable, Equatable, Sendable {
    let name: String
    let email: String
    let address: String
    let description: String
    let openingHours: String

    enum CodingKeys: String, CodingKey {
        case name, email, address, description
        case openingHours = "opening_hours"
    }
}

struct CafeProfileRequest: Encodable, Sendable {
    let name: String
    let address: String
    let description: String
    let openingHours: String

    enum CodingKeys: String, CodingKey {
        case name, address, description
        case openingHours = "opening_hours"
    }
}
