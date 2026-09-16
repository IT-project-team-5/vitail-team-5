import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import Vitail

@MainActor
final class WalkHistoryTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_788_800_000)

    func testFinishedWalkKeepsItsDatesDogsDistanceAndRoute() throws {
        var now = referenceDate
        var completed: [WalkRecord] = []
        let tracker = WalkSessionTracker(now: { now }, onFinish: { completed.append($0) })
        var milo = dog(id: 1, name: "Milo")
        let start = location(seconds: 0)
        let next = location(latitude: -37.8130, seconds: 30)

        tracker.start(from: start, dogs: [milo, dog(id: 2, name: "Luna"), milo])
        milo.name = "Changed after starting"
        tracker.record(next)
        now = referenceDate.addingTimeInterval(60)
        tracker.finish()

        let record = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(record.startedAt, referenceDate)
        XCTAssertEqual(record.endedAt, now)
        XCTAssertEqual(record.activeDuration, 60, accuracy: 0.001)
        XCTAssertEqual(record.dogs, [WalkDogSnapshot(id: 1, name: "Milo"), WalkDogSnapshot(id: 2, name: "Luna")])
        XCTAssertEqual(record.distanceMetres, next.distance(from: start), accuracy: 0.001)
        XCTAssertEqual(record.distanceKilometres, record.distanceMetres / 1_000, accuracy: 0.000001)
        XCTAssertEqual(record.routeSegments.map(\.count), [2])
        XCTAssertEqual(record.routeSegments[0].map(\.timestamp), [start.timestamp, next.timestamp])
        XCTAssertEqual(record.routeSegments[0][0].coordinate.latitude, start.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(completed, [record])
    }

    func testPausedTimeAndMovementAreExcludedAndResumeCreatesANewSegment() throws {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        let start = location(seconds: 0)
        let beforePause = location(latitude: -37.8130, seconds: 20)
        let resume = location(latitude: -37.8100, seconds: 100)
        let afterResume = location(latitude: -37.8095, seconds: 110)
        tracker.start(from: start, dogs: [dog()])
        tracker.record(beforePause)

        now = referenceDate.addingTimeInterval(30)
        tracker.pause()
        tracker.record(location(latitude: -37.8110, seconds: 60))
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])

        now = referenceDate.addingTimeInterval(100)
        tracker.resume(from: resume)
        tracker.record(afterResume)
        now = referenceDate.addingTimeInterval(120)
        tracker.finish()

        let record = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(record.activeDuration, 50, accuracy: 0.001)
        XCTAssertEqual(record.endedAt.timeIntervalSince(record.startedAt), 120, accuracy: 0.001)
        XCTAssertEqual(record.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(record.routeSegments[1][0].timestamp, resume.timestamp)
        XCTAssertEqual(record.distanceMetres, beforePause.distance(from: start) + afterResume.distance(from: resume), accuracy: 0.001)
    }

    func testFinishingWhilePausedDoesNotIncludeTheFinalPause() throws {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(seconds: 0), dogs: [dog()])
        now = referenceDate.addingTimeInterval(25)
        tracker.pause()
        now = referenceDate.addingTimeInterval(200)
        tracker.finish()

        let record = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(record.activeDuration, 25, accuracy: 0.001)
        XCTAssertEqual(record.endedAt, now)
    }

    func testFinishOnlyCreatesOneRecordAndStartingAgainClearsThePreviousRoute() throws {
        var now = referenceDate
        var completed: [WalkRecord] = []
        let tracker = WalkSessionTracker(now: { now }, onFinish: { completed.append($0) })
        tracker.finish()
        XCTAssertTrue(completed.isEmpty)

        tracker.start(from: location(seconds: 0), dogs: [dog()])
        tracker.record(location(latitude: -37.8120, seconds: 30))
        now = referenceDate.addingTimeInterval(60)
        tracker.finish()
        let first = try XCTUnwrap(tracker.completedWalk)
        tracker.finish()
        tracker.pause()
        tracker.resume(from: location(seconds: 70))
        tracker.record(location(latitude: -37.8100, seconds: 80))
        XCTAssertEqual(completed, [first])
        XCTAssertEqual(tracker.completedWalk, first)

        now = referenceDate.addingTimeInterval(100)
        tracker.start(from: location(seconds: 100), dogs: [dog(id: 2, name: "Luna")])
        XCTAssertNil(tracker.completedWalk)
        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1])
        now = referenceDate.addingTimeInterval(110)
        tracker.finish()

        let second = try XCTUnwrap(tracker.completedWalk)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.startedAt, referenceDate.addingTimeInterval(100))
        XCTAssertEqual(second.activeDuration, 10, accuracy: 0.001)
        XCTAssertEqual(second.dogs, [WalkDogSnapshot(id: 2, name: "Luna")])
        XCTAssertEqual(completed, [first, second])
    }

    func testInvalidAccuracyAndNonIncreasingTimestampsDoNotEnterTheRoute() {
        let tracker = WalkSessionTracker(now: { self.referenceDate })
        let start = location(seconds: 0)
        tracker.start(from: start, dogs: [dog()])

        tracker.record(location(latitude: -37.8100, seconds: 1, accuracy: -1))
        tracker.record(location(latitude: -37.8100, seconds: 2, accuracy: 31))
        tracker.record(location(latitude: -37.8100, seconds: 0))
        tracker.record(location(latitude: -37.8100, seconds: -1))
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1])
        XCTAssertEqual(tracker.distanceMetres, 0)

        let valid = location(latitude: -37.8130, seconds: 3)
        tracker.record(valid)
        tracker.record(location(latitude: -37.8090, seconds: 2))
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2])
        XCTAssertEqual(tracker.distanceMetres, valid.distance(from: start), accuracy: 0.001)
    }

    func testResumeWithoutUsableGPSWaitsForAFreshSegmentAnchor() throws {
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now })
        tracker.start(from: location(seconds: 0), dogs: [dog()])
        tracker.record(location(latitude: -37.8130, seconds: 10))
        let firstDistance = tracker.distanceMetres
        now = referenceDate.addingTimeInterval(20)
        tracker.pause()
        now = referenceDate.addingTimeInterval(60)
        tracker.resume(from: location(latitude: -37.8000, seconds: 60, accuracy: 100))
        tracker.record(location(latitude: -37.8000, seconds: 5))
        tracker.record(location(latitude: -37.8000, seconds: 61, accuracy: -1))
        let anchor = location(latitude: -37.8000, seconds: 62)
        tracker.record(anchor)
        let next = location(latitude: -37.7995, seconds: 70)
        tracker.record(next)
        now = referenceDate.addingTimeInterval(80)
        tracker.finish()

        let record = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(record.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(record.routeSegments[1][0].timestamp, anchor.timestamp)
        XCTAssertEqual(record.distanceMetres, firstDistance + next.distance(from: anchor), accuracy: 0.001)
        XCTAssertEqual(record.activeDuration, 40, accuracy: 0.001)
    }

    func testAnInvalidStartDoesNotCreateHistory() {
        var completed: [WalkRecord] = []
        let tracker = WalkSessionTracker(now: { self.referenceDate }, onFinish: { completed.append($0) })
        tracker.start(from: nil, dogs: [dog()])
        tracker.start(from: location(accuracy: 100), dogs: [dog()])
        tracker.start(from: location(), dogs: [])
        tracker.finish()

        XCTAssertEqual(tracker.status, .idle)
        XCTAssertTrue(tracker.routeSegments.isEmpty)
        XCTAssertNil(tracker.completedWalk)
        XCTAssertTrue(completed.isEmpty)
    }

    func testRecordCanRoundTripThroughJSONWithoutLosingSegmentsOrDogs() throws {
        let original = record()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WalkRecord.self, from: data), original)
    }

    func testHistoryLoadsNewestFirstAndDoesNotDuplicateAnAppendedRecord() {
        let older = record(seconds: 0)
        let newer = record(seconds: 200)
        let persistence = HistoryPersistenceStub(records: [older, newer])
        let store = WalkHistoryStore(persistence: persistence)
        XCTAssertEqual(store.records.map(\.id), [newer.id, older.id])

        store.append(newer)
        store.append(newer)
        XCTAssertEqual(store.records.map(\.id), [newer.id, older.id])
        XCTAssertNil(store.errorMessage)
    }

    func testSaveFailureKeepsNewWalksInMemoryAndRetrySavesEachOnce() {
        let older = record(seconds: 0)
        let newest = record(seconds: 200)
        let persistence = HistoryPersistenceStub(records: [older])
        let store = WalkHistoryStore(persistence: persistence)
        persistence.failSave = true

        store.append(newest)
        store.append(newest)
        XCTAssertEqual(store.records.map(\.id), [newest.id, older.id])
        XCTAssertEqual(persistence.records, [older])
        XCTAssertNotNil(store.errorMessage)
        store.retry()
        XCTAssertNotNil(store.errorMessage)

        persistence.failSave = false
        store.retry()
        store.retry()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.records.map(\.id), [newest.id, older.id])
        XCTAssertEqual(persistence.records.map(\.id), [newest.id, older.id])
    }

    func testLoadFailureNeverOverwritesUnreadHistoryAndRetryMergesPendingWalks() {
        let unread = record(seconds: 0)
        let newlyFinished = record(seconds: 200)
        let persistence = HistoryPersistenceStub(records: [unread])
        persistence.failLoad = true
        let store = WalkHistoryStore(persistence: persistence)
        XCTAssertNotNil(store.errorMessage)
        store.append(newlyFinished)
        store.retry()

        XCTAssertEqual(store.records, [newlyFinished])
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(persistence.records, [unread])

        persistence.failLoad = false
        store.retry()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.records.map(\.id), [newlyFinished.id, unread.id])
        XCTAssertEqual(persistence.records.map(\.id), [newlyFinished.id, unread.id])
    }

    func testFileHistoryPersistsAcrossStoreRecreation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = URL(string: "http://localhost:8000")!
        let original = record()
        let first = WalkHistoryStore(persistence: WalkHistoryFileStore(ownerID: 1, serverURL: server, directory: directory))
        XCTAssertTrue(first.records.isEmpty)
        first.append(original)
        XCTAssertNil(first.errorMessage)

        let second = WalkHistoryStore(persistence: WalkHistoryFileStore(ownerID: 1, serverURL: server, directory: directory))
        XCTAssertNil(second.errorMessage)
        XCTAssertEqual(second.records, [original])
    }

    func testFinishingAWalkSavesItsDogsAndRouteThroughTheHistoryStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = URL(string: "http://localhost:8000")!
        let store = WalkHistoryStore(persistence: WalkHistoryFileStore(ownerID: 7, serverURL: server, directory: directory))
        var now = referenceDate
        let tracker = WalkSessionTracker(now: { now }, onFinish: { store.append($0) })
        tracker.start(from: location(seconds: 0), dogs: [dog(), dog(id: 2, name: "Luna")])
        tracker.record(location(latitude: -37.8130, seconds: 20))
        now = referenceDate.addingTimeInterval(30)
        tracker.finish()
        tracker.finish()

        let completed = try XCTUnwrap(tracker.completedWalk)
        XCTAssertEqual(store.records, [completed])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(completed.dogs.map(\.name), ["Milo", "Luna"])
        XCTAssertEqual(completed.routeSegments.map(\.count), [2])
        let reopened = WalkHistoryStore(persistence: WalkHistoryFileStore(ownerID: 7, serverURL: server, directory: directory))
        XCTAssertEqual(reopened.records, [completed])
        XCTAssertNil(reopened.errorMessage)
    }

    func testFileHistoryIsSeparatedByOwnerAndServer() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = URL(string: "http://localhost:8000")!
        let other = URL(string: "https://example.test")!
        let records = (0..<4).map { record(seconds: TimeInterval($0 * 100)) }
        let stores = [
            WalkHistoryFileStore(ownerID: 1, serverURL: local, directory: directory),
            WalkHistoryFileStore(ownerID: 2, serverURL: local, directory: directory),
            WalkHistoryFileStore(ownerID: 1, serverURL: other, directory: directory),
            WalkHistoryFileStore(ownerID: 2, serverURL: other, directory: directory)
        ]
        for (index, store) in stores.enumerated() { try store.save([records[index]]) }
        XCTAssertEqual(Set(stores.map(\.fileURL)).count, 4)
        for (index, store) in stores.enumerated() {
            XCTAssertEqual(try store.load(), [records[index]])
        }
    }

    func testCorruptHistoryFileIsPreservedUntilItCanBeReadAndMerged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WalkHistoryFileStore(ownerID: 1, serverURL: URL(string: "http://localhost:8000"), directory: directory)
        let existing = record(seconds: 0)
        try disk.save([existing])
        let damagedBytes = Data("not valid JSON: original history must not be replaced".utf8)
        try damagedBytes.write(to: disk.fileURL)
        let store = WalkHistoryStore(persistence: disk)
        XCTAssertNotNil(store.errorMessage)

        let pending = record(seconds: 200)
        store.append(pending)
        store.retry()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: disk.fileURL), damagedBytes)
        XCTAssertEqual(store.records, [pending])

        // Repair only this temporary fixture to simulate the original file becoming readable.
        try disk.save([existing])
        store.retry()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.records.map(\.id), [pending.id, existing.id])
        XCTAssertEqual(try disk.load(), store.records)
    }

    func testInvalidRecordsCannotReplaceAnExistingHistoryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WalkHistoryFileStore(ownerID: 1, serverURL: nil, directory: directory)
        let original = record()
        try disk.save([original])
        let invalid = WalkRecord(
            id: UUID(), startedAt: referenceDate, endedAt: referenceDate.addingTimeInterval(30),
            activeDuration: 30, distanceMetres: -100, dogs: original.dogs, routeSegments: original.routeSegments
        )
        XCTAssertThrowsError(try disk.save([invalid]))
        XCTAssertEqual(try disk.load(), [original])

        let store = WalkHistoryStore(persistence: disk)
        store.append(invalid)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.records, [original])
        XCTAssertEqual(try disk.load(), [original])
    }

    func testRouteBoundsKeepDatelineCrossingCompactWithoutJoiningSegments() throws {
        let segments = [
            [
                WalkRoutePoint(latitude: 10, longitude: 179.999, timestamp: referenceDate),
                WalkRoutePoint(latitude: 10, longitude: -179.999, timestamp: referenceDate.addingTimeInterval(10))
            ],
            [WalkRoutePoint(latitude: 10.001, longitude: -179.998, timestamp: referenceDate.addingTimeInterval(40))]
        ]
        let projected = WalkRouteBounds.projectedSegments(segments)
        XCTAssertEqual(projected.map(\.count), [2, 1])
        let first = try XCTUnwrap(projected.first?.first)
        let last = try XCTUnwrap(projected.last?.last)
        XCTAssertLessThan(abs(last.x - first.x), MKMapRect.world.size.width / 1_000)
        let bounds = WalkRouteBounds.mapRect(for: segments.flatMap { $0 })
        XCTAssertLessThan(bounds.size.width, MKMapRect.world.size.width / 1_000)
        XCTAssertGreaterThan(bounds.size.width, 0)
        XCTAssertGreaterThan(bounds.size.height, 0)
    }

    func testSinglePointRouteHasUsableMapBounds() {
        let point = WalkRoutePoint(latitude: -37.8136, longitude: 144.9631, timestamp: referenceDate)
        let bounds = WalkRouteBounds.mapRect(for: [point])
        let projected = MKMapPoint(point.coordinate)
        let minimumSpan = MKMapPointsPerMeterAtLatitude(point.latitude) * 350
        XCTAssertGreaterThanOrEqual(bounds.size.width, minimumSpan)
        XCTAssertGreaterThanOrEqual(bounds.size.height, minimumSpan)
        XCTAssertTrue(bounds.origin.x.isFinite)
        XCTAssertTrue(bounds.origin.y.isFinite)
        XCTAssertLessThan(bounds.origin.x, projected.x)
        XCTAssertGreaterThan(bounds.origin.x + bounds.size.width, projected.x)
        XCTAssertLessThan(bounds.origin.y, projected.y)
        XCTAssertGreaterThan(bounds.origin.y + bounds.size.height, projected.y)
        XCTAssertTrue(WalkRouteBounds.projectedSegments([]).isEmpty)
    }

    func testSinglePointRoutesNearEitherPoleHavePositiveFiniteMapBounds() {
        for latitude in [-89.0, 89.0] {
            let point = WalkRoutePoint(latitude: latitude, longitude: 20, timestamp: referenceDate)
            let bounds = WalkRouteBounds.mapRect(for: [point])
            XCTAssertTrue(bounds.origin.x.isFinite, "Invalid x at latitude \(latitude)")
            XCTAssertTrue(bounds.origin.y.isFinite, "Invalid y at latitude \(latitude)")
            XCTAssertTrue(bounds.size.width.isFinite, "Invalid width at latitude \(latitude)")
            XCTAssertTrue(bounds.size.height.isFinite, "Invalid height at latitude \(latitude)")
            XCTAssertGreaterThan(bounds.size.width, 0, "Zero width at latitude \(latitude)")
            XCTAssertGreaterThan(bounds.size.height, 0, "Zero height at latitude \(latitude)")
        }
    }

    func testHistoryLayoutSnapshots() async throws {
        let example = routeExample()
        try await attachSnapshot(
            WalkHistoryCard(walk: example),
            name: "History 01 - completed walk with two dogs and route preview"
        )
        let longNames = WalkRecord(
            id: UUID(), startedAt: example.startedAt, endedAt: example.endedAt,
            activeDuration: example.activeDuration, distanceMetres: example.distanceMetres,
            dogs: [WalkDogSnapshot(id: 1, name: "Sir Bartholomew Fluffington the Third"),
                   WalkDogSnapshot(id: 2, name: "Princess Luna Marshmallow")],
            routeSegments: example.routeSegments
        )
        try await attachSnapshot(
            WalkHistoryCard(walk: longNames),
            name: "History 02 - narrow card with large text and long dog names",
            width: 320,
            dynamicTypeSize: .accessibility1
        )
        let empty = WalkHistoryStore(persistence: HistoryPersistenceStub())
        try await attachSnapshot(WalkHistorySection(store: empty), name: "History 03 - empty history")
        let failedPersistence = HistoryPersistenceStub()
        failedPersistence.failLoad = true
        let failed = WalkHistoryStore(persistence: failedPersistence)
        try await attachSnapshot(WalkHistorySection(store: failed), name: "History 04 - recoverable read error")
        try await attachSnapshot(
            WalkHistoryDetailView(walk: example),
            name: "History 05 - full details and recorded map segments",
            fixedHeight: 844,
            pagePadding: 0
        )
        let noRoute = WalkRecord(
            id: UUID(), startedAt: referenceDate, endedAt: referenceDate,
            activeDuration: 0, distanceMetres: 0, dogs: example.dogs, routeSegments: []
        )
        try await attachSnapshot(WalkHistoryCard(walk: noRoute), name: "History 06 - record without route")
    }

    private func routeExample() -> WalkRecord {
        let first = [
            (-37.7960, 144.9605), (-37.7960, 144.9620), (-37.7960, 144.9640), (-37.7980, 144.9640)
        ].enumerated().map { index, coordinate in
            WalkRoutePoint(latitude: coordinate.0, longitude: coordinate.1,
                           timestamp: referenceDate.addingTimeInterval(TimeInterval(index * 60)))
        }
        let second = [
            (-37.7995, 144.9640), (-37.7995, 144.9620), (-37.7995, 144.9605)
        ].enumerated().map { index, coordinate in
            WalkRoutePoint(latitude: coordinate.0, longitude: coordinate.1,
                           timestamp: referenceDate.addingTimeInterval(TimeInterval(300 + index * 60)))
        }
        return WalkRecord(
            id: UUID(), startedAt: referenceDate, endedAt: referenceDate.addingTimeInterval(480),
            activeDuration: 360, distanceMetres: 1_125,
            dogs: [WalkDogSnapshot(id: 1, name: "Milo"), WalkDogSnapshot(id: 2, name: "Luna")],
            routeSegments: [first, second]
        )
    }

    private func attachSnapshot<Content: View>(
        _ content: Content,
        name: String,
        width: CGFloat = 393,
        dynamicTypeSize: DynamicTypeSize = .large,
        fixedHeight: CGFloat? = nil,
        pagePadding: CGFloat = 16
    ) async throws {
        let page = content
            .padding(pagePadding)
            .frame(width: width, height: fixedHeight)
            .background(AppColors.background)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .preferredColorScheme(.light)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: page)
        host.safeAreaRegions = []
        let fittingSize = host.sizeThatFits(in: CGSize(width: width, height: fixedHeight ?? 2_500))
        let bounds = CGRect(x: 0, y: 0, width: width, height: fixedHeight ?? ceil(fittingSize.height))
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
        try await Task.sleep(nanoseconds: 500_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: bounds, afterScreenUpdates: true), "Could not render \(name)")
        }
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 100)
        XCTAssertLessThan(image.size.height, 2_500)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitailWalkHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(seconds: TimeInterval = 0) -> WalkRecord {
        let start = referenceDate.addingTimeInterval(seconds)
        return WalkRecord(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(90),
            activeDuration: 60,
            distanceMetres: 125,
            dogs: [WalkDogSnapshot(id: 1, name: "Milo"), WalkDogSnapshot(id: 2, name: "Luna")],
            routeSegments: [
                [
                    WalkRoutePoint(latitude: -37.8136, longitude: 144.9631, timestamp: start),
                    WalkRoutePoint(latitude: -37.8130, longitude: 144.9632, timestamp: start.addingTimeInterval(20))
                ],
                [
                    WalkRoutePoint(latitude: -37.8120, longitude: 144.9633, timestamp: start.addingTimeInterval(60)),
                    WalkRoutePoint(latitude: -37.8115, longitude: 144.9634, timestamp: start.addingTimeInterval(80))
                ]
            ]
        )
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

@MainActor
private final class HistoryPersistenceStub: WalkHistoryPersisting {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "The history file is temporarily unavailable." }
    }

    var records: [WalkRecord]
    var failLoad = false
    var failSave = false
    private(set) var saveCount = 0

    init(records: [WalkRecord] = []) { self.records = records }

    func load() throws -> [WalkRecord] {
        if failLoad { throw Failure.unavailable }
        return records
    }

    func save(_ records: [WalkRecord]) throws {
        saveCount += 1
        if failSave { throw Failure.unavailable }
        self.records = records
    }
}
