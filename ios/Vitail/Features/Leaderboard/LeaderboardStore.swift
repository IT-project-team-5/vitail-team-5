import Combine
import Foundation

@MainActor
final class LeaderboardStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var period: LeaderboardPeriod = .week
    @Published private(set) var snapshot: LeaderboardSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private weak var session: SessionStore?
    private let service: any LeaderboardServing
    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    init(ownerID: Int, session: SessionStore, service: any LeaderboardServing = LeaderboardService()) {
        self.ownerID = ownerID
        self.session = session
        self.service = service
    }

    deinit { refreshTask?.cancel() }

    var currentEntry: LeaderboardEntry? {
        snapshot?.entries.first { $0.userID == ownerID && $0.isCurrentUser }
    }

    func selectPeriod(_ period: LeaderboardPeriod) async {
        if self.period != period {
            stop()
            self.period = period
        }
        await refresh()
    }

    func refresh() async {
        guard isCurrentOwner else { stop(); return }
        if let refreshTask { await refreshTask.value; return }
        let currentGeneration = generation
        let requestedPeriod = period
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.fetchLeaderboard(period: requestedPeriod)
                guard currentGeneration == generation, isCurrentOwner, !Task.isCancelled else { return }
                snapshot = result
                errorMessage = nil
            } catch {
                if currentGeneration == generation, isCurrentOwner, !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        refreshTask = task
        await task.value
        if currentGeneration == generation {
            refreshTask = nil
            isRefreshing = false
        }
    }

    func stop() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        snapshot = nil
        errorMessage = nil
        isRefreshing = false
    }

    private var isCurrentOwner: Bool {
        guard case let .signedIn(user) = session?.state else { return false }
        return user.id == ownerID && user.role == .owner
    }
}
