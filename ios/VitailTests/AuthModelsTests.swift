import CoreLocation
import XCTest
@testable import Vitail

final class AuthModelsTests: XCTestCase {
    func testAuthResponseDecodesSnakeCaseContract() throws {
        let json = #"""
        {
          "access": "access-token",
          "refresh": "refresh-token",
          "user": {
            "id": 42,
            "email": "owner@example.com",
            "display_name": "Taylor",
            "role": "OWNER"
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)

        XCTAssertEqual(response.user.id, 42)
        XCTAssertEqual(response.user.displayName, "Taylor")
        XCTAssertEqual(response.user.role, .owner)
        XCTAssertEqual(response.tokens.refresh, "refresh-token")
    }

    func testOnlyOwnerAndCafeRolesAreSupportedOnMobile() {
        XCTAssertTrue(UserRole.owner.isSupportedOnMobile)
        XCTAssertTrue(UserRole.cafe.isSupportedOnMobile)
        XCTAssertFalse(UserRole.admin.isSupportedOnMobile)
    }

    func testRegisterRequestEncodesDisplayNameAsSnakeCase() throws {
        let request = RegisterRequest(
            email: "owner@example.com",
            password: "example-password",
            displayName: "Taylor"
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object["display_name"], "Taylor")
        XCTAssertNil(object["displayName"])
    }

    func testAccountTypesMapToExpectedRoles() async {
        await MainActor.run {
            XCTAssertEqual(AuthViewModel.AccountType.dogOwner.role, .owner)
            XCTAssertEqual(AuthViewModel.AccountType.cafeOwner.role, .cafe)
        }
    }

    func testSelectingCafeOwnerForcesSignIn() async {
        await MainActor.run {
            let viewModel = AuthViewModel()
            viewModel.mode = .register

            viewModel.select(.cafeOwner)

            XCTAssertEqual(viewModel.accountType, .cafeOwner)
            XCTAssertEqual(viewModel.mode, .login)
        }
    }

    func testRoleMismatchExplainsHowToRetry() {
        let error = APIError.roleMismatch(expected: .owner, actual: .cafe)

        XCTAssertEqual(
            error.localizedDescription,
            "This is a café account. Choose “I'm a cafe owner” to sign in."
        )
    }
}

@MainActor
final class WalkSessionTrackerTests: XCTestCase {
    func testDistanceOnlyCountsWhileWalking() {
        let tracker = WalkSessionTracker()
        let first = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let second = location(latitude: -37.8126, longitude: 144.9631, seconds: 10)
        let third = location(latitude: -37.8116, longitude: 144.9631, seconds: 20)
        let fourth = location(latitude: -37.8106, longitude: 144.9631, seconds: 30)

        tracker.start(from: first)
        tracker.record(second)
        let distanceBeforePause = tracker.distanceMetres

        tracker.pause()
        tracker.record(third)
        XCTAssertEqual(tracker.distanceMetres, distanceBeforePause, accuracy: 0.01)

        tracker.resume(from: third)
        tracker.record(fourth)

        let expectedDistance = second.distance(from: first) + fourth.distance(from: third)
        XCTAssertEqual(tracker.distanceMetres, expectedDistance, accuracy: 0.01)
    }

    func testPoorAccuracyLocationsAreIgnored() {
        let tracker = WalkSessionTracker()
        let accurate = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let inaccurate = location(
            latitude: -37.8036,
            longitude: 144.9631,
            accuracy: 50,
            seconds: 10
        )

        tracker.start(from: accurate)
        tracker.record(inaccurate)

        XCTAssertEqual(tracker.distanceMetres, 0)
    }

    func testStartingANewWalkResetsDistance() {
        let tracker = WalkSessionTracker()
        let first = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let second = location(latitude: -37.8126, longitude: 144.9631, seconds: 10)

        tracker.start(from: first)
        tracker.record(second)
        XCTAssertGreaterThan(tracker.distanceMetres, 0)

        tracker.finish()
        tracker.start(from: second)

        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.status, .walking)
    }

    private func location(
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees,
        accuracy: CLLocationAccuracy = 5,
        seconds: TimeInterval
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            course: 0,
            speed: 1,
            timestamp: Date(timeIntervalSince1970: seconds)
        )
    }
}
