import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

@MainActor
final class WalkSessionTracker: ObservableObject {
    enum Status: Equatable {
        case idle
        case walking
        case paused
        case finished
    }

    static let maximumAcceptedAccuracy: CLLocationAccuracy = 30
    static let maximumRouteGap: TimeInterval = 60

    @Published private(set) var status: Status = .idle
    @Published private(set) var distanceMetres: CLLocationDistance = 0
    @Published private(set) var participatingDogs: [Dog] = []
    @Published private(set) var routeSegments: [[WalkRoutePoint]] = []
    @Published private(set) var completedWalk: WalkRecord?
    @Published private(set) var trackingNotice: String?

    // These callbacks run with the location delegate, not with a SwiftUI render.
    var onChange: (() -> Void)?
    var onFinish: (WalkRecord) -> Void

    private var lastTrackedLocation: CLLocation?
    private var lastRouteTimestamp: Date?
    private var startsNewSegment = true
    private var startedAt: Date?
    private var sessionID: UUID?
    private var activeIntervalStartedAt: Date?
    private var activeDuration: TimeInterval = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init, onFinish: @escaping (WalkRecord) -> Void = { _ in }) {
        self.now = now
        self.onFinish = onFinish
    }

    var distanceKilometres: Double {
        distanceMetres / 1_000
    }

    var canStart: Bool {
        status == .idle || status == .finished
    }

    var canPauseOrResume: Bool {
        status == .walking || status == .paused
    }

    var isInProgress: Bool {
        status == .walking || status == .paused
    }

    var canFinish: Bool {
        status == .walking || status == .paused
    }

    static func canUse(_ location: CLLocation?) -> Bool {
        guard let location else { return false }
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.timestamp.timeIntervalSince1970.isFinite
            && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maximumAcceptedAccuracy
    }

    static func isFresh(_ location: CLLocation?, at date: Date = Date()) -> Bool {
        guard let location, canUse(location) else { return false }
        let age = date.timeIntervalSince(location.timestamp)
        return age.isFinite && age >= -5 && age <= 15
    }

    func start(from location: CLLocation?, dogs: [Dog]) {
        guard canStart, let location, Self.canUse(location), !dogs.isEmpty else { return }

        let startTime = now()
        var seenDogIDs: Set<Int> = []
        participatingDogs = dogs.filter { seenDogIDs.insert($0.id).inserted }
        distanceMetres = 0
        routeSegments = []
        completedWalk = nil
        trackingNotice = nil
        sessionID = UUID()
        lastRouteTimestamp = nil
        startsNewSegment = true
        startedAt = startTime
        activeIntervalStartedAt = startTime
        activeDuration = 0
        // A fresh map fix can still predate the Start tap. Do not count that
        // movement; the first fix in the active interval becomes the anchor.
        lastTrackedLocation = nil
        if location.timestamp >= startTime {
            lastTrackedLocation = location
            appendRoutePoint(location)
        }
        status = .walking
        onChange?()
    }

    func pause() {
        guard status == .walking else { return }
        finishActiveInterval(at: now())
        lastTrackedLocation = nil
        startsNewSegment = true
        status = .paused
        onChange?()
    }

    func resume(from location: CLLocation?) {
        guard status == .paused else { return }
        lastTrackedLocation = nil
        startsNewSegment = true
        let resumeTime = now()
        activeIntervalStartedAt = resumeTime
        trackingNotice = nil
        if let location, Self.canUse(location), location.timestamp >= resumeTime,
           isNewRouteTimestamp(location.timestamp) {
            lastTrackedLocation = location
            appendRoutePoint(location)
        }
        status = .walking
        onChange?()
    }

    func finish() {
        guard canFinish, let startedAt, let sessionID else { return }
        let endTime = max(now(), startedAt)
        finishActiveInterval(at: endTime)
        lastTrackedLocation = nil
        let record = WalkRecord(
            id: sessionID, startedAt: startedAt, endedAt: endTime,
            activeDuration: activeDuration, distanceMetres: distanceMetres,
            dogs: participatingDogs.map { WalkDogSnapshot(id: $0.id, name: $0.name) },
            routeSegments: routeSegments
        )
        completedWalk = record
        status = .finished
        trackingNotice = nil
        onFinish(record)
        onChange?()
    }

    func record(_ location: CLLocation) {
        if recordLocation(location) { onChange?() }
    }

    func recordBatch(_ locations: [CLLocation]) {
        guard status == .walking, let activeIntervalStartedAt else { return }
        let latestAllowedTime = now().addingTimeInterval(5)
        var changed = false
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            // Delayed batches are valid; samples from before Start/Resume are not.
            guard location.timestamp >= activeIntervalStartedAt,
                  location.timestamp <= latestAllowedTime else { continue }
            if recordLocation(location) { changed = true }
        }
        if changed { onChange?() }
    }

    func interruptRoute(message: String) {
        guard status == .walking else { return }
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = message
        onChange?()
    }

    func pauseForInterruption(message: String) {
        guard status == .walking else { return }
        finishActiveInterval(at: now())
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = message
        status = .paused
        onChange?()
    }

    func makeDraft() -> WalkDraft? {
        guard isInProgress, let sessionID, let startedAt else { return nil }
        let checkpoint = max(now(), startedAt)
        let elapsed = activeIntervalStartedAt.map { max(0, checkpoint.timeIntervalSince($0)) } ?? 0
        return WalkDraft(
            id: sessionID, startedAt: startedAt, checkpointAt: checkpoint,
            activeDuration: activeDuration + elapsed, distanceMetres: distanceMetres,
            dogs: participatingDogs, routeSegments: routeSegments
        )
    }

    @discardableResult
    func restore(_ draft: WalkDraft) -> Bool {
        guard canStart, draft.isValid, draft.finishedRecord == nil else { return false }
        sessionID = draft.id
        startedAt = draft.startedAt
        activeDuration = draft.activeDuration
        activeIntervalStartedAt = nil
        participatingDogs = draft.dogs
        distanceMetres = draft.distanceMetres
        routeSegments = draft.routeSegments
        completedWalk = nil
        lastRouteTimestamp = draft.routeSegments.last?.last?.timestamp
        lastTrackedLocation = nil
        startsNewSegment = true
        trackingNotice = "Previous walk recovered. Tap Resume when ready. Time while the app was closed is not counted."
        status = .paused
        onChange?()
        return true
    }

    private func recordLocation(_ location: CLLocation) -> Bool {
        guard status == .walking, Self.canUse(location), isNewRouteTimestamp(location.timestamp) else { return false }

        if let previous = lastTrackedLocation,
           location.timestamp.timeIntervalSince(previous.timestamp) > Self.maximumRouteGap {
            lastTrackedLocation = nil
            startsNewSegment = true
        }

        guard let previousLocation = lastTrackedLocation else {
            lastTrackedLocation = location
            appendRoutePoint(location)
            trackingNotice = nil
            return true
        }

        guard location.timestamp > previousLocation.timestamp else { return false }

        let segmentDistance = location.distance(from: previousLocation)
        guard segmentDistance.isFinite, segmentDistance >= 0 else { return false }

        distanceMetres += segmentDistance
        lastTrackedLocation = location
        appendRoutePoint(location)
        trackingNotice = nil
        return true
    }

    private func isNewRouteTimestamp(_ timestamp: Date) -> Bool {
        guard let lastRouteTimestamp else { return true }
        return timestamp > lastRouteTimestamp
    }

    private func appendRoutePoint(_ location: CLLocation) {
        let point = WalkRoutePoint(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            timestamp: location.timestamp
        )
        if startsNewSegment || routeSegments.isEmpty {
            routeSegments.append([point])
            startsNewSegment = false
        } else {
            routeSegments[routeSegments.count - 1].append(point)
        }
        lastRouteTimestamp = location.timestamp
    }

    private func finishActiveInterval(at endTime: Date) {
        guard let activeIntervalStartedAt else { return }
        activeDuration += max(0, endTime.timeIntervalSince(activeIntervalStartedAt))
        self.activeIntervalStartedAt = nil
    }
}

struct WalkMapView: View {
    let isActive: Bool
    let onManageDogs: () -> Void

    @ObservedObject private var coordinator: WalkSessionCoordinator
    @ObservedObject private var locationManager: WalkLocationManager
    @ObservedObject private var walkTracker: WalkSessionTracker
    @ObservedObject private var dogSelection: WalkDogSelectionViewModel
    @ObservedObject private var walkHistory: WalkHistoryStore
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var hasCentredOnUser = false
    @State private var walkCardHeight: CGFloat = 300
    @Environment(\.openURL) private var openURL

    init(coordinator: WalkSessionCoordinator, isActive: Bool, onManageDogs: @escaping () -> Void) {
        self.isActive = isActive
        self.onManageDogs = onManageDogs
        self.coordinator = coordinator
        locationManager = coordinator.locationManager
        walkTracker = coordinator.tracker
        dogSelection = coordinator.dogSelection
        walkHistory = coordinator.history
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    WalkDogSelectionCard(
                        selection: dogSelection,
                        session: walkTracker,
                        location: locationManager.location,
                        canStartNewWalk: coordinator.canStartNewWalk,
                        onManageDogs: onManageDogs
                    )
                    .background {
                        GeometryReader { cardGeometry in
                            Color.clear.preference(key: WalkCardHeightKey.self, value: cardGeometry.size.height)
                        }
                    }

                    if let message = coordinator.storageErrorMessage {
                        LocationStatusCard(
                            icon: "exclamationmark.triangle.fill",
                            title: "Walk storage needs attention",
                            message: message, actionTitle: "Retry", action: coordinator.retryStorage
                        )
                    }

                    mapCard
                        .frame(height: Self.mapHeight(availableHeight: geometry.size.height, cardHeight: walkCardHeight))

                    WalkHistorySection(store: walkHistory)
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
            .refreshable { await dogSelection.load() }
            .onPreferenceChange(WalkCardHeightKey.self) { height in
                if height > 0 { walkCardHeight = height }
            }
        }
        .onAppear {
            coordinator.setWalkPageVisible(isActive)
            if isActive { reloadDogs() }
        }
        .onDisappear {
            coordinator.setWalkPageVisible(false)
        }
        .onChange(of: isActive) { _, active in
            coordinator.setWalkPageVisible(active)
            if active { reloadDogs() }
        }
        .onChange(of: walkTracker.status) { _, status in
            if status == .finished { reloadDogs() }
        }
        .onChange(of: locationManager.location?.timestamp) { _, _ in
            guard !hasCentredOnUser, locationManager.location != nil else { return }
            centreOnCurrentLocation()
            hasCentredOnUser = true
        }
    }

    static func mapHeight(availableHeight: CGFloat, cardHeight: CGFloat) -> CGFloat {
        // Use the space below the controls, but keep the map usable on short screens.
        // The outer ScrollView handles extra height, including larger accessibility text.
        max(220, availableHeight - cardHeight - AppSpacing.medium * 3)
    }

    private func reloadDogs() {
        Task { await dogSelection.load() }
    }

    private var mapCard: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            ForEach(Array(walkTracker.routeSegments.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment.map(\.coordinate))
                        .stroke(AppColors.brand, lineWidth: 5)
                }
            }
            if let location = locationManager.location {
                MapCircle(
                    center: location.coordinate,
                    radius: max(location.horizontalAccuracy, 1)
                )
                .foregroundStyle(Color.blue.opacity(0.12))

                Annotation("Current location", coordinate: location.coordinate) {
                    currentLocationMarker
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) {
            statusCard
                .padding(AppSpacing.medium)
        }
        .overlay(alignment: .bottomTrailing) {
            if locationManager.location != nil {
                Button {
                    centreOnCurrentLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.brand)
                        .frame(width: 46, height: 46)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 3, y: 1)
                }
                .accessibilityLabel("Centre map on my location")
                .padding(AppSpacing.medium)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
    }

    private var currentLocationMarker: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .shadow(radius: 2)
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel("Your current location")
    }

    @ViewBuilder
    private var statusCard: some View {
        switch locationManager.state {
        case .idle, .ready:
            EmptyView()
        case .requestingPermission:
            LocationStatusCard(
                icon: "location.fill",
                title: "Location access needed",
                message: "Allow access to show your current position on the map."
            )
        case .locating:
            LocationStatusCard(
                icon: "location.magnifyingglass",
                title: "Finding your location",
                message: "This may take a few seconds."
            )
        case .denied:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location access is off",
                message: "Allow location access in Settings to use the walk map.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .restricted:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location is restricted",
                message: "This device does not allow Vitail to use location services."
            )
        case .servicesDisabled:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Location Services are off",
                message: "Turn on Location Services in Settings to use the walk map.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .preciseLocationRequired:
            LocationStatusCard(
                icon: "location.slash.fill",
                title: "Precise Location is off",
                message: "Enable Precise Location in Settings to track your walk accurately.",
                actionTitle: "Open Settings", action: openSettings
            )
        case let .failed(message):
            LocationStatusCard(
                icon: "exclamationmark.triangle.fill",
                title: "Could not find your location",
                message: message
            )
        }
    }

    private func centreOnCurrentLocation() {
        guard let location = locationManager.location else { return }

        cameraPosition = .region(
            MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }
}

private struct WalkCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LocationStatusCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.medium) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppColors.brand)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.brand)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .shadow(radius: 4, y: 2)
    }
}
