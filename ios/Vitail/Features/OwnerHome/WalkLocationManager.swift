import Combine
import CoreLocation
import Foundation

/// A small hardware boundary so background tracking can be tested without GPS or permissions.
@MainActor
protocol WalkLocationClient: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var activityType: CLActivityType { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: WalkLocationClient {}

@MainActor
final class WalkLocationManager: NSObject, ObservableObject {
    enum Mode: Equatable {
        case off
        case preview
        case recording
    }

    enum State: Equatable {
        case idle
        case requestingPermission
        case locating
        case ready
        case denied
        case restricted
        case servicesDisabled
        case preciseLocationRequired
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var location: CLLocation?
    private(set) var mode: Mode = .off

    /// Called synchronously for the complete chronological batch, independent of SwiftUI rendering.
    var onLocations: (([CLLocation]) -> Void)?
    /// A temporary GPS gap splits the route; loss of permission also requires pausing the walk.
    var onInterruption: ((String, Bool) -> Void)?

    private let client: any WalkLocationClient
    private let locationServicesEnabled: () -> Bool
    private let now: () -> Date
    private var updatesRunning = false
    private var requestedPermission = false

    init(
        client: any WalkLocationClient = CLLocationManager(),
        locationServicesEnabled: @escaping () -> Bool = CLLocationManager.locationServicesEnabled,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.locationServicesEnabled = locationServicesEnabled
        self.now = now
        super.init()
        client.delegate = self
        client.desiredAccuracy = kCLLocationAccuracyBest
        client.distanceFilter = 5
        client.activityType = .fitness
        configureBackgroundUpdates(enabled: false)
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .off {
            stopUpdates()
            location = nil
            state = .idle
            return
        }
        refreshAuthorization()
    }

    /// Re-check on each foreground entry because Settings can change while the app is away.
    func refreshAuthorization() {
        guard mode != .off else { return }
        guard locationServicesEnabled() else {
            loseAccess(.servicesDisabled, message: "Location Services are off. Turn them on before resuming your walk.")
            return
        }

        switch client.authorizationStatus {
        case .notDetermined:
            loseAccess(.requestingPermission, message: "Location permission is needed to continue your walk.")
            if mode != .off && !requestedPermission {
                requestedPermission = true
                client.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            requestedPermission = false
            guard client.accuracyAuthorization == .fullAccuracy else {
                loseAccess(.preciseLocationRequired, message: "Precise Location is off. Turn it on before resuming your walk.")
                return
            }
            configureBackgroundUpdates(enabled: mode == .recording)
            if !updatesRunning {
                updatesRunning = true
                client.startUpdatingLocation()
            }
            updatePreviewLocation(from: [])
        case .denied:
            requestedPermission = false
            loseAccess(.denied, message: "Location permission was removed. Allow location access before resuming your walk.")
        case .restricted:
            requestedPermission = false
            loseAccess(.restricted, message: "Location access is restricted. Your walk has been paused.")
        @unknown default:
            loseAccess(.failed("Vitail could not read the location permission status."), message: "Location access is unavailable. Your walk has been paused.")
        }
    }

    private func configureBackgroundUpdates(enabled: Bool) {
        client.allowsBackgroundLocationUpdates = enabled
        client.showsBackgroundLocationIndicator = enabled
        // Preview already stops when the Walk page leaves the foreground.
        // An automatic pause here could strand Start/Resume without a fresh fix.
        client.pausesLocationUpdatesAutomatically = mode == .off
    }

    private func stopUpdates() {
        client.stopUpdatingLocation()
        updatesRunning = false
        configureBackgroundUpdates(enabled: false)
    }

    private func loseAccess(_ newState: State, message: String) {
        stopUpdates()
        location = nil
        state = newState
        if mode == .recording {
            onInterruption?(message, true)
        }
    }

    private func hasLocationAccess() -> Bool {
        let authorized = client.authorizationStatus == .authorizedWhenInUse
            || client.authorizationStatus == .authorizedAlways
        return authorized && client.accuracyAuthorization == .fullAccuracy && locationServicesEnabled()
    }

    private func updatePreviewLocation(from locations: [CLLocation]) {
        let currentTime = now()
        if let location, !isUsablePreviewLocation(location, at: currentTime) {
            self.location = nil
        }
        if let latest = locations.last(where: { isUsablePreviewLocation($0, at: currentTime) }),
           location == nil || latest.timestamp > location!.timestamp {
            location = latest
        }
        state = location == nil ? .locating : .ready
    }

    private func isUsablePreviewLocation(_ location: CLLocation, at currentTime: Date) -> Bool {
        let age = currentTime.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
            && age.isFinite && age >= -5 && age <= 15
    }

    private func reportTemporaryInterruption(_ message: String, state: State) {
        location = nil
        self.state = state
        if mode == .recording {
            onInterruption?(message, false)
        }
    }
}

// Core Location delivers delegate events on the run loop where its manager was created.
// The manager is created on the main actor, so callbacks stay synchronous and in order.
extension WalkLocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard mode != .off else { return }
        guard hasLocationAccess() else {
            refreshAuthorization()
            return
        }
        let orderedLocations = locations.sorted { $0.timestamp < $1.timestamp }
        updatePreviewLocation(from: orderedLocations)
        // Older queued points are useful for the active route even when too old for the map/start button.
        // The tracker applies its own session-window, accuracy and duplicate checks to each point.
        if mode == .recording && !orderedLocations.isEmpty {
            onLocations?(orderedLocations)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard mode != .off else { return }
        guard hasLocationAccess() else {
            refreshAuthorization()
            return
        }
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain && nsError.code == CLError.Code.denied.rawValue {
            loseAccess(.denied, message: "Location access is unavailable. Check location settings before resuming your walk.")
        } else if nsError.domain == kCLErrorDomain && nsError.code == CLError.Code.locationUnknown.rawValue {
            reportTemporaryInterruption("GPS signal was lost. Tracking will continue when a position is available.", state: .locating)
        } else {
            reportTemporaryInterruption(error.localizedDescription, state: .failed(error.localizedDescription))
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard mode != .off else { return }
        updatesRunning = false
        if mode == .recording {
            reportTemporaryInterruption("Location updates were interrupted. Vitail is trying to restore GPS tracking.", state: .locating)
        } else {
            location = nil
            state = .locating
        }
        // Preview only runs in the foreground, where restarting can also keep
        // the Start/Resume controls from being stranded after a system pause.
        refreshAuthorization()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard mode != .off else { return }
        updatesRunning = true
        refreshAuthorization()
    }
}
