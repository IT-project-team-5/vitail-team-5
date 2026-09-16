import CoreLocation
import Foundation
import XCTest
@testable import Vitail

@MainActor
final class WalkBackgroundTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_789_000_000)

    func testFreshLocationRequiresRecentAccurateValidCoordinates() {
        XCTAssertTrue(WalkSessionTracker.isFresh(location(seconds: -15), at: referenceDate))
        XCTAssertTrue(WalkSessionTracker.isFresh(location(seconds: 5), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(location(seconds: -15.01), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(location(seconds: 5.01), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(location(accuracy: 31), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(location(accuracy: -1), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(location(latitude: 91), at: referenceDate))
        XCTAssertFalse(WalkSessionTracker.isFresh(nil, at: referenceDate))
    }

    func testBatchProcessesEveryLocationInTimestampOrder() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let first = location()
        let second = location(latitude: -37.8130, seconds: 10)
        let third = location(latitude: -37.8125, seconds: 20)
        let fourth = location(latitude: -37.8120, seconds: 30)
        tracker.start(from: first, dogs: [dog()])
        now = referenceDate.addingTimeInterval(35)

        tracker.recordBatch([fourth, second, third])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [4])
        XCTAssertEqual(tracker.routeSegments[0].map(\.timestamp), [first, second, third, fourth].map(\.timestamp))
        XCTAssertEqual(
            tracker.distanceMetres,
            second.distance(from: first) + third.distance(from: second) + fourth.distance(from: third),
            accuracy: 0.001
        )
    }

    func testBufferedBatchDoesNotRejectSamplesSimplyBecauseTheyAreOlderThanFifteenSeconds() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(40)

        tracker.recordBatch([
            location(latitude: -37.8130, seconds: 10),
            location(latitude: -37.8125, seconds: 20),
            location(latitude: -37.8120, seconds: 30)
        ])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [4])
        XCTAssertGreaterThan(tracker.distanceMetres, 0)
    }

    func testBatchRejectsSamplesBeforeStartInTheFutureAndWithInvalidAccuracy() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)
        let valid = location(latitude: -37.8130, seconds: 5)

        tracker.recordBatch([
            location(latitude: -37.8000, seconds: -1),
            location(latitude: -37.8000, seconds: 2, accuracy: 31),
            location(latitude: -37.8000, seconds: 15.1),
            valid
        ])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])
        XCTAssertEqual(tracker.routeSegments[0].last?.timestamp, valid.timestamp)
        XCTAssertEqual(tracker.distanceMetres, valid.distance(from: location()), accuracy: 0.001)
    }

    func testRepeatedAndOutOfOrderBatchesDoNotDuplicateDistanceOrRoutePoints() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(30)
        let second = location(latitude: -37.8130, seconds: 10)
        let third = location(latitude: -37.8125, seconds: 20)
        tracker.recordBatch([third, second, second])
        let distance = tracker.distanceMetres
        let route = tracker.routeSegments

        tracker.recordBatch([second, third, location(latitude: -37.8000, seconds: 15)])

        XCTAssertEqual(tracker.routeSegments, route)
        XCTAssertEqual(tracker.distanceMetres, distance)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [3])
    }

    func testPausedAndLateQueuedLocationsCannotEnterTheResumedRoute() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let start = location()
        let beforePause = location(latitude: -37.8130, seconds: 10)
        tracker.start(from: start, dogs: [dog()])
        now = referenceDate.addingTimeInterval(15)
        tracker.recordBatch([beforePause])
        now = referenceDate.addingTimeInterval(20)
        tracker.pause()
        tracker.recordBatch([location(latitude: -37.8000, seconds: 21)])
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])

        now = referenceDate.addingTimeInterval(100)
        tracker.resume(from: nil)
        let anchor = location(latitude: -37.7990, seconds: 101)
        let next = location(latitude: -37.7985, seconds: 110)
        now = referenceDate.addingTimeInterval(115)
        tracker.recordBatch([
            location(latitude: -37.8100, seconds: 18),
            location(latitude: -37.8050, seconds: 50),
            location(latitude: -37.8000, seconds: 99),
            next,
            anchor
        ])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(tracker.routeSegments[1].map(\.timestamp), [anchor.timestamp, next.timestamp])
        XCTAssertEqual(
            tracker.distanceMetres,
            beforePause.distance(from: start) + next.distance(from: anchor),
            accuracy: 0.001
        )
    }

    func testCachedLocationBeforeStartDoesNotCountMovementBeforeTheStartTap() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let cached = location(latitude: -37.8140, seconds: -5)
        XCTAssertTrue(WalkSessionTracker.isFresh(cached, at: now))

        tracker.start(from: cached, dogs: [dog()])

        XCTAssertEqual(tracker.status, .walking)
        XCTAssertTrue(tracker.routeSegments.isEmpty)
        now = referenceDate.addingTimeInterval(5)
        let first = location(latitude: -37.8130, seconds: 5)
        tracker.recordBatch([first])
        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1])
        XCTAssertEqual(tracker.routeSegments[0][0].timestamp, first.timestamp)
        now = referenceDate.addingTimeInterval(10)
        let next = location(latitude: -37.8125, seconds: 10)
        tracker.recordBatch([next])
        XCTAssertEqual(tracker.distanceMetres, next.distance(from: first), accuracy: 0.001)
    }

    func testCachedResumeLocationDoesNotIncludeAnyPausedMovement() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)
        tracker.recordBatch([location(latitude: -37.8130, seconds: 10)])
        let firstDistance = tracker.distanceMetres
        now = referenceDate.addingTimeInterval(20)
        tracker.pause()
        now = referenceDate.addingTimeInterval(100)
        let cached = location(latitude: -37.8050, seconds: 95)
        XCTAssertTrue(WalkSessionTracker.isFresh(cached, at: now))

        tracker.resume(from: cached)

        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])
        now = referenceDate.addingTimeInterval(105)
        let anchor = location(latitude: -37.8000, seconds: 105)
        tracker.recordBatch([anchor])
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2, 1])
        XCTAssertEqual(tracker.distanceMetres, firstDistance)
        now = referenceDate.addingTimeInterval(110)
        let next = location(latitude: -37.7995, seconds: 110)
        tracker.recordBatch([next])
        XCTAssertEqual(tracker.distanceMetres, firstDistance + next.distance(from: anchor), accuracy: 0.001)
    }

    func testLongLocationGapStartsAnotherSegmentWithoutInventingDistance() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let start = location()
        let beforeGap = location(latitude: -37.8130, seconds: 10)
        let afterGap = location(latitude: -37.8000, seconds: 10 + WalkSessionTracker.maximumRouteGap + 1)
        let next = location(latitude: -37.7995, seconds: afterGap.timestamp.timeIntervalSince(referenceDate) + 10)
        tracker.start(from: start, dogs: [dog()])
        now = next.timestamp.addingTimeInterval(1)

        tracker.recordBatch([next, beforeGap, afterGap])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(tracker.routeSegments[1].first?.timestamp, afterGap.timestamp)
        XCTAssertEqual(
            tracker.distanceMetres,
            beforeGap.distance(from: start) + next.distance(from: afterGap),
            accuracy: 0.001
        )
    }

    func testGapAtTheAllowedBoundaryDoesNotSplitTheRoute() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let next = location(latitude: -37.8130, seconds: WalkSessionTracker.maximumRouteGap)
        tracker.start(from: location(), dogs: [dog()])
        now = next.timestamp

        tracker.recordBatch([next])

        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])
        XCTAssertEqual(tracker.distanceMetres, next.distance(from: location()), accuracy: 0.001)
    }

    func testTemporaryInterruptionKeepsWalkingButBreaksTheRoute() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)
        tracker.recordBatch([location(latitude: -37.8130, seconds: 10)])
        let distance = tracker.distanceMetres

        tracker.interruptRoute(message: "GPS signal interrupted.")

        XCTAssertEqual(tracker.status, .walking)
        XCTAssertEqual(tracker.trackingNotice, "GPS signal interrupted.")
        now = referenceDate.addingTimeInterval(20)
        tracker.recordBatch([location(latitude: -37.8000, seconds: 20)])
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2, 1])
        XCTAssertEqual(tracker.distanceMetres, distance)
    }

    func testPermissionInterruptionPausesTimeAndRejectsFurtherLocationUpdates() throws {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(25)

        tracker.pauseForInterruption(message: "Location permission is required.")

        XCTAssertEqual(tracker.status, .paused)
        XCTAssertEqual(tracker.trackingNotice, "Location permission is required.")
        now = referenceDate.addingTimeInterval(200)
        tracker.recordBatch([location(latitude: -37.8000, seconds: 190)])
        tracker.finish()
        let completed = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(completed.activeDuration, 25, accuracy: 0.001)
        XCTAssertEqual(completed.routeSegments.map(\.count), [1])
        XCTAssertEqual(completed.distanceMetres, 0)
    }

    func testIdleAndFinishedTrackersIgnoreLocationBatches() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.recordBatch([location()])
        XCTAssertEqual(tracker.status, .idle)
        XCTAssertTrue(tracker.routeSegments.isEmpty)
        tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)
        tracker.finish()
        let completed = tracker.completedWalk

        now = referenceDate.addingTimeInterval(20)
        tracker.recordBatch([location(latitude: -37.8000, seconds: 20)])

        XCTAssertEqual(tracker.status, .finished)
        XCTAssertEqual(tracker.completedWalk, completed)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1])
    }

    func testCheckpointIncludesOnlyActiveTimeAndUsesOneStableWalkID() throws {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        XCTAssertNil(tracker.makeDraft())
        tracker.start(from: location(), dogs: [dog(), dog(id: 2, name: "Luna")])
        now = referenceDate.addingTimeInterval(20)
        let first = try XCTUnwrap(tracker.makeDraft())
        XCTAssertEqual(first.startedAt, referenceDate)
        XCTAssertEqual(first.checkpointAt, now)
        XCTAssertEqual(first.activeDuration, 20, accuracy: 0.001)
        XCTAssertEqual(first.dogs.map(\.name), ["Milo", "Luna"])
        XCTAssertEqual(first.routeSegments, tracker.routeSegments)
        tracker.pause()
        now = referenceDate.addingTimeInterval(100)
        let paused = try XCTUnwrap(tracker.makeDraft())
        XCTAssertEqual(paused.id, first.id)
        XCTAssertEqual(paused.checkpointAt, now)
        XCTAssertEqual(paused.activeDuration, 20, accuracy: 0.001)

        tracker.finish()

        XCTAssertEqual(tracker.completedWalk?.id, first.id)
        XCTAssertEqual(tracker.completedWalk?.activeDuration, 20)
    }

    func testRecoveredWalkIsPausedWithSavedDogsRouteAndNoUnobservedTime() throws {
        var now = referenceDate
        let original = WalkSessionTracker(now: { now })
        original.start(from: location(), dogs: [dog(), dog(id: 2, name: "Luna")])
        now = referenceDate.addingTimeInterval(10)
        original.recordBatch([location(latitude: -37.8130, seconds: 10)])
        now = referenceDate.addingTimeInterval(20)
        let draft = try XCTUnwrap(original.makeDraft())

        now = referenceDate.addingTimeInterval(500)
        var completed: [WalkRecord] = []
        let recovered = WalkSessionTracker(now: { now }, onFinish: { completed.append($0) })
        XCTAssertTrue(recovered.restore(draft))
        XCTAssertEqual(recovered.status, .paused)
        XCTAssertTrue(recovered.isInProgress)
        XCTAssertEqual(recovered.participatingDogs, draft.dogs)
        XCTAssertEqual(recovered.routeSegments, draft.routeSegments)
        XCTAssertEqual(recovered.distanceMetres, draft.distanceMetres)
        XCTAssertNotNil(recovered.trackingNotice)
        recovered.recordBatch([location(latitude: -37.8000, seconds: 499)])
        XCTAssertEqual(recovered.routeSegments, draft.routeSegments)
        XCTAssertTrue(completed.isEmpty)

        recovered.finish()

        let record = try XCTUnwrap(recovered.completedWalk)
        XCTAssertEqual(record.id, draft.id)
        XCTAssertEqual(record.activeDuration, 20, accuracy: 0.001)
        XCTAssertEqual(record.startedAt, referenceDate)
        XCTAssertEqual(record.endedAt, now)
        XCTAssertEqual(completed, [record])
    }

    func testResumingRecoveredWalkCreatesANewSegmentAndExcludesDowntime() throws {
        var now = referenceDate
        let original = WalkSessionTracker(now: { now })
        original.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)
        original.recordBatch([location(latitude: -37.8130, seconds: 10)])
        now = referenceDate.addingTimeInterval(20)
        let draft = try XCTUnwrap(original.makeDraft())
        now = referenceDate.addingTimeInterval(500)
        let recovered = WalkSessionTracker(now: { now })
        XCTAssertTrue(recovered.restore(draft))
        let anchor = location(latitude: -37.8000, seconds: 500)
        recovered.resume(from: anchor)
        now = referenceDate.addingTimeInterval(510)
        let next = location(latitude: -37.7995, seconds: 510)
        recovered.recordBatch([next])
        now = referenceDate.addingTimeInterval(520)

        recovered.finish()

        let record = try XCTUnwrap(recovered.completedWalk)
        XCTAssertEqual(record.id, draft.id)
        XCTAssertEqual(record.activeDuration, 40, accuracy: 0.001)
        XCTAssertEqual(record.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(record.distanceMetres, draft.distanceMetres + next.distance(from: anchor), accuracy: 0.001)
    }

    func testFinishedDraftCannotBeRestoredAsAnActiveWalk() throws {
        var now = referenceDate
        let original = WalkSessionTracker(now: { now })
        original.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(20)
        let activeDraft = try XCTUnwrap(original.makeDraft())
        original.finish()
        let record = try XCTUnwrap(original.completedWalk)
        let finishedDraft = WalkDraft(
            id: activeDraft.id,
            startedAt: activeDraft.startedAt,
            checkpointAt: now,
            activeDuration: record.activeDuration,
            distanceMetres: record.distanceMetres,
            dogs: activeDraft.dogs,
            routeSegments: record.routeSegments,
            finishedRecord: record
        )
        let recovered = WalkSessionTracker(now: { now })

        XCTAssertFalse(recovered.restore(finishedDraft))

        XCTAssertEqual(recovered.status, .idle)
        XCTAssertFalse(recovered.isInProgress)
        XCTAssertTrue(recovered.routeSegments.isEmpty)
    }

    func testActiveWalkCannotBeOverwrittenByAnotherDraft() throws {
        var now = referenceDate
        let first = WalkSessionTracker(now: { now })
        first.start(from: location(), dogs: [dog()])
        let firstDraft = try XCTUnwrap(first.makeDraft())
        let second = WalkSessionTracker(now: { now })
        second.start(from: location(), dogs: [dog(id: 2, name: "Luna")])
        now = referenceDate.addingTimeInterval(10)
        let secondDraft = try XCTUnwrap(second.makeDraft())

        XCTAssertFalse(first.restore(secondDraft))

        XCTAssertEqual(first.status, .walking)
        XCTAssertEqual(first.participatingDogs.map(\.id), [1])
        XCTAssertEqual(first.makeDraft()?.id, firstDraft.id)
    }

    func testOneChangeCallbackPerAcceptedBatchAndPerLifecycleTransition() {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        var changeCount = 0
        tracker.onChange = { changeCount += 1 }
        tracker.start(from: location(), dogs: [dog()])
        XCTAssertEqual(changeCount, 1)
        now = referenceDate.addingTimeInterval(30)
        tracker.recordBatch([
            location(latitude: -37.8130, seconds: 10),
            location(latitude: -37.8125, seconds: 20),
            location(latitude: -37.8120, seconds: 30)
        ])
        XCTAssertEqual(changeCount, 2)
        tracker.recordBatch([])
        tracker.recordBatch([location(seconds: 10), location(seconds: 20)])
        XCTAssertEqual(changeCount, 2)
        tracker.pause()
        XCTAssertEqual(changeCount, 3)
        tracker.pause()
        XCTAssertEqual(changeCount, 3)
        now = referenceDate.addingTimeInterval(40)
        tracker.resume(from: location(seconds: 40))
        XCTAssertEqual(changeCount, 4)
        now = referenceDate.addingTimeInterval(50)
        tracker.finish()
        XCTAssertEqual(changeCount, 5)
        tracker.finish()
        XCTAssertEqual(changeCount, 5)
    }

    private func dog(id: Int = 1, name: String = "Milo") -> Dog {
        Dog(
            id: id,
            name: name,
            photo: nil,
            breed: Breed(id: 1, name: "Mixed Breed", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false),
            ageMonths: 24,
            size: .medium,
            isBrachycephalic: false,
            createdAt: "2026-09-08T00:00:00Z"
        )
    }

    private func location(latitude: Double = -37.8136, seconds: TimeInterval = 0, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 144.9631),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            timestamp: referenceDate.addingTimeInterval(seconds)
        )
    }
}
