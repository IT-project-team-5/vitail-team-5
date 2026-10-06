import CoreLocation
import XCTest
@testable import Vitail

@MainActor
final class FriendsTests: XCTestCase {
    func testOverviewAndInvitationsDecodeServerContractWithoutEmail() throws {
        let profile = #"{"public_id":"abc123","display_name":"Sam","photo_url":null}"#
        let preferences = #"{"public_id":"me123","display_name":"Me","photo_url":null,"location_visibility":"OFF","net_matching_enabled":false}"#
        let relationship = #"{"id":3,"user":\#(profile),"status":"PENDING","is_incoming":true}"#
        let overview = try JSONDecoder().decode(SocialOverview.self, from: Data(
            #"{"me":\#(preferences),"friends":[],"incoming_requests":[\#(relationship)],"outgoing_requests":[],"blocked_users":[],"current_session":null}"#.utf8))
        XCTAssertFalse(overview.me.netMatchingEnabled)
        XCTAssertEqual(overview.incomingRequests.first?.user.publicID, "abc123")
        let session = try JSONDecoder().decode(SocialWalkSession.self, from: Data(
            #"{"id":7,"request_id":"00000000-0000-0000-0000-000000000100","state":"RECORDING","net_consent":true,"shared_distance_m":250.5,"estimated_bonus_points":0,"bonus_points":0,"bonus_status":"awaiting_rules","partner":\#(profile)}"#.utf8))
        XCTAssertEqual(session.bonusStatus, "awaiting_rules")
        XCTAssertEqual(session.bonusPoints, 0)
        let invitations = try JSONDecoder().decode(NetWalkInvitations.self, from: Data(
            #"{"incoming":[{"id":9,"user":\#(profile),"status":"PENDING","is_incoming":true,"created_at":"2026-10-07T03:00:00Z","session_id":7,"partner_session_id":8}],"outgoing":[],"active":null}"#.utf8))
        XCTAssertEqual(invitations.incoming.first?.id, 9)
    }

    func testFreshLocationRequiresAccuracyAndRejectsOldFutureAndSimulatedFixes() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotNil(SocialLocationSample(location(at: date, accuracy: 10), now: date))
        XCTAssertNil(SocialLocationSample(location(at: date.addingTimeInterval(-16)), now: date))
        XCTAssertNil(SocialLocationSample(location(at: date.addingTimeInterval(6)), now: date))
        XCTAssertNil(SocialLocationSample(location(at: date, accuracy: 31), now: date))
        let simulated = CLLocation(coordinate: .init(latitude: -37.8, longitude: 144.9), altitude: 0,
                                   horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, courseAccuracy: 1, speed: 1, speedAccuracy: 1,
                                   timestamp: date, sourceInfo: CLLocationSourceInformation(softwareSimulationState: true, andExternalAccessoryState: false))
        XCTAssertNil(SocialLocationSample(simulated, now: date))
        let sample = try XCTUnwrap(SocialLocationSample(location(at: date), now: date))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["latitude", "longitude", "accuracy_m", "recorded_at", "is_simulated"])
    }

    func testDefaultPrivacyDoesNotCreatePresenceEvenDuringWalk() async {
        let service = FriendsTestService(), clock = FriendsTestClock()
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: UUID(), startedAt: clock.date)
        await store.refresh()
        store.receiveLocation(location(at: clock.date))
        await settle()
        let starts = await service.starts
        let reports = await service.reports
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(reports, 0)
        XCTAssertFalse(store.sharesWithFriends)
        XCTAssertFalse(store.netMatchingEnabled)
        store.stop()
    }

    func testSharedWalkReusesRequestIDThrottlesAndPauseClearsPresence() async {
        let service = FriendsTestService(), clock = FriendsTestClock(), requestID = UUID()
        await service.setSharing(true)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: requestID, startedAt: clock.date)
        await store.refresh(); await settle()
        store.receiveLocation(location(at: clock.date)); await settle()
        clock.advance(1)
        store.receiveLocation(location(at: clock.date)); await settle()
        let firstReports = await service.reports
        XCTAssertEqual(firstReports, 1)
        clock.advance(5)
        store.receiveLocation(location(at: clock.date)); await settle()
        let secondReports = await service.reports
        XCTAssertEqual(secondReports, 2)
        XCTAssertEqual(store.currentSession?.requestID, requestID)
        store.updateWalk(isWalking: false, requestID: requestID, startedAt: clock.date)
        await settle()
        XCTAssertEqual(store.currentSession?.state, "PAUSED")
        XCTAssertTrue(store.peers.isEmpty)
        clock.advance(10); store.receiveLocation(location(at: clock.date)); await settle()
        let afterPause = await service.reports
        XCTAssertEqual(afterPause, 2)
        await store.prepareForLogout()
        let states = await service.states
        XCTAssertTrue(states.contains("FINISHED"))
        XCTAssertNil(store.overview)
    }

    func testPrivacyOffLocallyAndOnServerStopsPublishing() async {
        let service = FriendsTestService(), clock = FriendsTestClock()
        await service.setSharing(true)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: UUID(), startedAt: clock.date)
        await store.refresh(); await settle()
        store.receiveLocation(location(at: clock.date)); await settle()
        await store.updatePreferences(shareWithFriends: false, netMatching: false); await settle()
        XCTAssertFalse(store.sharesWithFriends)
        XCTAssertEqual(store.currentSession?.state, "PAUSED")
        clock.advance(6); store.receiveLocation(location(at: clock.date)); await settle()
        let reports = await service.reports
        XCTAssertEqual(reports, 1)
        store.stop()
    }

    func testFailedOptInNeverStartsSharing() async {
        let service = FriendsTestService(), clock = FriendsTestClock()
        await service.setPreferenceFailure(true)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: UUID(), startedAt: clock.date)
        await store.refresh()
        await store.updatePreferences(shareWithFriends: true, netMatching: true)
        store.receiveLocation(location(at: clock.date)); await settle()
        XCTAssertFalse(store.sharesWithFriends)
        XCTAssertFalse(store.netMatchingEnabled)
        let reports = await service.reports
        XCTAssertEqual(reports, 0)
        store.stop()
    }

    func testFailedRefreshRemovesPreviouslyVisiblePins() async {
        let service = FriendsTestService(), clock = FriendsTestClock()
        await service.setMapPeer(at: clock.date)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        await store.refresh()
        XCTAssertEqual(store.peers.count, 1)
        await service.setMapFailure(true)
        await store.refresh()
        XCTAssertTrue(store.peers.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        store.stop()
    }

    func testStalePinsAreFilteredAndExpiredNearbyLocationsDoNotRemain() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = SocialMapPeer(user: .init(publicID: "peer", displayName: "Sam", photoURL: nil), latitude: -37.8,
                                 longitude: 144.9, recordedAt: SocialDate.string(date.addingTimeInterval(-91)),
                                 expiresAt: SocialDate.string(date.addingTimeInterval(-1)), isApproximate: true,
                                 isNetPartner: false, distanceM: 100)
        XCTAssertTrue(SocialMapSnapshot(friends: [peer], nearby: [peer], partner: peer).fresh(at: date) == .empty)
    }

    func testSignOutDuringRefreshRejectsLateAccountResponse() async {
        let service = FriendsTestService()
        await service.setDelayedOverview(true)
        let store = FriendsStore(ownerID: 1, service: service)
        let refresh = Task { await store.refresh() }
        await settle()
        store.stop()
        await service.releaseOverview()
        await refresh.value
        XCTAssertNil(store.overview)
        XCTAssertTrue(store.peers.isEmpty)
        XCTAssertNil(store.currentSession)
    }

    func testPauseWhileSessionCreationIsPendingDoesNotPublishLateLocation() async {
        let service = FriendsTestService(), clock = FriendsTestClock(), requestID = UUID()
        await service.setSharing(true)
        await service.setDelayedStart(true)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: requestID, startedAt: clock.date)
        await store.refresh(); await settle()
        store.receiveLocation(location(at: clock.date))
        store.updateWalk(isWalking: false, requestID: requestID, startedAt: clock.date)
        await service.releaseStart(); await settle()
        XCTAssertEqual(store.currentSession?.state, "PAUSED")
        let reports = await service.reports
        XCTAssertEqual(reports, 0)
        store.stop()
    }

    func testInaccurateThenAccurateFixInSameBatchMustPauseBeforePublishingNewAnchor() async {
        let service = FriendsTestService(), clock = FriendsTestClock(), requestID = UUID()
        await service.setSharing(true)
        await service.setActiveInvitation()
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: requestID, startedAt: clock.date)
        await store.refresh(); await settle()
        store.receiveLocation(location(at: clock.date)); await settle()
        clock.advance(6)
        store.receiveLocation(location(at: clock.date, accuracy: 60))
        store.receiveLocation(location(at: clock.date))
        await settle()
        let events = await service.events
        XCTAssertEqual(events, ["start", "location", "PAUSED", "RECORDING", "location"])
        XCTAssertEqual(store.currentSession?.state, "RECORDING")
        XCTAssertFalse(store.currentSession?.netConsent ?? true)
        XCTAssertNil(store.invitations.active)
        store.stop()
    }

    func testInvalidFixDuringInFlightReportCannotLosePauseBarrier() async {
        let service = FriendsTestService(), clock = FriendsTestClock(), requestID = UUID()
        await service.setSharing(true)
        await service.setDelayedReport(true)
        let store = FriendsStore(ownerID: 1, service: service, now: { clock.date })
        store.updateWalk(isWalking: true, requestID: requestID, startedAt: clock.date)
        await store.refresh(); await settle()
        store.receiveLocation(location(at: clock.date)); await settle()
        clock.advance(6)
        store.receiveLocation(location(at: clock.date, accuracy: 60))
        store.receiveLocation(location(at: clock.date))
        await service.releaseReport(); await settle()
        let events = await service.events
        XCTAssertEqual(events, ["start", "location", "PAUSED", "RECORDING", "location"])
        store.stop()
    }

    private func location(at date: Date, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: .init(latitude: -37.8, longitude: 144.9), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: date)
    }
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor private final class FriendsTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private actor FriendsTestService: FriendsServing {
    private(set) var starts = 0
    private(set) var reports = 0
    private(set) var states: [String] = []
    private(set) var events: [String] = []
    private var sharing = false
    private var netMatching = false
    private var preferenceFailure = false
    private var mapFailure = false
    private var mapValue = SocialMapSnapshot.empty
    private var current: SocialWalkSession?
    private var inviteValue = NetWalkInvitations.empty
    private var delayedOverview = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var delayedStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var delayedReport = false
    private var reportContinuation: CheckedContinuation<Void, Never>?
    func setSharing(_ value: Bool) { sharing = value }
    func setActiveInvitation() {
        inviteValue = .init(incoming: [], outgoing: [], active: .init(id: 4,
            user: .init(publicID: "peer", displayName: "Sam", photoURL: nil), status: "ACTIVE",
            isIncoming: false, createdAt: "2026-10-07T03:00:00Z", sessionID: 3, partnerSessionID: 5))
    }
    func setPreferenceFailure(_ value: Bool) { preferenceFailure = value }
    func setMapFailure(_ value: Bool) { mapFailure = value }
    func setDelayedOverview(_ value: Bool) { delayedOverview = value }
    func releaseOverview() { continuation?.resume(); continuation = nil }
    func setDelayedStart(_ value: Bool) { delayedStart = value }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func setDelayedReport(_ value: Bool) { delayedReport = value }
    func releaseReport() { delayedReport = false; reportContinuation?.resume(); reportContinuation = nil }
    func setMapPeer(at date: Date) {
        let peer = SocialMapPeer(user: .init(publicID: "peer", displayName: "Sam", photoURL: nil), latitude: -37.8,
                                 longitude: 144.9, recordedAt: SocialDate.string(date),
                                 expiresAt: SocialDate.string(date.addingTimeInterval(90)), isApproximate: false,
                                 isNetPartner: false, distanceM: nil)
        mapValue = .init(friends: [peer], nearby: [], partner: nil)
    }
    private var me: SocialPreferences {
        .init(publicID: "me", displayName: "Me", photoURL: nil, locationVisibility: sharing ? "FRIENDS" : "OFF", netMatchingEnabled: netMatching)
    }
    func overview() async throws -> SocialOverview {
        if delayedOverview { await withCheckedContinuation { continuation = $0 } }
        return .init(me: me, friends: [], incomingRequests: [], outgoingRequests: [], blockedUsers: [], currentSession: current)
    }
    func search(_ query: String) async throws -> [SocialProfile] { [] }
    func sendRequest(publicID: String) async throws {}
    func respondToRequest(id: Int, accept: Bool) async throws {}
    func removeFriend(publicID: String) async throws {}
    func block(publicID: String) async throws {}
    func unblock(publicID: String) async throws {}
    func updatePreferences(_ preferences: SocialPreferenceUpdate) async throws -> SocialPreferences {
        if preferenceFailure { throw APIError.network("Offline") }
        sharing = preferences.locationVisibility == "FRIENDS"
        netMatching = preferences.netMatchingEnabled
        return me
    }
    func map() async throws -> SocialMapSnapshot {
        if mapFailure { throw APIError.network("Offline") }
        return mapValue
    }
    func startWalk(requestID: UUID, startedAt: Date) async throws -> SocialWalkSession {
        starts += 1
        events.append("start")
        if delayedStart { await withCheckedContinuation { startContinuation = $0 } }
        let result = makeSession(requestID: requestID, state: "RECORDING")
        current = result
        return result
    }
    func reportLocation(sessionID: Int, sample: SocialLocationSample) async throws -> SocialWalkSession {
        reports += 1
        events.append("location")
        if delayedReport { await withCheckedContinuation { reportContinuation = $0 } }
        return current!
    }
    func setWalkState(sessionID: Int, state: String) async throws -> SocialWalkSession {
        states.append(state)
        events.append(state)
        if state == "PAUSED" || state == "FINISHED" { inviteValue = .empty }
        let result = makeSession(requestID: current!.requestID, state: state)
        current = result
        return result
    }
    func invitations() async throws -> NetWalkInvitations { inviteValue }
    func invite(publicID: String) async throws {}
    func respondToInvitation(id: Int, accept: Bool) async throws {}
    func endInvitation(id: Int) async throws {}
    private func makeSession(requestID: UUID, state: String) -> SocialWalkSession {
        .init(id: 3, requestID: requestID, state: state, netConsent: inviteValue.active != nil, sharedDistanceM: 0,
              estimatedBonusPoints: 0, bonusPoints: 0, bonusStatus: "awaiting_rules", partner: nil)
    }
}
