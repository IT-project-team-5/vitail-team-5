import Foundation

protocol AuthServing: Sendable {
    var credentialEvents: AsyncStream<CredentialEvent> { get }

    func login(email: String, password: String) async throws -> AuthResponse
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse
    func persist(_ tokens: AuthTokens) async throws
    func restoreUser() async throws -> User?
    func clearSession() async throws
}

actor AuthService: AuthServing {
    nonisolated let credentialEvents: AsyncStream<CredentialEvent>

    private let apiClient: APIClient
    private let authenticatedAPIClient: AuthenticatedAPIClient
    private let credentials: CredentialAuthority

    init() {
        let apiClient = APIClient()
        let credentials = CredentialAuthority.shared
        self.apiClient = apiClient
        self.credentials = credentials
        self.authenticatedAPIClient = AuthenticatedAPIClient(
            apiClient: apiClient,
            credentials: credentials
        )
        self.credentialEvents = credentials.events
    }

    init(apiClient: APIClient, keychain: KeychainStore = KeychainStore()) {
        let credentials = CredentialAuthority(apiClient: apiClient, store: keychain)
        self.apiClient = apiClient
        self.credentials = credentials
        self.authenticatedAPIClient = AuthenticatedAPIClient(
            apiClient: apiClient,
            credentials: credentials
        )
        self.credentialEvents = credentials.events
    }

    init(
        apiClient: APIClient,
        authenticatedAPIClient: AuthenticatedAPIClient,
        credentials: CredentialAuthority
    ) {
        self.apiClient = apiClient
        self.authenticatedAPIClient = authenticatedAPIClient
        self.credentials = credentials
        self.credentialEvents = credentials.events
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

    func persist(_ tokens: AuthTokens) async throws {
        try await credentials.install(tokens)
    }

    func restoreUser() async throws -> User? {
        guard try await credentials.hasCredentials() else {
            return nil
        }

        return try await currentUser()
    }

    func clearSession() async throws {
        try await credentials.logout()
    }

    private func currentUser() async throws -> User {
        let response: CurrentUserResponse = try await authenticatedAPIClient.get(
            "/api/auth/me"
        )
        return response.user
    }
}
