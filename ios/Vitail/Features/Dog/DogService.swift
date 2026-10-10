import Foundation

protocol DogServicing: Sendable {
    func completeOnboarding() async throws -> User
    func getDogs() async throws -> [Dog]
    func getBreeds() async throws -> [Breed]
    func createDog(_ request: DogWriteRequest) async throws -> Dog
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog
    func uploadPhoto(dogID: Int, data: Data) async throws -> Dog
    func deleteDog(id: Int) async throws
    func previewGoal(dogID: Int, percentage: Int) async throws -> DogGoalPreview
    func saveGoal(dogID: Int, request: DogGoalRequest) async throws -> DogGoalPreview
}

extension DogServicing {
    func completeOnboarding() async throws -> User { throw APIError.invalidResponse }
    func previewGoal(dogID: Int, percentage: Int) async throws -> DogGoalPreview { throw URLError(.unsupportedURL) }
    func saveGoal(dogID: Int, request: DogGoalRequest) async throws -> DogGoalPreview { throw URLError(.unsupportedURL) }
    func uploadPhoto(dogID: Int, data: Data) async throws -> Dog { throw PhotoUploadError.unavailable }
}

actor DogService: DogServicing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func getDogs() async throws -> [Dog] {
        try await apiClient.get("/api/dogs")
    }

    func completeOnboarding() async throws -> User {
        try await apiClient.post("/api/auth/onboarding/complete", body: EmptyRequestBody())
    }

    func previewGoal(dogID: Int, percentage: Int) async throws -> DogGoalPreview {
        let adjustment = NSDecimalNumber(value: percentage).dividing(by: 100).stringValue
        return try await apiClient.get("/api/dogs/\(dogID)/goal",
            queryItems: [URLQueryItem(name: "owner_adjustment", value: adjustment)])
    }

    func saveGoal(dogID: Int, request: DogGoalRequest) async throws -> DogGoalPreview {
        try await apiClient.post("/api/dogs/\(dogID)/goal", body: request)
    }

    func getBreeds() async throws -> [Breed] {
        try await apiClient.get("/api/dogs/breeds")
    }

    func createDog(_ request: DogWriteRequest) async throws -> Dog {
        try await apiClient.post("/api/dogs", body: request)
    }

    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog {
        try await apiClient.patch("/api/dogs/\(id)", body: request)
    }

    func uploadPhoto(dogID: Int, data: Data) async throws -> Dog {
        try await apiClient.post("/api/dogs/\(dogID)/photo", body: PhotoUploadRequest(data: data))
    }

    func deleteDog(id: Int) async throws {
        try await apiClient.delete("/api/dogs/\(id)")
    }
}
