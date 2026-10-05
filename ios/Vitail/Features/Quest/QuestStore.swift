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
    private var snapshotRevision = 0
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
    var dailyGoals: [DogDailyGoalProgress]? {
        guard snapshot?.localDate == displayDate else { return nil }
        return snapshot?.dailyGoals
    }
    var visibleTasks: [QuestTask] {
        allTasks.filter { task in
            guard task.isSupported else { return false }
            if task.isStreak {
                // Earned rewards survive a break; cached live progress must await a new-day snapshot.
                return task.status == .ready || (task.status == .inProgress && snapshot?.localDate == displayDate)
            }
            if task.documentKind == .council, task.status != .inProgress {
                guard let date = displayDate.flatMap(DogBirthday.date),
                      DocumentRegistration.isCurrent(task.validTo, on: date) else { return false }
            }
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
            if task.isStreak && confirmedCollections[task.id] != nil { return false }
            // A delayed pre-submission row must not offer the same upload again
            // while its entitlement collection is awaiting a fresh server view.
            return task.status != .inProgress || !unacknowledged.contains {
                $0.documentKind != nil && $0.kind == task.kind && $0.dogID == task.dogID
                    && (task.documentKind != .council || (task.entitlementID == nil
                        || ($0.entitlementID == task.entitlementID && $0.validTo == task.validTo
                            && $0.needsExpiry == task.needsExpiry)))
                    && $0.collectedAt.flatMap(QuestCalendar.parse).map(QuestCalendar.dateString) == displayDate
            }
        }
        var tasks = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, task) in confirmedCollections where !task.isStreak { tasks[id] = task }
        return Array(tasks.values)
    }
    private var displayDate: String? {
        guard let serverDate, let receivedAt else { return snapshot?.localDate }
        return QuestCalendar.dateString(serverDate.addingTimeInterval(max(0, now().timeIntervalSince(receivedAt))))
    }
    func task(id: String) -> QuestTask? { visibleTasks.first { $0.id == id } }
    func detailTask(id: String) -> QuestTask? {
        task(id: id) ?? confirmedCollections[id].flatMap { $0.isStreak ? $0 : nil }
    }
    func canCollect(_ task: QuestTask) -> Bool {
        guard isActive, isCurrentOwner, !isRefreshing, collectingTaskID == nil,
              self.task(id: task.id) == task, task.status == .ready, task.isSupported else { return false }
        if task.isStreak { return true }
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
            var requestedRevision: Int
            repeat {
                requestedRevision = snapshotRevision
                await loadSnapshot(generation: requestGeneration, revision: requestedRevision)
            } while accepts(requestGeneration) && !Task.isCancelled && requestedRevision != snapshotRevision
            // Release only this operation's state before waking its waiters.
            if requestGeneration == generation { isRefreshing = false; refreshTask = nil }
        }
        refreshTask = task
        await task.value
    }

    func documentsDidChange() async {
        // Finish claims before invalidating registrations changed in dog settings.
        // Normal refreshes still retain confirmed awards when the network fails.
        while let collectionTask { await collectionTask.value }
        guard isActive, isCurrentOwner else { return }
        snapshotRevision += 1
        confirmedCollections = confirmedCollections.filter {
            $0.value.documentKind != .council && $0.value.documentKind != .microchip
        }
        if let previous = snapshot {
            snapshot = QuestSnapshot(serverTime: previous.serverTime, timezone: previous.timezone,
                localDate: previous.localDate, tasks: previous.tasks.filter {
                    $0.documentKind != .council && $0.documentKind != .microchip
                }, dailyGoals: previous.dailyGoals, goalRewardsStatus: previous.goalRewardsStatus)
        }
        await refresh()
    }

    func walksDidChange() async {
        // Invalidate older reads immediately. Their owning operation fetches
        // again, so polling and simultaneous change notifications stay serialized.
        snapshotRevision += 1
        while let collectionTask { await collectionTask.value }
        guard isActive, isCurrentOwner else { return }
        await refresh()
    }

    func collect(taskID: String) async {
        guard let selected = task(id: taskID), canCollect(selected) else { return }
        let requestGeneration = generation
        let expectedYear = snapshot.flatMap { Int($0.localDate.prefix(4)) }
        collectingTaskID = taskID
        errorMessage = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if requestGeneration == generation {
                    collectingTaskID = nil
                    isRefreshing = false
                    collectionTask = nil
                }
            }
            do {
                let receipt: QuestAwardReceipt
                if selected.isStreak {
                    guard let runStartDate = selected.runStartDate, let milestoneDays = selected.milestoneDays else {
                        throw APIError.invalidResponse
                    }
                    let request = StreakCollectRequest(runStartDate: runStartDate, milestoneDays: milestoneDays)
                    let result = try await service.collectStreak(request)
                    guard result.award.id > 0, result.award.kind == "STREAK",
                          result.award.runStartDate == runStartDate, result.award.milestoneDays == milestoneDays,
                          result.award.points == selected.rewardPoints else { throw APIError.invalidResponse }
                    receipt = QuestAwardReceipt(kind: result.award.kind, dogID: nil, points: result.award.points,
                                                balance: result.balance, collectedAt: result.award.awardedAt, created: result.created)
                } else if selected.isBirthday {
                    guard let dogID = selected.dogID else { throw APIError.invalidResponse }
                    let result = try await service.collectBirthday(dogID: dogID)
                    guard result.award.id > 0, result.award.dogID == dogID,
                          result.award.year == expectedYear, result.award.kind == "BIRTHDAY",
                          result.award.points == 60 else { throw APIError.invalidResponse }
                    receipt = QuestAwardReceipt(kind: result.award.kind, dogID: dogID, points: result.award.points,
                                                balance: result.balance, collectedAt: result.award.awardedAt, created: result.created)
                } else {
                    guard let dogID = selected.dogID, let entitlementID = selected.entitlementID else { throw APIError.invalidResponse }
                    let result = try await service.collectDocument(entitlementID: entitlementID)
                    guard result.entitlementID == entitlementID, result.dogID == dogID,
                          result.kind == selected.documentKind, result.points == selected.rewardPoints,
                          (result.kind != .council || (result.validTo == selected.validTo && result.needsExpiry != true)) else {
                        throw APIError.invalidResponse
                    }
                    receipt = QuestAwardReceipt(kind: result.kind.rawValue, dogID: dogID, points: result.points,
                                                balance: result.balance, collectedAt: result.collectedAt, created: result.created)
                }
                guard accepts(requestGeneration), !Task.isCancelled else { return }
                guard receipt.balance >= 0, receipt.points > 0,
                      QuestCalendar.parse(receipt.collectedAt) != nil else { throw APIError.invalidResponse }
                if selected.isStreak {
                    guard let run = selected.runStartDate.flatMap(DogBirthday.date),
                          let awarded = QuestCalendar.parse(receipt.collectedAt), let milestone = selected.milestoneDays,
                          let days = DogBirthday.calendar.dateComponents([.day],
                              from: DogBirthday.calendar.startOfDay(for: run),
                              to: DogBirthday.calendar.startOfDay(for: awarded)).day,
                          days >= milestone - 1 else { throw APIError.invalidResponse }
                }
                confirmedCollections[taskID] = selected.collected(at: receipt.collectedAt)
                await onAward?(receipt)
                guard accepts(requestGeneration), !Task.isCancelled else { return }
                isRefreshing = true
                await loadSnapshot(generation: requestGeneration, revision: snapshotRevision, afterAward: true)
            } catch {
                if accepts(requestGeneration), !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        collectionTask = operation
        await operation.value
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
    private func loadSnapshot(generation requestGeneration: Int, revision: Int, afterAward: Bool = false) async {
        let requestedAt = now()
        do {
            let result = try await service.fetchQuests()
            guard accepts(requestGeneration), revision == snapshotRevision, !Task.isCancelled else { return }
            guard let timestamp = QuestCalendar.parse(result.serverTime), result.timezone == "Australia/Melbourne",
                  QuestCalendar.dateString(timestamp) == result.localDate,
                  Set(result.tasks.map(\.id)).count == result.tasks.count else { throw APIError.invalidResponse }
            if let goals = result.dailyGoals {
                guard Set(goals.map(\.dogID)).count == goals.count,
                      goals.allSatisfy({ $0.isValid(on: result.localDate) }) else { throw APIError.invalidResponse }
            }
            let streakTasks = result.tasks.filter(\.isStreak)
            guard streakTasks.count <= 1, streakTasks.allSatisfy({ task in
                task.isSupported && (task.status == .ready || task.status == .inProgress)
                    && (task.runStartDate.map { $0 <= result.localDate } ?? true)
            }) else { throw APIError.invalidResponse }
            guard serverDate.map({ timestamp >= $0 }) ?? true,
                  displayDate.map({ result.localDate >= $0 }) ?? true else { return }
            for task in result.tasks where task.status == .collected && task.isSupported {
                confirmedCollections[task.id] = task
            }
            snapshot = result
            serverDate = timestamp
            // Include time spent awaiting the response when expiring calendars.
            // A slow pre-midnight response must not start a fresh cache lifetime.
            receivedAt = requestedAt
            errorMessage = nil
        } catch {
            if accepts(requestGeneration), revision == snapshotRevision, !Task.isCancelled {
                errorMessage = afterAward ? "Your reward was collected. Pull down to refresh." : error.localizedDescription
            }
        }
    }
}
