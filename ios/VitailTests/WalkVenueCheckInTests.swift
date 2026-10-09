import CoreLocation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class WalkVenueCheckInTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testVenueRecordingRequiresActiveWalkAndCapturedFreshGPS() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        await store.load()
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let beforeStart = await service.locations
        XCTAssertTrue(beforeStart.isEmpty)
        let id = UUID()
        store.updateWalk(id: id, startedAt: clock, status: .walking)
        await store.load()
        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, accuracy: 21), fix(at: clock.addingTimeInterval(1), accuracy: 5)])
        await store.load()
        let recorded = await service.locations
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.walkRequestID, id)
        XCTAssertEqual(recorded.first?.recordedAt, WalkTimestamp.string(clock.addingTimeInterval(1)))
        let contexts = await service.contexts
        XCTAssertEqual(contexts.first?.state, "RECORDING")
        XCTAssertTrue(contexts.contains { $0.state == "PAUSED" })
        XCTAssertEqual(contexts.last?.state, "RECORDING")
    }

    func testDuplicateFixAndClientTimeDoNotAdvanceVerifiedDwell() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        let sample = fix(at: clock)
        store.receiveLocations([sample, sample])
        await store.load()
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 40)
        clock = clock.addingTimeInterval(100)
        store.receiveLocations([sample])
        await store.load()
        let requests = await service.locations
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 40)
        XCTAssertEqual(store.presentation(for: store.venues[0], at: clock).state, .paused)
    }

    func testInvalidFutureFixCannotPoisonOrderingWatermark() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        store.updateWalk(id: UUID(), startedAt: origin, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: origin.addingTimeInterval(3_600))])
        await store.load()
        store.receiveLocations([fix(at: origin)])
        await store.load()
        let requests = await service.locations
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sequence, WalkVenueCheckInStore.sequence(for: origin))
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
    }

    func testLeavingPausesAndReturningSameWalkKeepsAccumulatedProgress() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let id = UUID()
        store.updateWalk(id: id, startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(45)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await store.load()
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 45)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .outside)
        let paused = await service.pauses
        XCTAssertEqual(paused, 1)
        clock = clock.addingTimeInterval(20)
        await service.setVerifiedSeconds(60)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 60)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
        let requests = await service.locations
        XCTAssertEqual(requests.map(\.walkRequestID), [id, id])
    }

    func testReadyIsRetainedOutsideButIncompleteProgressDoesNotReachNextWalk() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let first = UUID()
        store.updateWalk(id: first, startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(180)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .ready)
        XCTAssertEqual(store.presentation(for: store.venues[0]).message, "Check-in complete. Finish your walk.")
        store.updateWalk(id: first, startedAt: origin, status: .finished)
        await store.load()
        XCTAssertEqual(store.sessions[1]?.status, .ready)
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.presentation(for: store.venues[0]).progress, 0)
    }

    func testUnreliableFixStopsActivityWithoutClearingVerifiedProgress() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(120)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        XCTAssertTrue(store.hasVerifiedVenueActivity(at: clock))
        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, accuracy: 40)])
        await store.load()
        XCTAssertFalse(store.hasVerifiedVenueActivity(at: clock))
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 120)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .paused)
    }

    func testFailedExitRemainsBarrierUntilPauseIsConfirmedBeforeReentry() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: clock)])
        await store.load()
        await service.setPauseFailures(2)
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await store.load()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let blocked = await service.locations
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .paused)
        XCTAssertFalse(store.hasVerifiedVenueActivity(at: clock))
        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let resumed = await service.locations
        let pauseAttempts = await service.pauses
        XCTAssertEqual(resumed.count, 2)
        XCTAssertEqual(pauseAttempts, 3)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
    }

    func testUnconfirmedTerminalStateRetainsReadyAndRetriesSameContext() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        let id = UUID()
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(180)
        store.receiveLocations([fix(at: origin)])
        await store.load()
        await service.setFinishFailure(true)
        store.updateWalk(id: id, startedAt: origin, status: .finished)
        await store.load()
        XCTAssertTrue(store.requiresTerminalConfirmation)
        XCTAssertEqual(store.sessions[1]?.status, .ready)
        let request = WalkRequest(requestID: id, startedAt: WalkTimestamp.string(origin),
            endedAt: WalkTimestamp.string(origin.addingTimeInterval(200)), dogIDs: [1], samples: [])
        let failed = await store.prepareForSettlement(request: request)
        XCTAssertFalse(failed)
        XCTAssertTrue(store.requiresTerminalConfirmation)
        var terminalCallbacks = 0
        store.onTerminalConfirmed = { terminalCallbacks += 1 }
        await service.setFinishFailure(false)
        let retried = await store.prepareForSettlement(request: request)
        XCTAssertTrue(retried)
        XCTAssertFalse(store.requiresTerminalConfirmation)
        XCTAssertEqual(terminalCallbacks, 1)
        XCTAssertEqual(store.sessions[1]?.status, .ready)
        let contexts = await service.contexts
        XCTAssertTrue(contexts.allSatisfy { $0.walkRequestID == id })
    }

    func testPauseBarrierIncludesStartWhoseResponseIsStillPending() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let id = UUID()
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await store.load()
        await service.holdStart()
        store.receiveLocations([fix(at: clock)])
        await service.waitForStart()
        XCTAssertTrue(store.sessions.isEmpty)
        await service.setPauseFailures(2)
        await service.setContextPauseFailure(true)
        store.updateWalk(id: id, startedAt: origin, status: .paused)
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await service.releaseStart()
        await store.load()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let blocked = await service.locations
        XCTAssertEqual(blocked.count, 1)
        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let resumed = await service.locations
        let pauses = await service.pauses
        XCTAssertEqual(resumed.count, 2)
        XCTAssertEqual(pauses, 3)
    }

    func testLocalOnlyFinishCanRetryTerminalStateWithoutUpload() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        let id = UUID()
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: origin)])
        await store.load()
        await service.setFinishFailure(true)
        store.updateWalk(id: id, startedAt: origin, status: .finished)
        await store.load()
        XCTAssertTrue(store.requiresTerminalConfirmation)
        var callbacks = 0
        store.onTerminalConfirmed = { callbacks += 1 }
        await service.setFinishFailure(false)
        await store.load()
        XCTAssertFalse(store.requiresTerminalConfirmation)
        XCTAssertEqual(callbacks, 1)
    }

    func testPollingTerminalRetryDrainsReportsQueuedAfterLoadStarted() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let id = UUID()
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await store.load()
        await service.holdStart()
        store.receiveLocations([fix(at: clock)])
        await service.waitForStart()
        let polling = Task { await store.load() }
        await Task.yield()
        await service.holdReport()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        store.updateWalk(id: id, startedAt: origin, status: .finished)
        await service.releaseStart()
        await service.waitForReport()
        for _ in 0..<10 { await Task.yield() }
        let beforeReportReply = await service.contexts
        XCTAssertFalse(beforeReportReply.contains { $0.state == "FINISHED" })
        await service.releaseReport()
        await polling.value
        let contexts = await service.contexts
        XCTAssertEqual(contexts.last?.state, "FINISHED")
        XCTAssertFalse(store.requiresTerminalConfirmation)
    }

    func testLostStartResponseRequiresContextResetBeforeReentry() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setHiddenSession(true)
        await service.failNextStartResponse()
        store.receiveLocations([fix(at: clock)])
        await store.load()
        XCTAssertTrue(store.sessions.isEmpty)
        await service.setContextPauseFailure(true)
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await store.load()
        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let blocked = await service.locations
        XCTAssertEqual(blocked.count, 1)
        XCTAssertFalse(store.hasVerifiedVenueActivity(at: clock))
        await service.setContextPauseFailure(false)
        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let resumed = await service.locations
        let contexts = await service.contexts
        XCTAssertEqual(resumed.count, 2)
        XCTAssertEqual(contexts.last?.state, "RECORDING")
        XCTAssertTrue(contexts.contains { $0.state == "PAUSED" })
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 0)
    }

    func testCollectedMapReceiptExpiresWhenServerOpensNewDay() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        store.updateWalk(id: UUID(), startedAt: origin, status: .walking)
        await store.load()
        await service.setCollected(true)
        store.receiveLocations([fix(at: origin)])
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .collected)
        await service.setCollected(false)
        await service.setHiddenSession(true)
        await store.load()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNotEqual(store.presentation(for: store.venues[0]).state, .collected)
    }

    func testInRadiusVenueActivityAllowsTenMinuteStationaryWalk() {
        var clock = origin
        let tracker = WalkSessionTracker(now: { clock })
        tracker.enforcesRewardLimits = true
        tracker.hasVenueActivity = { date in date <= self.origin.addingTimeInterval(600) }
        tracker.start(from: fix(at: clock), dogs: [])
        clock = clock.addingTimeInterval(600)
        tracker.checkInactivity()
        XCTAssertEqual(tracker.status, .walking)
        clock = clock.addingTimeInterval(301)
        tracker.checkInactivity()
        XCTAssertEqual(tracker.status, .finished)
    }

    func testFinishFlushUsesSameUUIDAndNeverCallsRewardCollection() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        let id = UUID()
        store.updateWalk(id: id, startedAt: origin, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: origin)])
        store.updateWalk(id: id, startedAt: origin, status: .finished)
        let request = WalkRequest(requestID: id, startedAt: WalkTimestamp.string(origin),
            endedAt: WalkTimestamp.string(origin.addingTimeInterval(200)), dogIDs: [1], samples: [])
        let flushed = await store.prepareForSettlement(request: request)
        XCTAssertTrue(flushed)
        let contexts = await service.contexts
        XCTAssertEqual(contexts.last?.state, "FINISHED")
        XCTAssertTrue(contexts.allSatisfy { $0.walkRequestID == id })
        XCTAssertEqual(store.sessions[1]?.status, .inProgress)
        // There is intentionally no collect operation on WalkVenueCheckInServing.
    }

    func testOldOrdinaryWalkCanUploadWithoutVenueContext() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service)
        let request = WalkRequest(requestID: UUID(), startedAt: WalkTimestamp.string(origin),
            endedAt: WalkTimestamp.string(origin.addingTimeInterval(100)), dogIDs: [1], samples: [])
        let flushed = await store.prepareForSettlement(request: request)
        XCTAssertTrue(flushed)
        let contexts = await service.contexts
        XCTAssertTrue(contexts.isEmpty)
    }

    func testTwentyMetreBoundaryAndMessages() {
        let venue = WalkVenueFixture.venue()
        XCTAssertTrue(WalkVenueCheckInStore.isInside(fix(at: origin), venue: venue))
        XCTAssertFalse(WalkVenueCheckInStore.isInside(fix(at: origin, longitude: 145.001), venue: venue))
        XCTAssertEqual(WalkVenuePresentation(state: .accumulating, verifiedSeconds: 121, requiredSeconds: 180, category: "Vet").message,
            "Stay here for less than a minute to get points")
        XCTAssertEqual(WalkVenuePresentation(state: .accumulating, verifiedSeconds: 60, requiredSeconds: 180, category: "Vet").message,
            "Stay here for 2 more minutes to get points")
        XCTAssertEqual(CheckInVenueKind.cafe.rewardCategoryTitle, "Partner")
        XCTAssertEqual(CheckInVenueKind.restaurant.rewardCategoryTitle, "Partner")
    }

    func testSummaryDecodesActualPartialAwardsAndLegacyReceipts() throws {
        let prefix = #"{"id":1,"request_id":"00000000-0000-0000-0000-000000000100","started_at":"2026-10-09T01:00:00Z","ended_at":"2026-10-09T02:00:00Z","distance_m":1000,"points_awarded":8,"point_date":"2026-10-09","dog_ids":[1]"#
        let legacy = try JSONDecoder().decode(WalkSummary.self, from: Data((prefix + "}").utf8))
        XCTAssertEqual(legacy.settledTotalPoints, 8)
        XCTAssertTrue(legacy.checkInAwards.isEmpty)
        let receipt = try JSONDecoder().decode(WalkSummary.self, from: Data((prefix + #", "check_in_awards":[{"id":"visit-1","venue_id":1,"venue_name":"Vet","kind":"VET","reward_category":"VET","awarded_points":2}],"check_in_points_awarded":2,"net_points_awarded":4,"total_points_awarded":14,"wallet_balance":100}"#).utf8))
        XCTAssertEqual(receipt.checkInAwards.first?.awardedPoints, 2)
        XCTAssertEqual(receipt.settledTotalPoints, 14)
        XCTAssertEqual(receipt.walletBalance, 100)
        XCTAssertEqual(try JSONDecoder().decode(WalkSummary.self, from: JSONEncoder().encode(receipt)), receipt)
    }

    func testVenueStatesRenderWithReduceMotionAndLargeText() async throws {
        for state in [WalkVenuePresentation.State.outside, .accumulating, .paused, .ready, .collected, .unavailable] {
            let presentation = WalkVenuePresentation(state: state, verifiedSeconds: 90, requiredSeconds: 180, category: "Vet")
            let content = VStack(spacing: 20) {
                Text("Venue check-in").font(.title)
                WalkVenueMarker(venue: WalkVenueFixture.venue(), presentation: presentation, action: {})
                Text(presentation.message)
                Text("Veterinary clinic · 1 Test Street · stay 3 min within 20 metres")
            }
            .padding(24)
            .frame(width: 393, height: 500)
            .environment(\.accessibilityReduceMotion, true)
            .environment(\.dynamicTypeSize, .accessibility1)
            .vitailAppearance()
            let renderer = ImageRenderer(content: content)
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "SCRUM-57-Venue-\(state)-Reduce-Motion-Large-Text"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func fix(at date: Date, accuracy: Double = 5, longitude: Double = 145) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -37.8, longitude: longitude), altitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: date)
    }
}

private actor WalkVenueFixture: WalkVenueCheckInServing {
    private(set) var contexts: [VenueWalkContext] = []
    private(set) var locations: [WalkVenueLocationRequest] = []
    private(set) var pauses = 0
    private var seconds = 0
    private var session: VenueCheckInSession?
    private var pauseFailures = 0
    private var finishFails = false
    private var contextPauseFails = false
    private var holdingStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var enteredStart: CheckedContinuation<Void, Never>?
    private var holdingReport = false
    private var reportContinuation: CheckedContinuation<Void, Never>?
    private var enteredReport: CheckedContinuation<Void, Never>?
    private var startResponseFails = false
    private var hiddenSession = false
    private var collected = false
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    func setVerifiedSeconds(_ value: Int) { seconds = value }
    func setPauseFailures(_ value: Int) { pauseFailures = value }
    func setFinishFailure(_ value: Bool) { finishFails = value }
    func setContextPauseFailure(_ value: Bool) { contextPauseFails = value }
    func setHiddenSession(_ value: Bool) { hiddenSession = value }
    func failNextStartResponse() { startResponseFails = true }
    func setCollected(_ value: Bool) { collected = value }
    func holdStart() { holdingStart = true }
    func waitForStart() async {
        if startContinuation != nil { return }
        await withCheckedContinuation { enteredStart = $0 }
    }
    func releaseStart() { holdingStart = false; startContinuation?.resume(); startContinuation = nil }
    func holdReport() { holdingReport = true }
    func waitForReport() async {
        if reportContinuation != nil { return }
        await withCheckedContinuation { enteredReport = $0 }
    }
    func releaseReport() { holdingReport = false; reportContinuation?.resume(); reportContinuation = nil }
    nonisolated static func venue(session: VenueCheckInSession? = nil) -> CheckInVenue {
        CheckInVenue(id: 1, name: "Vet", kindRaw: "VET", description: "Veterinary clinic", address: "1 Test Street",
            openingHours: "", latitude: -37.8, longitude: 145, checkinRadiusM: 20, requiredSeconds: 180,
            checkInStatus: "AVAILABLE", checkIn: session)
    }
    func fetchVenues(walkRequestID: UUID?) async throws -> [CheckInVenue] {
        [Self.venue(session: !hiddenSession && session?.walkRequestID == walkRequestID ? session : nil)]
    }
    func updateContext(_ context: VenueWalkContext) async throws {
        contexts.append(context)
        if context.state == "FINISHED", finishFails { throw APIError.network("Finish response interrupted") }
        if context.state == "PAUSED", contextPauseFails { throw APIError.network("Pause context interrupted") }
    }
    func start(venueID: Int, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession {
        let response = result(request)
        if holdingStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
                enteredStart?.resume(); enteredStart = nil
            }
        }
        if startResponseFails { startResponseFails = false; throw APIError.network("Start response lost") }
        return response
    }
    func report(checkInID: UUID, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession {
        let response = result(request)
        if holdingReport {
            await withCheckedContinuation { continuation in
                reportContinuation = continuation
                enteredReport?.resume(); enteredReport = nil
            }
        }
        return response
    }
    func pause(checkInID: UUID) async throws {
        pauses += 1
        if pauseFailures > 0 { pauseFailures -= 1; throw APIError.network("Pause response interrupted") }
    }
    private func result(_ request: WalkVenueLocationRequest) -> VenueCheckInSession {
        locations.append(request)
        let result = VenueCheckInSession(id: id, venueID: 1, venueName: "Vet", status: collected ? .collected : seconds >= 180 ? .ready : .inProgress,
            requiredSeconds: 180, verifiedSeconds: seconds, rewardPoints: 12,
            walkRequestID: request.walkRequestID, isAccumulating: seconds < 180)
        session = result
        return result
    }
}
