import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

@MainActor
final class WalkLocationManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case locating
        case ready
        case denied
        case restricted
        case servicesDisabled
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var location: CLLocation?

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        wantsUpdates = true

        guard CLLocationManager.locationServicesEnabled() else {
            state = .servicesDisabled
            return
        }

        handleAuthorization(manager.authorizationStatus)
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            state = .requestingPermission
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            state = location == nil ? .locating : .ready
            manager.startUpdatingLocation()
        case .denied:
            manager.stopUpdatingLocation()
            state = .denied
        case .restricted:
            manager.stopUpdatingLocation()
            state = .restricted
        @unknown default:
            manager.stopUpdatingLocation()
            state = .failed("Vitail could not read the location permission status.")
        }
    }
}

extension WalkLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsUpdates else { return }
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last, latestLocation.horizontalAccuracy >= 0 else {
            return
        }

        location = latestLocation
        state = .ready
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.Code.locationUnknown.rawValue {
            return
        }

        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.Code.denied.rawValue {
            handleAuthorization(manager.authorizationStatus)
            return
        }

        state = .failed(error.localizedDescription)
    }
}

@MainActor
final class WalkSessionTracker: ObservableObject {
    enum Status: Equatable {
        case idle
        case walking
        case paused
        case finished
    }

    static let maximumAcceptedAccuracy: CLLocationAccuracy = 30

    @Published private(set) var status: Status = .idle
    @Published private(set) var distanceMetres: CLLocationDistance = 0
    @Published private(set) var participatingDogs: [Dog] = []
    @Published private(set) var routeSegments: [[WalkRoutePoint]] = []
    @Published private(set) var completedWalk: WalkRecord?

    private var lastTrackedLocation: CLLocation?
    private var lastRouteTimestamp: Date?
    private var startsNewSegment = true
    private var startedAt: Date?
    private var activeIntervalStartedAt: Date?
    private var activeDuration: TimeInterval = 0
    private let now: () -> Date
    private let onFinish: (WalkRecord) -> Void

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

    func start(from location: CLLocation?, dogs: [Dog]) {
        guard canStart, let location, Self.canUse(location), !dogs.isEmpty else { return }

        let startTime = now()
        var seenDogIDs: Set<Int> = []
        participatingDogs = dogs.filter { seenDogIDs.insert($0.id).inserted }
        distanceMetres = 0
        routeSegments = []
        completedWalk = nil
        lastRouteTimestamp = nil
        startsNewSegment = true
        startedAt = startTime
        activeIntervalStartedAt = startTime
        activeDuration = 0
        lastTrackedLocation = location
        appendRoutePoint(location)
        status = .walking
    }

    func pause() {
        guard status == .walking else { return }
        finishActiveInterval(at: now())
        lastTrackedLocation = nil
        startsNewSegment = true
        status = .paused
    }

    func resume(from location: CLLocation?) {
        guard status == .paused else { return }
        lastTrackedLocation = nil
        startsNewSegment = true
        activeIntervalStartedAt = now()
        if let location, Self.canUse(location), isNewRouteTimestamp(location.timestamp) {
            lastTrackedLocation = location
            appendRoutePoint(location)
        }
        status = .walking
    }

    func finish() {
        guard canFinish, let startedAt else { return }
        let endTime = max(now(), startedAt)
        finishActiveInterval(at: endTime)
        lastTrackedLocation = nil
        let record = WalkRecord(
            id: UUID(), startedAt: startedAt, endedAt: endTime,
            activeDuration: activeDuration, distanceMetres: distanceMetres,
            dogs: participatingDogs.map { WalkDogSnapshot(id: $0.id, name: $0.name) },
            routeSegments: routeSegments
        )
        completedWalk = record
        status = .finished
        onFinish(record)
    }

    func record(_ location: CLLocation) {
        guard status == .walking, Self.canUse(location), isNewRouteTimestamp(location.timestamp) else { return }

        guard let previousLocation = lastTrackedLocation else {
            lastTrackedLocation = location
            appendRoutePoint(location)
            return
        }

        guard location.timestamp > previousLocation.timestamp else { return }

        let segmentDistance = location.distance(from: previousLocation)
        guard segmentDistance.isFinite, segmentDistance >= 0 else { return }

        distanceMetres += segmentDistance
        lastTrackedLocation = location
        appendRoutePoint(location)
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

    @StateObject private var locationManager = WalkLocationManager()
    @StateObject private var walkTracker: WalkSessionTracker
    @StateObject private var dogSelection: WalkDogSelectionViewModel
    @StateObject private var walkHistory: WalkHistoryStore
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var hasCentredOnUser = false
    @State private var walkCardHeight: CGFloat = 300
    @Environment(\.openURL) private var openURL

    init(ownerID: Int, isActive: Bool, onManageDogs: @escaping () -> Void) {
        self.isActive = isActive
        self.onManageDogs = onManageDogs
        let history = WalkHistoryStore(persistence: WalkHistoryFileStore(
            ownerID: ownerID, serverURL: AppConfiguration.apiBaseURL
        ))
        let tracker = WalkSessionTracker(onFinish: { history.append($0) })
        _walkHistory = StateObject(wrappedValue: history)
        _walkTracker = StateObject(wrappedValue: tracker)
        _dogSelection = StateObject(wrappedValue: WalkDogSelectionViewModel(session: tracker))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    WalkDogSelectionCard(
                        selection: dogSelection,
                        session: walkTracker,
                        location: locationManager.location,
                        onManageDogs: onManageDogs
                    )
                    .background {
                        GeometryReader { cardGeometry in
                            Color.clear.preference(key: WalkCardHeightKey.self, value: cardGeometry.size.height)
                        }
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
            updateLocationActivity(isActive)
            if isActive { reloadDogs() }
        }
        .onDisappear {
            updateLocationActivity(false)
        }
        .onChange(of: isActive) { _, active in
            updateLocationActivity(active)
            if active { reloadDogs() }
        }
        .onChange(of: walkTracker.status) { _, status in
            updateLocationActivity(isActive)
            if status == .finished { reloadDogs() }
        }
        .onChange(of: locationManager.location?.timestamp) { _, _ in
            if let location = locationManager.location {
                walkTracker.record(location)
            }

            guard !hasCentredOnUser else { return }
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
        case let .failed(message):
            LocationStatusCard(
                icon: "exclamationmark.triangle.fill",
                title: "Could not find your location",
                message: message
            )
        }
    }

    private func updateLocationActivity(_ active: Bool) {
        if active || walkTracker.status == .walking {
            locationManager.start()
        } else {
            locationManager.stop()
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
