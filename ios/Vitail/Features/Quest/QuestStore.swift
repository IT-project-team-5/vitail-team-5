import Combine
import Foundation

@MainActor
final class QuestStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var snapshot: QuestSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var collectingTaskID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmedCollections: [String: QuestTask] = [:]
    var onAward: (@MainActor (QuestAwardReceipt) async -> Void)?

    private weak var session: SessionStore?
    private let service: any QuestServing
    private let now: () -> Date
    private var receivedAt: Date?
    private var serverDate: Date?
    private var generation = 0
    private var isActive = true
    private var refreshTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?
    private var sessionSubscription: AnyCancellable?

    init(ownerID: Int, session: SessionStore, service: any QuestServing = QuestService(), now: @escaping () -> Date = Date.init) {
        self.ownerID = ownerID
        self.session = session
        self.service = service
        self.now = now
        sessionSubscription = session.$state.sink { [weak self] state in
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self?.stop()
        }
    }

    deinit { refreshTask?.cancel(); collectionTask?.cancel() }

    var readyTasks: [QuestTask] { visibleTasks.filter { $0.status == .ready } }
    var inProgressTasks: [QuestTask] { visibleTasks.filter { $0.status == .inProgress } }
    var collectedTodayTasks: [QuestTask] { visibleTasks.filter { $0.status == .collected } }
    var visibleTasks: [QuestTask] {
        allTasks.filter { task in
            guard task.isSupported else { return false }
            if task.status == .collected {
                guard let date = task.collectedAt.flatMap(QuestCalendar.parse) else { return false }
                return QuestCalendar.dateString(date) == displayDate
            }
            // A cached birthday offer does not stay ready after Melbourne midnight.
            return !task.isBirthday || snapshot?.localDate == displayDate
        }
        .sorted { left, right in
            let lhs = sortOrder(left.status), rhs = sortOrder(right.status)
            return lhs == rhs ? left.id < right.id : lhs < rhs
        }
    }
    private var allTasks: [QuestTask] {
        let serverTasks = snapshot?.tasks ?? []
        let unacknowledged = confirmedCollections.values.filter { confirmed in
            !serverTasks.contains { $0.id == confirmed.id && $0.status == .collected }
        }
        let filtered = serverTasks.filter { task in
            // A delayed pre-submission row must not offer the same upload again
            // while its entitlement collection is awaiting a fresh server view.
            task.status != .inProgress || !unacknowledged.contains {
                $0.documentKind != nil && $0.kind == task.kind && $0.dogID == task.dogID
                    && $0.collectedAt.flatMap(QuestCalendar.parse).map(QuestCalendar.dateString) == displayDate
            }
        }
        var tasks = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, task) in confirmedCollections { tasks[id] = task }
        return Array(tasks.values)
    }
    private var displayDate: String? {
        guard let serverDate, let receivedAt else { return snapshot?.localDate }
        return QuestCalendar.dateString(serverDate.addingTimeInterval(max(0, now().timeIntervalSince(receivedAt))))
    }
    func task(id: String) -> QuestTask? { visibleTasks.first { $0.id == id } }
    func canCollect(_ task: QuestTask) -> Bool {
        guard isActive, isCurrentOwner, !isRefreshing, collectingTaskID == nil,
              self.task(id: task.id)?.status == .ready, task.isSupported,
              let dogID = task.dogID, dogID > 0 else { return false }
        return task.rewardPoints == (task.isBirthday ? 60 : task.documentKind?.points)
    }

    func refresh() async {
        guard isActive, isCurrentOwner else { stop(); return }
        if let refreshTask { await refreshTask.value; return }
        guard collectingTaskID == nil, !isRefreshing else { return }
        let requestGeneration = generation
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadSnapshot(generation: requestGeneration)
        }
        refreshTask = task
        await task.value
        if requestGeneration == generation { isRefreshing = false; refreshTask = nil }
    }

    func collect(taskID: String) async {
        guard let selected = task(id: taskID), canCollect(selected), let dogID = selected.dogID else { return }
        let requestGeneration = generation
        let expectedYear = snapshot.flatMap { Int($0.localDate.prefix(4)) }
        collectingTaskID = taskID
        errorMessage = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt: QuestAwardReceipt
                if selected.isBirthday {
                    let result = try await service.collectBirthday(dogID: dogID)
                    guard result.award.id > 0, result.award.dogID == dogID,
                          result.award.year == expectedYear, result.award.kind == "BIRTHDAY",
                          result.award.points == 60 else { throw APIError.invalidResponse }
                    receipt = QuestAwardReceipt(kind: result.award.kind, dogID: dogID, points: result.award.points,
                                                balance: result.balance, collectedAt: result.award.awardedAt, created: result.created)
                } else {
                    guard let entitlementID = selected.entitlementID else { throw APIError.invalidResponse }
                    let result = try await service.collectDocument(entitlementID: entitlementID)
                    guard result.entitlementID == entitlementID, result.dogID == dogID,
                          result.kind == selected.documentKind, result.points == selected.rewardPoints else { throw APIError.invalidResponse }
                    receipt = QuestAwardReceipt(kind: result.kind.rawValue, dogID: dogID, points: result.points,
                                                balance: result.balance, collectedAt: result.collectedAt, created: result.created)
                }
                guard accepts(requestGeneration), !Task.isCancelled else { return }
                guard receipt.balance >= 0, receipt.points > 0,
                      QuestCalendar.parse(receipt.collectedAt) != nil else { throw APIError.invalidResponse }
                confirmedCollections[taskID] = selected.collected(at: receipt.collectedAt)
                await onAward?(receipt)
                guard accepts(requestGeneration), !Task.isCancelled else { return }
                isRefreshing = true
                await loadSnapshot(generation: requestGeneration, afterAward: true)
            } catch {
                if accepts(requestGeneration), !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        collectionTask = operation
        await operation.value
        if requestGeneration == generation {
            collectingTaskID = nil
            isRefreshing = false
            collectionTask = nil
        }
    }

    func stop() {
        isActive = false
        generation += 1
        refreshTask?.cancel(); collectionTask?.cancel()
        refreshTask = nil; collectionTask = nil
        snapshot = nil; confirmedCollections = [:]
        errorMessage = nil; isRefreshing = false; collectingTaskID = nil
        receivedAt = nil; serverDate = nil; onAward = nil
        sessionSubscription?.cancel(); sessionSubscription = nil
    }
    private var isCurrentOwner: Bool {
        guard case let .signedIn(user) = session?.state else { return false }
        return user.id == ownerID && user.role == .owner
    }
    private func accepts(_ requestGeneration: Int) -> Bool { isActive && requestGeneration == generation && isCurrentOwner }
    private func sortOrder(_ status: QuestTaskStatus) -> Int {
        switch status { case .ready: 0; case .inProgress: 1; case .collected: 2; case .unknown: 3 }
    }
    private func loadSnapshot(generation requestGeneration: Int, afterAward: Bool = false) async {
        do {
            let result = try await service.fetchQuests()
            guard accepts(requestGeneration), !Task.isCancelled else { return }
            guard let timestamp = QuestCalendar.parse(result.serverTime), result.timezone == "Australia/Melbourne",
                  QuestCalendar.dateString(timestamp) == result.localDate,
                  Set(result.tasks.map(\.id)).count == result.tasks.count else { throw APIError.invalidResponse }
            guard serverDate.map({ timestamp >= $0 }) ?? true,
                  displayDate.map({ result.localDate >= $0 }) ?? true else { return }
            for task in result.tasks where task.status == .collected && task.isSupported {
                confirmedCollections[task.id] = task
            }
            snapshot = result
            serverDate = timestamp
            receivedAt = now()
            errorMessage = nil
        } catch {
            if accepts(requestGeneration), !Task.isCancelled {
                errorMessage = afterAward ? "Your reward was collected. Pull down to refresh." : error.localizedDescription
            }
        }
    }
}
