import Foundation

protocol DocumentServing: Sendable {
    func fetchDocuments() async throws -> DocumentDashboard
    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt
    func download(submissionID: Int) async throws -> Data
    func collect(entitlementID: Int) async throws -> DocumentCollectionReceipt
}

extension DocumentServing {
    func collect(entitlementID: Int) async throws -> DocumentCollectionReceipt { throw APIError.invalidResponse }
}

actor DocumentService: DocumentServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchDocuments() async throws -> DocumentDashboard {
        try await apiClient.get("/api/quests/documents")
    }

    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt {
        let path = request.correctsSubmissionID.map { "/api/quests/documents/\($0)/corrections" } ?? "/api/quests/documents"
        return try await apiClient.post(path, body: request)
    }

    func download(submissionID: Int) async throws -> Data {
        try await apiClient.getData("/api/quests/documents/\(submissionID)/file")
    }

    func collect(entitlementID: Int) async throws -> DocumentCollectionReceipt {
        try await apiClient.post("/api/quests/documents/entitlements/\(entitlementID)/collect", body: [String: String]())
    }
}
