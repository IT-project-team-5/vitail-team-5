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

    /// Two missed reports make the server abandon the check-in, so report well inside 90 s.
    static let reportInterval: TimeInterval = 25

    @Published private(set) var venues: [CheckInVenue] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var isCollecting = false
    @Published var errorMessage: String?
    @Published private(set) var connectionNotice: String?

    /// Called after points are awarded so the wallet can refresh.
    var onPointsAwarded: (() async -> Void)?
    var onProgressChanged: (() async -> Void)?

    private let service: any VenueCheckInServing
    private let location: any CheckInLocationProviding
    private let now: () -> Date
    private var startedAt: Date?
    private var lastReportAt: Date?
    private var isReporting = false
    private var ticker: Task<Void, Never>?

    init(
        service: any VenueCheckInServing = VenueCheckInService(),
        location: (any CheckInLocationProviding)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let location = location ?? CheckInLocationManager()
        self.service = service
        self.location = location
        self.now = now
        location.onLocation = { [weak self] sample in self?.handle(sample) }
    }

    var activeCheckIn: VenueCheckInSession? {
        if case let .active(checkIn) = phase { return checkIn }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .active: return true
        case .idle, .finished: return false
        }
    }

    func remainingSeconds(for checkIn: VenueCheckInSession) -> Int {
        max(0, checkIn.requiredSeconds - elapsedSeconds)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            venues = try await service.fetchVenues()
            hasLoaded = true
            if !isBusy { errorMessage = nil }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func start(_ venue: CheckInVenue) async {
        guard !isBusy, venue.checkInStatus == "AVAILABLE" else { return }
        errorMessage = nil
        phase = .starting(venueID: venue.id)
        do {
            let sample = try await location.currentSample()
            let checkIn = try await service.startCheckIn(venueID: venue.id, sample: sample)
            if checkIn.status == .inProgress {
                begin(checkIn)
            } else {
                phase = .finished(checkIn)
                await onProgressChanged?()
            }
        } catch {
            phase = .idle
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        guard let checkIn = activeCheckIn else { return }
        endSession()
        phase = .idle
        try? await service.cancelCheckIn(checkInID: checkIn.id)
        await onProgressChanged?()
    }

    /// Logout and sign-out stop location updates and abandon the open check-in.
    func prepareForLogout() async {
        await cancel()
    }

    func dismissResult() {
        if case .finished = phase { phase = .idle }
    }

    func collect() async {
        guard case let .finished(checkIn) = phase, checkIn.status == .ready, !isCollecting else { return }
        isCollecting = true
        errorMessage = nil
        defer { isCollecting = false }
        do {
            let receipt = try await service.collectCheckIn(attemptID: checkIn.id)
            phase = .finished(receipt.checkIn)
            await load()
            await onProgressChanged?()
            await onPointsAwarded?()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Active session

    private func begin(_ checkIn: VenueCheckInSession) {
        startedAt = now()
        lastReportAt = startedAt
        elapsedSeconds = checkIn.verifiedSeconds
        connectionNotice = nil
        phase = .active(checkIn)
        location.startMonitoring()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let startedAt, case let .active(checkIn) = phase else { return }
        elapsedSeconds = min(checkIn.requiredSeconds, checkIn.verifiedSeconds + Int(now().timeIntervalSince(startedAt)))
    }

    private func endSession() {
        location.stopMonitoring()
        ticker?.cancel()
        ticker = nil
        startedAt = nil
        lastReportAt = nil
        connectionNotice = nil
    }

    private func handle(_ sample: LocationSample) {
        guard case .active = phase, !isReporting else { return }
        let current = now()
        if let lastReportAt, current.timeIntervalSince(lastReportAt) < Self.reportInterval { return }
        lastReportAt = current
        Task { await report(sample) }
    }

    private func report(_ sample: LocationSample) async {
        guard case let .active(checkIn) = phase else { return }
        isReporting = true
        defer { isReporting = false }
        do {
            let updated = try await service.reportLocation(checkInID: checkIn.id, sample: sample)
            guard case .active = phase else { return }
            connectionNotice = nil
            switch updated.status {
            case .inProgress:
                phase = .active(updated)
            case .ready, .collected:
                endSession()
                phase = .finished(updated)
                await load()
                await onProgressChanged?()
            }
        } catch is CancellationError {
        } catch {
            // Transient: keep tracking. The server ends the check-in if reports stay missing.
            connectionNotice = "Can't reach Vitail. Keep the app open — your check-in continues."
        }
    }
}
