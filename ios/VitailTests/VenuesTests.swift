import XCTest
@testable import Vitail

@MainActor
final class VenuesTests: XCTestCase {
    private let sample = LocationSample(latitude: -37.8136, longitude: 144.9631, accuracyM: 5)

    private func makeModel(
        service: VenueStub = VenueStub(), location: LocationStub? = nil, clock: Clock = Clock()
    ) -> VenuesViewModel {
        VenuesViewModel(service: service, location: location ?? LocationStub(), now: { clock.date })
    }

    func testVenueAndCheckInDecodeServerJSON() throws {
        let venue = try JSONDecoder().decode(Venue.self, from: Data(
            #"{"id":3,"name":"Park","venue_type":"DOG_PARK","description":"","address":"1 St","opening_hours":"","latitude":-37.8,"longitude":145.0,"checkin_radius_m":100,"required_dwell_s":300,"checked_in_today":true}"#.utf8))
        XCTAssertEqual(venue.venueType, .dogPark)
        XCTAssertEqual(venue.dwellText, "5 min")
        XCTAssertTrue(venue.checkedInToday)
        let checkIn = try JSONDecoder().decode(CheckIn.self, from: Data(
            #"{"id":9,"venue_id":3,"venue_name":"Park","status":"ABANDONED","abandon_reason":"LEFT_RADIUS","entered_at":"2026-09-09T12:00:00+10:00","required_dwell_s":300,"verified_seconds":60,"awarded_points":0}"#.utf8))
        XCTAssertEqual(checkIn.status, .abandoned)
        XCTAssertTrue(checkIn.abandonMessage.contains("try again"))
    }

    func testUnknownVenueTypeFallsBackToOther() {
        let venue = VenueStub.venue(type: "GROOMER")
        XCTAssertEqual(venue.venueType, .other)
    }

    func testSampleEncodesSnakeCaseKeysAndNothingElse() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["latitude", "longitude", "accuracy_m", "is_simulated"])
    }

    func testStartVerifiesLocationThenBeginsMonitoring() async {
        let service = VenueStub(); let location = LocationStub()
        let model = makeModel(service: service, location: location)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertEqual(model.activeCheckIn?.id, 100)
        XCTAssertEqual(location.startCount, 1)
        let started = await service.startedVenueIDs
        XCTAssertEqual(started, [1])
        XCTAssertTrue(model.isBusy)
    }

    func testStartFailureShowsServerMessageAndStaysIdle() async {
        let service = VenueStub(); await service.failStart(with: APIError.http(status: 400, message: "Move within 100 m of Café to check in."))
        let location = LocationStub()
        let model = makeModel(service: service, location: location)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.errorMessage, "Move within 100 m of Café to check in.")
        XCTAssertEqual(location.startCount, 0)
    }

    func testLocationPermissionFailureStopsBeforeCallingServer() async {
        let service = VenueStub(); let location = LocationStub(); location.fixError = CheckInLocationError.denied
        let model = makeModel(service: service, location: location)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.errorMessage, CheckInLocationError.denied.errorDescription)
        let started = await service.startedVenueIDs
        XCTAssertTrue(started.isEmpty)
    }

    func testAlreadyCheckedInVenueCannotStart() async {
        let service = VenueStub(); await service.setCheckedIn(true)
        let model = makeModel(service: service)
        await model.load()
        await model.start(model.venues[0])
        XCTAssertEqual(model.phase, .idle)
        let started = await service.startedVenueIDs
        XCTAssertTrue(started.isEmpty)
    }

    func testReportsAreThrottledAndCompletionAwardsAndStopsMonitoring() async {
        let service = VenueStub(); let location = LocationStub(); let clock = Clock()
        let model = makeModel(service: service, location: location, clock: clock)
        var awarded = 0
        model.onPointsAwarded = { awarded += 1 }
        await model.load()
        await model.start(model.venues[0])

        clock.advance(5); location.emit(sample); await settle()
        clock.advance(5); location.emit(sample); await settle()
        var reports = await service.reportCount
        XCTAssertEqual(reports, 0, "Fixes inside the throttle window are not sent")

        clock.advance(20); location.emit(sample); await settle()
        reports = await service.reportCount
        XCTAssertEqual(reports, 1)
        XCTAssertNotNil(model.activeCheckIn)

        await service.setNextReport(status: .completed, points: 12)
        clock.advance(30); location.emit(sample); await settle()
        guard case let .finished(result) = model.phase else { return XCTFail("Expected finished") }
        XCTAssertEqual(result.awardedPoints, 12)
        XCTAssertEqual(location.stopCount, 1)
        XCTAssertEqual(awarded, 1)
        XCTAssertFalse(model.isBusy)
    }

    func testServerAbandonEndsCheckInWithoutAward() async {
        let service = VenueStub(); let location = LocationStub(); let clock = Clock()
        let model = makeModel(service: service, location: location, clock: clock)
        var awarded = 0
        model.onPointsAwarded = { awarded += 1 }
        await model.load()
        await model.start(model.venues[0])
        await service.setNextReport(status: .abandoned, points: 0, reason: "LEFT_RADIUS")
        clock.advance(30); location.emit(sample); await settle()
        guard case let .finished(result) = model.phase else { return XCTFail("Expected finished") }
        XCTAssertEqual(result.status, .abandoned)
        XCTAssertEqual(awarded, 0)
        XCTAssertEqual(location.stopCount, 1)
    }

    func testNetworkErrorWhileReportingKeepsTracking() async {
        let service = VenueStub(); let location = LocationStub(); let clock = Clock()
        let model = makeModel(service: service, location: location, clock: clock)
        await model.load()
        await model.start(model.venues[0])
        await service.failReport(true)
        clock.advance(30); location.emit(sample); await settle()
        XCTAssertNotNil(model.activeCheckIn)
        XCTAssertNotNil(model.connectionNotice)
        XCTAssertEqual(location.stopCount, 0)
    }

    func testCancelAndLogoutAbandonAndStopLocation() async {
        for viaLogout in [false, true] {
            let service = VenueStub(); let location = LocationStub()
            let model = makeModel(service: service, location: location)
            await model.load()
            await model.start(model.venues[0])
            if viaLogout { await model.prepareForLogout() } else { await model.cancel() }
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(location.stopCount, 1)
            let abandoned = await service.abandonedIDs
            XCTAssertEqual(abandoned, [100])
        }
    }

    func testSecondCheckInCannotStartWhileOneIsActive() async {
        let service = VenueStub()
        let model = makeModel(service: service)
        await model.load()
        await model.start(model.venues[0])
        await model.start(model.venues[1])
        let started = await service.startedVenueIDs
        XCTAssertEqual(started, [1])
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

final class Clock: @unchecked Sendable {
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

actor VenueStub: VenueServing {
    private(set) var startedVenueIDs: [Int] = []
    private(set) var reportCount = 0
    private(set) var abandonedIDs: [Int] = []
    private var startError: Error?
    private var reportFails = false
    private var checkedIn = false
    private var nextReport: (CheckInStatus, Int, String)?

    static func venue(id: Int = 1, type: String = "CAFE", checkedIn: Bool = false) -> Venue {
        Venue(id: id, name: "Venue \(id)", venueTypeRaw: type, description: "", address: "",
              openingHours: "", latitude: -37.8136, longitude: 144.9631,
              checkinRadiusM: 100, requiredDwellS: 600, checkedInToday: checkedIn)
    }

    func failStart(with error: Error) { startError = error }
    func failReport(_ value: Bool) { reportFails = value }
    func setCheckedIn(_ value: Bool) { checkedIn = value }
    func setNextReport(status: CheckInStatus, points: Int, reason: String = "") { nextReport = (status, points, reason) }

    private func checkIn(_ status: CheckInStatus = .inProgress, points: Int = 0, reason: String = "") -> CheckIn {
        CheckIn(id: 100, venueID: 1, venueName: "Venue 1", status: status, abandonReason: reason,
                requiredDwellS: 600, verifiedSeconds: 0, awardedPoints: points)
    }

    func fetchVenues() async throws -> [Venue] {
        [Self.venue(id: 1, checkedIn: checkedIn), Self.venue(id: 2)]
    }

    func startCheckIn(venueID: Int, sample: LocationSample) async throws -> CheckIn {
        if let startError { throw startError }
        startedVenueIDs.append(venueID)
        return checkIn()
    }

    func reportLocation(checkInID: Int, sample: LocationSample) async throws -> CheckIn {
        if reportFails { throw APIError.network("offline") }
        reportCount += 1
        if let next = nextReport {
            nextReport = nil
            return checkIn(next.0, points: next.1, reason: next.2)
        }
        return checkIn()
    }

    func abandonCheckIn(checkInID: Int) async throws -> CheckIn {
        abandonedIDs.append(checkInID)
        return checkIn(.abandoned, reason: "CANCELLED")
    }
}
