import Foundation

struct AuthenticatedAPIClient: Sendable {
    private let apiClient: APIClient
    private let credentials: CredentialAuthority

    init() {
        self.apiClient = APIClient()
        self.credentials = .shared
    }

    init(apiClient: APIClient, keychain: KeychainStore = KeychainStore()) {
        self.apiClient = apiClient
        self.credentials = CredentialAuthority(apiClient: apiClient, store: keychain)
    }

    init(apiClient: APIClient, credentials: CredentialAuthority) {
        self.apiClient = apiClient
        self.credentials = credentials
    }

    func get<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let apiClient = self.apiClient
        return try await withAccessToken { accessToken in
            try await apiClient.get(
                path,
                queryItems: queryItems,
                bearerToken: accessToken,
                as: responseType
            )
        }
    }

    func getConditional<Response: Decodable & Sendable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as responseType: Response.Type = Response.self
    ) async throws -> ConditionalAPIResponse<Response> {
        let apiClient = self.apiClient
        return try await withAccessToken { accessToken in
            try await apiClient.getConditional(
                path,
                queryItems: queryItems,
                bearerToken: accessToken,
                as: responseType
            )
        }
    }

    private func withAccessToken<Value: Sendable>(
        _ operation: @Sendable (String) async throws -> Value
    ) async throws -> Value {
        let originalLease = try await credentials.lease()

        do {
            return try await operation(originalLease.accessToken)
        } catch let APIError.http(status, _) where status == 401 {
            try Task.checkCancellation()
            let renewedLease = try await credentials.renew(
                afterUnauthorized: originalLease
            )
            try Task.checkCancellation()

            do {
                return try await operation(renewedLease.accessToken)
            } catch let APIError.http(retryStatus, _) where retryStatus == 401 {
                await credentials.invalidate(renewedLease)
                throw APIError.missingSession
            }
        }
    }
}
