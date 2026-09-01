import Foundation

protocol DogServicing: Sendable {
    func getDogs() async throws -> [Dog]
    func getBreeds() async throws -> [Breed]
    func createDog(_ request: DogWriteRequest) async throws -> Dog
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog
    func getGoal(dogID: Int) async throws -> DogGoal
}

actor DogService: DogServicing {
    private let authService: AuthService

    init(authService: AuthService = AuthService()) {
        self.authService = authService
    }

    func getDogs() async throws -> [Dog] {
        try await authService.authenticatedGet("/api/dogs")
    }

    func getBreeds() async throws -> [Breed] {
        try await authService.authenticatedGet("/api/dogs/breeds")
    }

    func createDog(_ request: DogWriteRequest) async throws -> Dog {
        try await authService.authenticatedPost("/api/dogs", body: request)
    }

    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog {
        try await authService.authenticatedPatch("/api/dogs/\(id)", body: request)
    }

    func getGoal(dogID: Int) async throws -> DogGoal {
        try await authService.authenticatedGet("/api/dogs/\(dogID)/goal")
    }
}
