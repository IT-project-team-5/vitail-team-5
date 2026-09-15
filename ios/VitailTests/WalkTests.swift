import Foundation
import XCTest
@testable import Vitail

final class WalkTests: XCTestCase {
    func testWalkRequestSendsSamplesNotTrustedDistanceOrPoints() throws {
        let request = WalkRequest(
            requestID: UUID(), startedAt: "2026-09-09T01:00:00Z", endedAt: "2026-09-09T01:01:00Z",
            dogIDs: [1, 2], samples: [WalkSample(
                latitude: -37.81, longitude: 144.96, recordedAt: "2026-09-09T01:00:00Z",
                accuracyM: 5, isSimulated: false
            )]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNotNil(body["request_id"])
        XCTAssertEqual(body["dog_ids"] as? [Int], [1, 2])
        XCTAssertNil(body["distance_m"])
        XCTAssertNil(body["points_awarded"])
        let samples = try XCTUnwrap(body["samples"] as? [[String: Any]])
        XCTAssertEqual(samples[0]["accuracy_m"] as? Double, 5)
        XCTAssertEqual(samples[0]["is_simulated"] as? Bool, false)
    }

    func testWalkSummaryDecodesServerContract() throws {
        let json = #"""
        {"id":1,"request_id":"00000000-0000-0000-0000-000000000001",
        "started_at":"2026-09-09T01:00:00Z","ended_at":"2026-09-09T01:20:00Z",
        "distance_m":1250.5,"points_awarded":10,"point_date":"2026-09-09","dog_ids":[1]}
        """#.data(using: .utf8)!
        let walk = try JSONDecoder().decode(WalkSummary.self, from: json)
        XCTAssertEqual(walk.distanceM, 1250.5)
        XCTAssertEqual(walk.pointsAwarded, 10)
        XCTAssertEqual(walk.dogIDs, [1])
    }

    func testWalkTimestampIsAnISO8601String() {
        XCTAssertEqual(WalkTimestamp.string(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }
}
