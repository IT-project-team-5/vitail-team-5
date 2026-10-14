import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class CheckInProgressTests: XCTestCase {
    func testSlowPreMidnightResponseDoesNotReviveYesterday() async {
        let serverTime = ISO8601DateFormatter().date(from: "2026-09-25T13:59:50Z")!
        var clock = serverTime
        let service = CheckInProgressFixture(serverTime: serverTime)
        await service.suspendFetch()
        let store = CheckInProgressStore(ownerID: 1, service: service, now: { clock })
        let refresh = Task { await store.refresh() }
        await service.waitForFetch()
        clock = clock.addingTimeInterval(20)
        await service.finishFetch(); await refresh.value
        XCTAssertTrue(store.visibleItems.isEmpty)
    }

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
        XCTAssertEqual(store.collectedTodayItems.count, 1)
        await service.setHidden(false)
        await store.refresh()
        XCTAssertEqual(store.items.first?.status, .collected)
        await store.collect(id: "visit-1")
        let requests = await service.requestIDs
        XCTAssertEqual(requests.count, 1)
    }

    func testSuccessfulTestResetReplacesConfirmedReceiptWithSameIDReplay() async {
        let service = ResetReplayFixture()
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        XCTAssertEqual(store.collectedTodayItems.map(\.id), ["same-attempt"])

        await service.restartSameVenue()
        await store.refresh()
        XCTAssertEqual(store.collectedTodayItems.map(\.id), ["same-attempt"],
                       "Ordinary refreshes must retain stale-response protection.")
        XCTAssertTrue(store.activeItems.isEmpty)

        await store.resetForTesting()
        XCTAssertTrue(store.collectedTodayItems.isEmpty)
        XCTAssertEqual(store.activeItems.map(\.id), ["same-attempt"])
        XCTAssertEqual(store.activeItems.first?.status, .inProgress)
        XCTAssertTrue(store.activeItems.first?.isReplayable == true)
        XCTAssertEqual(store.earnedPointsToday, 72, "The test reset must not lower the wallet's earned total.")
    }

    func testFourVenueOpportunitiesRemainVisibleBelowCapAndHideAtCap() async {
        let service = VenueBudgetFixture(points: 71)
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        XCTAssertEqual(store.activeItems.count, 4)
        await service.setPoints(72)
        await store.refresh()
        XCTAssertTrue(store.activeItems.isEmpty)
        await store.collect(id: "venue-1")
        let calls = await service.claims
        XCTAssertEqual(calls, 0)
    }

    func testResetReplayRemainsVisibleAtCapWithoutUnlockingOrdinaryVenues() async throws {
        let service = VenueBudgetFixture(points: 72, replayableIndex: 2)
        let store = CheckInProgressStore(ownerID: 1, service: service)

        await store.refresh()

        let replay = try XCTUnwrap(store.activeItems.first)
        XCTAssertEqual(store.activeItems.map(\.id), ["venue-2"])
        XCTAssertEqual(store.visibleItems.map(\.id), ["venue-2"])
        XCTAssertTrue(replay.isReplayable)
        XCTAssertEqual(replay.status, .inProgress)
        XCTAssertNotNil(replay.walkRequestID)
        XCTAssertEqual(replay.availablePoints(earnedToday: store.earnedPointsToday), 12)
        XCTAssertEqual(serviceItem(isReplayable: false).availablePoints(earnedToday: 72), 0)

        // A Walk-linked replay remains progress-only in Quest. It cannot use
        // the legacy direct-collect endpoint and must still finish the Walk.
        await store.collect(id: replay.id)
        let claims = await service.claims
        XCTAssertEqual(claims, 0)

        let renderer = ImageRenderer(content:
            CheckInProgressCard(store: store, checkInID: replay.id)
                .padding()
                .frame(width: 393)
                .background(AppColors.background)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Quest replayable venue at daily cap"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReplayableSignalDecodesFailClosedAndRequiresAWalk() throws {
        let json = """
        {
          "items": [{
            "id": "replay", "venue_id": 7, "venue_name": "Replay Vet", "photo": null,
            "required_seconds": 180, "verified_seconds": 60, "status": "IN_PROGRESS",
            "updated_at": "2026-09-25T13:59:00Z", "reward_points": 12,
            "walk_request_id": "550e8400-e29b-41d4-a716-446655440000", "is_replayable": true
          }, {
            "id": "ordinary", "venue_id": 8, "venue_name": "Ordinary Park", "photo": null,
            "required_seconds": 300, "verified_seconds": 60, "status": "IN_PROGRESS",
            "updated_at": "2026-09-25T13:59:00Z", "reward_points": 12,
            "walk_request_id": "550e8400-e29b-41d4-a716-446655440001"
          }],
          "local_date": "2026-09-25", "earned_points_today": 72,
          "server_time": "2026-09-25T13:59:00Z"
        }
        """
        let snapshot = try JSONDecoder().decode(CheckInProgressSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertTrue(snapshot.items[0].isReplayable)
        XCTAssertFalse(snapshot.items[1].isReplayable, "Missing server signals must stay capped.")

        let invalid = serviceItem(isReplayable: true, walkRequestID: nil)
        XCTAssertFalse(invalid.isValid, "A standalone row cannot claim reset-replay authority.")
    }

    private func serviceItem(isReplayable: Bool, walkRequestID: UUID? = UUID()) -> VenueCheckInProgress {
        VenueCheckInProgress(
            id: "policy", venueID: 99, venueName: "Policy venue", photo: nil,
            requiredSeconds: 600, verifiedSeconds: 120, status: .inProgress,
            updatedAt: Date(), rewardPoints: 12, walkRequestID: walkRequestID,
            isReplayable: isReplayable
        )
    }

    func testPartialFinalRewardHidesRemainingVenuesAndKeepsCollectedAtBottom() async {
        let service = VenueBudgetFixture(points: 70)
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await store.collect(id: "venue-1")
        XCTAssertEqual(store.earnedPointsToday, 72)
        XCTAssertTrue(store.activeItems.isEmpty)
        XCTAssertEqual(store.collectedTodayItems.map(\.id), ["venue-1"])
        // Stale budget and READY data cannot re-enable further collection.
        await service.setPoints(70)
        await store.refresh()
        XCTAssertEqual(store.visibleItems.map(\.id), ["venue-1"])
        XCTAssertEqual(store.earnedPointsToday, 72)
    }

    func testCollectedMovesBelowOtherVenuesAndExpiresAtMelbourneMidnight() async {
        let service = VenueBudgetFixture(points: 0)
        var deviceTime = Date()
        let store = CheckInProgressStore(ownerID: 1, service: service, now: { deviceTime })
        await store.refresh()
        await store.collect(id: "venue-1")
        XCTAssertEqual(store.visibleItems.count, 4)
        XCTAssertEqual(store.visibleItems.last?.status, .collected)
        deviceTime = deviceTime.addingTimeInterval(120) // 23:59 Melbourne -> next day.
        XCTAssertTrue(store.visibleItems.isEmpty)
        await service.nextDay()
        await store.refresh()
        XCTAssertEqual(store.activeItems.count, 4)
        XCTAssertTrue(store.collectedTodayItems.isEmpty)
        XCTAssertEqual(store.earnedPointsToday, 0)
    }

    func testProviderCannotReturnMoreThanFourVenues() async {
        let service = VenueBudgetFixture(points: 0, count: 5)
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testPreviousDaySnapshotCannotResetCapOrResurrectCollectedVenues() async {
        let service = VenueBudgetFixture(points: 70)
        let store = CheckInProgressStore(ownerID: 1, service: service)
        await store.refresh()
        await store.collect(id: "venue-1")
        await service.previousDay()
        await store.refresh()
        XCTAssertEqual(store.earnedPointsToday, 72)
        XCTAssertTrue(store.activeItems.isEmpty)
        XCTAssertEqual(store.collectedTodayItems.map(\.id), ["venue-1"])
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
    private let serverTimeOverride: Date?

    init(initial: VenueCheckInProgress = CheckInProgressFixture.item(), serverTime: Date? = nil) {
        self.initial = initial
        serverTimeOverride = serverTime
    }

    nonisolated static func item(seconds: Int = 600, status: VenueCheckInProgress.Status = .ready) -> VenueCheckInProgress {
        VenueCheckInProgress(id: "visit-1", venueID: 1, venueName: "Garden Tails", photo: nil,
                             requiredSeconds: 600, verifiedSeconds: seconds, status: status,
                             updatedAt: Date(), rewardPoints: 12, collectedAt: status == .collected ? Date() : nil)
    }

    func fetchProgress() async throws -> CheckInProgressSnapshot {
        fetchCount += 1
        if shouldSuspendFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
                fetchStarted?.resume(); fetchStarted = nil
            }
        }
        let now = serverTimeOverride ?? Date()
        return CheckInProgressSnapshot(items: isHidden ? [] : [initial], localDate: CheckInProgressSnapshot.day(now),
                                       earnedPointsToday: 0, serverTime: now)
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
        return CheckInCollectionReceipt(checkIn: Self.item(status: .collected), awardedPoints: 12, walletBalance: 112,
                                        dailyEarnedPoints: 12, localDate: CheckInProgressSnapshot.day(Date()))
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

private actor VenueBudgetFixture: CheckInProgressServing {
    private var serverTime = ISO8601DateFormatter().date(from: "2026-09-25T13:59:00Z")!
    private var points: Int
    private let count: Int
    private let replayableIndex: Int?
    private(set) var claims = 0
    init(points: Int, count: Int = 4, replayableIndex: Int? = nil) {
        self.points = points
        self.count = count
        self.replayableIndex = replayableIndex
    }
    func setPoints(_ value: Int) { points = value }
    func nextDay() { serverTime = serverTime.addingTimeInterval(120); points = 0 }
    func previousDay() { serverTime = serverTime.addingTimeInterval(-86_400); points = 0 }
    func item(_ index: Int, collected: Bool = false) -> VenueCheckInProgress {
        let replayable = !collected && index == replayableIndex
        return VenueCheckInProgress(id: "venue-\(index)", venueID: index, venueName: "Venue \(index)", photo: nil,
                                    requiredSeconds: 600, verifiedSeconds: replayable ? 240 : 600,
                                    status: collected ? .collected : (replayable ? .inProgress : .ready),
                                    updatedAt: serverTime, rewardPoints: 12,
                                    collectedAt: collected ? serverTime : nil,
                                    walkRequestID: replayable ? UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000") : nil,
                                    isReplayable: replayable)
    }
    func fetchProgress() async throws -> CheckInProgressSnapshot {
        CheckInProgressSnapshot(items: (1...count).map { item($0) },
                                localDate: CheckInProgressSnapshot.day(serverTime),
                                earnedPointsToday: points, serverTime: serverTime)
    }
    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt {
        claims += 1
        let award = min(12, 72 - points)
        points += award
        return CheckInCollectionReceipt(checkIn: item(1, collected: true), awardedPoints: award,
                                        walletBalance: 10_000 + award, dailyEarnedPoints: points,
                                        localDate: CheckInProgressSnapshot.day(serverTime))
    }
}

private actor ResetReplayFixture: CheckInProgressServing {
    private let serverTime = ISO8601DateFormatter().date(from: "2026-09-25T13:59:00Z")!
    private var replaying = false

    func restartSameVenue() { replaying = true }

    func fetchProgress() async throws -> CheckInProgressSnapshot {
        let item = VenueCheckInProgress(
            id: "same-attempt", venueID: 7, venueName: "Replay Vet", photo: nil,
            requiredSeconds: 180, verifiedSeconds: replaying ? 60 : 180,
            status: replaying ? .inProgress : .collected, updatedAt: serverTime,
            rewardPoints: 12, collectedAt: replaying ? nil : serverTime,
            walkRequestID: replaying ? UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000") : nil,
            isReplayable: replaying
        )
        return CheckInProgressSnapshot(
            items: [item], localDate: CheckInProgressSnapshot.day(serverTime),
            earnedPointsToday: 72, serverTime: serverTime
        )
    }

    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt {
        throw APIError.invalidResponse
    }
}
