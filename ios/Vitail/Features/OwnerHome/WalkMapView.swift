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

    private var lastTrackedLocation: CLLocation?

    var distanceKilometres: Double {
        distanceMetres / 1_000
    }

    var canStart: Bool {
        status == .idle || status == .finished
    }

    var canPauseOrResume: Bool {
        status == .walking || status == .paused
    }

    var canFinish: Bool {
        status == .walking || status == .paused
    }

    static func canUse(_ location: CLLocation?) -> Bool {
        guard let location else { return false }
        return location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maximumAcceptedAccuracy
    }

    func start(from location: CLLocation?) {
        guard canStart, Self.canUse(location) else { return }

        distanceMetres = 0
        lastTrackedLocation = location
        status = .walking
    }

    func pause() {
        guard status == .walking else { return }
        lastTrackedLocation = nil
        status = .paused
    }

    func resume(from location: CLLocation?) {
        guard status == .paused else { return }
        lastTrackedLocation = Self.canUse(location) ? location : nil
        status = .walking
    }

    func finish() {
        guard canFinish else { return }
        lastTrackedLocation = nil
        status = .finished
    }

    func record(_ location: CLLocation) {
        guard status == .walking, Self.canUse(location) else { return }

        guard let previousLocation = lastTrackedLocation else {
            lastTrackedLocation = location
            return
        }

        guard location.timestamp > previousLocation.timestamp else { return }

        let segmentDistance = location.distance(from: previousLocation)
        guard segmentDistance.isFinite, segmentDistance >= 0 else { return }

        distanceMetres += segmentDistance
        lastTrackedLocation = location
    }
}

struct WalkMapView: View {
    let isActive: Bool

    @StateObject private var locationManager = WalkLocationManager()
    @StateObject private var walkTracker = WalkSessionTracker()
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var hasCentredOnUser = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current location")
                            .font(.title3.bold())
                        Text("Move and zoom the map to explore your area.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }

                    mapCard
                        .frame(height: max(260, geometry.size.height * 0.5))

                    walkControlsCard
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
        }
        .onAppear {
            updateLocationActivity(isActive)
        }
        .onDisappear {
            updateLocationActivity(false)
        }
        .onChange(of: isActive) { _, active in
            updateLocationActivity(active)
        }
        .onChange(of: walkTracker.status) { _, _ in
            updateLocationActivity(isActive)
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

    private var mapCard: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
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

    private var walkControlsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack {
                Text("This walk")
                    .font(.headline)
                Spacer()
                Text(walkStatusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(walkStatusColour)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(walkStatusColour.opacity(0.12))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Distance")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(walkTracker.distanceKilometres, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("km")
                        .font(.headline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            Divider()

            HStack(spacing: AppSpacing.small) {
                WalkControlButton(
                    title: "Start Walk",
                    icon: "play.fill",
                    colour: AppColors.brand,
                    isDisabled: !canStartWalk
                ) {
                    walkTracker.start(from: locationManager.location)
                }

                WalkControlButton(
                    title: walkTracker.status == .paused ? "Resume" : "Pause",
                    icon: walkTracker.status == .paused ? "playpause.fill" : "pause.fill",
                    colour: .orange,
                    isDisabled: !walkTracker.canPauseOrResume
                ) {
                    togglePause()
                }

                WalkControlButton(
                    title: "Finish Walk",
                    icon: "stop.fill",
                    colour: AppColors.error,
                    isDisabled: !walkTracker.canFinish
                ) {
                    walkTracker.finish()
                }
            }

            if walkTracker.canStart && !hasAccurateLocation {
                Label("Waiting for an accurate location before starting.", systemImage: "location.magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
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

    private var hasAccurateLocation: Bool {
        WalkSessionTracker.canUse(locationManager.location)
    }

    private var canStartWalk: Bool {
        walkTracker.canStart && hasAccurateLocation
    }

    private var walkStatusTitle: String {
        switch walkTracker.status {
        case .idle:
            return "Ready"
        case .walking:
            return "Walking"
        case .paused:
            return "Paused"
        case .finished:
            return "Finished"
        }
    }

    private var walkStatusColour: Color {
        switch walkTracker.status {
        case .idle:
            return AppColors.secondaryText
        case .walking:
            return AppColors.brand
        case .paused:
            return .orange
        case .finished:
            return .blue
        }
    }

    private func togglePause() {
        switch walkTracker.status {
        case .walking:
            walkTracker.pause()
        case .paused:
            walkTracker.resume(from: locationManager.location)
        case .idle, .finished:
            break
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

private struct WalkControlButton: View {
    let title: String
    let icon: String
    let colour: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.headline)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .foregroundStyle(isDisabled ? AppColors.secondaryText : colour)
            .background(isDisabled ? Color.secondary.opacity(0.08) : colour.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous)
                    .stroke(isDisabled ? Color.secondary.opacity(0.12) : colour.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
