import Foundation

protocol QuestServing: Sendable {
    func fetchQuests() async throws -> QuestSnapshot
    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse
    func collectDocument(entitlementID: Int) async throws -> DocumentCollectionReceipt
    func collectStreak(_ request: StreakCollectRequest) async throws -> StreakCollectResponse
}

actor QuestService: QuestServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse {
        try await apiClient.post("/api/quests/birthdays/\(dogID)/collect/", body: EmptyRequestBody())
    }

    func fetchQuests() async throws -> QuestSnapshot {
        try await apiClient.get("/api/quests/")
    }

    func collectDocument(entitlementID: Int) async throws -> DocumentCollectionReceipt {
        try await apiClient.post("/api/quests/documents/entitlements/\(entitlementID)/collect/", body: EmptyRequestBody())
    }

    func collectStreak(_ request: StreakCollectRequest) async throws -> StreakCollectResponse {
        try await apiClient.post("/api/quests/streaks/collect/", body: request)
    }
}
