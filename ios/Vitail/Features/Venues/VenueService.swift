import Foundation

protocol VenueCheckInServing: Sendable {
    func fetchVenues() async throws -> [CheckInVenue]
    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> VenueCheckInSession
    func reportLocation(checkInID: UUID, sample: LocationSample) async throws -> VenueCheckInSession
    func cancelCheckIn(checkInID: UUID) async throws
    func collectCheckIn(attemptID: UUID) async throws -> VenueCheckInCollectionReceipt
}

actor VenueCheckInService: VenueCheckInServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchVenues() async throws -> [CheckInVenue] {
        try await apiClient.get("/api/venues")
    }

    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> VenueCheckInSession {
        try await apiClient.post("/api/venues/\(venueID)/check-ins", body: sample)
    }

    func reportLocation(checkInID: UUID, sample: LocationSample) async throws -> VenueCheckInSession {
        try await apiClient.post("/api/check-ins/\(checkInID)/locations", body: sample)
    }

    func cancelCheckIn(checkInID: UUID) async throws {
        let _: EmptyResponse = try await apiClient.post("/api/check-ins/\(checkInID)/cancel", body: EmptyRequestBody())
    }

    func collectCheckIn(attemptID: UUID) async throws -> VenueCheckInCollectionReceipt {
        try await apiClient.post("/api/check-ins/\(attemptID)/collect", body: EmptyRequestBody())
    }
}

private struct EmptyResponse: Decodable, Sendable {}

struct VenueCheckInCollectionReceipt: Decodable, Sendable {
    let checkIn: VenueCheckInSession
    let awardedPoints: Int

    enum CodingKeys: String, CodingKey {
        case checkIn = "check_in"
        case awardedPoints = "awarded_points"
    }
}
