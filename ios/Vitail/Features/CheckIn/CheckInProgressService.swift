import Foundation

actor CheckInProgressService: CheckInProgressServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchProgress() async throws -> CheckInProgressSnapshot {
        try await apiClient.get("/api/check-ins")
    }

    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt {
        try await apiClient.post("/api/check-ins/\(id)/collect", body: CheckInCollectRequest(requestID: requestID))
    }
}

private struct CheckInCollectRequest: Encodable, Sendable {
    let requestID: UUID

    enum CodingKeys: String, CodingKey { case requestID = "request_id" }
}
