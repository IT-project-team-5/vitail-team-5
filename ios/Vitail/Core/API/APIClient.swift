import Foundation

enum APIError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case invalidCursor
    case missingSession
    case http(status: Int, message: String?)
    case decoding
    case network(String)
    case unsupportedRole
    case roleMismatch(expected: UserRole, actual: UserRole)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The app's server address is not configured."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .invalidCursor:
            return "The saved order cursor is no longer valid."
        case .missingSession:
            return "Your session has expired. Please sign in again."
        case let .http(status, message):
            if let message, !message.isEmpty {
                return message
            }
            return status == 401
                ? "The email or password is incorrect."
                : "The request failed (HTTP \(status))."
        case .decoding:
            return "The server returned data the app could not read."
        case let .network(message):
            return message
        case .unsupportedRole:
            return "Administrator accounts cannot sign in to the mobile app."
        case let .roleMismatch(expected, actual):
            switch (expected, actual) {
            case (.owner, .cafe):
                return "This is a café account. Choose “I'm a cafe owner” to sign in."
            case (.cafe, .owner):
                return "This is a dog owner account. Choose “I'm a dog owner” to sign in."
            default:
                return "This account does not match the selected account type."
            }
        }
    }
}

enum ConditionalAPIResponse<Value: Sendable>: Sendable {
    case value(Value)
    case notModified(headers: [String: String])
}

enum AppConfiguration {
    static var apiBaseURL: URL? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
            !value.isEmpty
        else {
            return nil
        }

        return URL(string: value)
    }
}

struct APIClient: Sendable {
    let baseURL: URL?
    let session: URLSession

    init(baseURL: URL? = AppConfiguration.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func get<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let payload = try await request(
            path: path,
            queryItems: queryItems,
            method: "GET",
            body: nil,
            bearerToken: bearerToken
        )
        return try decode(Response.self, from: payload.data)
    }

    func getConditional<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil,
        as responseType: Response.Type = Response.self
    ) async throws -> ConditionalAPIResponse<Response> {
        let payload = try await request(
            path: path,
            queryItems: queryItems,
            method: "GET",
            body: nil,
            bearerToken: bearerToken,
            allowsNotModified: true
        )

        guard payload.statusCode != 304 else {
            return .notModified(headers: payload.headers)
        }
        return .value(try decode(Response.self, from: payload.data))
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        bearerToken: String? = nil,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.invalidResponse
        }

        let payload = try await request(
            path: path,
            queryItems: [],
            method: "POST",
            body: encodedBody,
            bearerToken: bearerToken
        )
        return try decode(Response.self, from: payload.data)
    }

    private struct Payload: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?,
        bearerToken: String?,
        allowsNotModified: Bool = false
    ) async throws -> Payload {
        guard let baseURL else {
            throw APIError.invalidConfiguration
        }

        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointWithoutQuery = baseURL.appendingPathComponent(cleanPath)
        guard var components = URLComponents(
            url: endpointWithoutQuery,
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidConfiguration
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let endpoint = components.url else {
            throw APIError.invalidConfiguration
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            let isAllowedNotModified = allowsNotModified && response.statusCode == 304
            guard (200..<300).contains(response.statusCode) || isAllowedNotModified else {
                if response.statusCode == 400,
                   Self.serverCode(from: data) == "INVALID_CURSOR" {
                    throw APIError.invalidCursor
                }
                throw APIError.http(
                    status: response.statusCode,
                    message: Self.serverMessage(from: data)
                )
            }

            let headers = response.allHeaderFields.reduce(
                into: [String: String]()
            ) { result, header in
                guard let name = header.key as? String else { return }
                result[name] = String(describing: header.value)
            }
            return Payload(
                data: data,
                statusCode: response.statusCode,
                headers: headers
            )
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: Any]
        else {
            return nil
        }

        for key in ["detail", "message", "error"] {
            if let message = object[key] as? String, !message.isEmpty {
                return message
            }
        }

        for value in object.values {
            if let messages = value as? [String], let first = messages.first {
                return first
            }
            if let message = value as? String, !message.isEmpty {
                return message
            }
        }

        return nil
    }

    private static func serverCode(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: Any]
        else {
            return nil
        }
        return object["code"] as? String
    }
}
