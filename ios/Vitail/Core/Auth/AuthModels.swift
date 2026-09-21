import Foundation

enum UserRole: String, Codable, Sendable {
    case owner = "OWNER"
    case cafe = "CAFE"
    case admin = "ADMIN"

    var isSupportedOnMobile: Bool {
        self == .owner || self == .cafe
    }
}
struct User: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let email: String
    let displayName: String
    let role: UserRole

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case role
    }
}

struct AuthTokens: Codable, Equatable, Sendable {
    let access: String
    let refresh: String
}

struct AuthResponse: Codable, Equatable, Sendable {
    let access: String
    let refresh: String
    let user: User

    var tokens: AuthTokens {
        AuthTokens(access: access, refresh: refresh)
    }
}

struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
}

struct RegisterRequest: Encodable, Sendable {
    let email: String
    let password: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case displayName = "display_name"
    }
}

struct RefreshRequest: Encodable, Sendable {
    let refresh: String
}

struct RefreshResponse: Decodable, Sendable {
    let access: String
    let refresh: String?
}

struct ProfileUpdateRequest: Encodable, Sendable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct CurrentUserResponse: Decodable, Sendable {
    let user: User

    private enum CodingKeys: String, CodingKey {
        case user
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let wrappedUser = try container.decodeIfPresent(User.self, forKey: .user) {
            user = wrappedUser
        } else {
            user = try User(from: decoder)
        }
    }
}
