import Foundation
import XCTest
@testable import Vitail

@MainActor
final class StatisticsTests: XCTestCase {
    func testDecodesServerDogProgressWithoutUsingOwnerMinutes() throws {
        let statistics = try JSONDecoder().decode(UserStatistics.self, from: Data(statisticsJSON.utf8))
        XCTAssertEqual(statistics.todayWalkingMinutes, 90)
        XCTAssertEqual(statistics.dailyGoalMinutes, 63)
        XCTAssertEqual(statistics.dailyGoalActiveSeconds, 1875)
        XCTAssertEqual(statistics.dailyGoalTargetSeconds, 3750)
        XCTAssertEqual(statistics.goalProgress, 0.5)
        XCTAssertEqual(statistics.dogDailyGoals.first?.dogID, 7)
        XCTAssertEqual(statistics.completedGoals, 1)
        XCTAssertFalse(statistics.leaderboardVisible)
        let missingConsent = statisticsJSON.replacingOccurrences(of: "\"leaderboard_visible\":false,", with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(UserStatistics.self, from: Data(missingConsent.utf8)))
    }

    func testLeaderboardUsesPublicIdentityExplicitMinutesAndNoEmailFallback() throws {
        let leaderboard = try JSONDecoder().decode(LeaderboardResponse.self, from: Data(leaderboardJSON.utf8))
        XCTAssertEqual(leaderboard.entries.first?.id, "public-owner")
        XCTAssertEqual(leaderboard.entries.first?.value, 62.5)
        XCTAssertEqual(leaderboard.unit, "min")
        XCTAssertEqual(leaderboard.timezone, "Australia/Melbourne")
        XCTAssertEqual(leaderboard.entries.last?.name, "Walker")
        XCTAssertEqual(leaderboard.myRank, 1)
    }

    func testDayIsParsedInMelbourneAcrossDaylightSavingAndInvalidDateStaysText() throws {
        let day = DailyGoalResult(date: "2026-10-04", completed: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne"))
        let date = try XCTUnwrap(day.parsedDate)
        XCTAssertEqual(calendar.component(.day, from: date), 4)
        XCTAssertEqual(calendar.component(.hour, from: date), 0)
        XCTAssertEqual(date.timeIntervalSince1970, 1791036000)
        XCTAssertNil(DailyGoalResult(date: "2026-02-30", completed: false).parsedDate)
        XCTAssertEqual(DailyGoalResult(date: "invalid", completed: false).dateLabel(template: "EEEEE"), "invalid")
    }

    func testPersonalStatisticsRemainAvailableWhenLeaderboardFailsThenRetryRecovers() async {
        let service = StatisticsTestService()
        await service.failLeaderboard(true)
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadData()
        XCTAssertNotNil(model.statistics)
        XCTAssertNil(model.statisticsError)
        XCTAssertNil(model.leaderboard)
        XCTAssertNotNil(model.leaderboardError)
        await service.failLeaderboard(false)
        await model.loadLeaderboard()
        XCTAssertNotNil(model.leaderboard)
        XCTAssertNil(model.leaderboardError)
        let counts = await service.readCounts
        XCTAssertEqual(counts.statistics, 1)
        XCTAssertEqual(counts.leaderboard, 2)
    }

    func testLeaderboardCanLoadIndependentlyAndFailedRefreshDoesNotShowStaleFriends() async {
        let service = StatisticsTestService()
        await service.failStatistics(true)
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadData()
        XCTAssertNil(model.statistics)
        XCTAssertNotNil(model.statisticsError)
        XCTAssertNotNil(model.leaderboard)
        XCTAssertFalse(model.canChangeVisibility)
        await service.failLeaderboard(true)
        await model.loadLeaderboard()
        XCTAssertNil(model.leaderboard)
        XCTAssertNotNil(model.leaderboardError)
    }

    func testOlderReadCannotOverwriteNewerRefresh() async {
        let service = StatisticsTestService()
        await service.holdNextStatistics()
        let model = StatisticsViewModel(ownerID: 1, service: service)
        let oldRead = Task { await model.loadStatistics() }
        await service.waitForStatistics()
        await service.setMinutes(120)
        await model.loadStatistics()
        await service.releaseStatistics()
        await oldRead.value
        XCTAssertEqual(model.statistics?.todayWalkingMinutes, 120)
        XCTAssertFalse(model.isLoadingStatistics)
    }

    func testCancelledReadDoesNotPublishOrShowAnError() async {
        let service = StatisticsTestService()
        await service.holdNextStatistics()
        let model = StatisticsViewModel(ownerID: 1, service: service)
        let read = Task { await model.loadStatistics() }
        await service.waitForStatistics()
        read.cancel()
        await service.releaseStatistics()
        await read.value
        XCTAssertNil(model.statistics)
        XCTAssertNil(model.statisticsError)
        XCTAssertFalse(model.isLoadingStatistics)
        await model.loadStatistics()
        XCTAssertNotNil(model.statistics)
    }

    func testOptInWaitsForConfirmationAndOldReadCannotRestorePreviousConsent() async {
        let service = StatisticsTestService()
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadStatistics()
        await service.holdNextStatistics()
        let oldRead = Task { await model.loadStatistics() }
        await service.waitForStatistics()
        await service.holdNextWrite()
        let save = Task { await model.setLeaderboardVisible(true) }
        await service.waitForWrite()
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertFalse(model.canChangeVisibility)
        await model.setLeaderboardVisible(false) // An in-flight save cannot be raced by another toggle.
        await service.releaseWrite()
        await save.value
        await service.releaseStatistics()
        await oldRead.value
        XCTAssertTrue(model.leaderboardVisible)
        XCTAssertNil(model.visibilityError)
        let writes = await service.visibilityWrites
        XCTAssertEqual(writes, [true])
    }

    func testFailedOptOutRemainsLocallyOffAndRetriesTheSameChoice() async {
        let service = StatisticsTestService()
        await service.setVisible(true)
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadStatistics()
        await service.failNextWrite()
        await model.setLeaderboardVisible(false)
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertEqual(model.pendingVisibility, false)
        XCTAssertNotNil(model.visibilityError)
        await model.loadStatistics() // A server read does not discard the unconfirmed opt-out.
        XCTAssertFalse(model.leaderboardVisible)
        await model.setLeaderboardVisible(true)
        await model.retryVisibility()
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertNil(model.pendingVisibility)
        XCTAssertNil(model.visibilityError)
        let writes = await service.visibilityWrites
        XCTAssertEqual(writes, [false, false])
    }

    func testRefreshConfirmsAppliedPreferenceWhenTheSaveReplyWasLost() async {
        let service = StatisticsTestService()
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadStatistics()
        await service.failNextWrite(afterApplying: true)
        await model.setLeaderboardVisible(true)
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertNotNil(model.visibilityError)
        await model.loadStatistics()
        XCTAssertTrue(model.leaderboardVisible)
        XCTAssertNil(model.pendingVisibility)
        XCTAssertNil(model.visibilityError)
        XCTAssertTrue(model.canChangeVisibility)
    }

    func testUnconfirmedOptInDoesNotClaimSharingWasEnabled() async {
        let service = StatisticsTestService()
        let model = StatisticsViewModel(ownerID: 1, service: service)
        await model.loadStatistics()
        await service.ignoreNextWrite()
        await model.setLeaderboardVisible(true)
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertNotNil(model.visibilityError)
        XCTAssertEqual(model.pendingVisibility, true)
        await model.retryVisibility()
        XCTAssertTrue(model.leaderboardVisible)
        XCTAssertNil(model.visibilityError)
    }

    func testAccountChangeDiscardsLateReadAndPreventsOldStoreReuse() async throws {
        let auth = StatisticsAuthService()
        let session = SessionStore(authService: auth)
        await session.restore()
        let service = StatisticsTestService()
        let model = StatisticsViewModel(ownerID: 1, session: session, service: service)
        await service.holdNextStatistics()
        let read = Task { await model.loadData() }
        await service.waitForStatistics()
        await session.logout()
        await auth.setOwnerID(2)
        try await session.login(email: "other@example.test", password: "test", expectedRole: .owner)
        await service.releaseStatistics()
        await read.value
        await model.loadData()
        XCTAssertNil(model.statistics)
        XCTAssertNil(model.leaderboard)
        XCTAssertFalse(model.isLoadingStatistics)
        let counts = await service.readCounts
        XCTAssertEqual(counts.statistics, 1)
    }

    func testLogoutDuringVisibilityWriteRejectsLateResponse() async {
        let auth = StatisticsAuthService()
        let session = SessionStore(authService: auth)
        await session.restore()
        let service = StatisticsTestService()
        let model = StatisticsViewModel(ownerID: 1, session: session, service: service)
        await model.loadStatistics()
        await service.holdNextWrite()
        let save = Task { await model.setLeaderboardVisible(true) }
        await service.waitForWrite()
        await session.logout()
        await service.releaseWrite()
        await save.value
        XCTAssertNil(model.statistics)
        XCTAssertNil(model.pendingVisibility)
        XCTAssertFalse(model.leaderboardVisible)
        XCTAssertFalse(model.isSavingVisibility)
        XCTAssertNil(model.visibilityError)
    }

    func testServiceUsesAuthenticatedRoutesAndOnlySendsTheVisibilityPreference() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatisticsURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StatisticsURLProtocol.handler = nil }
        let client = APIClient(baseURL: URL(string: "https://statistics.example"), session: session)
        let authority = CredentialAuthority(apiClient: client, store: StatisticsTokenStore())
        try await authority.install(AuthTokens(access: "statistics-token", refresh: "refresh"))
        let service = StatisticsService(apiClient: AuthenticatedAPIClient(apiClient: client, credentials: authority))
        let calls = StatisticsRequestLog()
        StatisticsURLProtocol.handler = { request in
            calls.add(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer statistics-token")
            if request.httpMethod == "PATCH" {
                XCTAssertEqual(request.url?.absoluteString, "https://statistics.example/api/statistics/")
                let body = try? statisticsRequestBody(request)
                XCTAssertEqual(body?["leaderboard_visible"] as? Bool, true)
                XCTAssertEqual(body?.count, 1)
                return statisticsJSON.replacingOccurrences(of: "\"leaderboard_visible\":false", with: "\"leaderboard_visible\":true")
            }
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.absoluteString == "https://statistics.example/api/statistics/leaderboard/" { return leaderboardJSON }
            XCTAssertEqual(request.url?.absoluteString, "https://statistics.example/api/statistics/")
            return statisticsJSON
        }
        let personal = try await service.fetchStatistics()
        let friends = try await service.fetchLeaderboard()
        let saved = try await service.updateLeaderboardVisibility(true)
        XCTAssertEqual(personal.goalProgress, 0.5)
        XCTAssertEqual(friends.entries.first?.publicID, "public-owner")
        XCTAssertTrue(saved.leaderboardVisible)
        XCTAssertEqual(calls.count, 3)
    }
}

private let statisticsJSON = #"{"today_walking_minutes":90,"today_distance_km":3.2,"daily_goal_minutes":63,"seven_day_goals":[{"date":"2026-10-15","completed":true},{"date":"2026-10-16","completed":false}],"leaderboard_visible":false,"daily_goal_active_seconds":1875,"daily_goal_target_seconds":3750,"daily_goal_progress":0.5,"dog_daily_goals":[{"dog_id":7,"dog_name":"Milo","active_seconds":1875,"target_seconds":3750,"completed":false}]}"#
private let leaderboardJSON = #"{"metric":"Walking minutes","period":"Last 7 days","unit":"min","start_date":"2026-10-10","end_date":"2026-10-16","timezone":"Australia/Melbourne","my_rank":1,"entries":[{"public_id":"public-owner","display_name":"Sam","rank":1,"value":62.5,"is_current_user":true},{"public_id":"public-friend","display_name":" ","rank":2,"value":30.25,"is_current_user":false}]}"#

private actor StatisticsTestService: StatisticsServing {
    private var visible = false
    private var minutes = 90
    private var statisticsFailure = false
    private var leaderboardFailure = false
    private var writeFailure = false
    private var applyBeforeFailure = false
    private var ignoredWrite = false
    private var holdStatistics = false
    private var holdWrite = false
    private var statisticsGate: CheckedContinuation<Void, Never>?
    private var statisticsStarted: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?
    private var writeStarted: CheckedContinuation<Void, Never>?
    private(set) var visibilityWrites: [Bool] = []
    private(set) var readCounts = (statistics: 0, leaderboard: 0)

    func failStatistics(_ value: Bool) { statisticsFailure = value }
    func failLeaderboard(_ value: Bool) { leaderboardFailure = value }
    func failNextWrite(afterApplying: Bool = false) { writeFailure = true; applyBeforeFailure = afterApplying }
    func ignoreNextWrite() { ignoredWrite = true }
    func setVisible(_ value: Bool) { visible = value }
    func setMinutes(_ value: Int) { minutes = value }
    func holdNextStatistics() { holdStatistics = true }
    func holdNextWrite() { holdWrite = true }
    func waitForStatistics() async {
        if statisticsGate == nil { await withCheckedContinuation { statisticsStarted = $0 } }
    }
    func waitForWrite() async {
        if writeGate == nil { await withCheckedContinuation { writeStarted = $0 } }
    }
    func releaseStatistics() { statisticsGate?.resume(); statisticsGate = nil }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }

    private func snapshot() throws -> UserStatistics {
        let json = statisticsJSON
            .replacingOccurrences(of: "\"leaderboard_visible\":false", with: "\"leaderboard_visible\":\(visible)")
            .replacingOccurrences(of: "\"today_walking_minutes\":90", with: "\"today_walking_minutes\":\(minutes)")
        return try JSONDecoder().decode(UserStatistics.self, from: Data(json.utf8))
    }
    func fetchStatistics() async throws -> UserStatistics {
        readCounts.statistics += 1
        let result = try snapshot()
        if holdStatistics {
            holdStatistics = false
            await withCheckedContinuation {
                statisticsGate = $0
                statisticsStarted?.resume()
                statisticsStarted = nil
            }
        }
        if statisticsFailure { throw APIError.network("Offline") }
        return result
    }
    func fetchLeaderboard() async throws -> LeaderboardResponse {
        readCounts.leaderboard += 1
        if leaderboardFailure { throw APIError.network("Offline") }
        return try JSONDecoder().decode(LeaderboardResponse.self, from: Data(leaderboardJSON.utf8))
    }
    func updateLeaderboardVisibility(_ value: Bool) async throws -> UserStatistics {
        visibilityWrites.append(value)
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation {
                writeGate = $0
                writeStarted?.resume()
                writeStarted = nil
            }
        }
        if writeFailure {
            writeFailure = false
            if applyBeforeFailure { visible = value }
            applyBeforeFailure = false
            throw APIError.network("Response lost")
        }
        if ignoredWrite { ignoredWrite = false } else { visible = value }
        return try snapshot()
    }
}

private actor StatisticsAuthService: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    private var ownerID = 1
    private var user: User { .init(id: ownerID, email: "owner@example.test", displayName: "Owner", role: .owner) }
    func setOwnerID(_ value: Int) { ownerID = value }
    func login(email: String, password: String) async throws -> AuthResponse { .init(access: "access", refresh: "refresh", user: user) }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { .init(access: "access", refresh: "refresh", user: user) }
    func persist(_ tokens: AuthTokens) async throws {}
    func restoreUser() async throws -> User? { user }
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { user }
}

private final class StatisticsTokenStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    func load() -> AuthTokens? { lock.withLock { tokens } }
    func save(_ tokens: AuthTokens) { lock.withLock { self.tokens = tokens } }
    func delete() { lock.withLock { tokens = nil } }
}
private final class StatisticsRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func add(_ request: URLRequest) { lock.withLock { calls += 1 } }
}
private final class StatisticsURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: APIError.invalidResponse); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(handler(request).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
private func statisticsRequestBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
