import Foundation

protocol QuestServing: Sendable {
    func collectDailyGoal(dogID: Int, localDate: String) async throws -> DailyGoalCollectResponse
    func fetchQuests() async throws -> QuestSnapshot
    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse
    func collectDocument(entitlementID: Int) async throws -> DocumentCollectionReceipt
    func collectStreak(_ request: StreakCollectRequest) async throws -> StreakCollectResponse
    func resetQuests() async throws -> QuestResetResponse
}

extension QuestServing {
    func collectDailyGoal(dogID: Int, localDate: String) async throws -> DailyGoalCollectResponse { throw APIError.invalidResponse }
    func resetQuests() async throws -> QuestResetResponse {
        throw APIError.http(status: 404, message: "Quest reset is unavailable on this server.")
    }
}

actor QuestService: QuestServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse {
        try await apiClient.post("/api/quests/birthdays/\(dogID)/collect/", body: EmptyRequestBody())
    }

    func collectDailyGoal(dogID: Int, localDate: String) async throws -> DailyGoalCollectResponse {
        try await apiClient.post("/api/quests/goals/\(dogID)/collect", body: ["local_date": localDate])
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

    func resetQuests() async throws -> QuestResetResponse {
        try await apiClient.post("/api/quests/reset", body: EmptyRequestBody())
    }
}
