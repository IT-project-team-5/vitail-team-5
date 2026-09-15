import Foundation

protocol CafeProfileServing: Sendable {
    func getProfile() async throws -> CafeProfile
    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile
}

actor CafeProfileService: CafeProfileServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func getProfile() async throws -> CafeProfile {
        try await apiClient.get("/api/cafe/profile")
    }

    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile {
        try await apiClient.patch("/api/cafe/profile", body: request)
    }
}
