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
        let pending = store.presentation(for: store.venues[0], at: clock)
        XCTAssertEqual(pending.state, .accumulating)
        XCTAssertEqual(pending.displayedSeconds, 140)
        XCTAssertTrue(pending.isPendingVerification)
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

    func testOlderStaleOrInaccurateFixDoesNotPauseNewerReliableVisit() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: clock)])
        await store.load()

        clock = clock.addingTimeInterval(20)
        await service.setVerifiedSeconds(20)
        let currentFix = fix(at: clock)
        store.receiveLocations([currentFix])
        await store.load()
        clock = clock.addingTimeInterval(1)
        store.receiveLocations([
            fix(at: origin),
            fix(at: currentFix.timestamp.addingTimeInterval(-1), accuracy: 40),
            currentFix,
        ])
        await store.load()

        let pauses = await service.pauses
        let contexts = await service.contexts
        let locations = await service.locations
        XCTAssertEqual(pauses, 0)
        XCTAssertFalse(contexts.contains { $0.state == "PAUSED" })
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(store.latestLocation?.timestamp, currentFix.timestamp)
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 20)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
    }

    func testCachedPreviewBeforeStartDoesNotPauseRecordingContext() async {
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { self.origin })
        store.updateWalk(id: UUID(), startedAt: origin, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: origin.addingTimeInterval(-1))])
        await store.load()
        let beforeFirstFix = await service.contexts
        let beforeFirstLocations = await service.locations
        XCTAssertEqual(beforeFirstFix.map(\.state), ["RECORDING"])
        XCTAssertTrue(beforeFirstLocations.isEmpty)
        XCTAssertNil(store.latestLocation)

        store.receiveLocations([fix(at: origin)])
        await store.load()
        let contexts = await service.contexts
        let locations = await service.locations
        XCTAssertEqual(contexts.map(\.state), ["RECORDING"])
        XCTAssertEqual(locations.count, 1)
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
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
        XCTAssertTrue(store.presentation(for: store.venues[0]).isPendingVerification)
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

    func testTestResetDropsServerOmittedSessionAndRestartsTheSameWalk() async throws {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let walkID = UUID()
        store.updateWalk(id: walkID, startedAt: clock, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let staleSessionID = try XCTUnwrap(store.sessions[1]?.id)
        let startsBeforeReset = await service.starts
        XCTAssertEqual(startsBeforeReset, 1)

        await service.simulateTestReset()
        await store.load()
        XCTAssertEqual(store.sessions[1]?.id, staleSessionID, "Ordinary polling must retain a receipt omitted by a stale GET")

        let contextsBeforeReset = await service.contexts.count
        await store.resetForTesting()
        XCTAssertEqual(store.walkRequestID, walkID)
        XCTAssertTrue(store.isWalking)
        XCTAssertNil(store.latestLocation)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .outside)
        let contextsAfterReset = await service.contexts
        XCTAssertEqual(contextsAfterReset.count, contextsBeforeReset + 1)
        XCTAssertEqual(contextsAfterReset.last?.walkRequestID, walkID)
        XCTAssertEqual(contextsAfterReset.last?.state, "RECORDING")

        clock = clock.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let replacementSessionID = try XCTUnwrap(store.sessions[1]?.id)
        let startsAfterReset = await service.starts
        let reportedCheckInIDs = await service.reportedCheckInIDs
        XCTAssertNotEqual(replacementSessionID, staleSessionID)
        XCTAssertEqual(startsAfterReset, 2)
        XCTAssertTrue(reportedCheckInIDs.isEmpty,
                      "Fresh GPS after reset must start a new attempt instead of reporting the deleted ID")
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

    func testVenueRadiusControlsInsideBoundary() {
        let standardVenue = WalkVenueFixture.venue()
        let expandedVenue = WalkVenueFixture.venue(radius: 50)
        let fortyMetresAway = fix(at: origin, longitude: 145.00045)
        let sixtyMetresAway = fix(at: origin, longitude: 145.0007)
        XCTAssertEqual(fortyMetresAway.distance(from: fix(at: origin)), 40, accuracy: 1)
        XCTAssertGreaterThan(sixtyMetresAway.distance(from: fix(at: origin)), 50)
        XCTAssertFalse(WalkVenueCheckInStore.isInside(fortyMetresAway, venue: standardVenue))
        XCTAssertTrue(WalkVenueCheckInStore.isInside(fortyMetresAway, venue: expandedVenue))
        XCTAssertFalse(WalkVenueCheckInStore.isInside(sixtyMetresAway, venue: expandedVenue))
    }

    func testExpandedRadiusRecordsInsideFiftyMetresWithReliableGPSOnly() async {
        var clock = origin
        let service = WalkVenueFixture(radius: 50)
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        store.receiveLocations([fix(at: clock, accuracy: 21, longitude: 145.00045)])
        await store.load()
        let unreliableRequests = await service.locations
        XCTAssertTrue(unreliableRequests.isEmpty)
        XCTAssertFalse(store.hasVerifiedVenueActivity(at: clock))

        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, longitude: 145.00045)])
        await store.load()
        let reliableRequests = await service.locations
        XCTAssertEqual(reliableRequests.count, 1)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
        XCTAssertTrue(store.hasVerifiedVenueActivity(at: clock))

        clock = clock.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, longitude: 145.0007)])
        await store.load()
        let outsideRequests = await service.locations
        let pauses = await service.pauses
        XCTAssertEqual(outsideRequests.count, 1)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .outside)
        XCTAssertFalse(store.hasVerifiedVenueActivity(at: clock))
    }

    func testTwentyMetreVenueAndMessages() {
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

    func testLiveDisplayTicksEachSecondWithoutChangingVerifiedProgress() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        for seconds in 1...3 {
            clock = origin.addingTimeInterval(Double(seconds))
            let presentation = store.presentation(for: store.venues[0])
            XCTAssertEqual(presentation.displayedSeconds, 40 + seconds)
            XCTAssertEqual(presentation.verifiedSeconds, 40)
            XCTAssertEqual(presentation.state, .accumulating)
        }
        let requests = await service.locations
        XCTAssertEqual(requests.count, 1, "A display tick must not manufacture GPS reports")
    }

    func testLiveDisplayWaitsForServerPauseAndResumesFromVerifiedReceipt() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()

        await service.holdPause()
        clock = origin.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await service.waitForPause()
        clock = origin.addingTimeInterval(12)
        let pending = store.presentation(for: store.venues[0])
        XCTAssertEqual(pending.displayedSeconds, 52)
        XCTAssertEqual(pending.state, .accumulating)
        XCTAssertTrue(pending.isPendingVerification)
        await service.releasePause()
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 40)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .outside)
        clock = origin.addingTimeInterval(20)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 41)
        XCTAssertEqual(store.presentation(for: store.venues[0]).verifiedSeconds, 40)
    }

    func testAccumulatingReceiptsKeepDisplayMonotonicButServerPauseCorrectsIt() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        clock = origin.addingTimeInterval(10.75)
        await service.setVerifiedSeconds(45)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 50)
        XCTAssertEqual(store.sessions[1]?.verifiedSeconds, 45)
        clock = origin.addingTimeInterval(11)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 51,
                       "A receipt must preserve the running clock's fractional second")
        clock = origin.addingTimeInterval(21)
        await service.setVerifiedSeconds(48)
        await service.setAccumulating(false)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        let paused = store.presentation(for: store.venues[0])
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.displayedSeconds, 48)
        XCTAssertEqual(paused.verifiedSeconds, 48)
    }

    func testProjectedTargetWaitsForReadyAndOfflineDisplayIsMarkedPending() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(179)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        await service.setFetchFailure(true)
        clock = origin.addingTimeInterval(5)
        await store.load()
        let pending = store.presentation(for: store.venues[0])
        XCTAssertEqual(pending.displayedSeconds, 180)
        XCTAssertEqual(pending.verifiedSeconds, 179)
        XCTAssertEqual(pending.state, .accumulating)
        XCTAssertEqual(pending.message, "Confirming check-in…")
        XCTAssertTrue(pending.isPendingVerification)
        XCTAssertEqual(store.sessions[1]?.status, .inProgress)
        await service.setFetchFailure(false)
        await service.setVerifiedSeconds(180)
        clock = origin.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .ready)
        XCTAssertEqual(store.presentation(for: store.venues[0]).verifiedSeconds, 180)
    }

    func testExplicitPauseFinishAndNewWalkStopOrResetLiveDisplay() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        let id = UUID()
        store.updateWalk(id: id, startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        clock = clock.addingTimeInterval(3)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 43)
        store.updateWalk(id: id, startedAt: origin, status: .paused)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 40)
        store.updateWalk(id: id, startedAt: origin, status: .finished)
        await store.load()
        clock = clock.addingTimeInterval(10)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 40)
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 0)
    }

    func testDelayedPausedGETCannotOverwriteNewerAccumulatingReceipt() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        await service.setSessionAccumulating(false)
        await service.holdFetch()
        let polling = Task { await store.load() }
        await service.waitForFetch()

        clock = origin.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock)])
        await store.load() // Drain the POST; the earlier polling GET is still held.
        XCTAssertEqual(store.sessions[1]?.isAccumulating, true)
        await service.releaseFetch()
        await polling.value
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(store.sessions[1]?.isAccumulating, true)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 51)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .accumulating)
    }

    func testDelayedAccumulatingGETCannotUndoConfirmedPause() async {
        var clock = origin
        let service = WalkVenueFixture()
        let store = WalkVenueCheckInStore(service: service, now: { clock })
        store.updateWalk(id: UUID(), startedAt: clock, status: .walking)
        await store.load()
        await service.setVerifiedSeconds(40)
        store.receiveLocations([fix(at: clock)])
        await store.load()
        await service.holdFetch()
        let polling = Task { await store.load() }
        await service.waitForFetch()

        clock = origin.addingTimeInterval(10)
        store.receiveLocations([fix(at: clock, longitude: 145.001)])
        await store.load() // Drain pause acknowledgement while the old GET waits.
        XCTAssertEqual(store.sessions[1]?.isAccumulating, false)
        await service.releaseFetch()
        await polling.value
        clock = clock.addingTimeInterval(1)
        XCTAssertEqual(store.sessions[1]?.isAccumulating, false)
        XCTAssertEqual(store.presentation(for: store.venues[0]).displayedSeconds, 40)
        XCTAssertEqual(store.presentation(for: store.venues[0]).state, .outside)
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
        for scheme in [ColorScheme.light, .dark] {
        for state in [WalkVenuePresentation.State.outside, .accumulating, .paused, .ready, .collected, .unavailable] {
            let presentation = WalkVenuePresentation(state: state, verifiedSeconds: 90, requiredSeconds: 180, category: "Vet")
            let content = VStack(spacing: 20) {
                Text("Venue check-in").font(.title)
                WalkVenueMarker(venue: WalkVenueFixture.venue(), presentation: presentation,
                    reduceMotionOverride: true, action: {})
                Text(presentation.message)
                Text("Veterinary clinic · 1 Test Street · stay 3 min within 20 metres")
            }
            .padding(24)
            .frame(width: 393, height: 500)
            .environment(\.dynamicTypeSize, .accessibility1)
            .environment(\.colorScheme, scheme)
            .vitailAppearance()
            let renderer = ImageRenderer(content: content)
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "SCRUM-57-Venue-\(state)-\(scheme)-Reduce-Motion-Large-Text"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        }
    }

    private func fix(at date: Date, accuracy: Double = 5, longitude: Double = 145) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -37.8, longitude: longitude), altitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: date)
    }
}

private actor WalkVenueFixture: WalkVenueCheckInServing {
    private let radius: Int
    private(set) var contexts: [VenueWalkContext] = []
    private(set) var locations: [WalkVenueLocationRequest] = []
    private(set) var pauses = 0
    private(set) var starts = 0
    private(set) var reportedCheckInIDs: [UUID] = []
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
    private var accumulatingOverride: Bool?
    private var fetchFails = false
    private var holdingPause = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var enteredPause: CheckedContinuation<Void, Never>?
    private var holdingFetch = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var enteredFetch: CheckedContinuation<Void, Never>?
    private var id = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    init(radius: Int = 20) { self.radius = radius }
    func setVerifiedSeconds(_ value: Int) { seconds = value }
    func setPauseFailures(_ value: Int) { pauseFailures = value }
    func setFinishFailure(_ value: Bool) { finishFails = value }
    func setContextPauseFailure(_ value: Bool) { contextPauseFails = value }
    func setHiddenSession(_ value: Bool) { hiddenSession = value }
    func simulateTestReset() {
        session = nil
        seconds = 0
        collected = false
        hiddenSession = false
        id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    }
    func failNextStartResponse() { startResponseFails = true }
    func setCollected(_ value: Bool) { collected = value }
    func setAccumulating(_ value: Bool) { accumulatingOverride = value }
    func setFetchFailure(_ value: Bool) { fetchFails = value }
    func setSessionAccumulating(_ value: Bool) { session?.isAccumulating = value }
    func holdFetch() { holdingFetch = true }
    func waitForFetch() async {
        if fetchContinuation != nil { return }
        await withCheckedContinuation { enteredFetch = $0 }
    }
    func releaseFetch() { holdingFetch = false; fetchContinuation?.resume(); fetchContinuation = nil }
    func holdPause() { holdingPause = true }
    func waitForPause() async {
        if pauseContinuation != nil { return }
        await withCheckedContinuation { enteredPause = $0 }
    }
    func releasePause() { holdingPause = false; pauseContinuation?.resume(); pauseContinuation = nil }
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
    nonisolated static func venue(session: VenueCheckInSession? = nil, radius: Int = 20) -> CheckInVenue {
        CheckInVenue(id: 1, name: "Vet", kindRaw: "VET", description: "Veterinary clinic", address: "1 Test Street",
            openingHours: "", latitude: -37.8, longitude: 145, checkinRadiusM: radius, requiredSeconds: 180,
            checkInStatus: "AVAILABLE", checkIn: session)
    }
    func fetchVenues(walkRequestID: UUID?) async throws -> [CheckInVenue] {
        if fetchFails { throw APIError.network("Venue response unavailable") }
        let result = [Self.venue(session: !hiddenSession && session?.walkRequestID == walkRequestID ? session : nil, radius: radius)]
        if holdingFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
                enteredFetch?.resume(); enteredFetch = nil
            }
        }
        return result
    }
    func updateContext(_ context: VenueWalkContext) async throws {
        contexts.append(context)
        if context.state == "FINISHED", finishFails { throw APIError.network("Finish response interrupted") }
        if context.state == "PAUSED", contextPauseFails { throw APIError.network("Pause context interrupted") }
    }
    func start(venueID: Int, request: WalkVenueLocationRequest) async throws -> VenueCheckInSession {
        starts += 1
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
        reportedCheckInIDs.append(checkInID)
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
        if holdingPause {
            await withCheckedContinuation { continuation in
                pauseContinuation = continuation
                enteredPause?.resume(); enteredPause = nil
            }
        }
        session?.isAccumulating = false
    }
    private func result(_ request: WalkVenueLocationRequest) -> VenueCheckInSession {
        locations.append(request)
        let result = VenueCheckInSession(id: id, venueID: 1, venueName: "Vet", status: collected ? .collected : seconds >= 180 ? .ready : .inProgress,
            requiredSeconds: 180, verifiedSeconds: seconds, rewardPoints: 12,
            walkRequestID: request.walkRequestID, isAccumulating: accumulatingOverride ?? (seconds < 180))
        session = result
        return result
    }
}
