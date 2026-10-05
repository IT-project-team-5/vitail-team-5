import XCTest
@testable import Vitail

@MainActor
final class VenuesTests: XCTestCase {
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
    private let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!

    func setNextStatus(_ value: VenueCheckInSessionStatus) { nextStatus = value }
    func fetchVenues() async throws -> [CheckInVenue] { [venue()] }
    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> VenueCheckInSession {
        startedVenueIDs.append(venueID); return session()
    }
    func reportLocation(checkInID: UUID, sample: LocationSample) async throws -> VenueCheckInSession { session(nextStatus) }
    func cancelCheckIn(checkInID: UUID) async throws { cancelledIDs.append(checkInID) }
    func collectCheckIn(attemptID: UUID) async throws -> VenueCheckInCollectionReceipt {
        VenueCheckInCollectionReceipt(checkIn: session(.collected), awardedPoints: 12)
    }

    private func venue() -> CheckInVenue {
        CheckInVenue(id: 1, name: "Venue 1", kindRaw: "CAFE", description: "", address: "",
                     openingHours: "", latitude: -37.8136, longitude: 144.9631, checkinRadiusM: 20,
                     requiredSeconds: 600, checkInStatus: "AVAILABLE")
    }
    private func session(_ status: VenueCheckInSessionStatus = .inProgress) -> VenueCheckInSession {
        VenueCheckInSession(id: attemptID, venueID: 1, venueName: "Venue 1", status: status,
                            requiredSeconds: 600, verifiedSeconds: status == .inProgress ? 0 : 600, rewardPoints: 12)
    }
}
