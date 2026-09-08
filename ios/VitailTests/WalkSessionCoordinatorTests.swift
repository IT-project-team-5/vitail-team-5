import CoreLocation
import Foundation
import XCTest
@testable import Vitail

@MainActor
final class WalkSessionCoordinatorTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_789_000_000)

    func testLocationDelegateRecordsWholeBatchAndCheckpointsWithoutAView() {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        XCTAssertEqual(coordinator.locationManager.mode, .recording)
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        let previousSaveCount = drafts.saveCount
        now = referenceDate.addingTimeInterval(30)

        client.deliver([
            location(latitude: -37.8120, seconds: 30),
            location(latitude: -37.8130, seconds: 10),
            location(latitude: -37.8125, seconds: 20)
        ])

        XCTAssertEqual(coordinator.tracker.routeSegments.map(\.count), [4])
        XCTAssertEqual(drafts.draft?.routeSegments, coordinator.tracker.routeSegments)
        XCTAssertEqual(drafts.saveCount, previousSaveCount + 1)
        XCTAssertNil(coordinator.storageErrorMessage)
    }

    func testChangingTabsAndEnteringBackgroundDoesNotStopAnActiveWalk() {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.setWalkPageVisible(true)
        XCTAssertEqual(coordinator.locationManager.mode, .preview)
        coordinator.tracker.start(from: location(), dogs: [dog()])
        let startCount = client.startCount

        coordinator.setWalkPageVisible(false)
        now = referenceDate.addingTimeInterval(10)
        coordinator.setForeground(false)
        now = referenceDate.addingTimeInterval(20)
        client.deliver([location(latitude: -37.8130, seconds: 20)])

        XCTAssertEqual(coordinator.tracker.status, .walking)
        XCTAssertEqual(coordinator.locationManager.mode, .recording)
        XCTAssertEqual(client.startCount, startCount)
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        XCTAssertTrue(client.showsBackgroundLocationIndicator)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(coordinator.tracker.routeSegments.map(\.count), [2])
        XCTAssertEqual(drafts.draft?.activeDuration, 20)
    }

    func testPauseAndFinishStopBackgroundUpdatesAndSaveExactlyOneHistoryRecord() throws {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        coordinator.setForeground(false)
        now = referenceDate.addingTimeInterval(20)

        coordinator.tracker.pause()

        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.showsBackgroundLocationIndicator)
        let route = coordinator.tracker.routeSegments
        now = referenceDate.addingTimeInterval(100)
        client.deliver([location(latitude: -37.8000, seconds: 100)])
        XCTAssertEqual(coordinator.tracker.routeSegments, route)
        coordinator.tracker.finish()
        coordinator.tracker.finish()
        coordinator.retryStorage()

        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(record.activeDuration, 20)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertNil(drafts.draft)
        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(coordinator.storageErrorMessage)
    }

    func testFinishedWalkMayPreviewOnVisiblePageButDoesNotRetainBackgroundTracking() {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let coordinator = makeCoordinator(client: client, now: { now })
        coordinator.setWalkPageVisible(true)
        coordinator.tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(10)

        coordinator.tracker.finish()

        XCTAssertEqual(coordinator.locationManager.mode, .preview)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        coordinator.setForeground(false)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
    }

    func testPermissionLossPausesAndCheckpointsWithoutWaitingForSwiftUI() {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        coordinator.setForeground(false)
        now = referenceDate.addingTimeInterval(25)

        client.authorizationStatus = .denied
        client.notifyAuthorizationChanged()

        XCTAssertEqual(coordinator.tracker.status, .paused)
        XCTAssertNotNil(coordinator.tracker.trackingNotice)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertEqual(drafts.draft?.activeDuration, 25)
        let route = coordinator.tracker.routeSegments
        now = referenceDate.addingTimeInterval(50)
        client.deliver([location(latitude: -37.8000, seconds: 50)])
        XCTAssertEqual(coordinator.tracker.routeSegments, route)
    }

    func testRecoveringAnActiveDraftIsPausedAndDoesNotStartGPSAutomatically() throws {
        var now = referenceDate.addingTimeInterval(500)
        let savedDraft = activeDraft()
        let drafts = CoordinatorDraftStub(draft: savedDraft)
        let client = CoordinatorLocationClientStub()

        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })

        XCTAssertEqual(coordinator.tracker.status, .paused)
        XCTAssertEqual(coordinator.tracker.participatingDogs, savedDraft.dogs)
        XCTAssertEqual(coordinator.tracker.routeSegments, savedDraft.routeSegments)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertTrue(coordinator.history.records.isEmpty)
        now = referenceDate.addingTimeInterval(600)
        coordinator.tracker.finish()
        let finished = try XCTUnwrap(coordinator.history.records.first)
        XCTAssertEqual(finished.id, savedDraft.id)
        XCTAssertEqual(finished.activeDuration, savedDraft.activeDuration)
    }

    func testFinishedDraftIsRetriedIntoHistoryWithStableIDAndNoDuplicate() throws {
        let savedDraft = finishedDraft()
        let drafts = CoordinatorDraftStub(draft: savedDraft)
        let history = CoordinatorHistoryStub()
        history.failSave = true
        let coordinator = makeCoordinator(drafts: drafts, history: history)
        XCTAssertFalse(coordinator.canStartNewWalk)
        XCTAssertNotNil(coordinator.storageErrorMessage)
        XCTAssertEqual(coordinator.tracker.status, .idle)
        XCTAssertEqual(coordinator.history.records.map(\.id), [savedDraft.id])
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(drafts.draft?.finishedRecord?.id, savedDraft.id)

        history.failSave = false
        coordinator.retryStorage()
        coordinator.retryStorage()

        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(coordinator.storageErrorMessage)
        XCTAssertEqual(history.records, [try XCTUnwrap(savedDraft.finishedRecord)])
        XCTAssertEqual(coordinator.history.records.map(\.id), [savedDraft.id])
        XCTAssertNil(drafts.draft)
    }

    func testAlreadySavedHistoryClearsLeftoverDraftWithoutCreatingAnotherRecord() {
        let savedDraft = finishedDraft()
        let drafts = CoordinatorDraftStub(draft: savedDraft)
        let history = CoordinatorHistoryStub(records: [savedDraft.finishedRecord!])

        let coordinator = makeCoordinator(drafts: drafts, history: history)

        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(drafts.draft)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.saveCount, 0)
        XCTAssertEqual(coordinator.tracker.status, .idle)
    }

    func testUnreadableDraftBlocksNewWalkAndDoesNotOverwriteUntilRetrySucceeds() {
        let savedDraft = activeDraft()
        let drafts = CoordinatorDraftStub(draft: savedDraft)
        drafts.failLoad = true
        let coordinator = makeCoordinator(drafts: drafts)
        XCTAssertFalse(coordinator.canStartNewWalk)
        XCTAssertNotNil(coordinator.storageErrorMessage)
        XCTAssertEqual(coordinator.tracker.status, .idle)
        XCTAssertEqual(drafts.saveCount, 0)
        XCTAssertEqual(drafts.clearCount, 0)
        XCTAssertEqual(drafts.draft, savedDraft)

        drafts.failLoad = false
        coordinator.retryStorage()

        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertEqual(coordinator.tracker.status, .paused)
        XCTAssertEqual(coordinator.tracker.makeDraft()?.id, savedDraft.id)
        XCTAssertNil(coordinator.storageErrorMessage)
    }

    func testFailureOfBothFinishDestinationsKeepsDataInMemoryThenRetrySavesOnce() throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        drafts.failSave = true
        history.failSave = true
        now = referenceDate.addingTimeInterval(20)

        coordinator.tracker.finish()

        let record = try XCTUnwrap(coordinator.tracker.completedWalk)
        XCTAssertFalse(coordinator.canStartNewWalk)
        XCTAssertNotNil(coordinator.storageErrorMessage)
        XCTAssertEqual(coordinator.history.records, [record])
        XCTAssertTrue(history.records.isEmpty)
        drafts.failSave = false
        history.failSave = false
        coordinator.retryStorage()
        coordinator.retryStorage()
        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(coordinator.storageErrorMessage)
        XCTAssertEqual(history.records, [record])
        XCTAssertEqual(coordinator.history.records, [record])
        XCTAssertNil(drafts.draft)
    }

    func testCheckpointClearFailureBlocksNextWalkUntilRetry() throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(20)
        drafts.failClear = true

        coordinator.tracker.finish()

        let record = try XCTUnwrap(coordinator.tracker.completedWalk)
        XCTAssertFalse(coordinator.canStartNewWalk)
        XCTAssertNotNil(coordinator.storageErrorMessage)
        XCTAssertEqual(history.records, [record])
        XCTAssertEqual(drafts.draft?.finishedRecord, record)
        drafts.failClear = false
        coordinator.retryStorage()
        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(coordinator.storageErrorMessage)
        XCTAssertNil(drafts.draft)
        XCTAssertEqual(history.records, [record])
    }

    func testSigningOutPausesCheckpointsAndDisablesFurtherGPSActivity() {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [dog()])
        now = referenceDate.addingTimeInterval(20)

        coordinator.shutdown()

        XCTAssertEqual(coordinator.tracker.status, .paused)
        XCTAssertEqual(drafts.draft?.activeDuration, 20)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        let startCount = client.startCount
        coordinator.setForeground(true)
        coordinator.setWalkPageVisible(true)
        coordinator.shutdown()
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertEqual(client.startCount, startCount)
    }

    private func makeCoordinator(
        client: CoordinatorLocationClientStub? = nil,
        drafts: CoordinatorDraftStub? = nil,
        history: CoordinatorHistoryStub? = nil,
        now: (() -> Date)? = nil
    ) -> WalkSessionCoordinator {
        let clock = now ?? { self.referenceDate.addingTimeInterval(500) }
        let manager = WalkLocationManager(client: client ?? CoordinatorLocationClientStub(), locationServicesEnabled: { true }, now: clock)
        return WalkSessionCoordinator(
            ownerID: 1,
            serverURL: URL(string: "http://unit-test.invalid"),
            locationManager: manager,
            historyPersistence: history ?? CoordinatorHistoryStub(),
            draftPersistence: drafts ?? CoordinatorDraftStub(),
            now: clock,
            isForeground: true,
            observeLifecycle: false
        )
    }

    private func activeDraft() -> WalkDraft {
        WalkDraft(
            id: UUID(),
            startedAt: referenceDate,
            checkpointAt: referenceDate.addingTimeInterval(20),
            activeDuration: 20,
            distanceMetres: 0,
            dogs: [dog()],
            routeSegments: [[WalkRoutePoint(latitude: -37.8136, longitude: 144.9631, timestamp: referenceDate)]]
        )
    }

    private func finishedDraft() -> WalkDraft {
        var draft = activeDraft()
        draft.finishedRecord = WalkRecord(
            id: draft.id,
            startedAt: draft.startedAt,
            endedAt: draft.checkpointAt,
            activeDuration: draft.activeDuration,
            distanceMetres: draft.distanceMetres,
            dogs: draft.dogs.map { WalkDogSnapshot(id: $0.id, name: $0.name) },
            routeSegments: draft.routeSegments
        )
        return draft
    }

    private func dog() -> Dog {
        Dog(
            id: 1, name: "Milo", photo: nil,
            breed: Breed(id: 1, name: "Mixed Breed", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false),
            ageMonths: 24, size: .medium, isBrachycephalic: false, createdAt: "2026-09-08T00:00:00Z"
        )
    }

    private func location(latitude: Double = -37.8136, seconds: TimeInterval = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 144.9631),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: referenceDate.addingTimeInterval(seconds)
        )
    }
}

@MainActor
private final class CoordinatorLocationClientStub: WalkLocationClient {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var pausesLocationUpdatesAutomatically = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private lazy var eventManager = CLLocationManager()

    func requestWhenInUseAuthorization() {}
    func startUpdatingLocation() { startCount += 1 }
    func stopUpdatingLocation() { stopCount += 1 }
    func deliver(_ locations: [CLLocation]) {
        delegate?.locationManager?(eventManager, didUpdateLocations: locations)
    }
    func notifyAuthorizationChanged() {
        delegate?.locationManagerDidChangeAuthorization?(eventManager)
    }
}

@MainActor
private final class CoordinatorDraftStub: WalkDraftPersisting {
    var draft: WalkDraft?
    var failLoad = false
    var failSave = false
    var failClear = false
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(draft: WalkDraft? = nil) { self.draft = draft }
    func load() throws -> WalkDraft? {
        if failLoad { throw CoordinatorStorageFailure.unavailable }
        return draft
    }
    func save(_ draft: WalkDraft) throws {
        saveCount += 1
        if failSave { throw CoordinatorStorageFailure.unavailable }
        self.draft = draft
    }
    func clear() throws {
        clearCount += 1
        if failClear { throw CoordinatorStorageFailure.unavailable }
        draft = nil
    }
}

@MainActor
private final class CoordinatorHistoryStub: WalkHistoryPersisting {
    var records: [WalkRecord]
    var failSave = false
    private(set) var saveCount = 0

    init(records: [WalkRecord] = []) { self.records = records }
    func load() throws -> [WalkRecord] { records }
    func save(_ records: [WalkRecord]) throws {
        saveCount += 1
        if failSave { throw CoordinatorStorageFailure.unavailable }
        self.records = records
    }
}

private enum CoordinatorStorageFailure: Error {
    case unavailable
}
