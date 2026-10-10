import Foundation

protocol DocumentServing: Sendable {
    func searchCouncils(_ query: String) async throws -> [CouncilOption]
    func fetchDocuments() async throws -> DocumentDashboard
    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt
    func download(submissionID: Int) async throws -> Data
    func collect(entitlementID: Int) async throws -> DocumentCollectionReceipt
}

extension DocumentServing {
    func searchCouncils(_ query: String) async throws -> [CouncilOption] { throw APIError.invalidResponse }
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

    func searchCouncils(_ query: String) async throws -> [CouncilOption] {
        try await apiClient.get("/api/councils", queryItems: [URLQueryItem(name: "q", value: query)])
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

struct CouncilOption: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let postcodes: [String]
}
