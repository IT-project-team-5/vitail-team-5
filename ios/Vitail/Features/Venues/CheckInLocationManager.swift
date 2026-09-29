import CoreLocation
import Foundation

/// The hardware boundary for check-ins, so the view model is testable without GPS.
@MainActor
protocol CheckInLocationProviding: AnyObject {
    /// Called with each fix while a check-in is active, including in the background.
    var onLocation: ((LocationSample) -> Void)? { get set }
    /// Asks for permission if needed and returns one precise fix.
    func currentSample() async throws -> LocationSample
    /// Begins background-capable updates. Only call after the owner taps Start check-in.
    func startMonitoring()
    /// Stops updates. Called when a check-in completes, is abandoned or the owner logs out.
    func stopMonitoring()
}

enum CheckInLocationError: LocalizedError, Equatable {
    case denied
    case restricted
    case preciseLocationRequired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Location access is off. Allow it in Settings › Vitail › Location to check in."
        case .restricted:
            return "Location access is restricted on this device."
        case .preciseLocationRequired:
            return "Precise Location is required. Turn it on in Settings › Vitail › Location."
        case .unavailable:
            return "We couldn't get your location. Try again in a moment."
        }
    }
}

@MainActor
final class CheckInLocationManager: NSObject, CheckInLocationProviding, CLLocationManagerDelegate {
    var onLocation: ((LocationSample) -> Void)?

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<LocationSample, Error>] = []
    private var isMonitoring = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func currentSample() async throws -> LocationSample {
        guard CLLocationManager.locationServicesEnabled() else { throw CheckInLocationError.denied }
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .denied: throw CheckInLocationError.denied
        case .restricted: throw CheckInLocationError.restricted
        default: break
        }
        if manager.accuracyAuthorization == .reducedAccuracy {
            try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CheckIn")
            guard manager.accuracyAuthorization == .fullAccuracy else {
                throw CheckInLocationError.preciseLocationRequired
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            fixWaiters.append(continuation)
            manager.requestLocation()
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stopMonitoring() {
        isMonitoring = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let samples = locations.filter { $0.horizontalAccuracy >= 0 }.map(LocationSample.init)
        Task { @MainActor in
            if let latest = samples.last {
                let waiters = fixWaiters
                fixWaiters = []
                waiters.forEach { $0.resume(returning: latest) }
            }
            if isMonitoring { samples.forEach { onLocation?($0) } }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiters = fixWaiters
            fixWaiters = []
            waiters.forEach { $0.resume(throwing: CheckInLocationError.unavailable) }
        }
    }
}
