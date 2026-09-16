import CoreLocation
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class WalkDogSelectionTests: XCTestCase {
    private var referenceDate = Date()

    func testLoadingDogsRequiresAnExplicitSelectionBeforeStarting() async {
        let dogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let model = WalkDogSelectionViewModel(
            session: WalkSessionTracker(),
            service: WalkDogServiceStub(dogs: dogs)
        )

        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)

        await model.load()

        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.dogs, dogs)
        XCTAssertTrue(model.selectedDogIDs.isEmpty)
        XCTAssertTrue(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)
    }

    func testMultipleDogsCanBeSelectedAndDeselectedWithoutDuplicates() async {
        let dogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let model = WalkDogSelectionViewModel(
            session: WalkSessionTracker(),
            service: WalkDogServiceStub(dogs: dogs)
        )
        await model.load()

        model.toggleDog(id: 2)
        model.toggleDog(id: 1)

        XCTAssertEqual(model.selectedDogIDs, Set([1, 2]))
        XCTAssertEqual(model.selectedDogs, dogs)
        XCTAssertTrue(model.canStartWalk)

        model.toggleDog(id: 1)
        XCTAssertEqual(model.selectedDogIDs, Set([2]))
        XCTAssertEqual(model.selectedDogs, [dogs[1]])

        model.toggleDog(id: 2)
        XCTAssertTrue(model.selectedDogs.isEmpty)
        XCTAssertFalse(model.canStartWalk)
    }

    func testSelectAllClearSelectionAndUnknownDogHandling() async {
        let dogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let model = WalkDogSelectionViewModel(
            session: WalkSessionTracker(),
            service: WalkDogServiceStub(dogs: dogs)
        )
        await model.load()

        model.toggleDog(id: 999)
        XCTAssertTrue(model.selectedDogIDs.isEmpty)

        model.selectAll()
        model.selectAll()
        XCTAssertEqual(model.selectedDogIDs, Set([1, 2]))
        XCTAssertEqual(model.selectedDogs.count, 2)

        model.clearSelection()
        XCTAssertTrue(model.selectedDogIDs.isEmpty)
        XCTAssertFalse(model.canStartWalk)
    }

    func testEmptyDogListCannotStartAWalk() async {
        let model = WalkDogSelectionViewModel(
            session: WalkSessionTracker(),
            service: WalkDogServiceStub(dogs: [])
        )

        await model.load()
        model.selectAll()
        model.toggleDog(id: 1)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.dogs.isEmpty)
        XCTAssertTrue(model.selectedDogIDs.isEmpty)
        XCTAssertFalse(model.canStartWalk)
    }

    func testRefreshRemovesDeletedDogsAndKeepsExistingSelections() async {
        let milo = dog(id: 1, name: "Milo")
        let luna = dog(id: 2, name: "Luna")
        let service = WalkDogServiceStub(dogs: [milo, luna])
        let model = WalkDogSelectionViewModel(session: WalkSessionTracker(), service: service)
        await model.load()
        model.selectAll()

        var renamedLuna = luna
        renamedLuna.name = "Luna Rose"
        await service.setDogs([renamedLuna, dog(id: 3, name: "Max")])
        await model.load()

        XCTAssertEqual(model.selectedDogIDs, Set([2]))
        XCTAssertEqual(model.selectedDogs, [renamedLuna])
        XCTAssertTrue(model.canStartWalk)

        await service.setDogs([])
        await model.load()

        XCTAssertTrue(model.selectedDogIDs.isEmpty)
        XCTAssertFalse(model.canStartWalk)
    }

    func testFailedLoadShowsAnErrorAndCanBeRetried() async {
        let service = WalkDogServiceStub(dogs: [])
        await service.failNextLoad()
        let model = WalkDogSelectionViewModel(session: WalkSessionTracker(), service: service)

        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)

        await service.setDogs([dog(id: 1, name: "Milo")])
        await model.load()
        model.toggleDog(id: 1)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.canStartWalk)
    }

    func testFailedRefreshPreservesTheListButPreventsStartingFromStaleData() async {
        let dogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let service = WalkDogServiceStub(dogs: dogs)
        let model = WalkDogSelectionViewModel(session: WalkSessionTracker(), service: service)
        await model.load()
        model.toggleDog(id: 1)

        await service.failNextLoad()
        await model.load()
        model.toggleDog(id: 2)
        model.clearSelection()

        XCTAssertEqual(model.dogs, dogs)
        XCTAssertEqual(model.selectedDogIDs, Set([1]))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)

        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canStartWalk)
    }

    func testLoadingBlocksEditingStartingAndOverlappingRequests() async {
        let service = WalkDogServiceStub(dogs: [dog(id: 1, name: "Milo")])
        let model = WalkDogSelectionViewModel(session: WalkSessionTracker(), service: service)
        await model.load()
        model.toggleDog(id: 1)

        await service.suspendNextLoad()
        let refresh = Task { await model.load() }
        await service.waitUntilSuspended()

        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)
        model.clearSelection()
        model.toggleDog(id: 1)
        await model.load()
        XCTAssertEqual(model.selectedDogIDs, Set([1]))
        let requestCount = await service.getDogsCallCount
        XCTAssertEqual(requestCount, 2)

        await service.resumeLoad()
        await refresh.value

        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.canStartWalk)
    }

    func testCancelledRetryAfterAFailedRefreshDoesNotEnableStarting() async {
        let service = WalkDogServiceStub(dogs: [dog(id: 1, name: "Milo")])
        let model = WalkDogSelectionViewModel(session: WalkSessionTracker(), service: service)
        await model.load()
        model.toggleDog(id: 1)

        await service.failNextLoad()
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.canStartWalk)

        await service.suspendNextLoad()
        let retry = Task { await model.load() }
        await service.waitUntilSuspended()
        retry.cancel()
        await service.resumeLoad()
        await retry.value

        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedDogIDs, Set([1]))
        XCTAssertFalse(model.canEditSelection)
        XCTAssertFalse(model.canStartWalk)

        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canStartWalk)
    }

    func testDogSelectionCardLayoutSnapshots() async throws {
        referenceDate = Date()
        let dogs = [
            dog(id: 1, name: "Milo"),
            dog(id: 2, name: "Luna"),
            dog(id: 3, name: "Max")
        ]
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        let model = WalkDogSelectionViewModel(
            session: tracker,
            service: WalkDogServiceStub(dogs: dogs)
        )
        await model.load()
        model.toggleDog(id: 1)
        model.toggleDog(id: 2)

        try await attachCardSnapshot(
            name: "01 Normal - selected dogs and ready walk controls",
            selection: model,
            session: tracker,
            location: location(),
            maximumCardHeight: 330
        )

        model.selectAll()
        try await attachCardSnapshot(
            name: "02 Compact phone - three dogs selected",
            selection: model,
            session: tracker,
            location: location(),
            width: 375,
            maximumCardHeight: 330
        )

        tracker.start(from: location(), dogs: model.selectedDogs)
        try await attachCardSnapshot(
            name: "03 Walking - pause and finish controls",
            selection: model,
            session: tracker,
            location: location(),
            maximumCardHeight: 330
        )

        tracker.pause()
        try await attachCardSnapshot(
            name: "04 Paused - locked dogs and resume controls",
            selection: model,
            session: tracker,
            location: location(),
            maximumCardHeight: 330
        )

        let emptyTracker = WalkSessionTracker()
        let emptyModel = WalkDogSelectionViewModel(
            session: emptyTracker,
            service: WalkDogServiceStub(dogs: [])
        )
        await emptyModel.load()
        try await attachCardSnapshot(
            name: "05 Empty - add a dog and disabled start",
            selection: emptyModel,
            session: emptyTracker,
            location: location(),
            maximumCardHeight: 330
        )

        let narrowTracker = WalkSessionTracker()
        let narrowModel = WalkDogSelectionViewModel(
            session: narrowTracker,
            service: WalkDogServiceStub(dogs: [
                dog(id: 1, name: "Sir Bartholomew Fluffington the Third"),
                dog(id: 2, name: "Princess Luna Marshmallow"),
                dog(id: 3, name: "Max")
            ])
        )
        await narrowModel.load()
        narrowModel.toggleDog(id: 1)
        narrowModel.toggleDog(id: 2)
        try await attachCardSnapshot(
            name: "06 Narrow - long names and accessible large text",
            selection: narrowModel,
            session: narrowTracker,
            location: location(),
            width: 320,
            dynamicTypeSize: .accessibility1
        )
    }

    func testMapAndCompactWalkCardFitStandardViewportHeights() {
        let cardHeight: CGFloat = 300
        let pageSpacing = AppSpacing.medium * 3
        let viewportHeights: [CGFloat] = [600, 700]

        for viewportHeight in viewportHeights {
            let mapHeight = WalkMapView.mapHeight(
                availableHeight: viewportHeight,
                cardHeight: cardHeight
            )

            XCTAssertGreaterThanOrEqual(mapHeight, 220)
            XCTAssertEqual(cardHeight + pageSpacing + mapHeight, viewportHeight, accuracy: 0.5)
        }
    }

    func testRecoveredWalkCardShowsSavedDogsBeforeAnyProfileRequest() async throws {
        referenceDate = Date()
        let savedDogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let startedAt = referenceDate.addingTimeInterval(-300)
        let draft = WalkDraft(
            id: UUID(),
            startedAt: startedAt,
            checkpointAt: startedAt.addingTimeInterval(60),
            activeDuration: 60,
            distanceMetres: 120,
            dogs: savedDogs,
            routeSegments: [[
                WalkRoutePoint(latitude: -37.8136, longitude: 144.9631, timestamp: startedAt),
                WalkRoutePoint(latitude: -37.8125, longitude: 144.9631, timestamp: startedAt.addingTimeInterval(60))
            ]]
        )
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        XCTAssertTrue(tracker.restore(draft))
        let service = WalkDogServiceStub(dogs: [])
        let model = WalkDogSelectionViewModel(session: tracker, service: service)

        // A recovered walk is usable from its saved participants even before
        // the server is reachable; a profile refresh must not replace them.
        await model.load()
        let requestsBeforeRendering = await service.getDogsCallCount
        XCTAssertEqual(requestsBeforeRendering, 0)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.dogs.isEmpty)
        XCTAssertEqual(tracker.participatingDogs, savedDogs)
        XCTAssertEqual(tracker.status, .paused)
        XCTAssertNotNil(tracker.trackingNotice)
        XCTAssertTrue(tracker.canFinish)
        XCTAssertFalse(tracker.canStart)
        XCTAssertFalse(model.canEditSelection)

        try await attachCardSnapshot(
            name: "07 Recovered walk - saved dogs and waiting for GPS",
            selection: model,
            session: tracker,
            location: nil,
            width: 375
        )
        try await attachCardSnapshot(
            name: "08 Recovered walk - narrow accessible large text",
            selection: model,
            session: tracker,
            location: nil,
            width: 320,
            dynamicTypeSize: .accessibility1
        )

        let requestsAfterRendering = await service.getDogsCallCount
        XCTAssertEqual(requestsAfterRendering, 0)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(tracker.participatingDogs, savedDogs)
        XCTAssertEqual(tracker.status, .paused)
        XCTAssertEqual(tracker.makeDraft()?.id, draft.id)
    }

    func testMapKeepsUsableMinimumHeightWhenPageNeedsScrolling() {
        let pageSpacing = AppSpacing.medium * 3
        let layouts: [(CGFloat, CGFloat)] = [(450, 300), (700, 500)]

        for (viewportHeight, cardHeight) in layouts {
            let mapHeight = WalkMapView.mapHeight(
                availableHeight: viewportHeight,
                cardHeight: cardHeight
            )

            XCTAssertEqual(mapHeight, 220)
            XCTAssertGreaterThan(cardHeight + pageSpacing + mapHeight, viewportHeight)
        }
    }

    func testWalkingAndPausedSessionsLockSelectionAndSkipReloads() async {
        let dogs = [dog(id: 1, name: "Milo"), dog(id: 2, name: "Luna")]
        let service = WalkDogServiceStub(dogs: dogs)
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        let model = WalkDogSelectionViewModel(session: tracker, service: service)
        await model.load()
        model.toggleDog(id: 1)
        tracker.start(from: location(), dogs: model.selectedDogs)

        for shouldPause in [false, true] {
            if shouldPause { tracker.pause() }
            XCTAssertTrue(tracker.isInProgress)
            XCTAssertFalse(model.canEditSelection)
            XCTAssertFalse(model.canStartWalk)

            model.toggleDog(id: 2)
            model.selectAll()
            model.clearSelection()
            await model.load()

            XCTAssertEqual(model.selectedDogIDs, Set([1]))
            XCTAssertEqual(tracker.participatingDogs, [dogs[0]])
        }

        let requestCount = await service.getDogsCallCount
        XCTAssertEqual(requestCount, 1)
        tracker.finish()
        XCTAssertFalse(tracker.isInProgress)
        XCTAssertTrue(model.canEditSelection)

        model.toggleDog(id: 2)
        XCTAssertEqual(model.selectedDogIDs, Set([1, 2]))
        XCTAssertEqual(tracker.participatingDogs, [dogs[0]])
    }

    func testTrackerRequiresDogsAndAccurateLocationBeforeStarting() {
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        let milo = dog(id: 1, name: "Milo")

        tracker.start(from: location(), dogs: [])
        XCTAssertEqual(tracker.status, .idle)
        XCTAssertTrue(tracker.participatingDogs.isEmpty)

        tracker.start(from: nil, dogs: [milo])
        XCTAssertEqual(tracker.status, .idle)
        tracker.start(from: location(accuracy: 100), dogs: [milo])
        XCTAssertEqual(tracker.status, .idle)
        XCTAssertTrue(tracker.participatingDogs.isEmpty)

        tracker.start(from: location(), dogs: [milo])
        XCTAssertEqual(tracker.status, .walking)
        XCTAssertEqual(tracker.participatingDogs, [milo])
    }

    func testParticipantsAreDeduplicatedAndCopiedForEachWalk() {
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        let milo = dog(id: 1, name: "Milo")
        let luna = dog(id: 2, name: "Luna")
        var selectedDogs = [milo, luna, milo]

        tracker.start(from: location(), dogs: selectedDogs)
        selectedDogs[0].name = "Updated Milo"
        selectedDogs.removeAll()

        XCTAssertEqual(tracker.participatingDogs, [milo, luna])

        tracker.start(from: location(), dogs: [luna])
        XCTAssertEqual(tracker.participatingDogs, [milo, luna])
        tracker.pause()
        tracker.start(from: location(), dogs: [luna])
        XCTAssertEqual(tracker.participatingDogs, [milo, luna])

        tracker.finish()
        XCTAssertEqual(tracker.participatingDogs, [milo, luna])
        tracker.start(from: location(), dogs: [luna])
        XCTAssertEqual(tracker.participatingDogs, [luna])
    }

    private func dog(id: Int, name: String) -> Dog {
        Dog(
            id: id,
            name: name,
            photo: nil,
            breed: Breed(
                id: 1,
                name: "Mixed Breed",
                energyLevel: .moderate,
                defaultSize: .medium,
                isBrachycephalic: false
            ),
            ageMonths: 24,
            size: .medium,
            isBrachycephalic: false,
            createdAt: "2026-09-08T00:00:00Z"
        )
    }

    private func attachCardSnapshot(
        name: String,
        selection: WalkDogSelectionViewModel,
        session: WalkSessionTracker,
        location: CLLocation? = nil,
        width: CGFloat = 393,
        dynamicTypeSize: DynamicTypeSize = .large,
        maximumCardHeight: CGFloat? = nil
    ) async throws {
        let content = WalkDogSelectionCard(
            selection: selection,
            session: session,
            location: location,
            onManageDogs: {}
        )
        .padding(16)
        .frame(width: width)
        .background(AppColors.background)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .preferredColorScheme(.light)
        // Host in a real test window so UIKit-backed menus and scrolling content render.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let fittingSize = host.sizeThatFits(in: CGSize(width: width, height: 2_500))
        let bounds = CGRect(x: 0, y: 0, width: width, height: ceil(fittingSize.height))
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.view.layoutIfNeeded()

        let displayedDogs = session.isInProgress ? session.participatingDogs : selection.dogs
        if !displayedDogs.isEmpty {
            let scrollView = try XCTUnwrap(scrollViews(in: host.view).first, "\(name) must render the dog list.")
            XCTAssertGreaterThan(scrollView.bounds.height, 40)
            XCTAssertGreaterThan(scrollView.contentSize.width, 0)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: bounds, afterScreenUpdates: true), "Could not render \(name)")
        }
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 120)
        XCTAssertLessThan(image.size.height, 2_500)
        if let maximumCardHeight {
            // Exclude the snapshot's 16-point top and bottom page margins.
            XCTAssertLessThanOrEqual(
                image.size.height - 32,
                maximumCardHeight,
                "\(name) should leave room for the map on a standard phone screen."
            )
        }

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func location(accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            timestamp: referenceDate
        )
    }
}

private actor WalkDogServiceStub: DogServicing {
    enum StubError: LocalizedError {
        case unavailable
        case unexpectedRequest

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Could not load dogs. Please try again."
            case .unexpectedRequest: return "The walk selector should only request the dog list."
            }
        }
    }

    private var dogs: [Dog]
    private var shouldFail = false
    private var shouldSuspend = false
    private var suspendedLoad: CheckedContinuation<Void, Never>?
    private var suspensionObserver: CheckedContinuation<Void, Never>?
    private(set) var getDogsCallCount = 0

    init(dogs: [Dog]) {
        self.dogs = dogs
    }

    func setDogs(_ dogs: [Dog]) { self.dogs = dogs }
    func failNextLoad() { shouldFail = true }
    func suspendNextLoad() { shouldSuspend = true }

    func waitUntilSuspended() async {
        guard suspendedLoad == nil else { return }
        await withCheckedContinuation { suspensionObserver = $0 }
    }

    func resumeLoad() {
        suspendedLoad?.resume()
        suspendedLoad = nil
    }

    func getDogs() async throws -> [Dog] {
        getDogsCallCount += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                suspendedLoad = continuation
                suspensionObserver?.resume()
                suspensionObserver = nil
            }
        }
        if shouldFail {
            shouldFail = false
            throw StubError.unavailable
        }
        return dogs
    }

    func getBreeds() async throws -> [Breed] { throw StubError.unexpectedRequest }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { throw StubError.unexpectedRequest }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { throw StubError.unexpectedRequest }
    func deleteDog(id: Int) async throws { throw StubError.unexpectedRequest }
    func getGoal(dogID: Int) async throws -> DogGoal { throw StubError.unexpectedRequest }
}
