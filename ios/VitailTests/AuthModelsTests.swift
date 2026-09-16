import CoreLocation
import Foundation
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

    func testOwnerProfileViewModelRequiresAChangedNonBlankName() async {
        await MainActor.run {
            let user = User(
                id: 1,
                email: "owner@example.com",
                displayName: "Taylor",
                role: .owner
            )
            let viewModel = OwnerProfileViewModel(user: user)

            XCTAssertFalse(viewModel.canSave)
            viewModel.displayName = "   "
            XCTAssertFalse(viewModel.canSave)
            viewModel.displayName = "Cache"
            XCTAssertTrue(viewModel.canSave)
        }
    }

    #if DEBUG
    func testDebugBackendURLCanBeSavedAndReset() throws {
        let suiteName = "DebugBackendURLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try AppConfiguration.saveDebugAPIBaseURL(
            "  http://192.168.1.50:8000/  ",
            defaults: defaults
        )

        XCTAssertEqual(url.absoluteString, "http://192.168.1.50:8000")
        XCTAssertEqual(AppConfiguration.debugAPIBaseURL(defaults: defaults), url)

        AppConfiguration.resetDebugAPIBaseURL(defaults: defaults)
        XCTAssertNil(AppConfiguration.debugAPIBaseURL(defaults: defaults))
    }

    func testDebugBackendURLRejectsInvalidValues() throws {
        let suiteName = "DebugBackendURLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for value in [
            "", "example.com", "ftp://example.com", "http://", "https://:8000",
            "https:///missing", "https://example.com/path",
            "https://user:password@example.com", "https://example.com?query=1",
            "https://example.com#fragment"
        ] {
            XCTAssertThrowsError(
                try AppConfiguration.saveDebugAPIBaseURL(value, defaults: defaults),
                "Expected \(value) to be rejected"
            )
        }
        XCTAssertNil(AppConfiguration.debugAPIBaseURL(defaults: defaults))
    }

    func testExistingAPIClientUsesSavedAndResetDebugURLForAllMethods() async throws {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: AppConfiguration.debugAPIBaseURLKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: AppConfiguration.debugAPIBaseURLKey)
            } else {
                defaults.removeObject(forKey: AppConfiguration.debugAPIBaseURLKey)
            }
            DebugBackendURLProtocol.handler = nil
        }

        try AppConfiguration.saveDebugAPIBaseURL("https://before.example")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugBackendURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let client = APIClient(session: urlSession)
        let fixedClient = APIClient(baseURL: URL(string: "https://fixed.example"), session: urlSession)

        try AppConfiguration.saveDebugAPIBaseURL("https://after.example")
        for method in ["GET", "POST", "PATCH", "DELETE"] {
            DebugBackendURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "after.example")
                XCTAssertEqual(request.url?.path, "/api/dogs")
                XCTAssertEqual(request.httpMethod, method)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                return DebugBackendURLProtocol.response(
                    for: request,
                    statusCode: method == "DELETE" ? 204 : 200,
                    json: method == "DELETE" ? "" : #"{"ok":true}"#
                )
            }

            switch method {
            case "GET":
                let response: DebugProbeResponse = try await client.get("/api/dogs", bearerToken: "test-token")
                XCTAssertTrue(response.ok)
            case "POST":
                let response: DebugProbeResponse = try await client.post(
                    "/api/dogs", body: ["name": "Milo"], bearerToken: "test-token"
                )
                XCTAssertTrue(response.ok)
            case "PATCH":
                let response: DebugProbeResponse = try await client.patch(
                    "/api/dogs", body: ["name": "Milo"], bearerToken: "test-token"
                )
                XCTAssertTrue(response.ok)
            default:
                try await client.delete("/api/dogs", bearerToken: "test-token")
            }
        }

        DebugBackendURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "fixed.example")
            return DebugBackendURLProtocol.response(for: request, json: #"{"ok":true}"#)
        }
        let fixedResponse: DebugProbeResponse = try await fixedClient.get("/probe")
        XCTAssertTrue(fixedResponse.ok)

        AppConfiguration.resetDebugAPIBaseURL()
        let bundledURL = try XCTUnwrap(AppConfiguration.apiBaseURL)
        DebugBackendURLProtocol.handler = { request in
            XCTAssertEqual(request.url, bundledURL.appendingPathComponent("probe"))
            return DebugBackendURLProtocol.response(for: request, json: #"{"ok":true}"#)
        }
        let resetResponse: DebugProbeResponse = try await client.get("/probe")
        XCTAssertTrue(resetResponse.ok)
    }
    #endif
}

@MainActor
final class WalkSessionTrackerTests: XCTestCase {
    func testDistanceOnlyCountsWhileWalking() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = WalkSessionTracker(now: { now })
        let first = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let second = location(latitude: -37.8126, longitude: 144.9631, seconds: 10)
        let third = location(latitude: -37.8116, longitude: 144.9631, seconds: 20)
        let fourth = location(latitude: -37.8106, longitude: 144.9631, seconds: 30)

        tracker.start(from: first, dogs: [dog()])
        now = second.timestamp
        tracker.record(second)
        let distanceBeforePause = tracker.distanceMetres

        tracker.pause()
        tracker.record(third)
        XCTAssertEqual(tracker.distanceMetres, distanceBeforePause, accuracy: 0.01)

        now = third.timestamp
        tracker.resume(from: third)
        now = fourth.timestamp
        tracker.record(fourth)

        let expectedDistance = second.distance(from: first) + fourth.distance(from: third)
        XCTAssertEqual(tracker.distanceMetres, expectedDistance, accuracy: 0.01)
    }

    func testPoorAccuracyLocationsAreIgnored() {
        let tracker = WalkSessionTracker(now: { Date(timeIntervalSince1970: 0) })
        let accurate = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let inaccurate = location(
            latitude: -37.8036,
            longitude: 144.9631,
            accuracy: 50,
            seconds: 10
        )

        tracker.start(from: accurate, dogs: [dog()])
        tracker.record(inaccurate)

        XCTAssertEqual(tracker.distanceMetres, 0)
    }

    func testStartingANewWalkResetsDistance() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = WalkSessionTracker(now: { now })
        let first = location(latitude: -37.8136, longitude: 144.9631, seconds: 0)
        let second = location(latitude: -37.8126, longitude: 144.9631, seconds: 10)

        tracker.start(from: first, dogs: [dog()])
        now = second.timestamp
        tracker.record(second)
        XCTAssertGreaterThan(tracker.distanceMetres, 0)

        tracker.finish()
        tracker.start(from: second, dogs: [dog()])

        XCTAssertEqual(tracker.distanceMetres, 0)
        XCTAssertEqual(tracker.status, .walking)
    }

    private func dog() -> Dog {
        Dog(
            id: 1,
            name: "Milo",
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

#if DEBUG
private struct DebugProbeResponse: Decodable, Sendable {
    let ok: Bool
}

private final class DebugBackendURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.invalidResponse)
            return
        }

        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}
#endif
