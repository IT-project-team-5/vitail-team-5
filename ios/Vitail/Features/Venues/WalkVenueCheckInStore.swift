import Combine
import CoreLocation
import Foundation

struct WalkVenuePresentation: Equatable {
    enum State: Equatable { case outside, accumulating, paused, ready, collected, unavailable }
    let state: State
    let verifiedSeconds: Int
    let requiredSeconds: Int
    let category: String
    var progress: Double { min(1, max(0, Double(verifiedSeconds) / Double(max(1, requiredSeconds)))) }
    var message: String {
        switch state {
        case .outside: return "Go here to get points"
        case .accumulating:
            let remaining = max(0, requiredSeconds - verifiedSeconds)
            if remaining < 60 { return "Stay here for less than a minute to get points" }
            return "Stay here for \(Int(ceil(Double(remaining) / 60))) more minutes to get points"
        case .paused: return "Location verification paused. Your progress is saved for this walk."
        case .ready: return "Check-in complete. Finish your walk."
        case .collected: return "You've got the \(category) check-in points for today"
        case .unavailable: return "Check-in points are unavailable today."
        }
    }
}

/// Uses the walk's existing Core Location stream. Progress comes exclusively
/// from server receipts; a ticking UI never adds client elapsed time.
@MainActor
final class WalkVenueCheckInStore: ObservableObject {
    static let radiusMetres: CLLocationDistance = 20
    static let maximumAccuracy: CLLocationAccuracy = 20
    static let maximumFixAge: TimeInterval = 15
    static let reportInterval: TimeInterval = 10

    @Published private(set) var venues: [CheckInVenue] = []
    @Published private(set) var sessions: [Int: VenueCheckInSession] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var isWalking = false
    private(set) var walkRequestID: UUID?
    private var startedAt: Date?
    private var contextState = "PAUSED"
    private var confirmedContext: VenueWalkContext?
    private var contextEstablished = false
    private var lastSequence: Int64?
    private var lastReportedAt: [Int: Date] = [:]
    private var insideVenueIDs: Set<Int> = []
    private var locationIsInterrupted = false
    private var needsPause: Set<Int> = []
    private var queue: Task<Void, Never>?
    private var generation = 0
    private var isEnabled = true
    private let service: any WalkVenueCheckInServing
    private let now: () -> Date
    var onTerminalConfirmed: (() -> Void)?

    var requiresTerminalConfirmation: Bool {
        contextState == "FINISHED" && !sessions.isEmpty && confirmedContext?.state != "FINISHED"
    }

    init(service: any WalkVenueCheckInServing = WalkVenueCheckInService(), now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    func updateWalk(id: UUID?, startedAt: Date?, status: WalkSessionTracker.Status) {
        guard isEnabled else { return }
        // Keep the just-finished walk's receipt scope until settlement/new Start.
        guard let id, let startedAt else {
            if status == .finished, walkRequestID != nil { setState("FINISHED") }
            return
        }
        let isNewWalk = walkRequestID != id
        if isNewWalk {
            generation += 1
            walkRequestID = id; self.startedAt = startedAt
            sessions = [:]; lastReportedAt = [:]; insideVenueIDs = []
            needsPause = []
            latestLocation = nil; lastSequence = nil; confirmedContext = nil; contextEstablished = false
            locationIsInterrupted = false
            contextState = ""
        }
        setState(status == .walking ? "RECORDING" : status == .finished ? "FINISHED" : "PAUSED")
        if isNewWalk { enqueue { store, revision in await store.refresh(revision: revision) } }
    }

    private func setState(_ state: String) {
        let changed = state != contextState
        contextState = state; isWalking = state == "RECORDING"
        if !isWalking {
            let interruptedVenues = insideVenueIDs.union(sessions.values.filter { $0.status == .inProgress }.map(\.venueID))
            latestLocation = nil; insideVenueIDs = []
            if state == "PAUSED" {
                for venueID in interruptedVenues { enqueuePause(venueID: venueID) }
            }
        }
        guard changed else { return }
        let context = currentContext
        enqueue { store, revision in
            guard let context else { return }
            do {
                try await store.service.updateContext(context)
                guard store.valid(revision) else { return }
                store.confirmedContext = context
                store.contextEstablished = true
                if context.state == "FINISHED" { store.onTerminalConfirmed?() }
            } catch { if store.valid(revision) { store.errorMessage = "Check-in recording could not be confirmed. Retry when online." } }
        }
    }

    func receiveLocations(_ locations: [CLLocation]) {
        guard isEnabled, isWalking, let walkRequestID else { return }
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let milliseconds = fix.timestamp.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else {
                locationInterrupted(); continue
            }
            guard Self.isReliable(fix, at: now()), fix.timestamp >= (startedAt ?? .distantFuture) else {
                locationInterrupted(); continue
            }
            let sequence = Self.sequence(for: fix.timestamp)
            guard lastSequence.map({ sequence > $0 }) ?? true else { continue }
            lastSequence = sequence
            locationIsInterrupted = false
            latestLocation = fix
            let inside = Set(venues.filter { Self.isInside(fix, venue: $0) }.map(\.id))
            let leaving = insideVenueIDs.subtracting(inside)
            insideVenueIDs = inside
            for venueID in leaving { enqueuePause(venueID: venueID) }
            for venue in venues where inside.contains(venue.id) && eligible(venue) {
                if let previous = lastReportedAt[venue.id], fix.timestamp.timeIntervalSince(previous) < Self.reportInterval { continue }
                lastReportedAt[venue.id] = fix.timestamp
                let request = WalkVenueLocationRequest(walkRequestID: walkRequestID, sequence: sequence,
                    recordedAt: WalkTimestamp.string(fix.timestamp),
                    latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                    accuracyM: fix.horizontalAccuracy, isSimulated: fix.sourceInformation?.isSimulatedBySoftware ?? false)
                enqueue { store, revision in await store.record(venueID: venue.id, request: request, revision: revision) }
            }
        }
    }

    func locationInterrupted() {
        guard isEnabled, !locationIsInterrupted else { return }
        locationIsInterrupted = true
        latestLocation = nil
        let previous = insideVenueIDs
        insideVenueIDs = []
        for venueID in previous { enqueuePause(venueID: venueID) }
        // A GPS gap pauses the venue context, independently of the social layer.
        if isWalking {
            confirmedContext = nil
            let context = currentContext.map { VenueWalkContext(walkRequestID: $0.walkRequestID, startedAt: $0.startedAt, state: "PAUSED") }
            enqueue { store, revision in
                guard let context else { return }
                do {
                    try await store.service.updateContext(context)
                    if store.valid(revision) { store.confirmedContext = context; store.contextEstablished = true }
                }
                catch { if store.valid(revision) { store.errorMessage = "Location verification is paused. Retry when online." } }
            }
        }
    }

    /// A reliable, live in-radius visit is activity, so stationary cafe/restaurant
    /// stays can finish without disabling the walk's normal inactivity rule.
    func hasVerifiedVenueActivity(at date: Date) -> Bool {
        guard isWalking, confirmedContext?.state == "RECORDING", errorMessage == nil,
              let fix = latestLocation, Self.isReliable(fix, at: date) else { return false }
        return venues.contains {
            Self.isInside(fix, venue: $0) && eligible($0) && !needsPause.contains($0.id)
                && sessions[$0.id]?.isAccumulating == true
        }
    }

    func presentation(for venue: CheckInVenue, at date: Date? = nil) -> WalkVenuePresentation {
        let session = sessions[venue.id]
        let seconds = session?.verifiedSeconds ?? 0
        let base = WalkVenuePresentation(state: .outside, verifiedSeconds: seconds,
            requiredSeconds: venue.requiredSeconds, category: venue.venueType.rewardCategoryTitle)
        let state: WalkVenuePresentation.State
        if venue.availability == .collected || session?.status == .collected { state = .collected }
        else if session?.status == .ready { state = .ready }
        else if venue.availability == .unavailable { state = .unavailable }
        else if !isWalking { state = seconds > 0 ? .paused : .outside }
        else if let fix = latestLocation, Self.isReliable(fix, at: date ?? now()) {
            if Self.isInside(fix, venue: venue) {
                state = confirmedContext?.state == "RECORDING" && errorMessage == nil && !needsPause.contains(venue.id)
                    && session?.isAccumulating == true ? .accumulating : .paused
            } else { state = .outside }
        } else { state = seconds > 0 ? .paused : .outside }
        return WalkVenuePresentation(state: state, verifiedSeconds: base.verifiedSeconds,
            requiredSeconds: base.requiredSeconds, category: base.category)
    }

    func load() async {
        await queue?.value
        let revision = generation
        // Local-only/no-dog records never reach the upload hook. Their terminal
        // recording state must still be independently retryable from the map.
        if requiresTerminalConfirmation {
            // A polling load may have awaited an earlier queue tail while a
            // final GPS report and Finish were appended. Finish stops fresh
            // reports, so drain the current tail before retrying its context.
            await queue?.value
        }
        if requiresTerminalConfirmation, let context = currentContext {
            do {
                try await service.updateContext(context)
                guard valid(revision), currentContext == context else { return }
                confirmedContext = context; contextEstablished = true
                onTerminalConfirmed?()
            } catch {
                if valid(revision) { errorMessage = "Retry finishing your venue recording before starting another walk." }
            }
        }
        await refresh(revision: generation)
        if requiresTerminalConfirmation {
            errorMessage = "Your venue progress is saved. Retry finishing this walk before starting another."
        }
    }

    /// Finish's immutable UUID is preserved while a timeout/relaunch retries the
    /// same settlement. GPS work queued before Finish completes first.
    func prepareForSettlement(request: WalkRequest) async -> Bool {
        await queue?.value
        // Old local history and walks recorded entirely offline have no venue
        // context. They still use the ordinary durable walk-upload path.
        guard request.requestID == walkRequestID, contextEstablished || !sessions.isEmpty else { return true }
        let context = VenueWalkContext(walkRequestID: request.requestID, startedAt: request.startedAt, state: "FINISHED")
        if confirmedContext == context { return true }
        do {
            try await service.updateContext(context)
            if walkRequestID == request.requestID { confirmedContext = context; contextEstablished = true }
            errorMessage = nil
            onTerminalConfirmed?()
            return true
        } catch {
            errorMessage = "Venue settlement is not confirmed. Retry when online."
            return false
        }
    }

    func stop() {
        isEnabled = false; generation += 1
        queue?.cancel(); queue = nil
        venues = []; sessions = [:]; latestLocation = nil; insideVenueIDs = []
        isWalking = false; errorMessage = nil
        onTerminalConfirmed = nil
    }

    static func isReliable(_ fix: CLLocation, at date: Date) -> Bool {
        let age = date.timeIntervalSince(fix.timestamp)
        return CLLocationCoordinate2DIsValid(fix.coordinate) && fix.horizontalAccuracy.isFinite
            && (0...maximumAccuracy).contains(fix.horizontalAccuracy)
            && age.isFinite && age >= -5 && age <= maximumFixAge
            && fix.sourceInformation?.isSimulatedBySoftware != true
    }
    static func isInside(_ fix: CLLocation, venue: CheckInVenue) -> Bool {
        fix.distance(from: CLLocation(latitude: venue.latitude, longitude: venue.longitude)) <= radiusMetres
    }
    static func sequence(for timestamp: Date) -> Int64 { Int64((timestamp.timeIntervalSince1970 * 1_000).rounded(.down)) }

    private var currentContext: VenueWalkContext? {
        guard let walkRequestID, let startedAt else { return nil }
        return VenueWalkContext(walkRequestID: walkRequestID, startedAt: WalkTimestamp.string(startedAt), state: contextState)
    }
    private func eligible(_ venue: CheckInVenue) -> Bool {
        venue.availability != .collected && venue.availability != .unavailable
            && sessions[venue.id]?.status != .ready && sessions[venue.id]?.status != .collected
    }
    private func valid(_ revision: Int) -> Bool { isEnabled && revision == generation && !Task.isCancelled }
    private func enqueue(_ operation: @escaping @MainActor (WalkVenueCheckInStore, Int) async -> Void) {
        let previous = queue, revision = generation
        queue = Task { [weak self] in
            await previous?.value
            guard let self, valid(revision) else { return }
            await operation(self, revision)
        }
    }
    private func enqueuePause(venueID: Int) {
        needsPause.insert(venueID)
        lastReportedAt[venueID] = nil
        enqueue { store, revision in
            do {
                try await store.confirmPause(venueID: venueID, revision: revision)
            }
            catch { if store.valid(revision) { store.errorMessage = "Check-in paused. Your verified progress is saved." } }
        }
    }
    private func confirmPause(venueID: Int, revision: Int) async throws {
        guard needsPause.contains(venueID) else { return }
        if let session = sessions[venueID] {
            if session.status == .inProgress { try await service.pause(checkInID: session.id) }
        } else if let context = currentContext {
            // A lost Start response can hide an accepted server attempt. Reset
            // the context's anchors without needing that unknown attempt ID.
            let paused = VenueWalkContext(walkRequestID: context.walkRequestID, startedAt: context.startedAt, state: "PAUSED")
            try await service.updateContext(paused)
            guard valid(revision) else { return }
            confirmedContext = paused; contextEstablished = true
        } else { return }
        if valid(revision) { needsPause.remove(venueID) }
    }
    private func record(venueID: Int, request: WalkVenueLocationRequest, revision: Int) async {
        do {
            // Retry context establishment without sharing location with friends.
            let context = VenueWalkContext(walkRequestID: request.walkRequestID,
                startedAt: WalkTimestamp.string(startedAt!), state: "RECORDING")
            if confirmedContext != context {
                try await service.updateContext(context)
                guard valid(revision) else { return }
                confirmedContext = context
                contextEstablished = true
            }
            if needsPause.contains(venueID) {
                try await confirmPause(venueID: venueID, revision: revision)
                guard valid(revision) else { return }
                if confirmedContext != context {
                    try await service.updateContext(context)
                    guard valid(revision) else { return }
                    confirmedContext = context; contextEstablished = true
                }
            }
            let result: VenueCheckInSession
            if let session = sessions[venueID] {
                guard session.status == .inProgress else { return }
                result = try await service.report(checkInID: session.id, request: request)
            } else { result = try await service.start(venueID: venueID, request: request) }
            guard valid(revision) else { return }
            guard result.venueID == venueID, result.walkRequestID == request.walkRequestID else { throw APIError.invalidResponse }
            sessions[venueID] = result; errorMessage = nil
        } catch { if valid(revision) { errorMessage = "Check-in progress could not be verified. Progress resumes with fresh GPS when online." } }
    }
    private func refresh(revision: Int) async {
        guard valid(revision), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.fetchVenues(walkRequestID: walkRequestID)
            guard valid(revision) else { return }
            venues = result
            for venue in result {
                if venue.checkIn == nil, venue.availability != .collected,
                   sessions[venue.id]?.status == .collected {
                    // Today's category receipts expire on the server's local
                    // day boundary. Do not retain yesterday's dimmed marker.
                    sessions[venue.id] = nil
                }
                if let session = venue.checkIn, session.walkRequestID == walkRequestID {
                    // Same-walk accumulation never resets. A delayed GET must
                    // not erase a newer POST receipt or completed visit.
                    let existing = sessions[venue.id]
                    if session.status == .collected || existing == nil
                        || (existing?.status != .ready && session.verifiedSeconds >= (existing?.verifiedSeconds ?? 0)) {
                        sessions[venue.id] = session
                    }
                }
            }
            errorMessage = nil
        } catch { if valid(revision) { errorMessage = "Venues could not be refreshed. Retry when online." } }
    }
}
