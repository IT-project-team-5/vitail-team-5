import Foundation

protocol DocumentServing: Sendable {
    func fetchDocuments() async throws -> DocumentDashboard
    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt
    func download(submissionID: Int) async throws -> Data
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
        try await apiClient.post("/api/quests/documents", body: request)
    }

    func download(submissionID: Int) async throws -> Data {
        try await apiClient.getData("/api/quests/documents/\(submissionID)/file")
    }
}
