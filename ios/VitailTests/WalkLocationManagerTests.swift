import CoreLocation
import Foundation
import XCTest
@testable import Vitail

@MainActor
final class WalkLocationManagerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_788_800_000)

    func testModesEnableBackgroundUpdatesOnlyDuringRecording() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)

        XCTAssertEqual(driver.mode, .off)
        XCTAssertEqual(driver.state, .idle)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertEqual(client.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(client.distanceFilter, 5)
        XCTAssertEqual(client.activityType, .fitness)
        XCTAssertTrue(client.delegate === driver)

        driver.setMode(.preview)
        XCTAssertEqual(client.startCount, 1)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.showsBackgroundLocationIndicator)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)

        driver.setMode(.recording)
        XCTAssertEqual(client.startCount, 1, "Switching modes must not restart an already active location stream.")
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        XCTAssertTrue(client.showsBackgroundLocationIndicator)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)

        driver.setMode(.recording)
        XCTAssertEqual(client.startCount, 1)
        driver.setMode(.preview)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.showsBackgroundLocationIndicator)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)

        driver.setMode(.off)
        XCTAssertEqual(client.stopCount, 1)
        XCTAssertEqual(driver.state, .idle)
        XCTAssertNil(driver.location)
        XCTAssertTrue(client.pausesLocationUpdatesAutomatically)
    }

    func testFirstPermissionRequestIsWhenInUseAndDoesNotRepeatWhilePending() {
        let client = WalkLocationClientStub()
        client.authorizationStatus = .notDetermined
        let driver = makeDriver(client: client)
        driver.setMode(.preview)
        driver.refreshAuthorization()
        driver.locationManagerDidChangeAuthorization(CLLocationManager())

        XCTAssertEqual(driver.state, .requestingPermission)
        XCTAssertEqual(client.permissionRequestCount, 1)
        XCTAssertEqual(client.startCount, 0)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)

        client.authorizationStatus = .authorizedWhenInUse
        driver.locationManagerDidChangeAuthorization(CLLocationManager())
        XCTAssertEqual(driver.state, .locating)
        XCTAssertEqual(client.startCount, 1)
    }

    func testRecordingDeliversEveryBatchedPointInTimestampOrderSynchronously() {
        let driver = makeDriver()
        var received: [[CLLocation]] = []
        driver.onLocations = { received.append($0) }
        driver.setMode(.recording)
        let batch = [location(seconds: 0), location(seconds: -60), location(seconds: -10), location(seconds: -30)]

        driver.locationManager(CLLocationManager(), didUpdateLocations: batch)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].map(\.timestamp), batch.map(\.timestamp).sorted())
        XCTAssertEqual(driver.location?.timestamp, referenceDate)
        XCTAssertEqual(driver.state, .ready)
    }

    func testPreviewUpdatesMapButDoesNotDeliverRoutePoints() {
        let driver = makeDriver()
        var delivered = false
        driver.onLocations = { _ in delivered = true }
        driver.setMode(.preview)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])

        XCTAssertFalse(delivered)
        XCTAssertEqual(driver.state, .ready)
        XCTAssertNotNil(driver.location)
    }

    func testOlderBatchesDoNotMoveTheCurrentMapLocationBackwards() {
        let driver = makeDriver()
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location(seconds: -10)])

        XCTAssertEqual(driver.location?.timestamp, referenceDate)
        XCTAssertEqual(driver.state, .ready)
    }

    func testCachedAndFutureLocationsCannotMakeStartLocationReady() {
        let driver = makeDriver()
        var forwardedCount = 0
        driver.onLocations = { forwardedCount += $0.count }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [
            location(seconds: -16), location(seconds: 6),
            location(accuracy: -1), location(latitude: 95)
        ])

        XCTAssertNil(driver.location)
        XCTAssertEqual(driver.state, .locating)
        XCTAssertEqual(forwardedCount, 4, "Route filtering belongs to the tracker, not the current-location preview.")
    }

    func testForegroundAuthorizationRefreshExpiresAnOldCurrentLocation() {
        var currentTime = referenceDate
        let driver = WalkLocationManager(
            client: WalkLocationClientStub(), locationServicesEnabled: { true }, now: { currentTime }
        )
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        XCTAssertNotNil(driver.location)

        currentTime = referenceDate.addingTimeInterval(16)
        driver.refreshAuthorization()
        XCTAssertNil(driver.location)
        XCTAssertEqual(driver.state, .locating)
    }

    func testTurningOffPreciseLocationClearsPositionAndRequiresPause() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        client.accuracyAuthorization = .reducedAccuracy
        driver.locationManagerDidChangeAuthorization(CLLocationManager())

        XCTAssertEqual(driver.state, .preciseLocationRequired)
        XCTAssertNil(driver.location)
        XCTAssertEqual(interruptions, [true])
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertEqual(client.stopCount, 1)

        client.accuracyAuthorization = .fullAccuracy
        driver.refreshAuthorization()
        XCTAssertEqual(driver.state, .locating)
        XCTAssertEqual(client.startCount, 2)
    }

    func testPermissionRevocationAndRestrictionStopUpdatesAndClearPosition() {
        for status: CLAuthorizationStatus in [.denied, .restricted, .notDetermined] {
            let client = WalkLocationClientStub()
            let driver = makeDriver(client: client)
            var pauseRequired = false
            driver.onInterruption = { _, required in pauseRequired = required }
            driver.setMode(.recording)
            driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
            client.authorizationStatus = status
            driver.refreshAuthorization()

            XCTAssertTrue(pauseRequired)
            XCTAssertNil(driver.location)
            XCTAssertFalse(client.allowsBackgroundLocationUpdates)
            XCTAssertFalse(client.showsBackgroundLocationIndicator)
            XCTAssertEqual(client.stopCount, 1)
            switch status {
            case .denied: XCTAssertEqual(driver.state, .denied)
            case .restricted: XCTAssertEqual(driver.state, .restricted)
            default: XCTAssertEqual(driver.state, .requestingPermission)
            }
        }
    }

    func testTurningOffDeviceLocationServicesRequiresPauseOnForegroundRefresh() {
        let client = WalkLocationClientStub()
        var servicesEnabled = true
        let driver = WalkLocationManager(
            client: client, locationServicesEnabled: { servicesEnabled }, now: { self.referenceDate }
        )
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        servicesEnabled = false
        driver.refreshAuthorization()

        XCTAssertEqual(driver.state, .servicesDisabled)
        XCTAssertNil(driver.location)
        XCTAssertEqual(interruptions, [true])
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertEqual(client.stopCount, 1)
    }

    func testTemporaryGPSLossSplitsRouteWithoutStoppingTheService() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])

        driver.locationManager(CLLocationManager(), didFailWithError: NSError(
            domain: kCLErrorDomain, code: CLError.Code.locationUnknown.rawValue
        ))

        XCTAssertEqual(driver.state, .locating)
        XCTAssertNil(driver.location)
        XCTAssertEqual(interruptions, [false])
        XCTAssertEqual(client.stopCount, 0)
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)

        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        XCTAssertEqual(driver.state, .ready)
        XCTAssertNotNil(driver.location)
    }

    func testUnexpectedSystemPauseSplitsRouteAndRestartsLocationStream() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])

        driver.locationManagerDidPauseLocationUpdates(CLLocationManager())

        XCTAssertEqual(interruptions, [false])
        XCTAssertEqual(client.startCount, 2)
        XCTAssertEqual(driver.state, .locating)
        XCTAssertNil(driver.location)
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)
    }

    func testUnexpectedPreviewPauseRestartsBeforeSwitchingToRecording() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptionCount = 0
        driver.onInterruption = { _, _ in interruptionCount += 1 }
        driver.setMode(.preview)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        XCTAssertEqual(client.startCount, 1)

        driver.locationManagerDidPauseLocationUpdates(CLLocationManager())

        XCTAssertEqual(client.startCount, 2, "A paused preview stream must really restart instead of remaining marked as running.")
        XCTAssertNil(driver.location)
        XCTAssertEqual(driver.state, .locating)
        XCTAssertEqual(interruptionCount, 0)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)

        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        XCTAssertEqual(driver.state, .ready)
        driver.setMode(.recording)
        XCTAssertEqual(client.startCount, 2, "The preview recovery already restarted the stream.")
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        XCTAssertFalse(client.pausesLocationUpdatesAutomatically)
    }

    func testSystemResumeDoesNotRestartAnAlreadyResumedPreviewStream() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        driver.setMode(.preview)
        driver.locationManagerDidPauseLocationUpdates(CLLocationManager())
        XCTAssertEqual(client.startCount, 2)

        driver.locationManagerDidResumeLocationUpdates(CLLocationManager())
        driver.refreshAuthorization()

        XCTAssertEqual(client.startCount, 2)
        XCTAssertEqual(driver.state, .locating)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
    }

    func testOtherLocationErrorsKeepServiceAliveAndRecoverOnTheNextFix() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didFailWithError: NSError(
            domain: "WalkTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "GPS unavailable"]
        ))

        XCTAssertEqual(driver.state, .failed("GPS unavailable"))
        XCTAssertEqual(interruptions, [false])
        XCTAssertEqual(client.stopCount, 0)
        XCTAssertTrue(client.allowsBackgroundLocationUpdates)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        XCTAssertEqual(driver.state, .ready)
    }

    func testDeniedErrorIsHandledEvenBeforeAuthorizationStatusCatchesUp() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var interruptions: [Bool] = []
        driver.onInterruption = { _, pauseRequired in interruptions.append(pauseRequired) }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didFailWithError: NSError(
            domain: kCLErrorDomain, code: CLError.Code.denied.rawValue
        ))

        XCTAssertEqual(driver.state, .denied)
        XCTAssertEqual(interruptions, [true])
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
        XCTAssertEqual(client.stopCount, 1)
    }

    func testStoppedDriverIgnoresLateLocationAndDelegateEvents() {
        let client = WalkLocationClientStub()
        let driver = makeDriver(client: client)
        var receivedCount = 0
        var interruptionCount = 0
        driver.onLocations = { receivedCount += $0.count }
        driver.onInterruption = { _, _ in interruptionCount += 1 }
        driver.setMode(.recording)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        driver.setMode(.off)
        driver.locationManager(CLLocationManager(), didUpdateLocations: [location()])
        driver.locationManagerDidChangeAuthorization(CLLocationManager())
        driver.locationManagerDidPauseLocationUpdates(CLLocationManager())
        driver.locationManager(CLLocationManager(), didFailWithError: NSError(domain: "Test", code: 1))

        XCTAssertEqual(driver.state, .idle)
        XCTAssertNil(driver.location)
        XCTAssertEqual(receivedCount, 1)
        XCTAssertEqual(interruptionCount, 0)
        XCTAssertEqual(client.startCount, 1)
        XCTAssertFalse(client.allowsBackgroundLocationUpdates)
    }

    private func makeDriver(client: WalkLocationClientStub? = nil) -> WalkLocationManager {
        WalkLocationManager(client: client ?? WalkLocationClientStub(), locationServicesEnabled: { true }, now: { self.referenceDate })
    }

    private func location(
        latitude: Double = -37.8136, accuracy: Double = 5, seconds: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 144.9631),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            timestamp: referenceDate.addingTimeInterval(seconds)
        )
    }
}

@MainActor
private final class WalkLocationClientStub: WalkLocationClient {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var pausesLocationUpdatesAutomatically = true
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func requestWhenInUseAuthorization() { permissionRequestCount += 1 }
    func startUpdatingLocation() { startCount += 1 }
    func stopUpdatingLocation() { stopCount += 1 }
}
