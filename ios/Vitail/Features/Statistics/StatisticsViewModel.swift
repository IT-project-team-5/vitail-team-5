import Combine
import Foundation

@MainActor
final class StatisticsViewModel: ObservableObject {
    let ownerID: Int
    @Published private(set) var statistics: UserStatistics?
    @Published private(set) var leaderboard: LeaderboardResponse?
    @Published private(set) var isLoadingStatistics = false
    @Published private(set) var isLoadingLeaderboard = false
    @Published private(set) var statisticsError: String?
    @Published private(set) var leaderboardError: String?
    @Published private(set) var isSavingVisibility = false
    @Published private(set) var visibilityError: String?
    @Published private(set) var pendingVisibility: Bool?

    private let service: any StatisticsServing
    private weak var session: SessionStore?
    private var sessionSubscription: AnyCancellable?
    private var enabled = true
    private var generation = 0
    private var statisticsRevision = 0
    private var leaderboardRevision = 0

    init(ownerID: Int, session: SessionStore? = nil,
         service: any StatisticsServing = StatisticsService()) {
        self.ownerID = ownerID
        self.session = session
        self.service = service
        sessionSubscription = session?.$state.sink { [weak self] state in
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self?.stop()
        }
    }

    // Do not display sharing as enabled until the server confirms it. A failed
    // opt-out remains off locally, with an explicit retry until it is confirmed.
    var leaderboardVisible: Bool {
        if pendingVisibility == false { return false }
        return statistics?.leaderboardVisible == true
    }
    var canChangeVisibility: Bool { statistics != nil && !isSavingVisibility && pendingVisibility == nil }

    func loadData() async {
        async let personal: Void = loadStatistics()
        async let friends: Void = loadLeaderboard()
        _ = await (personal, friends)
    }

    func loadStatistics() async {
        guard isCurrentOwner, !isSavingVisibility else { return }
        statisticsRevision += 1
        let revision = statisticsRevision
        let context = requestContext
        isLoadingStatistics = true
        statisticsError = nil
        defer { if revision == statisticsRevision { isLoadingStatistics = false } }
        do {
            let result = try await service.fetchStatistics()
            guard valid(context), revision == statisticsRevision, !Task.isCancelled else { return }
            statistics = result
            if pendingVisibility == result.leaderboardVisible {
                pendingVisibility = nil
                visibilityError = nil
            }
        } catch {
            guard valid(context), revision == statisticsRevision, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            statisticsError = "Could not refresh your activity. \(error.localizedDescription)"
        }
    }

    func loadLeaderboard() async {
        guard isCurrentOwner else { return }
        leaderboardRevision += 1
        let revision = leaderboardRevision
        let context = requestContext
        isLoadingLeaderboard = true
        leaderboardError = nil
        // Recheck consent and friendships instead of leaving an old ranking visible.
        leaderboard = nil
        defer { if revision == leaderboardRevision { isLoadingLeaderboard = false } }
        do {
            let result = try await service.fetchLeaderboard()
            guard valid(context), revision == leaderboardRevision, !Task.isCancelled else { return }
            leaderboard = result
        } catch {
            guard valid(context), revision == leaderboardRevision, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            leaderboardError = "Could not load the leaderboard. \(error.localizedDescription)"
        }
    }

    func setLeaderboardVisible(_ visible: Bool) async {
        guard isCurrentOwner, statistics != nil, !isSavingVisibility,
              pendingVisibility == nil || pendingVisibility == visible else { return }
        let context = requestContext
        statisticsRevision += 1 // A GET started before this edit must not restore old consent.
        isLoadingStatistics = false
        isSavingVisibility = true
        pendingVisibility = visible
        visibilityError = nil
        defer { if valid(context) { isSavingVisibility = false } }
        do {
            let result = try await service.updateLeaderboardVisibility(visible)
            guard valid(context) else { return }
            guard result.leaderboardVisible == visible else { throw APIError.invalidResponse }
            statistics = result
            pendingVisibility = nil
        } catch {
            guard valid(context) else { return }
            visibilityError = visible
                ? "Sharing was not confirmed. Retry to save your choice."
                : "Hiding your activity was not confirmed. Retry to make sure friends cannot see it."
        }
    }

    func retryVisibility() async {
        guard let pendingVisibility else { return }
        await setLeaderboardVisible(pendingVisibility)
    }

    func cancelReads() {
        statisticsRevision += 1
        leaderboardRevision += 1
        isLoadingStatistics = false
        isLoadingLeaderboard = false
        leaderboard = nil
    }

    func stop() {
        enabled = false
        generation += 1
        cancelReads()
        statistics = nil
        statisticsError = nil
        leaderboardError = nil
        visibilityError = nil
        pendingVisibility = nil
        isSavingVisibility = false
    }

    private var isCurrentOwner: Bool {
        guard enabled else { return false }
        guard let session else { return true }
        if case let .signedIn(user) = session.state { return user.id == ownerID && user.role == .owner }
        return false
    }
    private var requestContext: (generation: Int, session: Int?) { (generation, session?.sessionRevision) }
    private func valid(_ context: (generation: Int, session: Int?)) -> Bool {
        isCurrentOwner && generation == context.generation && session?.sessionRevision == context.session
    }
}
