import Combine
import CoreLocation
import Foundation

/// Shares only fixes captured by the existing walk coordinator. No independent GPS manager.
@MainActor
final class FriendsStore: ObservableObject {
    let ownerID: Int
    @Published private(set) var overview: SocialOverview?
    @Published private(set) var mapSnapshot: SocialMapSnapshot = .empty
    @Published private(set) var invitations: NetWalkInvitations = .empty
    @Published private(set) var currentSession: SocialWalkSession?
    @Published private(set) var searchResults: [SocialProfile] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var preferenceSaveError: String?
    @Published private(set) var notice: String?

    private let service: any FriendsServing
    private let now: () -> Date
    private weak var session: SessionStore?
    private var sessionSubscription: AnyCancellable?
    private var enabled = true
    private var foreground = false
    private var generation = 0
    private var readRevision = 0
    private var searchRevision = 0
    private var desiredPreferences: SocialPreferenceUpdate?
    private var failedPreferenceUpdate: SocialPreferenceUpdate?
    private var preferencesAwaitingConfirmation = false
    private var preferenceSafetyHold = false
    private var walkRequestID: UUID?
    private var walkStartedAt: Date?
    private var isWalking = false
    private var latestLocation: CLLocation?
    private var lastPublishedAt: Date?
    private var interruptionRevision = 0
    private var appliedInterruptionRevision = 0
    private var awaitingFreshFix = false
    private var syncRequested = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshIdentity: UUID?
    private var syncTask: Task<Void, Never>?

    init(ownerID: Int, session: SessionStore? = nil, service: any FriendsServing = FriendsService(),
         now: @escaping () -> Date = Date.init) {
        self.ownerID = ownerID
        self.session = session
        self.service = service
        self.now = now
        sessionSubscription = session?.$state.sink { [weak self] state in
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self?.stop()
        }
    }

    deinit { pollTask?.cancel(); refreshTask?.cancel(); syncTask?.cancel() }

    var sharesWithFriends: Bool { preferences?.locationVisibility == "FRIENDS" }
    var netMatchingEnabled: Bool { preferences?.netMatchingEnabled == true }
    var avatarKey: String { preferences?.avatarKey ?? "" }
    var hasPendingPreferenceRetry: Bool { failedPreferenceUpdate != nil }
    var preferenceRetrySummary: String? {
        guard let failedPreferenceUpdate else { return nil }
        let sharing = failedPreferenceUpdate.locationVisibility == "FRIENDS" ? "on" : "off"
        let matching = failedPreferenceUpdate.netMatchingEnabled ? "on" : "off"
        let avatar = SocialAvatarOption(rawValue: failedPreferenceUpdate.avatarKey)?.title ?? "selected"
        return "Retry will save: friend sharing \(sharing), Net-Walking \(matching), map avatar \(avatar)."
    }
    var isCurrentlyWalking: Bool { isWalking && walkRequestID != nil }
    private var isReadyForNetWalk: Bool {
        isCurrentlyWalking && netMatchingEnabled && !preferencesAwaitingConfirmation
            && !awaitingFreshFix && appliedInterruptionRevision == interruptionRevision
            && currentSession?.state == "RECORDING"
    }
    var canAcceptInvitation: Bool { isReadyForNetWalk }
    var canSendInvitation: Bool {
        isReadyForNetWalk && invitations.active == nil
            && invitations.incoming.isEmpty && invitations.outgoing.isEmpty
    }
    var peers: [SocialMapPeer] {
        let combined = mapSnapshot.friends + mapSnapshot.nearby + [mapSnapshot.partner].compactMap { $0 }
        return Dictionary(combined.filter { $0.isFresh(at: now()) }.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            second.isNetPartner ? second : first
        }).values.sorted { $0.id < $1.id }
    }
    private var preferences: SocialPreferenceUpdate? {
        desiredPreferences ?? overview.map {
            .init(locationVisibility: $0.me.locationVisibility, netMatchingEnabled: $0.me.netMatchingEnabled,
                  avatarKey: $0.me.avatarKey ?? "")
        }
    }
    private var shouldPublish: Bool {
        if preferenceSafetyHold { return false }
        if preferencesAwaitingConfirmation {
            // An existing accepted Net-Walk continues if only friend visibility changes.
            // Newly enabled channels wait for server confirmation; disabled channels stop now.
            return (sharesWithFriends && overview?.me.locationVisibility == "FRIENDS")
                || (netMatchingEnabled && overview?.me.netMatchingEnabled == true)
        }
        return sharesWithFriends || netMatchingEnabled
    }
    private var isCurrentOwner: Bool {
        guard let session else { return true }
        if case let .signedIn(user) = session.state { return user.id == ownerID && user.role == .owner }
        return false
    }
    private func valid(_ value: Int) -> Bool { enabled && isCurrentOwner && value == generation }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        pollTask?.cancel(); pollTask = nil
        mapSnapshot = mapSnapshot.fresh(at: now())
        guard enabled, value else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled, self.foreground else { return }
                await self.refresh()
                self.scheduleSync()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    func refresh() async {
        guard enabled, isCurrentOwner else { stop(); return }
        if let refreshTask { await refreshTask.value; return }
        let lifetime = generation
        let revision = readRevision
        let identity = UUID()
        refreshIdentity = identity
        isRefreshing = true
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let loadedOverview = service.overview()
                async let loadedMap = service.map()
                async let loadedInvitations = service.invitations()
                let (summary, positions, invites) = try await (loadedOverview, loadedMap, loadedInvitations)
                guard valid(lifetime), revision == readRevision, !Task.isCancelled else { return }
                overview = summary
                let interruptionPending = awaitingFreshFix || appliedInterruptionRevision < interruptionRevision
                mapSnapshot = interruptionPending ? .empty : positions.fresh(at: now())
                invitations = interruptionPending ? .empty : invites
                if syncTask == nil { currentSession = summary.currentSession }
                errorMessage = nil
                scheduleSync()
            } catch {
                guard valid(lifetime), revision == readRevision else { return }
                // Location data must not survive a failed refresh or an offline account.
                mapSnapshot = .empty
                invitations = .empty
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
        refreshTask = operation
        await operation.value
        if valid(lifetime), refreshIdentity == identity {
            refreshTask = nil; refreshIdentity = nil; isRefreshing = false
        }
    }

    func search(_ query: String) async {
        searchRevision += 1
        let revision = searchRevision, lifetime = generation
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = []
        errorMessage = nil
        guard valid(lifetime), value.count >= 2 else { isSearching = false; return }
        isSearching = true
        do {
            let users = try await service.search(value)
            guard valid(lifetime), revision == searchRevision, !Task.isCancelled else { return }
            searchResults = users.filter { $0.publicID != overview?.me.publicID }
        } catch {
            guard valid(lifetime), revision == searchRevision else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        if valid(lifetime), revision == searchRevision { isSearching = false }
    }

    func updatePreferences(shareWithFriends: Bool, netMatching: Bool, avatarKey: String? = nil) async {
        let update = SocialPreferenceUpdate(
            locationVisibility: shareWithFriends ? "FRIENDS" : "OFF",
            netMatchingEnabled: netMatching,
            avatarKey: avatarKey ?? self.avatarKey
        )
        await savePreferences(update)
    }

    func retryPreferences() async {
        guard let failedPreferenceUpdate else { return }
        await savePreferences(failedPreferenceUpdate)
    }

    private func savePreferences(_ update: SocialPreferenceUpdate) async {
        guard enabled, isCurrentOwner, !isWorking else { return }
        let lifetime = generation
        let isRecoveringFromFailure = failedPreferenceUpdate != nil
        preferenceSafetyHold = isRecoveringFromFailure
        failedPreferenceUpdate = isRecoveringFromFailure ? update : nil
        if !isRecoveringFromFailure { preferenceSaveError = nil }
        desiredPreferences = update
        preferencesAwaitingConfirmation = true
        readRevision += 1
        mapSnapshot = .empty
        latestLocation = nil
        notice = nil
        isWorking = true
        scheduleSync()
        do {
            let saved = try await service.updatePreferences(update)
            guard valid(lifetime) else { return }
            preferencesAwaitingConfirmation = false
            preferenceSafetyHold = false
            apply(savedPreferences: saved)
            failedPreferenceUpdate = nil
            preferenceSaveError = nil
            if saved.locationVisibility == update.locationVisibility,
               saved.netMatchingEnabled == update.netMatchingEnabled,
               (saved.avatarKey ?? "") == update.avatarKey { desiredPreferences = nil }
            await reloadAfterMutation()
            if overview?.me.locationVisibility == update.locationVisibility,
               overview?.me.netMatchingEnabled == update.netMatchingEnabled,
               (overview?.me.avatarKey ?? "") == update.avatarKey { desiredPreferences = nil }
            isWorking = false
            notice = "Privacy settings saved. Location is shared only during an active walk."
            scheduleSync()
        } catch {
            guard valid(lifetime) else { return }
            isWorking = false
            preferencesAwaitingConfirmation = false
            preferenceSafetyHold = false
            failedPreferenceUpdate = update
            preferenceSaveError = "These settings weren't saved. Location sharing is paused on this device until the server confirms your choice."
            // Preserve the exact server update for retry while every local sharing
            // channel remains off. Keep the selected avatar visible as unsaved work.
            desiredPreferences = SocialPreferenceUpdate(
                locationVisibility: "OFF", netMatchingEnabled: false,
                avatarKey: update.avatarKey
            )
            scheduleSync()
        }
    }

    private func apply(savedPreferences saved: SocialPreferences) {
        guard let overview else { return }
        self.overview = SocialOverview(
            me: saved,
            friends: overview.friends,
            incomingRequests: overview.incomingRequests,
            outgoingRequests: overview.outgoingRequests,
            blockedUsers: overview.blockedUsers,
            currentSession: overview.currentSession
        )
    }

    func sendRequest(_ user: SocialProfile) async {
        await perform { try await self.service.sendRequest(publicID: user.publicID) }
    }
    func respondToRequest(_ relationship: SocialRelationship, accept: Bool) async {
        await perform { try await self.service.respondToRequest(id: relationship.id, accept: accept) }
    }
    func removeFriend(_ user: SocialProfile) async {
        mapSnapshot = .empty
        await perform { try await self.service.removeFriend(publicID: user.publicID) }
    }
    func block(_ user: SocialProfile) async {
        mapSnapshot = .empty
        searchRevision += 1
        searchResults.removeAll { $0.id == user.id }
        await perform { try await self.service.block(publicID: user.publicID) }
    }
    func unblock(_ user: SocialProfile) async {
        await perform { try await self.service.unblock(publicID: user.publicID) }
    }
    func invite(_ user: SocialProfile) async {
        guard canSendInvitation else {
            errorMessage = "Start a walk, enable Net-Walking, wait for a fresh location, and resolve any open invitation first."
            return
        }
        await perform { try await self.service.invite(publicID: user.publicID) }
    }
    func respondToInvitation(_ invitation: NetWalkInvitation, accept: Bool) async {
        guard !accept || canAcceptInvitation else {
            errorMessage = "Start a walk with a fresh location and enable Net-Walking to accept this invitation."
            return
        }
        await perform { try await self.service.respondToInvitation(id: invitation.id, accept: accept) }
    }
    func endInvitation(_ invitation: NetWalkInvitation) async {
        mapSnapshot = .empty
        await perform { try await self.service.endInvitation(id: invitation.id) }
    }

    private func perform(_ operation: @MainActor () async throws -> Void) async {
        guard enabled, isCurrentOwner, !isWorking else { return }
        let lifetime = generation
        isWorking = true; errorMessage = nil; notice = nil
        readRevision += 1
        do {
            try await operation()
            guard valid(lifetime) else { return }
            await reloadAfterMutation()
        } catch {
            guard valid(lifetime) else { return }
            mapSnapshot = .empty
            errorMessage = error.localizedDescription
        }
        if valid(lifetime) { isWorking = false }
    }

    private func reloadAfterMutation() async {
        let previous = refreshTask
        previous?.cancel()
        refreshTask = nil; refreshIdentity = nil; isRefreshing = false
        await previous?.value
        await refresh()
    }

    func updateWalk(isWalking: Bool, requestID: UUID?, startedAt: Date?) {
        guard enabled, isCurrentOwner else { return }
        let changed = self.isWalking != isWalking || walkRequestID != requestID
        self.isWalking = isWalking
        walkRequestID = requestID
        walkStartedAt = startedAt
        if changed {
            readRevision += 1
            latestLocation = nil
            lastPublishedAt = nil
            // A preview fix predates the active-walk consent boundary. Wait for
            // the first post-start fix before creating social presence.
            awaitingFreshFix = isWalking
            mapSnapshot = .empty
            invitations = .empty
        }
        scheduleSync()
    }

    func receiveLocation(_ location: CLLocation) {
        guard enabled, isCurrentOwner, isCurrentlyWalking, shouldPublish else { return }
        guard SocialLocationSample(location, now: now()) != nil else { locationUpdatesInterrupted(); return }
        awaitingFreshFix = false
        latestLocation = location
        scheduleSync()
    }

    /// Synchronous safety barrier for Core Location gaps. This clears every
    /// local coordinate-derived surface before the server pause is reconciled.
    func locationUpdatesInterrupted() {
        guard enabled, isCurrentOwner, isCurrentlyWalking, shouldPublish else { return }
        interruptionRevision += 1
        awaitingFreshFix = true
        latestLocation = nil
        mapSnapshot = .empty
        invitations = .empty
        readRevision += 1
        scheduleSync()
    }

    private func scheduleSync() {
        guard enabled, isCurrentOwner else { return }
        syncRequested = true
        guard syncTask == nil else { return }
        let lifetime = generation
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while valid(lifetime), syncRequested, !Task.isCancelled {
                syncRequested = false
                do { try await reconcileWalk(lifetime: lifetime) }
                catch {
                    guard valid(lifetime) else { break }
                    mapSnapshot = .empty
                    if !(error is CancellationError) { errorMessage = error.localizedDescription }
                    break
                }
            }
            if valid(lifetime) { syncTask = nil }
        }
    }

    private func reconcileWalk(lifetime: Int) async throws {
        let request = walkRequestID
        var desiredState = request == nil ? "FINISHED" : (isWalking && shouldPublish && !awaitingFreshFix ? "RECORDING" : "PAUSED")
        if let existing = currentSession, existing.requestID != request {
            if existing.state != "FINISHED" {
                _ = try await service.setWalkState(sessionID: existing.id, state: "FINISHED")
            }
            guard valid(lifetime) else { return }
            currentSession = nil
        }
        guard let request, let startedAt = walkStartedAt else { return }
        if currentSession == nil, desiredState == "RECORDING" {
            let created = try await service.startWalk(requestID: request, startedAt: startedAt)
            guard valid(lifetime) else { return }
            currentSession = created
            if walkRequestID != request || !isWalking || !shouldPublish { syncRequested = true; return }
        }
        guard let existing = currentSession, existing.requestID == request else { return }
        var liveSession = existing
        if appliedInterruptionRevision < interruptionRevision {
            let barrier = interruptionRevision
            let paused = try await service.setWalkState(sessionID: existing.id, state: "PAUSED")
            guard valid(lifetime) else { return }
            currentSession = paused; liveSession = paused
            appliedInterruptionRevision = barrier
            lastPublishedAt = nil
            mapSnapshot = .empty; invitations = .empty
            if walkRequestID != request || interruptionRevision > barrier { syncRequested = true; return }
            desiredState = isWalking && shouldPublish && !awaitingFreshFix ? "RECORDING" : "PAUSED"
        }
        if liveSession.state != desiredState {
            let updated = try await service.setWalkState(sessionID: existing.id, state: desiredState)
            guard valid(lifetime) else { return }
            currentSession = updated
            if walkRequestID != request || (isWalking && shouldPublish && !awaitingFreshFix ? "RECORDING" : "PAUSED") != desiredState
                || appliedInterruptionRevision < interruptionRevision {
                syncRequested = true; return
            }
        }
        guard desiredState == "RECORDING", walkRequestID == request, isWalking, shouldPublish,
              !awaitingFreshFix, appliedInterruptionRevision == interruptionRevision,
              let location = latestLocation, let sample = SocialLocationSample(location, now: now()),
              lastPublishedAt.map({ now().timeIntervalSince($0) >= 5 }) ?? true else { return }
        let publishedAt = now()
        let updated = try await service.reportLocation(sessionID: existing.id, sample: sample)
        guard valid(lifetime), walkRequestID == request, isWalking, shouldPublish,
              !awaitingFreshFix, appliedInterruptionRevision == interruptionRevision else { syncRequested = true; return }
        currentSession = updated
        lastPublishedAt = publishedAt
    }

    func prepareForLogout() async {
        updateWalk(isWalking: false, requestID: nil, startedAt: nil)
        await syncTask?.value
        if let currentSession, currentSession.state != "FINISHED" {
            _ = try? await service.setWalkState(sessionID: currentSession.id, state: "FINISHED")
        }
        stop()
    }

    func stop() {
        guard enabled else { return }
        enabled = false; generation += 1; searchRevision += 1
        pollTask?.cancel(); refreshTask?.cancel(); syncTask?.cancel()
        pollTask = nil; refreshTask = nil; refreshIdentity = nil; syncTask = nil
        sessionSubscription = nil
        overview = nil; currentSession = nil; mapSnapshot = .empty; invitations = .empty
        searchResults = []; latestLocation = nil; desiredPreferences = nil; failedPreferenceUpdate = nil
        preferencesAwaitingConfirmation = false; preferenceSafetyHold = false
        isWorking = false; isRefreshing = false; isSearching = false
        errorMessage = nil; preferenceSaveError = nil; notice = nil
    }
}
