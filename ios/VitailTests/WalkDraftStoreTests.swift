import Foundation
import XCTest
@testable import Vitail

@MainActor
final class WalkDraftStoreTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_788_800_000)

    func testMissingDraftIsNilAndClearCanBeRepeated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)

        XCTAssertNil(try store.load())
        try store.clear()
        try store.save(draft())
        try store.clear()
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testCheckpointRoundTripsAcrossStoreRecreationWithoutAddingElapsedTime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = URL(string: "https://vitail.example.test/api")!
        let original = draft()
        let first = WalkDraftFileStore(ownerID: 7, serverURL: server, directory: directory)
        try first.save(original)

        let reopened = WalkDraftFileStore(ownerID: 7, serverURL: server, directory: directory)
        let loaded = try XCTUnwrap(reopened.load())
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.activeDuration, 60)
        XCTAssertEqual(loaded.routeSegments.map(\.count), [2, 1])
        XCTAssertEqual(loaded.dogs.map(\.name), ["Milo", "Luna"])
        XCTAssertNil(loaded.finishedRecord)
    }

    func testFinishedCheckpointKeepsTheExactRecordIDForHistoryRetry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        var original = draft()
        original.finishedRecord = finishedRecord(for: original)
        XCTAssertTrue(original.isValid)

        try store.save(original)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.finishedRecord?.id, original.id)
        try store.save(loaded)
        XCTAssertEqual(try store.load()?.finishedRecord, original.finishedRecord)
    }

    func testDraftsAreIsolatedByOwnerAndBackend() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = URL(string: "http://localhost:8000")!
        let production = URL(string: "https://vitail.example.test")!
        let stores = [
            WalkDraftFileStore(ownerID: 1, serverURL: local, directory: directory),
            WalkDraftFileStore(ownerID: 2, serverURL: local, directory: directory),
            WalkDraftFileStore(ownerID: 1, serverURL: production, directory: directory),
            WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        ]
        let drafts = stores.map { _ in draft() }
        XCTAssertEqual(Set(stores.map(\.fileURL)).count, stores.count)
        for (index, store) in stores.enumerated() { try store.save(drafts[index]) }
        for (index, store) in stores.enumerated() { XCTAssertEqual(try store.load(), drafts[index]) }

        try stores[0].clear()
        XCTAssertNil(try stores[0].load())
        for index in 1..<stores.count { XCTAssertEqual(try stores[index].load(), drafts[index]) }
    }

    func testBackendTrailingSlashUsesSameScopeAndCannotCollideWithHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = URL(string: "https://vitail.example.test")!
        let first = WalkDraftFileStore(ownerID: 1, serverURL: server, directory: directory)
        let slash = WalkDraftFileStore(
            ownerID: 1, serverURL: URL(string: "https://vitail.example.test/"), directory: directory
        )
        let history = WalkHistoryFileStore(ownerID: 1, serverURL: server, directory: directory)
        XCTAssertEqual(first.fileURL, slash.fileURL)
        XCTAssertNotEqual(first.fileURL, history.fileURL)
        XCTAssertFalse(first.fileURL.lastPathComponent.contains("vitail.example.test"))

        let original = draft()
        let finished = finishedRecord(for: original)
        try history.save([finished])
        try first.save(original)
        try first.clear()
        XCTAssertEqual(try history.load(), [finished])
    }

    func testDefaultStorageUsesAppApplicationSupportWithoutCreatingFiles() {
        let store = WalkDraftFileStore(ownerID: 10, serverURL: nil)
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, "WalkDrafts")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().deletingLastPathComponent(), applicationSupport)
    }

    func testInvalidDraftCannotReplaceThePreviousCheckpoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        let original = draft()
        try store.save(original)
        let previousBytes = try Data(contentsOf: store.fileURL)

        for invalid in [
            draft(duration: -1), draft(duration: .infinity),
            draft(distance: -1), draft(distance: .nan),
            draft(dogs: []), draft(dogs: [dog(), dog()]),
            draft(dogs: [dog(id: 0)]), draft(dogs: [dog(name: " \n ")]),
            draft(checkpoint: referenceDate.addingTimeInterval(-1)),
            draft(checkpoint: Date(timeIntervalSince1970: .infinity)),
            draft(start: Date(timeIntervalSince1970: -.infinity))
        ] {
            XCTAssertFalse(invalid.isValid)
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), previousBytes)
        }
        XCTAssertEqual(try store.load(), original)
    }

    func testRouteValidationRejectsInvalidCoordinatesTimestampsAndOrdering() {
        let valid = point(seconds: 10)
        let invalidRoutes: [[[WalkRoutePoint]]] = [
            [[]],
            [[WalkRoutePoint(latitude: 91, longitude: 0, timestamp: referenceDate)]],
            [[WalkRoutePoint(latitude: 0, longitude: 181, timestamp: referenceDate)]],
            [[WalkRoutePoint(latitude: .nan, longitude: 0, timestamp: referenceDate)]],
            [[WalkRoutePoint(latitude: 0, longitude: 0, timestamp: Date(timeIntervalSince1970: .infinity))]],
            [[valid, valid]],
            [[valid, point(seconds: 5)]],
            [[valid], [point(seconds: 5)]]
        ]
        for route in invalidRoutes { XCTAssertFalse(draft(route: route).isValid) }
        XCTAssertTrue(draft(route: []).isValid)
        XCTAssertTrue(draft(route: [[point(seconds: -5)], [point(seconds: 10)]]).isValid)
    }

    func testInvalidDogMetadataIsRejected() {
        var negativeAge = dog()
        negativeAge.ageMonths = -1
        var missingBreed = dog()
        missingBreed.breed = Breed(
            id: 0, name: "", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false
        )
        XCTAssertFalse(draft(dogs: [negativeAge]).isValid)
        XCTAssertFalse(draft(dogs: [missingBreed]).isValid)
    }

    func testMismatchingOrInvalidFinishedRecordsAreRejected() {
        var original = draft()
        let good = finishedRecord(for: original)
        let invalidRecords = [
            WalkRecord(
                id: UUID(), startedAt: good.startedAt, endedAt: good.endedAt,
                activeDuration: good.activeDuration, distanceMetres: good.distanceMetres,
                dogs: good.dogs, routeSegments: good.routeSegments
            ),
            WalkRecord(
                id: original.id, startedAt: good.startedAt, endedAt: good.endedAt,
                activeDuration: -1, distanceMetres: good.distanceMetres,
                dogs: good.dogs, routeSegments: good.routeSegments
            ),
            WalkRecord(
                id: original.id, startedAt: good.startedAt, endedAt: good.endedAt,
                activeDuration: good.activeDuration, distanceMetres: good.distanceMetres + 1,
                dogs: good.dogs, routeSegments: good.routeSegments
            ),
            WalkRecord(
                id: original.id, startedAt: good.startedAt, endedAt: good.endedAt,
                activeDuration: good.activeDuration, distanceMetres: good.distanceMetres,
                dogs: [], routeSegments: good.routeSegments
            ),
            WalkRecord(
                id: original.id, startedAt: good.startedAt, endedAt: good.endedAt.addingTimeInterval(1),
                activeDuration: good.activeDuration, distanceMetres: good.distanceMetres,
                dogs: good.dogs, routeSegments: good.routeSegments
            )
        ]
        for invalid in invalidRecords {
            original.finishedRecord = invalid
            XCTAssertFalse(original.isValid)
        }
        original.finishedRecord = good
        XCTAssertTrue(original.isValid)
    }

    func testCorruptCheckpointIsNotDeletedOrOverwrittenByReadOrSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        try store.save(draft())
        let corrupt = Data("This temporary fixture is not valid checkpoint JSON.".utf8)
        try corrupt.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(draft()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testUnknownSchemaAndInvalidStoredValuesArePreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        try store.save(draft())
        let originalJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        var unknownSchema = originalJSON
        unknownSchema["version"] = 99
        var invalidValues = originalJSON
        var draftJSON = try XCTUnwrap(invalidValues["draft"] as? [String: Any])
        draftJSON["distanceMetres"] = -1
        invalidValues["draft"] = draftJSON

        for invalidJSON in [unknownSchema, invalidValues] {
            let bytes = try JSONSerialization.data(withJSONObject: invalidJSON)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(draft()))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
    }

    func testCheckpointFileCanRemainAccessibleWhenPhoneLocksAfterFirstUnlock() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalkDraftFileStore(ownerID: 1, serverURL: nil, directory: directory)
        try store.save(draft())
        // Verify replacement writes retain the intended protection class too.
        try store.save(draft(distance: 200))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue
            ?? attributes[.protectionKey] as? String
        #if targetEnvironment(simulator)
        if protection == nil {
            throw XCTSkip("This simulator does not expose file protection attributes; verify on an iPhone.")
        }
        #endif
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitailWalkDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func draft(
        start: Date? = nil,
        checkpoint: Date? = nil,
        duration: TimeInterval = 60,
        distance: Double = 125,
        dogs: [Dog]? = nil,
        route: [[WalkRoutePoint]]? = nil
    ) -> WalkDraft {
        WalkDraft(
            id: UUID(), startedAt: start ?? referenceDate,
            checkpointAt: checkpoint ?? referenceDate.addingTimeInterval(90),
            activeDuration: duration, distanceMetres: distance,
            dogs: dogs ?? [dog(), dog(id: 2, name: "Luna")],
            routeSegments: route ?? [[point(seconds: 0), point(seconds: 20)], [point(seconds: 80)]]
        )
    }

    private func finishedRecord(for draft: WalkDraft) -> WalkRecord {
        WalkRecord(
            id: draft.id, startedAt: draft.startedAt, endedAt: draft.checkpointAt,
            activeDuration: draft.activeDuration, distanceMetres: draft.distanceMetres,
            dogs: draft.dogs.map { WalkDogSnapshot(id: $0.id, name: $0.name) },
            routeSegments: draft.routeSegments
        )
    }

    private func dog(id: Int = 1, name: String = "Milo") -> Dog {
        Dog(
            id: id, name: name, photo: nil,
            breed: Breed(id: 1, name: "Mixed Breed", energyLevel: .moderate, defaultSize: .medium, isBrachycephalic: false),
            ageMonths: 24, size: .medium, isBrachycephalic: false,
            createdAt: "2026-09-08T00:00:00Z"
        )
    }

    private func point(seconds: TimeInterval) -> WalkRoutePoint {
        WalkRoutePoint(
            latitude: -37.8136 + seconds / 100_000, longitude: 144.9631,
            timestamp: referenceDate.addingTimeInterval(seconds)
        )
    }
}
