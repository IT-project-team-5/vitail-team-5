import Foundation

actor AuthService {
    private let apiClient: APIClient
    private let keychain: KeychainStore

    init(apiClient: APIClient = APIClient(), keychain: KeychainStore = KeychainStore()) {
        self.apiClient = apiClient
        self.keychain = keychain
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await apiClient.post(
            "/api/auth/login",
            body: LoginRequest(email: email, password: password),
            as: AuthResponse.self
        )
    }

    func register(email: String, password: String, displayName: String) async throws -> AuthResponse {
        try await apiClient.post(
            "/api/auth/register",
            body: RegisterRequest(email: email, password: password, displayName: displayName),
            as: AuthResponse.self
        )
    }

    func persist(_ tokens: AuthTokens) throws {
        try keychain.save(tokens)
    }

    func restoreUser() async throws -> User? {
        guard let storedTokens = try keychain.load() else {
            return nil
        }

        do {
            return try await currentUser(accessToken: storedTokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(storedTokens)
            try keychain.save(refreshedTokens)
            return try await currentUser(accessToken: refreshedTokens.access)
        }
    }

    func clearSession() throws {
        try keychain.delete()
    }

    func updateProfile(displayName: String) async throws -> User {
        try await authenticatedPatch(
            "/api/auth/me",
            body: ProfileUpdateRequest(displayName: displayName),
            as: User.self
        )
    }

    func authenticatedGet<Response: Decodable & Sendable>(
        _ path: String,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let tokens = try requireTokens()
        do {
            return try await apiClient.get(path, bearerToken: tokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(tokens)
            try keychain.save(refreshedTokens)
            return try await apiClient.get(path, bearerToken: refreshedTokens.access)
        }
    }

    func authenticatedPost<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let tokens = try requireTokens()
        do {
            return try await apiClient.post(path, body: body, bearerToken: tokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(tokens)
            try keychain.save(refreshedTokens)
            return try await apiClient.post(
                path,
                body: body,
                bearerToken: refreshedTokens.access
            )
        }
    }

    func authenticatedPatch<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let tokens = try requireTokens()
        do {
            return try await apiClient.patch(path, body: body, bearerToken: tokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(tokens)
            try keychain.save(refreshedTokens)
            return try await apiClient.patch(
                path,
                body: body,
                bearerToken: refreshedTokens.access
            )
        }
    }

    func authenticatedDelete(_ path: String) async throws {
        let tokens = try requireTokens()
        do {
            try await apiClient.delete(path, bearerToken: tokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(tokens)
            try keychain.save(refreshedTokens)
            try await apiClient.delete(path, bearerToken: refreshedTokens.access)
        }
    }

    private func currentUser(accessToken: String) async throws -> User {
        let response: CurrentUserResponse = try await apiClient.get(
            "/api/auth/me",
            bearerToken: accessToken
        )
        return response.user
    }

    private func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        let response: RefreshResponse = try await apiClient.post(
            "/api/auth/refresh",
            body: RefreshRequest(refresh: tokens.refresh)
        )
        return AuthTokens(
            access: response.access,
            refresh: response.refresh ?? tokens.refresh
        )
    }

    private func requireTokens() throws -> AuthTokens {
        guard let tokens = try keychain.load() else {
            throw APIError.http(status: 401, message: "Your session has expired. Please sign in again.")
        }
        return tokens
    }
}
