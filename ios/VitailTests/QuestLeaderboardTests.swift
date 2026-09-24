import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class QuestLeaderboardTests: XCTestCase {
    func testPendingTargetsNeverBecomeZeroPercentAndUnknownStatusesAreSafe() throws {
        let dashboard = try QuestFixture.snapshot()
        XCTAssertEqual(dashboard.dailyGoal.dogs.first?.distanceMetres, 1250.5)
        XCTAssertNil(dashboard.dailyGoal.dogs.first?.progressRatio)
        let accidentalZero = try JSONDecoder().decode(QuestDogGoal.self, from: Data(#"{"dog_id":7,"name":"Milo","distance_m":"25","progress":0,"target_distance_m":null,"target_active_seconds":null}"#.utf8))
        XCTAssertNil(accidentalZero.progressRatio)
        let unknown = try JSONDecoder().decode(BirthdayQuestStatus.self, from: Data(#""NEW_SERVER_STATE""#.utf8))
        XCTAssertEqual(unknown, .unknown("NEW_SERVER_STATE"))
        XCTAssertThrowsError(try JSONDecoder().decode(QuestDogGoal.self, from: Data(#"{"dog_id":7,"name":"Milo","distance_m":"NaN"}"#.utf8)))
    }

    func testBirthdayRepeatedTapIsSerializedAndSuccessfulClaimSurvivesReloadFailure() async throws {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        await service.failNextFetch()
        var receivedBalances: [Int] = []
        store.onAward = { response in receivedBalances.append(response.balance) }
        let first = Task { await store.collectBirthday(dogID: 7) }
        await service.waitForClaim()
        await store.collectBirthday(dogID: 7)
        let count = await service.claimCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.collectingBirthdayID, 7)
        await service.releaseClaim()
        await first.value
        let dog = try XCTUnwrap(store.snapshot?.birthdays.dogs.first)
        XCTAssertTrue(store.birthdayWasCollected(dog))
        XCTAssertFalse(store.canCollectBirthday(dog))
        XCTAssertEqual(receivedBalances, [180])
        XCTAssertEqual(store.lastAward?.award.points, 60)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.collectingBirthdayID)
        await store.collectBirthday(dogID: 7)
        let finalCount = await service.claimCount
        XCTAssertEqual(finalCount, 1)
    }

    func testLostClaimResponseCanRetryWithoutInventingLocalPoints() async throws {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.failNextClaim()
        await store.collectBirthday(dogID: 7)
        XCTAssertNil(store.lastAward)
        XCTAssertTrue(store.confirmedBirthdays.isEmpty)
        let dog = try XCTUnwrap(store.snapshot?.birthdays.dogs.first)
        XCTAssertTrue(store.canCollectBirthday(dog))
        await store.collectBirthday(dogID: 7)
        XCTAssertEqual(store.lastAward?.created, false)
        XCTAssertEqual(store.lastAward?.balance, 180)
        XCTAssertTrue(store.birthdayWasCollected(dog))
    }

    func testMismatchedBirthdayReceiptCannotConfirmRewardOrRefreshWallet() async {
        let invalidValues: [(id: Int, dog: Int, year: Int, kind: String, points: Int, balance: Int)] = [
            (0, 7, 2026, "BIRTHDAY", 60, 180),
            (4, 8, 2026, "BIRTHDAY", 60, 180),
            (4, 7, 2025, "BIRTHDAY", 60, 180),
            (4, 7, 2026, "STREAK", 60, 180),
            (4, 7, 2026, "BIRTHDAY", 0, 180),
            (4, 7, 2026, "BIRTHDAY", 61, 180),
            (4, 7, 2026, "BIRTHDAY", 60, -1)
        ]
        for value in invalidValues {
            let session = await makeSession()
            let service = QuestFixture()
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideClaim(BirthdayCollectResponse(
                award: BirthdayAward(id: value.id, kind: value.kind, dogID: value.dog, year: value.year,
                                     points: value.points, awardedAt: "2026-09-25T01:00:00Z"),
                balance: value.balance, created: true
            ))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collectBirthday(dogID: 7)
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(store.lastAward)
            XCTAssertTrue(store.confirmedBirthdays.isEmpty)
            XCTAssertNotNil(store.errorMessage)
            let fetches = await service.fetchCount
            XCTAssertEqual(fetches, 1)
        }
    }

    func testQuestRefreshCoalescesAndStopRejectsLateResponse() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let first = Task { await store.refresh() }
        await service.waitForFetch()
        let second = Task { await store.refresh() }
        await Task.yield()
        let calls = await service.fetchCount
        XCTAssertEqual(calls, 1)
        store.stop()
        await service.releaseFetch()
        await first.value
        await second.value
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
        let finalCalls = await service.fetchCount
        XCTAssertEqual(finalCalls, 1)
    }

    func testStaleOwnerClaimCannotPublishAwardOrRunWalletCallback() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        var callbackCount = 0
        store.onAward = { _ in callbackCount += 1 }
        let claim = Task { await store.collectBirthday(dogID: 7) }
        await service.waitForClaim()
        await session.logout()
        store.stop()
        await service.releaseClaim()
        await claim.value
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastAward)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(store.confirmedBirthdays.isEmpty)
    }

    func testUnknownAndNonBirthdayStatesCannotCollect() async throws {
        for state in ["UPCOMING", "MISSING_BIRTHDAY", "INVALID_BIRTHDAY", "CLAIMED", "FUTURE_STATE"] {
            let session = await makeSession()
            let service = QuestFixture(birthdayStatus: state)
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await store.collectBirthday(dogID: 7)
            let calls = await service.claimCount
            XCTAssertEqual(calls, 0, state)
        }
    }

    func testLeaderboardPeriodSwitchDiscardsOlderRequestAndShowsOnlySelf() async throws {
        let session = await makeSession()
        let service = LeaderboardFixture()
        let store = LeaderboardStore(ownerID: 1, session: session, service: service)
        await service.suspendWeek()
        let oldRequest = Task { await store.refresh() }
        await service.waitForWeek()
        await store.selectPeriod(.allTime)
        XCTAssertEqual(store.snapshot?.period, "all_time")
        XCTAssertEqual(store.currentEntry?.userID, 1)
        XCTAssertEqual(store.currentEntry?.distanceMetres, 12_500)
        await service.releaseWeek()
        await oldRequest.value
        XCTAssertEqual(store.snapshot?.period, "all_time")
        XCTAssertEqual(store.period, .allTime)
        XCTAssertFalse(store.isRefreshing)
        await session.logout()
        await store.refresh()
        XCTAssertNil(store.snapshot)
    }

    func testLeaderboardTransientFailurePreservesLastSuccessfulStats() async {
        let session = await makeSession()
        let service = LeaderboardFixture()
        let store = LeaderboardStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        let original = store.currentEntry
        await service.failNextFetch()
        await store.refresh()
        XCTAssertEqual(store.currentEntry, original)
        XCTAssertNotNil(store.errorMessage)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
    }

    func testServicesUseSharedCredentialsCorrectEndpointsAndPeriod() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuestURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel(); QuestURLProtocol.handler = nil }
        let api = APIClient(baseURL: URL(string: "https://quests.example"), session: network)
        let authority = CredentialAuthority(apiClient: api, store: QuestTokenStore())
        try await authority.install(AuthTokens(access: "quest-token", refresh: "refresh-token"))
        let authenticated = AuthenticatedAPIClient(apiClient: api, credentials: authority)
        QuestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "quests.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer quest-token")
            // URL.path removes the trailing slash; URLComponents preserves the wire path.
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            switch components?.path {
            case "/api/quests/":
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, QuestFixture.json())
            case "/api/quests/birthdays/7/collect/":
                XCTAssertEqual(request.httpMethod, "POST")
                return (201, QuestFixture.awardJSON)
            case "/api/leaderboard/":
                XCTAssertEqual(request.httpMethod, "GET")
                let query = components?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "period" })?.value, "all_time")
                return (200, LeaderboardFixture.json(period: .allTime))
            default:
                XCTFail("Unexpected endpoint: \(request.url?.absoluteString ?? "missing URL")")
                return (404, "{}")
            }
        }
        let quest = QuestService(apiClient: authenticated)
        let dashboard = try await quest.fetchQuests()
        let receipt = try await quest.collectBirthday(dogID: 7)
        let leaderboard = try await LeaderboardService(apiClient: authenticated).fetchLeaderboard(period: .allTime)
        XCTAssertEqual(dashboard.birthdays.rewardPoints, 60)
        XCTAssertEqual(receipt.balance, 180)
        XCTAssertEqual(leaderboard.period, "all_time")
    }

    func testQuestAndLeaderboardAppearanceSnapshots() async throws {
        let session = await makeSession()
        let quests = QuestStore(ownerID: 1, session: session, service: QuestFixture())
        let leaderboard = LeaderboardStore(ownerID: 1, session: session, service: LeaderboardFixture())
        let checkIns = CheckInProgressStore(ownerID: 1)
        await quests.refresh()
        await leaderboard.refresh()
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(QuestView(store: quests, checkIns: checkIns), name: "Quest-\(mode)", dark: dark)
            try await snapshot(LeaderboardView(store: leaderboard), name: "Leaderboard-\(mode)", dark: dark)
        }
        try await snapshot(QuestView(store: quests, checkIns: checkIns).environment(\.dynamicTypeSize, .accessibility3),
                           name: "Quest-Large-Text", dark: false)
    }

    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: QuestAuthFixture())
        await session.restore()
        return session
    }

    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack {
            content.navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline)
        }.vitailAppearance().preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private actor QuestAuthFixture: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    func restoreUser() async throws -> User? { User(id: 1, email: "owner@example.com", displayName: "Chien", role: .owner) }
    func login(email: String, password: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
}

private actor QuestFixture: QuestServing {
    private(set) var fetchCount = 0
    private(set) var claimCount = 0
    let birthdayStatus: String
    private var failFetch = false
    private var failClaim = false
    private var pauseFetch = false
    private var pauseClaim = false
    private var claimResponse: BirthdayCollectResponse?
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var fetchStarted: CheckedContinuation<Void, Never>?
    private var claimStarted: CheckedContinuation<Void, Never>?

    init(birthdayStatus: String = "AVAILABLE") { self.birthdayStatus = birthdayStatus }
    func fetchQuests() async throws -> QuestSnapshot {
        fetchCount += 1
        if pauseFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
                fetchStarted?.resume(); fetchStarted = nil
            }
        }
        if failFetch { failFetch = false; throw APIError.network("Connection interrupted") }
        return try Self.snapshot(birthdayStatus: birthdayStatus)
    }
    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse {
        claimCount += 1
        if pauseClaim {
            await withCheckedContinuation { continuation in
                claimContinuation = continuation
                claimStarted?.resume(); claimStarted = nil
            }
        }
        if failClaim { failClaim = false; throw APIError.network("Response interrupted") }
        if let claimResponse { return claimResponse }
        let json = claimCount > 1 ? Self.awardJSON.replacingOccurrences(of: "\"created\":true", with: "\"created\":false") : Self.awardJSON
        return try JSONDecoder().decode(BirthdayCollectResponse.self, from: Data(json.utf8))
    }
    func failNextFetch() { failFetch = true }
    func overrideClaim(_ response: BirthdayCollectResponse) { claimResponse = response }
    func failNextClaim() { failClaim = true }
    func suspendFetch() { pauseFetch = true }
    func suspendClaim() { pauseClaim = true }
    func waitForFetch() async {
        if fetchContinuation != nil { return }
        await withCheckedContinuation { fetchStarted = $0 }
    }
    func waitForClaim() async {
        if claimContinuation != nil { return }
        await withCheckedContinuation { claimStarted = $0 }
    }
    func releaseFetch() { pauseFetch = false; fetchContinuation?.resume(); fetchContinuation = nil }
    func releaseClaim() { pauseClaim = false; claimContinuation?.resume(); claimContinuation = nil }
    nonisolated static let awardJSON = #"{"award":{"id":4,"kind":"BIRTHDAY","dog_id":7,"year":2026,"points":60,"awarded_at":"2026-09-25T01:00:00Z"},"balance":180,"created":true}"#
    nonisolated static func snapshot(birthdayStatus: String = "AVAILABLE") throws -> QuestSnapshot {
        try JSONDecoder().decode(QuestSnapshot.self, from: Data(json(birthdayStatus: birthdayStatus).utf8))
    }
    nonisolated static func json(birthdayStatus: String = "AVAILABLE") -> String {
        """
        {"server_time":"2026-09-25T01:00:00Z","timezone":"Australia/Melbourne","local_date":"2026-09-25","next_reset_at":"2026-09-25T14:00:00Z",
         "daily_goal":{"status":"RULES_PENDING","dogs":[{"dog_id":7,"name":"Milo","photo":null,"distance_m":"1250.50","target_distance_m":null,"active_seconds":null,"target_active_seconds":null,"progress":null}],"reward_points":null},
         "streak":{"status":"AVAILABLE","current_days":3,"longest_days":9,"active_today":true,"milestones":[{"days":7,"reward_points":20},{"days":30,"reward_points":100}],"next_milestone":{"days":7,"reward_points":20},"award_status":"NOT_ENABLED"},
         "birthdays":{"status":"AVAILABLE","reward_points":60,"dogs":[{"dog_id":7,"name":"Milo","photo":null,"date_of_birth":"2024-09-25","next_birthday":"2026-09-25","is_birthday_today":true,"status":"\(birthdayStatus)"}]},
         "check_ins":{"status":"NOT_AVAILABLE","items":[]},"documents":{"status":"NOT_AVAILABLE","items":[]}}
        """
    }
}

private actor LeaderboardFixture: LeaderboardServing {
    private var pauseWeek = false
    private var failFetch = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func fetchLeaderboard(period: LeaderboardPeriod) async throws -> LeaderboardSnapshot {
        if period == .week, pauseWeek {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started?.resume(); started = nil
            }
        }
        if failFetch { failFetch = false; throw APIError.network("Connection interrupted") }
        return try JSONDecoder().decode(LeaderboardSnapshot.self, from: Data(Self.json(period: period).utf8))
    }
    func failNextFetch() { failFetch = true }
    func suspendWeek() { pauseWeek = true }
    func waitForWeek() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseWeek() { pauseWeek = false; continuation?.resume(); continuation = nil }
    nonisolated static func json(period: LeaderboardPeriod) -> String {
        """
        {"server_time":"2026-09-25T01:00:00Z","timezone":"Australia/Melbourne","period":"\(period.rawValue)","starts_at":null,"ends_at":"2026-09-25T01:00:00Z","scope":"SELF_ONLY","friends_available":false,
         "entries":[{"rank":1,"user_id":99,"display_name":"Not this owner","photo":null,"is_current_user":false,"distance_m":"90000","walk_count":20,"walking_points":50},
         {"rank":1,"user_id":1,"display_name":"Chien","photo":null,"is_current_user":true,"distance_m":"\(period == .week ? "2500" : "12500")","walk_count":4,"walking_points":24}]}
        """
    }
}

private final class QuestTokenStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    func load() -> AuthTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ value: AuthTokens) { lock.lock(); defer { lock.unlock() }; tokens = value }
    func delete() { lock.lock(); defer { lock.unlock() }; tokens = nil }
}

private final class QuestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
