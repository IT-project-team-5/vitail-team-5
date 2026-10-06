import CoreLocation
import XCTest
@testable import Vitail

@MainActor
final class VenuesTests: XCTestCase {
    func testDisplayUsesOnlyVerifiedDwellAndHonoursServerReset() async {
        let service = VenueCheckInStub(); let location = LocationStub(); let clock = VenueClock()
        let model = makeModel(service: service, location: location, clock: clock)
        await model.load(); await model.start(model.venues[0])
        await service.setVerifiedSeconds(25)
        clock.advance(25); location.emit(sample); await settle()
        XCTAssertEqual(model.elapsedSeconds, 25)
        XCTAssertEqual(model.remainingSeconds(for: model.activeCheckIn!), 575)
        await service.setVerifiedSeconds(0)
        clock.advance(100); location.emit(sample); await settle()
        XCTAssertEqual(model.elapsedSeconds, 0)
        model.stop()
    }

    func testExistingInProgressVisitCanResumeAfterRelaunch() async {
        let service = VenueCheckInStub(); let location = LocationStub()
        await service.setVenueStatus("IN_PROGRESS")
        let model = makeModel(service: service, location: location)
        await model.load(); await model.start(model.venues[0])
        XCTAssertNotNil(model.activeCheckIn)
        XCTAssertEqual(location.startCount, 1)
        model.stop()
    }

    func testLateStartCannotRestartGPSAfterStop() async {
        let service = VenueCheckInStub(); let location = LocationStub()
        await service.suspendStart()
        let model = makeModel(service: service, location: location)
        await model.load()
        let start = Task { await model.start(model.venues[0]) }
        await service.waitForStart()
        model.stop()
        await service.finishStart()
        await start.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.venues.isEmpty)
        XCTAssertEqual(location.startCount, 0)
    }

    func testOldReadyReportCannotReplaceRestartedAttempt() async {
        let service = VenueCheckInStub(); let location = LocationStub(); let clock = VenueClock()
        let model = makeModel(service: service, location: location, clock: clock)
        await model.load(); await model.start(model.venues[0])
        await service.setNextStatus(.ready); await service.suspendReport()
        clock.advance(25); location.emit(sample)
        await service.waitForReport()
        await model.cancel()
        await service.setNextStatus(.inProgress)
        await model.start(model.venues[0])
        let newID = model.activeCheckIn?.id
        await service.finishReport(); await settle()
        XCTAssertNotNil(newID)
        XCTAssertEqual(model.activeCheckIn?.id, newID)
        XCTAssertEqual(location.startCount, 2)
        model.stop()
    }

    func testSessionLossStopsGPSWithoutBeforeLogoutHook() async {
        let session = SessionStore(authService: VenueAuthStub())
        await session.restore()
        let location = LocationStub()
        let model = VenuesViewModel(service: VenueCheckInStub(), location: location, session: session, ownerID: 1)
        await model.load(); await model.start(model.venues[0])
        await session.logout()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.venues.isEmpty)
        XCTAssertGreaterThanOrEqual(location.stopCount, 1)
    }

    func testLocationBoundaryRejectsStaleFutureAndImpreciseFixes() {
        let now = Date()
        for (age, accuracy, valid) in [(0.0, 5.0, true), (16, 5, false), (-6, 5, false), (0, 31, false), (0, -1, false)] {
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -37.8, longitude: 144.9),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-age))
            XCTAssertEqual(CheckInLocationManager.freshSample(fix, now: now) != nil, valid)
        }
    }

    private let sample = LocationSample(latitude: -37.8136, longitude: 144.9631, accuracyM: 5)

    private func makeModel(service: VenueCheckInStub = VenueCheckInStub(), location: LocationStub? = nil,
                           clock: VenueClock = VenueClock()) -> VenuesViewModel {
        VenuesViewModel(service: service, location: location ?? LocationStub(), now: { clock.date })
    }

    func testVenueAndSessionDecodeServerJSON() throws {
        let venue = try JSONDecoder().decode(CheckInVenue.self, from: Data(
            #"{"id":3,"name":"Park","kind":"PARK","description":"","address":"1 St","opening_hours":"","latitude":-37.8,"longitude":145.0,"checkin_radius_m":20,"required_seconds":300,"checkin_status":"AVAILABLE"}"#.utf8))
        XCTAssertEqual(venue.venueType, .dogPark)
        XCTAssertEqual(venue.dwellText, "5 min")
        let checkIn = try JSONDecoder().decode(VenueCheckInSession.self, from: Data(
            #"{"id":"00000000-0000-0000-0000-000000000100","venue_id":3,"venue_name":"Park","status":"READY","required_seconds":300,"verified_seconds":300,"reward_points":12}"#.utf8))
        XCTAssertEqual(checkIn.status, .ready)
    }

    func testSampleEncodesSnakeCaseKeys() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["latitude", "longitude", "accuracy_m", "is_simulated"])
    }

    func testStartVerifiesLocationThenBeginsMonitoring() async {
        let service = VenueCheckInStub(); let location = LocationStub()
        let model = makeModel(service: service, location: location)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertNotNil(model.activeCheckIn)
        XCTAssertEqual(location.startCount, 1)
        let started = await service.startedVenueIDs
        XCTAssertEqual(started, [1])
    }

    func testLocationFailureDoesNotCallServer() async {
        let service = VenueCheckInStub(); let location = LocationStub(); location.fixError = CheckInLocationError.denied
        let model = makeModel(service: service, location: location)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertEqual(model.errorMessage, CheckInLocationError.denied.errorDescription)
        let started = await service.startedVenueIDs
        XCTAssertTrue(started.isEmpty)
    }

    func testReadyReportStopsMonitoringThenCollectionRefreshesWallet() async {
        let service = VenueCheckInStub(); let location = LocationStub(); let clock = VenueClock()
        let model = makeModel(service: service, location: location, clock: clock)
        var walletRefreshes = 0
        model.onPointsAwarded = { walletRefreshes += 1 }
        await model.load()
        await model.start(model.venues[0])
        await service.setNextStatus(.ready)
        clock.advance(25); location.emit(sample); await settle()
        guard case let .finished(result) = model.phase else { return XCTFail("Expected ready state") }
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(location.stopCount, 1)
        XCTAssertEqual(walletRefreshes, 0)
        await model.collect()
        guard case let .finished(collected) = model.phase else { return XCTFail("Expected collection state") }
        XCTAssertEqual(collected.status, .collected)
        XCTAssertEqual(walletRefreshes, 1)
    }

    func testCancelStopsLocationAndCancelsServerAttempt() async {
        let service = VenueCheckInStub(); let location = LocationStub()
        let model = makeModel(service: service, location: location)
        await model.load(); await model.start(model.venues[0]); await model.cancel()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(location.stopCount, 1)
        let cancelled = await service.cancelledIDs
        XCTAssertEqual(cancelled.count, 1)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

final class VenueClock: @unchecked Sendable {
    private(set) var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
final class LocationStub: CheckInLocationProviding {
    var onLocation: ((LocationSample) -> Void)?
    var fixError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func currentSample() async throws -> LocationSample {
        if let fixError { throw fixError }
        return LocationSample(latitude: -37.8136, longitude: 144.9631, accuracyM: 5)
    }
    func startMonitoring() { startCount += 1 }
    func stopMonitoring() { stopCount += 1 }
    func emit(_ sample: LocationSample) { onLocation?(sample) }
}

actor VenueCheckInStub: VenueCheckInServing {
    private(set) var startedVenueIDs: [Int] = []
    private(set) var cancelledIDs: [UUID] = []
    private var nextStatus: VenueCheckInSessionStatus = .inProgress
    private var attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    private var venueStatus = "AVAILABLE"
    private var seconds = 0
    private var holdsStart = false, holdsReport = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var reportWaiter: CheckedContinuation<Void, Never>?
    private var startEntered: CheckedContinuation<Void, Never>?
    private var reportEntered: CheckedContinuation<Void, Never>?
    func setVenueStatus(_ value: String) { venueStatus = value }
    func setVerifiedSeconds(_ value: Int) { seconds = value }
    func suspendStart() { holdsStart = true }
    func suspendReport() { holdsReport = true }
    func waitForStart() async {
        if startWaiter != nil { return }
        await withCheckedContinuation { startEntered = $0 }
    }
    func waitForReport() async {
        if reportWaiter != nil { return }
        await withCheckedContinuation { reportEntered = $0 }
    }
    func finishStart() { holdsStart = false; startWaiter?.resume(); startWaiter = nil }
    func finishReport() { holdsReport = false; reportWaiter?.resume(); reportWaiter = nil }

    func setNextStatus(_ value: VenueCheckInSessionStatus) { nextStatus = value }
    func fetchVenues() async throws -> [CheckInVenue] { [venue()] }
    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> VenueCheckInSession {
        startedVenueIDs.append(venueID)
        let result = session()
        if holdsStart {
            await withCheckedContinuation { startWaiter = $0; startEntered?.resume(); startEntered = nil }
        }
        return result
    }
    func reportLocation(checkInID: UUID, sample: LocationSample) async throws -> VenueCheckInSession {
        let result = session(nextStatus)
        if holdsReport {
            await withCheckedContinuation { reportWaiter = $0; reportEntered?.resume(); reportEntered = nil }
        }
        return result
    }
    func cancelCheckIn(checkInID: UUID) async throws { cancelledIDs.append(checkInID); attemptID = UUID() }
    func collectCheckIn(attemptID: UUID) async throws -> VenueCheckInCollectionReceipt {
        VenueCheckInCollectionReceipt(checkIn: session(.collected), awardedPoints: 12)
    }

    private func venue() -> CheckInVenue {
        CheckInVenue(id: 1, name: "Venue 1", kindRaw: "CAFE", description: "", address: "",
                     openingHours: "", latitude: -37.8136, longitude: 144.9631, checkinRadiusM: 20,
                     requiredSeconds: 600, checkInStatus: venueStatus)
    }
    private func session(_ status: VenueCheckInSessionStatus = .inProgress) -> VenueCheckInSession {
        VenueCheckInSession(id: attemptID, venueID: 1, venueName: "Venue 1", status: status,
                            requiredSeconds: 600, verifiedSeconds: status == .inProgress ? seconds : 600, rewardPoints: 12)
    }
}

private actor VenueAuthStub: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    func restoreUser() async throws -> User? { User(id: 1, email: "owner@example.com", displayName: "Owner", role: .owner) }
    func login(email: String, password: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
}
