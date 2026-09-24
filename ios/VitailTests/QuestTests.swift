import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class QuestTests: XCTestCase {
    func testTaskListDecodesWithoutLegacyDashboardProjectionsOrUnusedPresentationFields() throws {
        let data = Data(QuestFixture.json.utf8)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "next_reset_at")
        var tasks = try XCTUnwrap(payload["tasks"] as? [[String: Any]])
        for index in tasks.indices { tasks[index].removeValue(forKey: "subtitle") }
        payload["tasks"] = tasks
        let snapshot = try JSONDecoder().decode(QuestSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(snapshot.tasks.count, 4)
        XCTAssertEqual(snapshot.tasks.first?.subjectName, "Milo")
        XCTAssertEqual(snapshot.localDate, "2026-09-25")
    }

    func testTaskDecodingPreservesUnknownStatusWithoutShowingUnavailableRows() async throws {
        let session = await makeSession()
        let unknown = try JSONDecoder().decode(QuestTaskStatus.self, from: Data(#""FUTURE_STATE""#.utf8))
        XCTAssertEqual(unknown, .unknown("FUTURE_STATE"))
        var tasks = QuestFixture.tasks
        tasks.append(QuestFixture.task(id: "unknown", kind: "DAILY_GOAL", status: .inProgress))
        tasks.append(QuestFixture.task(id: "disabled", status: unknown))
        tasks.append(QuestFixture.task(id: "old", status: .collected, collectedAt: "2026-09-24T01:00:00Z"))
        let store = QuestStore(ownerID: 1, session: session, service: QuestFixture(tasks: tasks))
        await store.refresh()
        XCTAssertEqual(store.visibleTasks.count, 4)
        XCTAssertEqual(store.readyTasks.map(\.id), ["birthday:7:2026", "document:10"])
        XCTAssertEqual(store.inProgressTasks.map(\.id), ["document:8:VET_CHECKUP"])
        XCTAssertEqual(store.collectedTodayTasks.map(\.id), ["document:11"])
        XCTAssertNil(store.inProgressTasks.first?.progressRatio)
    }

    func testCollectedRowsDisappearAtMelbourneMidnightWithoutBecomingReadyAgain() async {
        let session = await makeSession()
        var clock = Date(timeIntervalSince1970: 0)
        let service = QuestFixture(serverTime: "2026-09-25T13:59:00Z")
        let store = QuestStore(ownerID: 1, session: session, service: service, now: { clock })
        await store.refresh()
        XCTAssertEqual(store.collectedTodayTasks.count, 1)
        await store.collect(taskID: "birthday:7:2026")
        XCTAssertEqual(store.collectedTodayTasks.count, 2)
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(store.collectedTodayTasks.isEmpty)
        XCTAssertFalse(store.visibleTasks.contains { $0.isBirthday })
        XCTAssertEqual(store.readyTasks.map(\.id), ["document:10"])
        // Even without a new-day response, an older refresh must not turn the display clock back.
        await store.refresh()
        XCTAssertTrue(store.collectedTodayTasks.isEmpty)
        XCTAssertFalse(store.visibleTasks.contains { $0.isBirthday })
    }

    func testOlderServerDayCannotResurrectBirthdayOrCollectedRows() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.setServerTime("2026-09-25T14:01:00Z")
        await service.setTasks([])
        await store.refresh()
        XCTAssertEqual(store.snapshot?.localDate, "2026-09-26")
        XCTAssertTrue(store.visibleTasks.isEmpty)
        await service.setServerTime(QuestFixture.timestamp)
        await service.setTasks(QuestFixture.tasks)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.localDate, "2026-09-26")
        XCTAssertTrue(store.visibleTasks.isEmpty)
    }

    func testBirthdayAndDocumentCollectSerializeAcrossRowsAndKeepSuccessWhenReloadFails() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        await service.failNextFetch()
        var balances: [Int] = []
        store.onAward = { balances.append($0.balance) }
        let first = Task { await store.collect(taskID: "birthday:7:2026") }
        await service.waitForClaim()
        await store.collect(taskID: "birthday:7:2026")
        await store.collect(taskID: "document:10")
        XCTAssertEqual(store.collectingTaskID, "birthday:7:2026")
        await service.releaseClaim()
        await first.value
        XCTAssertEqual(store.task(id: "birthday:7:2026")?.status, .collected)
        XCTAssertEqual(balances, [180])
        XCTAssertNotNil(store.errorMessage)
        let calls = await service.calls
        XCTAssertEqual(calls, ["birthday:7"])
        await store.collect(taskID: "birthday:7:2026")
        let laterCalls = await service.calls
        XCTAssertEqual(laterCalls, calls)
    }

    func testDocumentSuccessSurvivesFailedReloadAndStaleReadyResponse() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.failNextFetch()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await store.collect(taskID: "document:10")
        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first?.points, 300)
        XCTAssertEqual(awards.first?.balance, 420)
        XCTAssertEqual(store.task(id: "document:10")?.status, .collected)
        await store.refresh()
        XCTAssertEqual(store.task(id: "document:10")?.status, .collected)
        await service.setTasks([])
        await store.refresh()
        XCTAssertEqual(store.collectedTodayTasks.map(\.id), ["document:10", "document:11"])
        await store.collect(taskID: "document:10")
        let calls = await service.calls
        XCTAssertEqual(calls, ["document:10"])
    }

    func testConfirmedEntitlementSuppressesStaleUploadRowWithoutSuppressingOtherReadyEntitlements() async {
        let session = await makeSession()
        let staleUpload = QuestTask(id: "document:7:COUNCIL_REGISTRATION", kind: "COUNCIL_REGISTRATION", status: .inProgress,
                                   title: "Council registration", subjectName: "Milo", photo: nil,
                                   icon: "doc.text", detail: "Add evidence", rewardPoints: 300, progress: nil,
                                   dogID: 7, entitlementID: nil, collectedAt: nil)
        let service = QuestFixture(tasks: QuestFixture.tasks + [staleUpload])
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await store.collect(taskID: "document:10")
        XCTAssertFalse(store.inProgressTasks.contains { $0.id == staleUpload.id })
        XCTAssertEqual(store.readyTasks.map(\.id), ["birthday:7:2026"])
        XCTAssertEqual(store.collectedTodayTasks.count, 2)
    }

    func testLostResponseRetryUsesEntitlementWithoutInventingPoints() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        var awards: [QuestAwardReceipt] = []
        store.onAward = { awards.append($0) }
        await service.failNextClaim()
        await store.collect(taskID: "document:10")
        XCTAssertTrue(awards.isEmpty)
        XCTAssertNil(store.confirmedCollections["document:10"])
        XCTAssertEqual(store.task(id: "document:10")?.status, .ready)
        await store.collect(taskID: "document:10")
        XCTAssertEqual(awards.count, 1)
        XCTAssertEqual(awards.first?.created, false)
        XCTAssertEqual(awards.first?.balance, 420)
        let calls = await service.calls
        XCTAssertEqual(calls, ["document:10", "document:10"])
    }

    func testInvalidDocumentReceiptDoesNotConfirmOrRefreshWallet() async {
        let cases: [(Int, DocumentKind, Int, Int, Int, String)] = [
            (99, .council, 7, 300, 420, QuestFixture.timestamp),
            (10, .vet, 7, 300, 420, QuestFixture.timestamp),
            (10, .council, 8, 300, 420, QuestFixture.timestamp),
            (10, .council, 7, 0, 420, QuestFixture.timestamp),
            (10, .council, 7, 300, -1, QuestFixture.timestamp),
            (10, .council, 7, 300, 420, "invalid date")
        ]
        for (id, kind, dog, points, balance, collectedAt) in cases {
            let session = await makeSession()
            let service = QuestFixture()
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideDocument(DocumentCollectionReceipt(entitlementID: id, kind: kind, dogID: dog, points: points,
                                                                   balance: balance, collectedAt: collectedAt, created: true))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: "document:10")
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(store.confirmedCollections["document:10"])
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testInvalidBirthdayReceiptNeverConfirmsReward() async {
        for (dog, year, kind, points) in [(8, 2026, "BIRTHDAY", 60), (7, 2025, "BIRTHDAY", 60),
                                         (7, 2026, "STREAK", 60), (7, 2026, "BIRTHDAY", 61)] {
            let session = await makeSession()
            let service = QuestFixture()
            let store = QuestStore(ownerID: 1, session: session, service: service)
            await store.refresh()
            await service.overrideBirthday(BirthdayCollectResponse(
                award: BirthdayAward(id: 4, kind: kind, dogID: dog, year: year, points: points, awardedAt: QuestFixture.timestamp),
                balance: 180, created: true))
            var callbacks = 0
            store.onAward = { _ in callbacks += 1 }
            await store.collect(taskID: "birthday:7:2026")
            XCTAssertEqual(callbacks, 0)
            XCTAssertNil(store.confirmedCollections["birthday:7:2026"])
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testSessionSignOutRejectsLateCollectionWithoutViewCallback() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await store.refresh()
        await service.suspendClaim()
        var callbacks = 0
        store.onAward = { _ in callbacks += 1 }
        let claim = Task { await store.collect(taskID: "document:10") }
        await service.waitForClaim()
        await session.logout()
        await service.releaseClaim()
        await claim.value
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.confirmedCollections.isEmpty)
        XCTAssertTrue(store.visibleTasks.isEmpty)
        XCTAssertEqual(callbacks, 0)
    }

    func testCoalescedRefreshAndTerminalStopRejectLateData() async {
        let session = await makeSession()
        let service = QuestFixture()
        let store = QuestStore(ownerID: 1, session: session, service: service)
        await service.suspendFetch()
        let first = Task { await store.refresh() }
        await service.waitForFetch()
        let second = Task { await store.refresh() }
        await Task.yield()
        store.stop()
        await service.releaseFetch()
        await first.value; await second.value
        await store.refresh()
        XCTAssertNil(store.snapshot)
        let count = await service.fetchCount
        XCTAssertEqual(count, 1)
    }

    func testServicesUseSharedCredentialsAndCorrectCollectionEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuestURLProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel(); QuestURLProtocol.handler = nil }
        let api = APIClient(baseURL: URL(string: "https://quests.example"), session: network)
        let authority = CredentialAuthority(apiClient: api, store: QuestTokenStore())
        try await authority.install(AuthTokens(access: "quest-token", refresh: "refresh-token"))
        let authenticated = AuthenticatedAPIClient(apiClient: api, credentials: authority)
        QuestURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer quest-token")
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path }
            switch path {
            case "/api/quests/":
                XCTAssertEqual(request.httpMethod, "GET"); return (200, QuestFixture.json)
            case "/api/quests/birthdays/7/collect/":
                XCTAssertEqual(request.httpMethod, "POST"); return (201, QuestFixture.awardJSON)
            case "/api/quests/documents/entitlements/10/collect/":
                XCTAssertEqual(request.httpMethod, "POST"); return (200, QuestFixture.documentJSON)
            default:
                XCTFail("Unexpected endpoint: \(request.url?.absoluteString ?? "missing")"); return (404, "{}")
            }
        }
        let service = QuestService(apiClient: authenticated)
        let dashboard = try await service.fetchQuests()
        let birthday = try await service.collectBirthday(dogID: 7)
        let document = try await service.collectDocument(entitlementID: 10)
        XCTAssertEqual(dashboard.tasks.count, 4)
        XCTAssertEqual(birthday.balance, 180)
        XCTAssertEqual(document.balance, 420)
        XCTAssertEqual(document.kind, .council)
    }

    func testCompactRowsAndDetailsAppearanceSnapshots() async throws {
        let session = await makeSession()
        let store = QuestStore(ownerID: 1, session: session, service: QuestFixture())
        let checkIns = CheckInProgressStore(ownerID: 1)
        await store.refresh()
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(QuestView(store: store, checkIns: checkIns), name: "Quest-Compact-\(mode)", dark: dark)
            try await snapshot(QuestDetailView(store: store, taskID: "document:10"), name: "Quest-Detail-Ready-\(mode)", dark: dark)
        }
        try await snapshot(QuestView(store: store, checkIns: checkIns).environment(\.dynamicTypeSize, .accessibility3),
                           name: "Quest-Compact-Large-Text", dark: false)
        try await snapshot(QuestDetailView(store: store, taskID: "document:8:VET_CHECKUP", onOpenDocuments: { _, _ in })
            .environment(\.dynamicTypeSize, .accessibility3), name: "Quest-Detail-Large-Text", dark: false)
        try await snapshot(QuestDetailView(store: store, taskID: "document:11"), name: "Quest-Detail-Collected", dark: false)
    }

    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: QuestAuthFixture())
        await session.restore()
        return session
    }
    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { content.navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline) }
            .vitailAppearance().preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
    private(set) var calls: [String] = []
    private var tasksValue: [QuestTask]
    private var serverTime: String
    private var failFetch = false, failClaim = false, pauseFetch = false, pauseClaim = false
    private var birthdayOverride: BirthdayCollectResponse?
    private var documentOverride: DocumentCollectionReceipt?
    private var fetchContinuation: CheckedContinuation<Void, Never>?, claimContinuation: CheckedContinuation<Void, Never>?
    private var fetchStarted: CheckedContinuation<Void, Never>?, claimStarted: CheckedContinuation<Void, Never>?
    init(tasks: [QuestTask] = QuestFixture.tasks, serverTime: String = QuestFixture.timestamp) {
        tasksValue = tasks; self.serverTime = serverTime
    }
    func fetchQuests() async throws -> QuestSnapshot {
        fetchCount += 1
        if pauseFetch { await withCheckedContinuation { fetchContinuation = $0; fetchStarted?.resume(); fetchStarted = nil } }
        if failFetch { failFetch = false; throw APIError.network("Connection interrupted") }
        return QuestSnapshot(serverTime: serverTime, timezone: "Australia/Melbourne", localDate: QuestCalendar.dateString(QuestCalendar.parse(serverTime)!),
                             tasks: tasksValue)
    }
    func collectBirthday(dogID: Int) async throws -> BirthdayCollectResponse {
        calls.append("birthday:\(dogID)"); try await claimGate()
        if let birthdayOverride { return birthdayOverride }
        return BirthdayCollectResponse(award: BirthdayAward(id: 4, kind: "BIRTHDAY", dogID: dogID, year: 2026, points: 60, awardedAt: Self.timestamp),
                                       balance: 180, created: calls.count == 1)
    }
    func collectDocument(entitlementID: Int) async throws -> DocumentCollectionReceipt {
        calls.append("document:\(entitlementID)"); try await claimGate()
        if let documentOverride { return documentOverride }
        return DocumentCollectionReceipt(entitlementID: entitlementID, kind: .council, dogID: 7, points: 300,
                                       balance: 420, collectedAt: Self.timestamp, created: calls.count == 1)
    }
    private func claimGate() async throws {
        if pauseClaim { await withCheckedContinuation { claimContinuation = $0; claimStarted?.resume(); claimStarted = nil } }
        if failClaim { failClaim = false; throw APIError.network("Response interrupted") }
    }
    func setTasks(_ tasks: [QuestTask]) { tasksValue = tasks }
    func setServerTime(_ value: String) { serverTime = value }
    func failNextFetch() { failFetch = true }
    func failNextClaim() { failClaim = true }
    func overrideBirthday(_ value: BirthdayCollectResponse) { birthdayOverride = value }
    func overrideDocument(_ value: DocumentCollectionReceipt) { documentOverride = value }
    func suspendFetch() { pauseFetch = true }
    func suspendClaim() { pauseClaim = true }
    func waitForFetch() async { if fetchContinuation != nil { return }; await withCheckedContinuation { fetchStarted = $0 } }
    func waitForClaim() async { if claimContinuation != nil { return }; await withCheckedContinuation { claimStarted = $0 } }
    func releaseFetch() { pauseFetch = false; fetchContinuation?.resume(); fetchContinuation = nil }
    func releaseClaim() { pauseClaim = false; claimContinuation?.resume(); claimContinuation = nil }
    nonisolated static let timestamp = "2026-09-25T01:00:00Z"
    nonisolated static func task(id: String, kind: String = "VET_CHECKUP", status: QuestTaskStatus = .inProgress, collectedAt: String? = nil) -> QuestTask {
        QuestTask(id: id, kind: kind, status: status, title: "Vet check-up", subjectName: "Luna",
                  photo: nil, icon: "doc.text", detail: "Add a photo of the visit evidence.", rewardPoints: 200, progress: nil,
                  dogID: 8, entitlementID: nil, collectedAt: collectedAt)
    }
    nonisolated static var tasks: [QuestTask] { try! JSONDecoder().decode(QuestSnapshot.self, from: Data(json.utf8)).tasks }
    nonisolated static let awardJSON = #"{"award":{"id":4,"kind":"BIRTHDAY","dog_id":7,"year":2026,"points":60,"awarded_at":"2026-09-25T01:00:00Z"},"balance":180,"created":true}"#
    nonisolated static let documentJSON = #"{"entitlement_id":10,"kind":"COUNCIL_REGISTRATION","dog_id":7,"points":300,"balance":420,"collected_at":"2026-09-25T01:00:00Z","created":true}"#
    nonisolated static let json = #"""
    {"server_time":"2026-09-25T01:00:00Z","timezone":"Australia/Melbourne","local_date":"2026-09-25","next_reset_at":"2026-09-25T14:00:00Z","tasks":[
    {"id":"birthday:7:2026","kind":"BIRTHDAY","status":"READY","title":"Birthday treat","subtitle":"Ready to collect","subject_name":"Milo","photo":null,"icon":"birthday.cake","detail":"Celebrate Milo's birthday with 60 points. One birthday treat each year.","reward_points":60,"progress":1,"dog_id":7,"entitlement_id":null,"collected_at":null},
    {"id":"document:10","kind":"COUNCIL_REGISTRATION","status":"READY","title":"Council registration","subtitle":"Ready to collect","subject_name":"Milo","photo":null,"icon":"doc.text","detail":"Your registration document is saved. Collect your 300 points. This reward is available once per dog.","reward_points":300,"progress":1,"dog_id":7,"entitlement_id":10,"collected_at":null},
    {"id":"document:8:VET_CHECKUP","kind":"VET_CHECKUP","status":"IN_PROGRESS","title":"Vet check-up","subtitle":"Add a document","subject_name":"Luna","photo":null,"icon":"doc.text","detail":"Add a photo of Luna's vet check-up. Eligible visits earn 200 points, up to twice a year and at least 60 days apart.","reward_points":200,"progress":null,"dog_id":8,"entitlement_id":null,"collected_at":null},
    {"id":"document:11","kind":"MICROCHIP_REGISTRATION","status":"COLLECTED","title":"Microchip registration","subtitle":"Collected","subject_name":"Luna","photo":null,"icon":"doc.text","detail":"Your annual registration reward was collected.","reward_points":300,"progress":1,"dog_id":8,"entitlement_id":11,"collected_at":"2026-09-25T00:00:00Z"}]}
    """#
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
