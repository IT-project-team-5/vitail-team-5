import Foundation
import Combine

/// The venue feature supplies verified progress and the walking/check-in daily total.
/// Wallet balance and unrelated bonuses never determine venue availability.
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
    var collectedAt: Date? = nil

    var progressRatio: Double {
        guard requiredSeconds > 0 else { return 0 }
        return min(1, max(0, Double(verifiedSeconds) / Double(requiredSeconds)))
    }

    var isValid: Bool {
        !id.isEmpty && venueID > 0 && !venueName.isEmpty
            && requiredSeconds > 0 && verifiedSeconds >= 0 && rewardPoints >= 0
            && updatedAt.timeIntervalSince1970.isFinite
            && (status != .ready || verifiedSeconds >= requiredSeconds)
            && (status != .collected || collectedAt?.timeIntervalSince1970.isFinite == true)
    }
}

struct CheckInProgressSnapshot: Equatable, Sendable {
    let items: [VenueCheckInProgress]
    let localDate: String
    let earnedPointsToday: Int
    let serverTime: Date

    static let dailyLimit = 72
    static let maximumVenues = 4

    var isValid: Bool {
        serverTime.timeIntervalSince1970.isFinite && localDate == Self.day(serverTime)
            && (0...Self.dailyLimit).contains(earnedPointsToday)
            && items.count <= Self.maximumVenues
            && items.allSatisfy(\.isValid) && Set(items.map(\.id)).count == items.count
            && items.allSatisfy { $0.status != .collected || $0.collectedAt.map(Self.day) == localDate }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Australia/Melbourne")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct CheckInCollectionReceipt: Equatable, Sendable {
    let checkIn: VenueCheckInProgress
    let awardedPoints: Int
    let walletBalance: Int
    let dailyEarnedPoints: Int
    let localDate: String
}

protocol CheckInProgressServing: Sendable {
    /// Return all four current daily opportunities while below the combined cap.
    func fetchProgress() async throws -> CheckInProgressSnapshot
    /// Server enforces eligibility, the 72-point cap, and request/entitlement idempotency.
    func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt
}

@MainActor
final class CheckInProgressStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var items: [VenueCheckInProgress] = []
    @Published private(set) var earnedPointsToday = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var collectingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    var onCollection: (@MainActor () async -> Void)?

    var isAvailable: Bool { service != nil }
    var activeItems: [VenueCheckInProgress] {
        guard isCurrentDay, earnedPointsToday < CheckInProgressSnapshot.dailyLimit else { return [] }
        return items.filter { $0.status == .ready || $0.status == .inProgress }
            .sorted { ($0.status == .ready ? 0 : 1, $0.id) < ($1.status == .ready ? 0 : 1, $1.id) }
    }
    var collectedTodayItems: [VenueCheckInProgress] {
        guard isCurrentDay else { return [] }
        return items.filter { $0.status == .collected && $0.collectedAt.map(CheckInProgressSnapshot.day) == localDate }
            .sorted { ($0.collectedAt ?? .distantPast) > ($1.collectedAt ?? .distantPast) }
    }
    var visibleItems: [VenueCheckInProgress] { activeItems + collectedTodayItems }

    private let service: (any CheckInProgressServing)?
    private weak var session: SessionStore?
    private let requiresOwnerSession: Bool
    private let now: () -> Date
    private var localDate: String?
    private var serverTime: Date?
    private var receivedAt: Date?
    private var sessionSubscription: AnyCancellable?
    private var requests: [String: UUID] = [:]
    private var confirmedCollections: [String: VenueCheckInProgress] = [:]
    private var revision = 0
    private var generation = 0
    private var isActive = true

    init(ownerID: Int, service: (any CheckInProgressServing)? = nil, session: SessionStore? = nil,
         now: @escaping () -> Date = Date.init) {
        self.ownerID = ownerID
        self.service = service
        self.session = session
        self.now = now
        requiresOwnerSession = session != nil
        sessionSubscription = session?.$state.sink { [weak self] state in
            guard let self else { return }
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self.stop()
        }
    }

    private var estimatedLocalDate: String? {
        guard let serverTime, let receivedAt else { return nil }
        // Advance the last server time only for display expiry, never dwell or awards.
        let estimatedServerTime = serverTime.addingTimeInterval(max(0, now().timeIntervalSince(receivedAt)))
        return CheckInProgressSnapshot.day(estimatedServerTime)
    }

    private var isCurrentDay: Bool { localDate != nil && localDate == estimatedLocalDate }

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
            guard fresh.isValid else { throw APIError.invalidResponse }
            if let serverTime, fresh.serverTime < serverTime { return }
            if let estimatedLocalDate, fresh.localDate < estimatedLocalDate { return }
            if localDate != fresh.localDate {
                confirmedCollections = [:]
                requests = [:]
                earnedPointsToday = 0
            }
            localDate = fresh.localDate
            serverTime = fresh.serverTime
            receivedAt = now()
            earnedPointsToday = max(earnedPointsToday, fresh.earnedPointsToday)
            for item in fresh.items where item.status == .collected { confirmedCollections[item.id] = item }
            var mergedItems = fresh.items.map { confirmedCollections[$0.id] ?? $0 }
            // Keep a confirmed receipt visible today even if a stale response omits it.
            for item in confirmedCollections.values where !mergedItems.contains(where: { $0.id == item.id }) {
                mergedItems.append(item)
            }
            guard mergedItems.count <= CheckInProgressSnapshot.maximumVenues else { throw APIError.invalidResponse }
            items = mergedItems
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard isCurrentOwner, generation == startedGeneration, revision == startedRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func collect(id: String) async {
        guard isCurrentOwner, let service, !collectingIDs.contains(id),
              let item = activeItems.first(where: { $0.id == id }), item.status == .ready,
              let requestedDate = localDate else { return }
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
            guard isCurrentOwner, generation == startedGeneration, localDate == requestedDate else { return }
            guard receipt.checkIn.isValid, receipt.checkIn.id == id,
                  receipt.checkIn.venueID == item.venueID, receipt.checkIn.status == .collected,
                  receipt.localDate == requestedDate,
                  receipt.checkIn.collectedAt.map(CheckInProgressSnapshot.day) == requestedDate,
                  (0...item.rewardPoints).contains(receipt.awardedPoints), receipt.walletBalance >= 0,
                  (0...CheckInProgressSnapshot.dailyLimit).contains(receipt.dailyEarnedPoints),
                  receipt.dailyEarnedPoints >= receipt.awardedPoints else { throw APIError.invalidResponse }
            revision += 1
            earnedPointsToday = max(earnedPointsToday, receipt.dailyEarnedPoints)
            confirmedCollections[id] = receipt.checkIn
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = receipt.checkIn }
            else { items.append(receipt.checkIn) }
            await onCollection?()
        } catch is CancellationError {
            // Retain the request ID when the server may already have committed.
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
        localDate = nil
        serverTime = nil
        receivedAt = nil
        earnedPointsToday = 0
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
