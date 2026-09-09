import Foundation

protocol DogServicing: Sendable {
    func getDogs() async throws -> [Dog]
    func getBreeds() async throws -> [Breed]
    func createDog(_ request: DogWriteRequest) async throws -> Dog
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog
    func deleteDog(id: Int) async throws
    func getGoal(dogID: Int) async throws -> DogGoal
}

actor DogService: DogServicing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func getDogs() async throws -> [Dog] {
        try await apiClient.get("/api/dogs")
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

    func deleteDog(id: Int) async throws {
        try await apiClient.delete("/api/dogs/\(id)")
    }

    func getGoal(dogID: Int) async throws -> DogGoal {
        try await apiClient.get("/api/dogs/\(dogID)/goal")
    }
}
