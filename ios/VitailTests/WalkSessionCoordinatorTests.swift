import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class WalkSessionCoordinatorTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_789_000_000)

    func testLocationDelegateRecordsWholeBatchAndCheckpointsWithoutAView() async {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
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

    func testChangingTabsAndEnteringBackgroundDoesNotStopAnActiveWalk() async {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.setWalkPageVisible(true)
        XCTAssertEqual(coordinator.locationManager.mode, .preview)
        coordinator.tracker.start(from: location(), dogs: [])
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

    func testPauseAndFinishStopBackgroundUpdatesAndSaveExactlyOneHistoryRecord() async throws {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
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
        await coordinator.confirmFinishedWalk()
        coordinator.tracker.finish()
        await coordinator.confirmFinishedWalk()
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

    func testFinishedWalkMayPreviewOnVisiblePageButDoesNotRetainBackgroundTracking() async {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let coordinator = makeCoordinator(client: client, now: { now })
        coordinator.setWalkPageVisible(true)
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(10)

        coordinator.tracker.finish()
        await coordinator.confirmFinishedWalk()

        XCTAssertEqual(coordinator.locationManager.mode, .preview)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        coordinator.setForeground(false)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
    }

    func testPermissionLossPausesAndCheckpointsWithoutWaitingForSwiftUI() async {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
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

    func testRecoveringAnActiveDraftIsPausedAndDoesNotStartGPSAutomatically() async throws {
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
        await coordinator.confirmFinishedWalk()
        let finished = try XCTUnwrap(coordinator.history.records.first)
        XCTAssertEqual(finished.id, savedDraft.id)
        XCTAssertEqual(finished.activeDuration, savedDraft.activeDuration)
    }

    func testFinishedDraftIsRetriedIntoHistoryWithStableIDAndNoDuplicate() async throws {
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

    func testAlreadySavedHistoryClearsLeftoverDraftWithoutCreatingAnotherRecord() async {
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

    func testUnreadableDraftBlocksNewWalkAndDoesNotOverwriteUntilRetrySucceeds() async {
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

    func testFailureOfBothFinishDestinationsKeepsDataInMemoryThenRetrySavesOnce() async throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        drafts.failSave = true
        history.failSave = true
        now = referenceDate.addingTimeInterval(20)

        coordinator.tracker.finish()
        await coordinator.confirmFinishedWalk()

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

    func testCheckpointClearFailureBlocksNextWalkUntilRetry() async throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let coordinator = makeCoordinator(drafts: drafts, history: history, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        drafts.failClear = true

        coordinator.tracker.finish()
        await coordinator.confirmFinishedWalk()

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

    func testSigningOutPausesCheckpointsAndDisablesFurtherGPSActivity() async {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let drafts = CoordinatorDraftStub()
        let coordinator = makeCoordinator(client: client, drafts: drafts, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
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

    func testFinishedWalkWaitsForDogConfirmationThenUploadsExactlyOnce() async throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let server = CoordinatorWalkServer()
        let coordinator = makeCoordinator(drafts: drafts, history: history, service: server, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        coordinator.tracker.recordBatch([location(latitude: -37.8135, seconds: 20)])
        coordinator.tracker.pause()
        coordinator.tracker.finish()
        let id = try XCTUnwrap(coordinator.finishSummary?.id)
        XCTAssertTrue(coordinator.needsFinishConfirmation)
        XCTAssertTrue(coordinator.isFinishPresented)
        XCTAssertFalse(coordinator.canStartNewWalk)
        XCTAssertTrue(history.records.isEmpty)
        coordinator.retryStorage()
        await coordinator.sync.refreshAndUpload()
        let before = await server.requests.count
        XCTAssertEqual(before, 0)

        await coordinator.dogSelection.load()
        coordinator.dogSelection.toggleDog(id: 1)
        await coordinator.confirmFinishedWalk()
        await coordinator.confirmFinishedWalk()
        await coordinator.sync.refreshAndUpload()

        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.requestID, id)
        XCTAssertEqual(requests.first?.dogIDs, [1])
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.serverSummary?.pointsAwarded, 1)
        XCTAssertNil(drafts.draft)
        XCTAssertTrue(coordinator.canStartNewWalk)
    }

    func testRelaunchKeepsFinishedSummaryUnconfirmedAndDoesNotUploadOnRefresh() async throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let server = CoordinatorWalkServer()
        let original = makeCoordinator(drafts: drafts, history: history, service: server, now: { now })
        original.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        original.tracker.recordBatch([location(latitude: -37.8135, seconds: 20)])
        original.tracker.finish()
        let saved = try XCTUnwrap(drafts.draft)
        original.shutdown()

        let recovered = makeCoordinator(drafts: drafts, history: history, service: server, now: { now })
        recovered.setForeground(true)
        recovered.retryStorage()
        await recovered.sync.refreshAndUpload()
        XCTAssertTrue(recovered.needsFinishConfirmation)
        XCTAssertTrue(recovered.isFinishPresented)
        XCTAssertEqual(recovered.finishSummary?.id, saved.id)
        XCTAssertEqual(recovered.finishSummary?.routeSegments, saved.routeSegments)
        XCTAssertFalse(recovered.canStartNewWalk)
        XCTAssertTrue(history.records.isEmpty)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)

        await recovered.dogSelection.load()
        recovered.dogSelection.toggleDog(id: 1)
        await recovered.confirmFinishedWalk()
        XCTAssertEqual(history.records.first?.id, saved.id)
        XCTAssertEqual(history.records.first?.dogs.map(\.id), [1])
    }

    func testConfirmingWithoutDogsSavesLocalHistoryAndNeverUploads() async throws {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let server = CoordinatorWalkServer()
        let coordinator = makeCoordinator(drafts: drafts, history: history, service: server, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        coordinator.tracker.recordBatch([location(latitude: -37.8135, seconds: 20)])
        coordinator.tracker.finish()
        await coordinator.confirmFinishedWalk()
        await coordinator.sync.refreshAndUpload()
        let record = try XCTUnwrap(history.records.first)
        XCTAssertTrue(record.dogs.isEmpty)
        XCTAssertNil(record.uploadRequest)
        XCTAssertNil(record.serverSummary)
        XCTAssertTrue(record.syncDescription.contains("0 points"))
        XCTAssertEqual(coordinator.estimatedPoints(for: record, hasSelectedDogs: false), 0)
        XCTAssertTrue(coordinator.canStartNewWalk)
        XCTAssertNil(drafts.draft)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testLogoutPreservesPendingSummaryWithoutChoosingDogsOrAwardingPoints() async {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let history = CoordinatorHistoryStub()
        let server = CoordinatorWalkServer()
        let coordinator = makeCoordinator(drafts: drafts, history: history, service: server, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        coordinator.tracker.recordBatch([location(latitude: -37.8135, seconds: 20)])
        await coordinator.prepareForLogout()
        coordinator.shutdown()
        XCTAssertEqual(drafts.draft?.requiresDogConfirmation, true)
        XCTAssertNotNil(drafts.draft?.finishedRecord)
        XCTAssertTrue(history.records.isEmpty)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testAutomaticFinishStillRequiresExplicitConfirmation() async {
        var now = referenceDate
        let drafts = CoordinatorDraftStub()
        let server = CoordinatorWalkServer()
        let coordinator = makeCoordinator(drafts: drafts, service: server, now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(301)
        coordinator.tracker.checkInactivity()
        XCTAssertEqual(coordinator.tracker.status, .finished)
        XCTAssertTrue(coordinator.needsFinishConfirmation)
        XCTAssertEqual(drafts.draft?.requiresDogConfirmation, true)
        await coordinator.sync.refreshAndUpload()
        XCTAssertTrue(coordinator.history.records.isEmpty)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testEstimatedPointsUsesMelbourneDayCarryAndRemainingDailyCap() async {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "Australia/Melbourne")
        date.dateFormat = "yyyy-MM-dd"
        for (earlierDistance, earlierPoints, distance, expected): (Double, Int, Double, Int) in [
            (80, 0, 60, 1), (4_900, 39, 200, 1), (5_000, 40, 1_000, 0)
        ] {
            let previous = WalkSummary(
                id: 1, requestID: UUID(), startedAt: "", endedAt: "",
                distanceM: earlierDistance, pointsAwarded: earlierPoints,
                pointDate: date.string(from: referenceDate), dogIDs: [1]
            )
            let coordinator = makeCoordinator(service: CoordinatorWalkServer(receipts: [previous]))
            await coordinator.sync.refreshAndUpload()
            let record = WalkRecord(
                id: UUID(), startedAt: referenceDate, endedAt: referenceDate,
                activeDuration: 0, distanceMetres: distance, dogs: [], routeSegments: []
            )
            XCTAssertEqual(coordinator.estimatedPoints(for: record, hasSelectedDogs: true), expected)
            XCTAssertEqual(coordinator.estimatedPoints(for: record, hasSelectedDogs: false), 0)
        }
    }

    func testFinishSummarySnapshotsBeforeAndAfterConfirmation() async throws {
        var now = referenceDate
        let coordinator = makeCoordinator(now: { now })
        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(20)
        coordinator.tracker.recordBatch([location(latitude: -37.8135, seconds: 20)])
        coordinator.tracker.pause()
        coordinator.tracker.finish()
        await coordinator.dogSelection.load()
        coordinator.dogSelection.selectAll()

        for scheme in [ColorScheme.light, .dark] {
            try await attachSummary(coordinator, scheme: scheme,
                                    name: "Walk finish - choose dogs - \(scheme)")
        }
        coordinator.dogSelection.clearSelection()
        await coordinator.confirmFinishedWalk()
        try await attachSummary(coordinator, scheme: .light,
                                name: "Walk finish - no dogs saved - large text", largeText: true)
    }

    func testFullWalkMapSnapshotsIdleAndPaused() async throws {
        var now = referenceDate
        let client = CoordinatorLocationClientStub()
        let coordinator = makeCoordinator(client: client, now: { now })
        try await attachMap(coordinator, scheme: .light, name: "Walk map - idle - light")
        XCTAssertEqual(coordinator.locationManager.mode, .off)
        XCTAssertEqual(client.startCount, 0, "Rendering the inactive fixture must not request live location.")

        coordinator.tracker.start(from: location(), dogs: [])
        now = referenceDate.addingTimeInterval(120)
        coordinator.tracker.recordBatch([
            location(latitude: -37.8134, seconds: 30),
            location(latitude: -37.8132, seconds: 60),
            location(latitude: -37.8130, seconds: 90),
            location(latitude: -37.8128, seconds: 120)
        ])
        coordinator.tracker.pause()
        XCTAssertEqual(coordinator.tracker.elapsedActiveDuration(at: now), 120)
        for scheme in [ColorScheme.light, .dark] {
            try await attachMap(coordinator, scheme: scheme, name: "Walk map - paused - \(scheme)")
        }
        XCTAssertEqual(coordinator.tracker.status, .paused)
        XCTAssertEqual(coordinator.locationManager.mode, .off)
    }

    private func attachMap(
        _ coordinator: WalkSessionCoordinator, scheme: ColorScheme, name: String
    ) async throws {
        let content = NavigationStack {
            WalkMapView(coordinator: coordinator, isActive: false, onManageDogs: {})
                .navigationTitle("Vitail")
                .navigationBarTitleDisplayMode(.inline)
        }
        .vitailAppearance()
        .preferredColorScheme(scheme)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.frame = bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        host.view.layoutIfNeeded()
        func maps(in view: UIView) -> [MKMapView] {
            (view as? MKMapView).map { [$0] } ?? view.subviews.flatMap { maps(in: $0) }
        }
        let map = try XCTUnwrap(maps(in: host.view).first)
        XCTAssertGreaterThan(map.bounds.height, bounds.height * 0.7, "Map should fill the page behind its controls.")
        XCTAssertGreaterThanOrEqual(map.bounds.width, bounds.width - 2)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachSummary(
        _ coordinator: WalkSessionCoordinator, scheme: ColorScheme,
        name: String, largeText: Bool = false
    ) async throws {
        let content = WalkFinishSummaryView(coordinator: coordinator)
            .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
            .preferredColorScheme(scheme)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.frame = bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeCoordinator(
        client: CoordinatorLocationClientStub? = nil,
        drafts: CoordinatorDraftStub? = nil,
        history: CoordinatorHistoryStub? = nil,
        service: (any WalkServing)? = nil,
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
            dogService: CoordinatorDogServiceStub(dogs: [dog()]),
            walkService: service,
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

private actor CoordinatorWalkServer: WalkServing {
    private(set) var requests: [WalkRequest] = []
    private var receipts: [WalkSummary]
    init(receipts: [WalkSummary] = []) { self.receipts = receipts }
    func getWalks() async throws -> [WalkSummary] { receipts }
    func submit(_ request: WalkRequest) async throws -> WalkSummary {
        requests.append(request)
        let receipt = WalkSummary(
            id: 1, requestID: request.requestID, startedAt: request.startedAt,
            endedAt: request.endedAt, distanceM: 11, pointsAwarded: 1,
            pointDate: "2026-09-10", dogIDs: request.dogIDs
        )
        receipts.append(receipt)
        return receipt
    }
}

private actor CoordinatorDogServiceStub: DogServicing {
    let dogs: [Dog]
    init(dogs: [Dog]) { self.dogs = dogs }
    func getDogs() async throws -> [Dog] { dogs }
    func getBreeds() async throws -> [Breed] { [] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { throw CoordinatorStorageFailure.unavailable }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { throw CoordinatorStorageFailure.unavailable }
    func deleteDog(id: Int) async throws { throw CoordinatorStorageFailure.unavailable }
    func getGoal(dogID: Int) async throws -> DogGoal { throw CoordinatorStorageFailure.unavailable }
}
