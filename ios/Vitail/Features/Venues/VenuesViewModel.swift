import Combine
import Foundation

@MainActor
final class VenuesViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting(venueID: Int)
        case active(VenueCheckInSession)
        case finished(VenueCheckInSession)
    }

    /// Gaps over 90 seconds reset server dwell; the attempt remains resumable.
    static let reportInterval: TimeInterval = 25

    @Published private(set) var venues: [CheckInVenue] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var isCollecting = false
    @Published private(set) var isCancelling = false
    @Published var errorMessage: String?
    @Published private(set) var connectionNotice: String?

    /// Called after points are awarded so the wallet can refresh.
    var onPointsAwarded: (() async -> Void)?
    var onProgressChanged: (() async -> Void)?

    private let service: any VenueCheckInServing
    private let location: any CheckInLocationProviding
    private let now: () -> Date
    private var lastReportAt: Date?
    private var reportTask: Task<Void, Never>?
    private var startTask: Task<VenueCheckInSession, Error>?
    private var generation = 0
    private var isEnabled = true
    private var sessionSubscription: AnyCancellable?

    init(
        service: any VenueCheckInServing = VenueCheckInService(),
        location: (any CheckInLocationProviding)? = nil,
        session: SessionStore? = nil, ownerID: Int? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let location = location ?? CheckInLocationManager()
        self.service = service
        self.location = location
        self.now = now
        location.onLocation = { [weak self] sample in self?.handle(sample) }
        sessionSubscription = session?.$state.sink { [weak self] state in
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self?.stop()
        }
    }

    var activeCheckIn: VenueCheckInSession? {
        if case let .active(checkIn) = phase { return checkIn }
        return nil
    }

    var isBusy: Bool {
        if isCancelling || isCollecting { return true }
        switch phase {
        case .starting, .active: return true
        case .idle, .finished: return false
        }
    }

    func remainingSeconds(for checkIn: VenueCheckInSession) -> Int {
        max(0, checkIn.requiredSeconds - elapsedSeconds)
    }

    func load() async {
        guard isEnabled, !isLoading, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.fetchVenues()
            guard isEnabled, !Task.isCancelled else { return }
            venues = result
            hasLoaded = true
            if !isBusy { errorMessage = nil }
        } catch is CancellationError {
        } catch {
            guard isEnabled, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func start(_ venue: CheckInVenue) async {
        guard isEnabled, !isBusy, !Task.isCancelled,
              venue.availability.canStart else { return }
        generation += 1
        let request = generation
        errorMessage = nil
        phase = .starting(venueID: venue.id)
        let task = Task { [location, service] in
            let sample = try await location.currentSample()
            try Task.checkCancellation()
            return try await service.startCheckIn(venueID: venue.id, sample: sample)
        }
        startTask = task
        defer { if generation == request { startTask = nil } }
        do {
            let checkIn = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard isEnabled, generation == request else { return }
            try Task.checkCancellation()
            guard checkIn.venueID == venue.id else { throw APIError.invalidResponse }
            if checkIn.status == .inProgress {
                begin(checkIn)
            } else {
                phase = .finished(checkIn)
                await onProgressChanged?()
            }
        } catch {
            guard isEnabled, generation == request else { return }
            phase = .idle
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        guard isEnabled, !isCancelling else { return }
        let checkIn = activeCheckIn
        generation += 1
        startTask?.cancel()
        startTask = nil
        endSession()
        phase = .idle
        guard let checkIn else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            try await service.cancelCheckIn(checkInID: checkIn.id)
            guard isEnabled else { return }
            await load()
            await onProgressChanged?()
        } catch {
            if isEnabled { errorMessage = "Cancellation was not confirmed. Reload to resume or cancel this visit." }
        }
    }

    /// Logout and sign-out stop location updates and abandon the open check-in.
    func prepareForLogout() async {
        await cancel()
        stop()
    }

    /// Involuntary expiry/account replacement stops GPS without a network dependency.
    func stop() {
        isEnabled = false
        generation += 1
        startTask?.cancel()
        startTask = nil
        endSession()
        phase = .idle
        venues = []
        isCollecting = false
        errorMessage = nil
        onProgressChanged = nil
        onPointsAwarded = nil
        sessionSubscription?.cancel()
        sessionSubscription = nil
    }

    func dismissResult() {
        if case .finished = phase { phase = .idle }
    }

    /// Quest and Venues share the same server qualification. If Quest collects
    /// a result while this page still holds a local READY phase, discard that
    /// stale phase so it cannot offer a second collection action.
    func reconcileSharedProgress(_ items: [VenueCheckInProgress]) {
        guard case let .finished(checkIn) = phase, checkIn.status == .ready,
              items.contains(where: { $0.venueID == checkIn.venueID && $0.status == .collected }) else { return }
        phase = .idle
        errorMessage = nil
    }

    func collect() async {
        guard isEnabled, case let .finished(checkIn) = phase, checkIn.status == .ready, !isCollecting else { return }
        let request = generation
        isCollecting = true
        errorMessage = nil
        defer { isCollecting = false }
        do {
            let receipt = try await service.collectCheckIn(attemptID: checkIn.id)
            guard isEnabled, generation == request, !Task.isCancelled else { return }
            guard receipt.checkIn.id == checkIn.id, receipt.checkIn.venueID == checkIn.venueID,
                  receipt.checkIn.status == .collected, receipt.awardedPoints == checkIn.rewardPoints else {
                throw APIError.invalidResponse
            }
            phase = .finished(receipt.checkIn)
            await load()
            await onProgressChanged?()
            await onPointsAwarded?()
        } catch is CancellationError {
        } catch {
            guard isEnabled, generation == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Active session

    private func begin(_ checkIn: VenueCheckInSession) {
        lastReportAt = now()
        elapsedSeconds = checkIn.verifiedSeconds
        connectionNotice = nil
        phase = .active(checkIn)
        location.startMonitoring()
    }

    private func endSession(cancelReport: Bool = true) {
        location.stopMonitoring()
        if cancelReport { reportTask?.cancel() }
        reportTask = nil
        elapsedSeconds = 0
        lastReportAt = nil
        connectionNotice = nil
    }

    private func handle(_ sample: LocationSample) {
        guard isEnabled, case let .active(checkIn) = phase, reportTask == nil else { return }
        let current = now()
        if let lastReportAt, current.timeIntervalSince(lastReportAt) < Self.reportInterval { return }
        lastReportAt = current
        let request = generation
        reportTask = Task { await report(sample, checkIn: checkIn, generation: request) }
    }

    private func report(_ sample: LocationSample, checkIn: VenueCheckInSession, generation request: Int) async {
        guard isEnabled, generation == request, !Task.isCancelled else { return }
        defer { if generation == request { reportTask = nil } }
        do {
            let updated = try await service.reportLocation(checkInID: checkIn.id, sample: sample)
            guard isEnabled, generation == request, activeCheckIn?.id == checkIn.id, !Task.isCancelled else { return }
            guard updated.id == checkIn.id, updated.venueID == checkIn.venueID else { throw APIError.invalidResponse }
            connectionNotice = nil
            switch updated.status {
            case .inProgress:
                // Never add client elapsed time to the server's verified duration.
                elapsedSeconds = updated.verifiedSeconds
                phase = .active(updated)
            case .ready, .collected:
                endSession(cancelReport: false)
                phase = .finished(updated)
                await load()
                await onProgressChanged?()
            }
        } catch is CancellationError {
        } catch {
            guard isEnabled, generation == request, !Task.isCancelled else { return }
            if case let APIError.http(status, _) = error, [400, 403, 404].contains(status) {
                endSession(cancelReport: false)
                phase = .idle
                errorMessage = error.localizedDescription
            } else {
                connectionNotice = "Progress is not confirmed. Keep the app open; a long connection gap resets the visit timer."
            }
        }
    }
}
