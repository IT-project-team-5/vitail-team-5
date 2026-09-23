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
    var photo: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case role, photo
    }
}

struct AuthTokens: Codable, Equatable, Sendable {
    let access: String
    let refresh: String
    var backendURL: String? = nil
}

struct AuthResponse: Codable, Equatable, Sendable {
    let access: String
    let refresh: String
    let user: User
    var backendURL: String? = nil

    var tokens: AuthTokens {
        AuthTokens(access: access, refresh: refresh, backendURL: backendURL)
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

struct PhotoUploadRequest: Encodable, Sendable {
    let imageBase64: String

    init(data: Data) { imageBase64 = data.base64EncodedString() }

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
    }
}

enum PhotoUploadError: LocalizedError {
    case unavailable
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unavailable: "Photo upload is unavailable. Please try again."
        case .invalidImage: "This photo could not be opened. Please choose another image."
        }
    }
}
