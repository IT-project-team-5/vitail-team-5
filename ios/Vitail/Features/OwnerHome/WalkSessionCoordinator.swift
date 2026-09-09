import Combine
import Foundation
import UIKit

/// Owned by the signed-in owner screen, not by an individual tab. Location
/// callbacks record and checkpoint synchronously even when SwiftUI is suspended.
@MainActor
final class WalkSessionCoordinator: ObservableObject {
    let locationManager: WalkLocationManager
    let tracker: WalkSessionTracker
    let dogSelection: WalkDogSelectionViewModel
    let history: WalkHistoryStore

    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var canStartNewWalk = false

    private let draftPersistence: any WalkDraftPersisting
    private let now: () -> Date
    private var hasLoadedDraft = false
    private var pendingFinish: WalkDraft?
    private var isForeground: Bool
    private var isWalkPageVisible = false
    private var isEnabled = true
    private var subscriptions: Set<AnyCancellable> = []

    init(
        ownerID: Int,
        session: SessionStore? = nil,
        serverURL: URL? = AppConfiguration.apiBaseURL,
        locationManager: WalkLocationManager? = nil,
        historyPersistence: (any WalkHistoryPersisting)? = nil,
        draftPersistence: (any WalkDraftPersisting)? = nil,
        dogService: (any DogServicing)? = nil,
        now: @escaping () -> Date = Date.init,
        isForeground: Bool? = nil,
        observeLifecycle: Bool = true
    ) {
        self.now = now
        self.isForeground = isForeground ?? (UIApplication.shared.applicationState == .active)
        self.locationManager = locationManager ?? WalkLocationManager()
        self.draftPersistence = draftPersistence ?? WalkDraftFileStore(ownerID: ownerID, serverURL: serverURL)
        history = WalkHistoryStore(persistence: historyPersistence ?? WalkHistoryFileStore(ownerID: ownerID, serverURL: serverURL))
        tracker = WalkSessionTracker(now: now)
        dogSelection = WalkDogSelectionViewModel(session: tracker, service: dogService ?? DogService())
        loadDraft()

        self.locationManager.onLocations = { [weak self] locations in
            self?.tracker.recordBatch(locations)
        }
        self.locationManager.onInterruption = { [weak self] message, pauseRequired in
            guard let self else { return }
            if pauseRequired {
                tracker.pauseForInterruption(message: message)
            } else {
                tracker.interruptRoute(message: message)
            }
        }
        tracker.onChange = { [weak self] in
            guard let self else { return }
            refreshLocationMode()
            saveCheckpoint()
        }
        tracker.onFinish = { [weak self] record in self?.finish(record) }

        // A full-screen presentation is not a logout. End tracking only when
        // the authenticated owner changes, independently of view disappearance.
        session?.$state.sink { [weak self] state in
            if case let .signedIn(user) = state, user.id == ownerID, user.role == .owner { return }
            self?.shutdown()
        }.store(in: &subscriptions)

        if observeLifecycle {
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in self?.setForeground(false) }
                .store(in: &subscriptions)
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.setForeground(true) }
                .store(in: &subscriptions)
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
                .sink { [weak self] _ in self?.saveCheckpoint() }
                .store(in: &subscriptions)
        }
    }

    func setWalkPageVisible(_ visible: Bool) {
        isWalkPageVisible = visible
        refreshLocationMode()
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        guard isEnabled else { return }
        if foreground {
            locationManager.refreshAuthorization()
            retryStorage()
        } else {
            saveCheckpoint()
        }
        refreshLocationMode()
    }

    /// Logout ends live collection, but leaves a paused checkpoint for this owner.
    func shutdown() {
        guard isEnabled else { return }
        isEnabled = false
        tracker.pauseForInterruption(message: "Walk paused when you signed out. Tap Resume when ready.")
        saveCheckpoint()
        locationManager.setMode(.off)
        subscriptions.removeAll()
    }

    func retryStorage() {
        history.retry()
        if !hasLoadedDraft { loadDraft() }
        if pendingFinish != nil {
            saveFinishedWalk()
        } else {
            saveCheckpoint()
        }
    }

    private func refreshLocationMode() {
        let mode: WalkLocationManager.Mode
        if !isEnabled {
            mode = .off
        } else if tracker.status == .walking {
            mode = .recording
        } else {
            mode = isForeground && isWalkPageVisible ? .preview : .off
        }
        locationManager.setMode(mode)
    }

    private func loadDraft() {
        do {
            let draft = try draftPersistence.load()
            hasLoadedDraft = true
            storageErrorMessage = nil
            guard let draft else {
                canStartNewWalk = true
                return
            }
            if history.containsSavedRecord(id: draft.id) {
                // A crash after saving history but before clearing the draft is safe.
                try draftPersistence.clear()
                canStartNewWalk = true
            } else if draft.finishedRecord != nil {
                pendingFinish = draft
                saveFinishedWalk()
            } else {
                tracker.restore(draft)
                canStartNewWalk = true
            }
        } catch {
            hasLoadedDraft = false
            canStartNewWalk = false
            storageErrorMessage = "Could not read your saved walk. Tap Retry before starting a new walk. Your saved data has not been replaced."
        }
    }

    private func saveCheckpoint() {
        guard hasLoadedDraft, pendingFinish == nil, let draft = tracker.makeDraft() else { return }
        do {
            try draftPersistence.save(draft)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Could not save a walk checkpoint. Keep the app open and tap Retry. The latest route is still in memory."
        }
    }

    private func finish(_ record: WalkRecord) {
        refreshLocationMode()
        canStartNewWalk = false
        pendingFinish = WalkDraft(
            id: record.id, startedAt: record.startedAt, checkpointAt: max(now(), record.endedAt),
            activeDuration: record.activeDuration, distanceMetres: record.distanceMetres,
            dogs: tracker.participatingDogs, routeSegments: record.routeSegments,
            finishedRecord: record
        )
        saveFinishedWalk()
    }

    private func saveFinishedWalk() {
        guard let draft = pendingFinish, let record = draft.finishedRecord else { return }
        var checkpointSaved = false
        do {
            try draftPersistence.save(draft)
            checkpointSaved = true
        } catch {
            // Still attempt history: it is an independent durable destination.
        }
        history.append(record)
        guard history.containsSavedRecord(id: record.id) else {
            storageErrorMessage = checkpointSaved
                ? "Your finished walk is safe in a checkpoint. Tap Retry to add it to history."
                : "Could not save this walk. Keep the app open and tap Retry."
            return
        }
        do {
            try draftPersistence.clear()
            pendingFinish = nil
            canStartNewWalk = true
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Your walk is saved in history. Tap Retry to clear its checkpoint before starting another walk."
        }
    }
}
