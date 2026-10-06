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
    private var authorizationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var fixWaiters: [UUID: CheckedContinuation<LocationSample, Error>] = [:]
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
        let requestID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await requestSample(id: requestID)
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingFix(id: requestID) }
        })
    }

    private func requestSample(id: UUID) async throws -> LocationSample {
        try Task.checkCancellation()
        guard CLLocationManager.locationServicesEnabled() else { throw CheckInLocationError.denied }
        if manager.authorizationStatus == .notDetermined {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                authorizationWaiters[id] = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        try Task.checkCancellation()
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
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            fixWaiters[id] = continuation
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
        cancelPendingFix()
        isMonitoring = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    private func cancelPendingFix(id: UUID? = nil) {
        if let id {
            authorizationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            fixWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        } else {
            let permission = authorizationWaiters
            let fixes = fixWaiters
            authorizationWaiters = [:]
            fixWaiters = [:]
            permission.values.forEach { $0.resume(throwing: CancellationError()) }
            fixes.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    // Match the walk preview's freshness window. Never turn cached GPS into
    // a fresh check-in merely because the server receives it now.
    static func freshSample(_ location: CLLocation, now: Date) -> LocationSample? {
        let age = now.timeIntervalSince(location.timestamp)
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, (0...30).contains(location.horizontalAccuracy),
              age.isFinite, (-5...15).contains(age) else { return nil }
        return LocationSample(location)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters = [:]
            waiters.values.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let latest = locations.sorted { $0.timestamp < $1.timestamp }
                .compactMap { Self.freshSample($0, now: Date()) }.last
            let waiters = fixWaiters
            fixWaiters = [:]
            if let latest {
                waiters.values.forEach { $0.resume(returning: latest) }
                if isMonitoring { onLocation?(latest) }
            } else {
                waiters.values.forEach { $0.resume(throwing: CheckInLocationError.unavailable) }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiters = fixWaiters
            fixWaiters = [:]
            waiters.values.forEach { $0.resume(throwing: CheckInLocationError.unavailable) }
        }
    }
}
