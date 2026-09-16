import CoreLocation
import Foundation
import XCTest
@testable import Vitail

@MainActor
final class WalkMVPIntegrationTests: XCTestCase {
    func testSegmentedRequestKeepsStableIDAndActualMetadata() throws {
        let walk = record()
        let request = try XCTUnwrap(walk.uploadRequest)
        XCTAssertEqual(request.requestID, walk.id)
        XCTAssertEqual(request.samples.map(\.segmentID), [0, 0, 1, 1])
        XCTAssertEqual(request.samples.map(\.accuracyM), [5, 5, 5, 5])
        XCTAssertEqual(request, walk.uploadRequest)
    }

    func testLegacyHistoryIsReadableButCannotInventUploadAccuracy() throws {
        var walk = record()
        let oldPoints = walk.routeSegments.map { segment in
            segment.map { WalkRoutePoint(latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.timestamp) }
        }
        walk = WalkRecord(id: walk.id, startedAt: walk.startedAt, endedAt: walk.endedAt,
                          activeDuration: walk.activeDuration, distanceMetres: walk.distanceMetres,
                          dogs: walk.dogs, routeSegments: oldPoints)
        let decoded = try JSONDecoder().decode(WalkRecord.self, from: JSONEncoder().encode(walk))
        XCTAssertEqual(decoded, walk)
        XCTAssertNil(decoded.uploadRequest)
    }

    func testTimeoutThenRefreshReconcilesReceiptWithoutAnotherPost() async throws {
        let persistence = MVPMemoryHistory()
        let history = WalkHistoryStore(persistence: persistence)
        let walk = record()
        history.append(walk)
        let server = MVPWalkServer()
        await server.setTimeoutAfterCommit(true)
        let sync = WalkSyncStore(history: history, service: server)
        await sync.refreshAndUpload()
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertNil(history.records.first?.serverSummary)
        // Simulate relaunch from the durable archive.
        let reloaded = WalkHistoryStore(persistence: persistence)
        let recovered = WalkSyncStore(history: reloaded, service: server)
        await recovered.refreshAndUpload()
        let count = await server.postCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(reloaded.records.first?.serverSummary?.requestID, walk.id)
        XCTAssertNil(recovered.errorMessage)
    }

    func testOfflineHistoryRemainsDurableAndUploadsOnRetry() async {
        let persistence = MVPMemoryHistory()
        let history = WalkHistoryStore(persistence: persistence)
        history.append(record())
        let server = MVPWalkServer()
        await server.setOffline(true)
        let sync = WalkSyncStore(history: history, service: server)
        await sync.refreshAndUpload()
        XCTAssertEqual(persistence.records.count, 1)
        XCTAssertNil(persistence.records.first?.serverSummary)
        await server.setOffline(false)
        await sync.refreshAndUpload()
        XCTAssertEqual(persistence.records.first?.serverSummary?.pointsAwarded, 1)
        await sync.refreshAndUpload()
        let count = await server.postCount
        XCTAssertEqual(count, 1)
    }

    func testStoppedSyncDoesNotUploadAnotherAccountsRecords() async {
        let history = WalkHistoryStore(persistence: MVPMemoryHistory())
        history.append(record())
        let server = MVPWalkServer()
        let sync = WalkSyncStore(history: history, service: server)
        sync.stop()
        await sync.refreshAndUpload()
        let count = await server.postCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(history.records.first?.serverSummary)
    }

    func testSimulatorFlagSurvivesRequestConversion() throws {
        let walk = record(simulated: true)
        XCTAssertTrue(try XCTUnwrap(walk.uploadRequest).samples.allSatisfy(\.isSimulated))
    }

    func testRewardModeRejectsJumpAndBreaksRouteButKeepsMeasuredEvidence() {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let tracker = WalkSessionTracker(now: { start })
        tracker.enforcesRewardLimits = true
        tracker.start(from: fix(0, at: start), dogs: [dog()])
        tracker.record(fix(100, at: start.addingTimeInterval(1)))
        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1, 1])
        XCTAssertEqual(tracker.routeSegments[1][0].accuracyM, 5)
    }

    func testRewardModePauseKeepsSegmentsAndEndsAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        var now = start
        let tracker = WalkSessionTracker(now: { now })
        tracker.enforcesRewardLimits = true
        tracker.start(from: fix(0, at: start), dogs: [dog()])
        now = start.addingTimeInterval(10)
        tracker.record(fix(10, at: now))
        tracker.pause()
        now = start.addingTimeInterval(40)
        tracker.resume(from: fix(30, at: now))
        now = start.addingTimeInterval(50)
        tracker.record(fix(40, at: now))
        XCTAssertEqual(tracker.routeSegments.map(\.count), [2, 2])
        XCTAssertEqual(tracker.distanceMetres, 20, accuracy: 0.2)
        tracker.pause()
        now = start.addingTimeInterval(351)
        tracker.checkInactivity()
        XCTAssertEqual(tracker.status, .finished)
        XCTAssertEqual(tracker.completedWalk?.activeDuration, 20)
    }

    func testRewardModeWeakFixBreaksDistanceBridge() {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let tracker = WalkSessionTracker(now: { start })
        tracker.enforcesRewardLimits = true
        tracker.start(from: fix(0, at: start), dogs: [dog()])
        tracker.record(fix(10, at: start.addingTimeInterval(10), accuracy: 100))
        tracker.record(fix(20, at: start.addingTimeInterval(20)))
        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.routeSegments.map(\.count), [1, 1])
    }

    private func fix(_ metres: Double, at date: Date, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: metres / 111_319.5),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: date)
    }

    private func dog() -> Dog {
        Dog(id: 1, name: "Milo", photo: nil,
            breed: Breed(id: 1, name: "Mixed", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false),
            ageMonths: 24, size: .medium, isBrachycephalic: false, createdAt: "2026-09-09T00:00:00Z")
    }

    private func record(simulated: Bool = false) -> WalkRecord {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        func point(_ seconds: Double) -> WalkRoutePoint {
            WalkRoutePoint(latitude: 0, longitude: seconds / 100_000,
                           timestamp: start.addingTimeInterval(seconds), accuracyM: 5, isSimulated: simulated)
        }
        return WalkRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(100),
                          activeDuration: 40, distanceMetres: 40, dogs: [WalkDogSnapshot(id: 1, name: "Milo")],
                          routeSegments: [[point(0), point(20)], [point(80), point(100)]])
    }
}

@MainActor
private final class MVPMemoryHistory: WalkHistoryPersisting {
    var records: [WalkRecord] = []
    func load() throws -> [WalkRecord] { records }
    func save(_ records: [WalkRecord]) throws { self.records = records }
}

private actor MVPWalkServer: WalkServing {
    var postCount = 0
    var receipts: [WalkSummary] = []
    var offline = false
    var timeoutAfterCommit = false
    func setOffline(_ value: Bool) { offline = value }
    func setTimeoutAfterCommit(_ value: Bool) { timeoutAfterCommit = value }
    func getWalks() async throws -> [WalkSummary] {
        if offline { throw URLError(.notConnectedToInternet) }
        return receipts
    }
    func submit(_ request: WalkRequest) async throws -> WalkSummary {
        postCount += 1
        let receipt = WalkSummary(id: 1, requestID: request.requestID, startedAt: request.startedAt,
                                  endedAt: request.endedAt, distanceM: 40, pointsAwarded: 1,
                                  pointDate: "2026-09-09", dogIDs: request.dogIDs)
        receipts.append(receipt)
        if timeoutAfterCommit { throw URLError(.timedOut) }
        return receipt
    }
}
