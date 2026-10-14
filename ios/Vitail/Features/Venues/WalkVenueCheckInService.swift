import Foundation

/// Venue recording is independent of social location sharing. The immutable
/// walk UUID also identifies its eventual settlement request.
protocol WalkVenueCheckInServing: Sendable {
    func fetchVenues(walkRequestID: UUID?) async throws -> [CheckInVenue]
    func updateContext(_ context: VenueWalkContext) async throws
    func start(venueID: Int, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession
    func report(checkInID: UUID, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession
    func pause(checkInID: UUID) async throws
}

struct VenueWalkContext: Encodable, Equatable, Sendable {
    let walkRequestID: UUID
    let startedAt: String
    let state: String
    enum CodingKeys: String, CodingKey {
        case walkRequestID = "walk_request_id", startedAt = "started_at", state
    }
}

struct WalkVenueLocationRequest: Encodable, Equatable, Sendable {
    let walkRequestID: UUID
    /// The captured GPS timestamp, not the number of network retries. It remains
    /// stable across replay/relaunch and repeated callbacks of the same fix.
    let sequence: Int64
    let recordedAt: String
    let latitude: Double
    let longitude: Double
    let accuracyM: Double
    let isSimulated: Bool
    enum CodingKeys: String, CodingKey {
        case walkRequestID = "walk_request_id", sequence, latitude, longitude
        case recordedAt = "recorded_at"
        case accuracyM = "accuracy_m", isSimulated = "is_simulated"
    }
}

actor WalkVenueCheckInService: WalkVenueCheckInServing {
    private let apiClient: AuthenticatedAPIClient
    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) { self.apiClient = apiClient }

    func fetchVenues(walkRequestID: UUID?) async throws -> [CheckInVenue] {
        let query = walkRequestID.map { [URLQueryItem(name: "walk_request_id", value: $0.uuidString)] } ?? []
        return try await apiClient.get("/api/venues", queryItems: query)
    }
    func updateContext(_ context: VenueWalkContext) async throws {
        let _: VenueContextAcknowledgement = try await apiClient.post("/api/check-ins/walk-context", body: context)
    }
    func start(venueID: Int, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession {
        try await apiClient.post("/api/venues/\(venueID)/check-ins", body: request)
    }
    func report(checkInID: UUID, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession {
        try await apiClient.post("/api/check-ins/\(checkInID)/locations", body: request)
    }
    func pause(checkInID: UUID) async throws {
        let _: VenueContextAcknowledgement = try await apiClient.post("/api/check-ins/\(checkInID)/pause", body: EmptyRequestBody())
    }
}

private struct VenueContextAcknowledgement: Decodable, Sendable {}

/// Coordinator fixtures/local-only walks do not start a second network feature.
struct DisabledWalkVenueCheckInService: WalkVenueCheckInServing {
    func fetchVenues(walkRequestID: UUID?) async throws -> [CheckInVenue] { [] }
    func updateContext(_ context: VenueWalkContext) async throws {}
    func start(venueID: Int, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession { throw APIError.invalidResponse }
    func report(checkInID: UUID, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession { throw APIError.invalidResponse }
    func pause(checkInID: UUID) async throws {}
}
