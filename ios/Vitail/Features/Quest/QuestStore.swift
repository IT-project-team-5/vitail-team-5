import Combine
import Foundation

@MainActor
final class QuestStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var snapshot: QuestSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var collectingBirthdayID: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastAward: BirthdayCollectResponse?
    @Published private(set) var confirmedBirthdays: [Int: BirthdayAward] = [:]
    var onAward: (@MainActor (BirthdayCollectResponse) async -> Void)?

    private weak var session: SessionStore?
    private let service: any QuestServing
    private var generation = 0
    private var isActive = true
    private var refreshTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?

    init(ownerID: Int, session: SessionStore, service: any QuestServing = QuestService()) {
        self.ownerID = ownerID
        self.session = session
        self.service = service
    }

    deinit {
        refreshTask?.cancel()
        collectionTask?.cancel()
    }

    func refresh() async {
        guard isActive, isCurrentOwner else { stop(); return }
        if let refreshTask { await refreshTask.value; return }
        guard collectingBirthdayID == nil, !isRefreshing else { return }
        let currentGeneration = generation
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadSnapshot(generation: currentGeneration)
        }
        refreshTask = task
        await task.value
        if currentGeneration == generation {
            isRefreshing = false
            refreshTask = nil
        }
    }

    func birthdayWasCollected(_ dog: BirthdayQuestDog) -> Bool {
        if dog.status == .claimed { return true }
        guard let award = confirmedBirthdays[dog.dogID], let date = snapshot?.localDate else { return false }
        return String(award.year) == String(date.prefix(4))
    }

    func canCollectBirthday(_ dog: BirthdayQuestDog) -> Bool {
        isActive && snapshot?.birthdays.status == .available && dog.status == .available && dog.isBirthdayToday
            && !birthdayWasCollected(dog) && collectingBirthdayID == nil && !isRefreshing && isCurrentOwner
    }

    func collectBirthday(dogID: Int) async {
        guard let dog = snapshot?.birthdays.dogs.first(where: { $0.dogID == dogID }),
              canCollectBirthday(dog),
              let expectedYear = snapshot.flatMap({ Int($0.localDate.prefix(4)) }) else { return }
        let currentGeneration = generation
        collectingBirthdayID = dogID
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await service.collectBirthday(dogID: dogID)
                guard accepts(currentGeneration), !Task.isCancelled else { return }
                guard response.award.id > 0, response.award.kind == "BIRTHDAY",
                      response.award.dogID == dogID, response.award.year == expectedYear,
                      response.award.points == 60, response.balance >= 0 else {
                    throw APIError.invalidResponse
                }
                confirmedBirthdays[response.award.dogID] = response.award
                lastAward = response
                await onAward?(response)
                guard accepts(currentGeneration), !Task.isCancelled else { return }
                isRefreshing = true
                await loadSnapshot(generation: currentGeneration, afterAward: true)
            } catch {
                if accepts(currentGeneration), !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        collectionTask = task
        await task.value
        if currentGeneration == generation {
            collectingBirthdayID = nil
            isRefreshing = false
            collectionTask = nil
        }
    }

    func stop() {
        isActive = false
        generation += 1
        refreshTask?.cancel()
        collectionTask?.cancel()
        refreshTask = nil
        collectionTask = nil
        snapshot = nil
        confirmedBirthdays = [:]
        lastAward = nil
        errorMessage = nil
        isRefreshing = false
        collectingBirthdayID = nil
        onAward = nil
    }

    private var isCurrentOwner: Bool {
        guard case let .signedIn(user) = session?.state else { return false }
        return user.id == ownerID && user.role == .owner
    }

    private func accepts(_ requestGeneration: Int) -> Bool {
        isActive && requestGeneration == generation && isCurrentOwner
    }

    private func loadSnapshot(generation requestGeneration: Int, afterAward: Bool = false) async {
        do {
            let result = try await service.fetchQuests()
            guard accepts(requestGeneration), !Task.isCancelled else { return }
            snapshot = result
            confirmedBirthdays = confirmedBirthdays.filter { String($0.value.year) == String(result.localDate.prefix(4)) }
            errorMessage = nil
        } catch {
            if accepts(requestGeneration), !Task.isCancelled {
                errorMessage = afterAward
                    ? "Your reward was collected. Refresh to update your quests."
                    : error.localizedDescription
            }
        }
    }
}
