import Foundation

protocol VenueServing: Sendable {
    func fetchVenues() async throws -> [Venue]
    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> CheckIn
    func reportLocation(checkInID: Int, sample: LocationSample) async throws -> CheckIn
    func abandonCheckIn(checkInID: Int) async throws -> CheckIn
}

actor VenueService: VenueServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchVenues() async throws -> [Venue] {
        try await apiClient.get("/api/venues")
    }

    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> CheckIn {
        try await apiClient.post("/api/venues/\(venueID)/check-ins", body: sample)
    }

    func reportLocation(checkInID: Int, sample: LocationSample) async throws -> CheckIn {
        try await apiClient.post("/api/check-ins/\(checkInID)/locations", body: sample)
    }

    func abandonCheckIn(checkInID: Int) async throws -> CheckIn {
        try await apiClient.post("/api/check-ins/\(checkInID)/abandon", body: EmptyRequestBody())
    }
}
