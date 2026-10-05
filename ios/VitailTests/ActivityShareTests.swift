import SwiftUI
import XCTest
@testable import Vitail

@MainActor
final class ActivityShareTests: XCTestCase {
    private func walk(dogs: [String] = ["Milo"], points: Int? = 12) -> WalkRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let route = [[
            WalkRoutePoint(latitude: -37.8136, longitude: 144.9631, timestamp: start),
            WalkRoutePoint(latitude: -37.8140, longitude: 144.9640, timestamp: start.addingTimeInterval(60)),
        ]]
        var record = WalkRecord(
            id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(1800),
            activeDuration: 1700, distanceMetres: 3420,
            dogs: dogs.enumerated().map { WalkDogSnapshot(id: $0.offset + 1, name: $0.element) },
            routeSegments: route
        )
        if let points {
            record.serverSummary = WalkSummary(
                id: 1, requestID: UUID(), startedAt: "", endedAt: "", distanceM: 3420,
                pointsAwarded: points, pointDate: "2026-09-09", dogIDs: [1]
            )
        }
        return record
    }

    func testSummaryCarriesOnlyActivityFieldsAndNeverLocation() {
        let summary = ActivityShareSummary(walk: walk())
        let labels = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        XCTAssertEqual(labels, ["date", "distanceKilometres", "activeDuration", "dogNames", "pointsAwarded"])
        XCTAssertEqual(summary.distanceKilometres, 3.42, accuracy: 0.001)
        XCTAssertEqual(summary.pointsAwarded, 12)
    }

    func testPointsAreUnknownUntilTheServerConfirmsTheWalk() {
        XCTAssertNil(ActivityShareSummary(walk: walk(points: nil)).pointsAwarded)
    }

    func testFormatting() {
        XCTAssertEqual(ActivityShareFormat.distance(3.4249), "3.42 km")
        XCTAssertEqual(ActivityShareFormat.distance(-1), "0.00 km")
        XCTAssertEqual(ActivityShareFormat.duration(1700), "28m 20s")
        XCTAssertEqual(ActivityShareFormat.duration(3_900), "1h 5m")
        XCTAssertEqual(ActivityShareFormat.duration(.infinity), "—")
        XCTAssertNil(ActivityShareFormat.dogs([]))
        XCTAssertNil(ActivityShareFormat.dogs(["  "]))
        XCTAssertEqual(ActivityShareFormat.dogs(["Milo"]), "with Milo")
        XCTAssertEqual(ActivityShareFormat.dogs(["Milo", "Pip"]), "with Milo & Pip")
        XCTAssertEqual(ActivityShareFormat.dogs(["A", "B", "C", "D"]), "with A, B & 2 more")
    }

    func testAccessibilityDescriptionRespectsOptions() {
        let summary = ActivityShareSummary(walk: walk())
        var options = ActivityShareOptions()
        let full = ActivityShareFormat.accessibilityDescription(summary, options: options)
        XCTAssertTrue(full.contains("Milo"))
        XCTAssertTrue(full.contains("12 points"))
        options.showDogNames = false
        options.showPoints = false
        let hidden = ActivityShareFormat.accessibilityDescription(summary, options: options)
        XCTAssertFalse(hidden.contains("Milo"))
        XCTAssertFalse(hidden.contains("points"))
    }

    func testCardRendersAtInstagramPortraitSize() throws {
        let renderer = ImageRenderer(content: ActivityShareCard(
            summary: ActivityShareSummary(walk: walk()), options: ActivityShareOptions()
        ))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width * image.scale, 1080)
        XCTAssertEqual(image.size.height * image.scale, 1350)
    }

    func testCardRendersWithEverythingHiddenAndNoDogs() throws {
        var options = ActivityShareOptions()
        options.showDate = false
        options.showDogNames = false
        options.showPoints = false
        let renderer = ImageRenderer(content: ActivityShareCard(
            summary: ActivityShareSummary(walk: walk(dogs: [], points: nil)), options: options
        ))
        renderer.scale = 1
        XCTAssertNotNil(renderer.uiImage)
    }
}
