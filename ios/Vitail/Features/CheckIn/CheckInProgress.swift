import Foundation
import Combine

/// Shared presentation contract for the venue team's verified check-in service.
/// Device clocks never advance dwell progress or make a check-in collectible.
struct VenueCheckInProgress: Equatable, Identifiable, Sendable {
    enum Status: String, Sendable { case inProgress, ready, collected, cancelled }

    let id: String
    let venueID: Int
    let venueName: String
    let photo: String?
    let requiredSeconds: Int
    let verifiedSeconds: Int
    let status: Status
    let updatedAt: Date
    let rewardPoints: Int

    var progressRatio: Double {
        guard requiredSeconds > 0 else { return 0 }
        return min(1, max(0, Double(verifiedSeconds) / Double(requiredSeconds)))
    }

    var isValid: Bool {
        !id.isEmpty && venueID > 0 && !venueName.isEmpty
            && requiredSeconds > 0 && verifiedSeconds >= 0 && rewardPoints >= 0
            && updatedAt.timeIntervalSince1970.isFinite
            && (status != .ready || verifiedSeconds >= requiredSeconds)
    }
}

struct CheckInCollectionReceipt: Equatable, Sendable {
    let checkIn: VenueCheckInProgress
    let awardedPoints: Int
    let walletBalance: Int
}

protocol CheckInProgressServing: Sendable {
    func fetchProgress() async throws -> [VenueCheckInProgress]
    /// Must be idempotent for both this request ID and the check-in entitlement.
    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt
}

@MainActor
final class CheckInProgressStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var items: [VenueCheckInProgress] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var collectingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    var onCollection: (@MainActor () async -> Void)?

    var isAvailable: Bool { service != nil }
    var visibleItems: [VenueCheckInProgress] { items.filter { $0.status != .cancelled } }

    private let service: (any CheckInProgressServing)?
    private weak var session: SessionStore?
    private let requiresOwnerSession: Bool
    private var sessionSubscription: AnyCancellable?
    private var requests: [String: UUID] = [:]
    private var confirmedCollections: [String: VenueCheckInProgress] = [:]
    private var revision = 0
    private var generation = 0
    private var isActive = true

    init(ownerID: Int, service: (any CheckInProgressServing)? = nil, session: SessionStore? = nil) {
        self.ownerID = ownerID
        self.service = service
        self.session = session
        requiresOwnerSession = session != nil
        sessionSubscription = session?.$state.sink { [weak self] state in
            guard let self else { return }
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self.stop()
        }
    }

    private var isCurrentOwner: Bool {
        guard requiresOwnerSession else { return isActive }
        guard case let .signedIn(user) = session?.state else { return false }
        return isActive && user.id == ownerID && user.role == .owner
    }

    func refresh() async {
        guard isCurrentOwner, !isRefreshing, let service else { return }
        let startedGeneration = generation
        let startedRevision = revision
        isRefreshing = true
        defer { if generation == startedGeneration { isRefreshing = false } }
        do {
            let fresh = try await service.fetchProgress()
            try Task.checkCancellation()
            guard isCurrentOwner, generation == startedGeneration, revision == startedRevision else { return }
            guard fresh.allSatisfy(\.isValid), Set(fresh.map(\.id)).count == fresh.count else {
                throw APIError.invalidResponse
            }
            // An eventually consistent refresh cannot resurrect a collected reward.
            for item in fresh where item.status == .collected { confirmedCollections[item.id] = item }
            items = fresh.map { confirmedCollections[$0.id] ?? $0 }
            errorMessage = nil
        } catch is CancellationError {
            // Leaving a tab is not a failed check-in.
        } catch {
            guard isCurrentOwner, generation == startedGeneration, revision == startedRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func collect(id: String) async {
        guard isCurrentOwner, let service, !collectingIDs.contains(id),
              let item = items.first(where: { $0.id == id }), item.status == .ready else { return }
        let startedGeneration = generation
        let requestID = requests[id] ?? UUID()
        requests[id] = requestID
        revision += 1
        collectingIDs.insert(id)
        errorMessage = nil
        defer { if generation == startedGeneration { collectingIDs.remove(id) } }
        do {
            let receipt = try await service.collect(id: id, requestID: requestID)
            try Task.checkCancellation()
            guard isCurrentOwner, generation == startedGeneration else { return }
            guard receipt.checkIn.isValid, receipt.checkIn.id == id,
                  receipt.checkIn.venueID == item.venueID, receipt.checkIn.status == .collected,
                  receipt.awardedPoints >= 0, receipt.walletBalance >= 0 else { throw APIError.invalidResponse }
            revision += 1
            confirmedCollections[id] = receipt.checkIn
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = receipt.checkIn }
            else { items.append(receipt.checkIn) }
            await onCollection?()
        } catch is CancellationError {
            // Keep requestID: a response may have been lost after the server committed.
        } catch {
            guard isCurrentOwner, generation == startedGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        isActive = false
        generation += 1
        revision += 1
        items = []
        requests = [:]
        confirmedCollections = [:]
        collectingIDs = []
        isRefreshing = false
        errorMessage = nil
        onCollection = nil
        sessionSubscription?.cancel()
        sessionSubscription = nil
    }
}
