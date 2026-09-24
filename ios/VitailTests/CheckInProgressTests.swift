import XCTest
@testable import Vitail

@MainActor
final class CheckInProgressTests: XCTestCase {
    func testBothSurfacesShareOneCollectionAndVerifiedProgress() async {
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        XCTAssertEqual(store.items.first?.progressRatio, 1)
        var callbacks = 0
        store.onCollection = { callbacks += 1 }
        await service.suspendCollection()
        let mapClaim = Task { await store.collect(id: "visit-1") }
        await service.waitForCollection()
        // The Quest button uses the very same store while the map request is pending.
        await store.collect(id: "visit-1")
        let callsBeforeCompletion = await service.requestIDs.count
        XCTAssertEqual(callsBeforeCompletion, 1)
        XCTAssertTrue(store.collectingIDs.contains("visit-1"))
        await service.finishCollection()
        await mapClaim.value
        XCTAssertEqual(store.items.first?.status, .collected)
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(store.collectingIDs.isEmpty)
    }

    func testLostResponseRetryUsesSameRequestID() async {
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await service.failNextCollection()
        await store.collect(id: "visit-1")
        XCTAssertEqual(store.items.first?.status, .ready)
        XCTAssertNotNil(store.errorMessage)
        await store.collect(id: "visit-1")
        let requests = await service.requestIDs
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(store.items.first?.status, .collected)
    }

    func testLateRefreshCannotRestoreAlreadyCollectedReward() async {
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await service.suspendFetch()
        let oldRefresh = Task { await store.refresh() }
        await service.waitForFetch()
        await store.collect(id: "visit-1")
        await service.finishFetch()
        await oldRefresh.value
        XCTAssertEqual(store.items.first?.status, .collected)
        // Even a subsequent eventually-consistent response must not resurrect it.
        await store.refresh()
        XCTAssertEqual(store.items.first?.status, .collected)
    }

    func testSignOutDiscardsLateResponseAndWalletCallback() async {
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        var callbacks = 0
        store.onCollection = { callbacks += 1 }
        await service.suspendCollection()
        let claim = Task { await store.collect(id: "visit-1") }
        await service.waitForCollection()
        store.stop()
        await service.finishCollection()
        await claim.value
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(store.collectingIDs.isEmpty)
    }

    func testSessionSignOutAutomaticallyStopsInFlightCollectionWithoutViewCallback() async {
        let session = SessionStore(authService: CheckInAuthFixture())
        await session.restore()
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service, session: session)
        await store.refresh()
        var callbacks = 0
        store.onCollection = { callbacks += 1 }
        await service.suspendCollection()
        let claim = Task { await store.collect(id: "visit-1") }
        await service.waitForCollection()

        // No OwnerHome observer or explicit store.stop(): the store observes the session itself.
        await session.logout()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.collectingIDs.isEmpty)
        XCTAssertNil(store.onCollection)
        await service.finishCollection()
        await claim.value
        await store.refresh()
        await store.collect(id: "visit-1")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(callbacks, 0)
        let claims = await service.requestIDs.count
        XCTAssertEqual(claims, 1)
    }

    func testOwnerReplacementAutomaticallyRejectsLateCheckInRefresh() async throws {
        let auth = CheckInAuthFixture()
        let session = SessionStore(authService: auth)
        await session.restore()
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service, session: session)
        await store.refresh()
        await service.suspendFetch()
        let refresh = Task { await store.refresh() }
        await service.waitForFetch()

        await auth.setOwnerID(2)
        try await session.login(email: "owner2@example.com", password: "fixture", expectedRole: .owner)
        XCTAssertEqual(session.state, .signedIn(User(id: 2, email: "owner2@example.com", displayName: "Owner 2", role: .owner)))
        XCTAssertTrue(store.items.isEmpty)
        await service.finishFetch()
        await refresh.value
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.errorMessage)
        let calls = await service.fetchCount
        XCTAssertEqual(calls, 2)
    }

    func testSameOwnerProfileUpdateDoesNotStopCheckInCollection() async throws {
        let session = SessionStore(authService: CheckInAuthFixture())
        await session.restore()
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service, session: session)
        await store.refresh()
        try await session.updateDisplayName("Updated owner")
        await store.collect(id: "visit-1")
        XCTAssertEqual(store.items.first?.status, .collected)
        let calls = await service.requestIDs.count
        XCTAssertEqual(calls, 1)
    }

    func testCollectedRewardStaysCollectedAfterItTemporarilyDisappears() async {
        let service = CheckInProgressFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await store.collect(id: "visit-1")
        await service.setHidden(true)
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        await service.setHidden(false)
        await store.refresh()
        XCTAssertEqual(store.items.first?.status, .collected)
        await store.collect(id: "visit-1")
        let requests = await service.requestIDs
        XCTAssertEqual(requests.count, 1)
    }

    func testProgressUsesVerifiedDwellAndUnavailableServiceCannotCollect() async {
        let waiting = CheckInProgressFixture.item(seconds: 120, status: .inProgress)
        XCTAssertEqual(waiting.progressRatio, 0.2, accuracy: 0.001)
        let inconsistent = CheckInProgressFixture.item(seconds: 120, status: .ready)
        XCTAssertFalse(inconsistent.isValid)
        let service = CheckInProgressFixture(initial: waiting)
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await store.collect(id: "visit-1")
        let requests = await service.requestIDs
        XCTAssertTrue(requests.isEmpty)
        let unavailable = CheckInProgressStore(ownerID: 1)
        await unavailable.refresh()
        await unavailable.collect(id: "visit-1")
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertTrue(unavailable.items.isEmpty)
    }
}

private actor CheckInProgressFixture: CheckInProgressServing {
    let initial: VenueCheckInProgress
    private(set) var requestIDs: [UUID] = []
    private(set) var fetchCount = 0
    private var shouldSuspendCollection = false
    private var shouldSuspendFetch = false
    private var shouldFailCollection = false
    private var isHidden = false
    private var collectionContinuation: CheckedContinuation<Void, Never>?
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var collectionStarted: CheckedContinuation<Void, Never>?
    private var fetchStarted: CheckedContinuation<Void, Never>?

    init(initial: VenueCheckInProgress = CheckInProgressFixture.item()) { self.initial = initial }

    nonisolated static func item(seconds: Int = 600, status: VenueCheckInProgress.Status = .ready) -> VenueCheckInProgress {
        VenueCheckInProgress(id: "visit-1", venueID: 1, venueName: "Garden Tails", photo: nil,
                             requiredSeconds: 600, verifiedSeconds: seconds, status: status,
                             updatedAt: Date(timeIntervalSince1970: 1_789_000_000), rewardPoints: 12)
    }

    func fetchProgress() async throws -> [VenueCheckInProgress] {
        fetchCount += 1
        if shouldSuspendFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
                fetchStarted?.resume(); fetchStarted = nil
            }
        }
        return isHidden ? [] : [initial]
    }

    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt {
        requestIDs.append(requestID)
        if shouldSuspendCollection {
            await withCheckedContinuation { continuation in
                collectionContinuation = continuation
                collectionStarted?.resume(); collectionStarted = nil
            }
        }
        if shouldFailCollection {
            shouldFailCollection = false
            throw APIError.network("Connection interrupted")
        }
        return CheckInCollectionReceipt(checkIn: Self.item(status: .collected), awardedPoints: 12, walletBalance: 112)
    }

    func suspendCollection() { shouldSuspendCollection = true }
    func suspendFetch() { shouldSuspendFetch = true }
    func failNextCollection() { shouldFailCollection = true }
    func setHidden(_ hidden: Bool) { isHidden = hidden }
    func waitForCollection() async {
        if collectionContinuation != nil { return }
        await withCheckedContinuation { collectionStarted = $0 }
    }
    func waitForFetch() async {
        if fetchContinuation != nil { return }
        await withCheckedContinuation { fetchStarted = $0 }
    }
    func finishCollection() {
        shouldSuspendCollection = false
        collectionContinuation?.resume(); collectionContinuation = nil
    }
    func finishFetch() {
        shouldSuspendFetch = false
        fetchContinuation?.resume(); fetchContinuation = nil
    }
}

private actor CheckInAuthFixture: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    private var ownerID = 1
    func setOwnerID(_ value: Int) { ownerID = value }
    func restoreUser() async throws -> User? { user() }
    func login(email: String, password: String) async throws -> AuthResponse {
        AuthResponse(access: "fixture-access", refresh: "fixture-refresh", user: user())
    }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User {
        User(id: ownerID, email: "owner\(ownerID)@example.com", displayName: displayName, role: .owner)
    }
    private func user() -> User {
        User(id: ownerID, email: "owner\(ownerID)@example.com", displayName: "Owner \(ownerID)", role: .owner)
    }
}
