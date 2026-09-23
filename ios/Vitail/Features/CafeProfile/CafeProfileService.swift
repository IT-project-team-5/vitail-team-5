import Foundation

protocol CafeProfileServing: Sendable {
    func uploadPhoto(_ data: Data) async throws -> CafeProfile
    func getProfile() async throws -> CafeProfile
    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile
}

extension CafeProfileServing {
    func uploadPhoto(_ data: Data) async throws -> CafeProfile { throw PhotoUploadError.unavailable }
}

actor CafeProfileService: CafeProfileServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func uploadPhoto(_ data: Data) async throws -> CafeProfile {
        try await apiClient.post("/api/cafe/profile/photo", body: PhotoUploadRequest(data: data))
    }

    func getProfile() async throws -> CafeProfile {
        try await apiClient.get("/api/cafe/profile")
    }

    func updateProfile(_ request: CafeProfileRequest) async throws -> CafeProfile {
        try await apiClient.patch("/api/cafe/profile", body: request)
    }
}
