import Foundation

struct CafeProduct: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let description: String
    let pointCost: Int
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case pointCost = "point_cost"
        case isAvailable = "is_available"
    }
}

struct CafeProductRequest: Encodable, Equatable, Sendable {
    let name: String
    let description: String
    let pointCost: Int
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case name, description
        case pointCost = "point_cost"
        case isAvailable = "is_available"
    }
}
