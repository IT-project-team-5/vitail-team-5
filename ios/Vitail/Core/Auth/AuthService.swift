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

    /// Runs `perform` with the current access token, refreshing once and
    /// retrying on a 401 so other features (e.g. RedemptionService) don't
    /// each duplicate this logic (TECH_STACK.md, section 22, shared-code rule).
    func performAuthorized<Response: Decodable & Sendable>(
        _ perform: @Sendable (String) async throws -> Response
    ) async throws -> Response {
        guard let tokens = try keychain.load() else {
            throw APIError.http(status: 401, message: "You are signed out.")
        }

        do {
            return try await perform(tokens.access)
        } catch let APIError.http(status, _) where status == 401 {
            let refreshedTokens = try await refresh(tokens)
            try keychain.save(refreshedTokens)
            return try await perform(refreshedTokens.access)
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
}
