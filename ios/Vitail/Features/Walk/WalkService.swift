import Foundation

protocol WalkServing: Sendable {
    func getWalks() async throws -> [WalkSummary]
    func submit(_ request: WalkRequest) async throws -> WalkSummary
}

actor WalkService: WalkServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func getWalks() async throws -> [WalkSummary] {
        try await apiClient.get("/api/walks")
    }

    func submit(_ request: WalkRequest) async throws -> WalkSummary {
        try await apiClient.post("/api/walks", body: request)
    }
}
