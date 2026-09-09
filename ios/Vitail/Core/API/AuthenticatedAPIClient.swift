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
        return try await withAccessToken { apiClient, accessToken in
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
        return try await withAccessToken { apiClient, accessToken in
            try await apiClient.getConditional(
                path,
                queryItems: queryItems,
                bearerToken: accessToken,
                as: responseType
            )
        }
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String, body: Body, as responseType: Response.Type = Response.self
    ) async throws -> Response {
        try await withAccessToken { apiClient, token in
            try await apiClient.post(path, body: body, bearerToken: token, as: responseType)
        }
    }

    func patch<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String, body: Body, as responseType: Response.Type = Response.self
    ) async throws -> Response {
        try await withAccessToken { apiClient, token in
            try await apiClient.patch(path, body: body, bearerToken: token, as: responseType)
        }
    }

    func delete(_ path: String) async throws {
        try await withAccessToken { apiClient, token in
            try await apiClient.delete(path, bearerToken: token)
        }
    }

    private func withAccessToken<Value: Sendable>(
        _ operation: @Sendable (APIClient, String) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let originalLease = try await credentials.lease()

        do {
            let result = try await operation(
                APIClient(baseURL: originalLease.backendURL, session: apiClient.session),
                originalLease.accessToken
            )
            try Task.checkCancellation()
            try await credentials.validate(originalLease)
            return result
        } catch let APIError.http(status, _) where status == 401 {
            try Task.checkCancellation()
            let renewedLease = try await credentials.renew(
                afterUnauthorized: originalLease
            )
            try Task.checkCancellation()

            do {
                let result = try await operation(
                    APIClient(baseURL: renewedLease.backendURL, session: apiClient.session),
                    renewedLease.accessToken
                )
                try Task.checkCancellation()
                try await credentials.validate(renewedLease)
                return result
            } catch let APIError.http(retryStatus, _) where retryStatus == 401 {
                await credentials.invalidate(renewedLease)
                throw APIError.missingSession
            }
        }
    }
}
