import Combine
import CoreLocation
import Foundation

@MainActor
final class WalkRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase { case idle, locating, recording, stopped }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var samples: [WalkSample] = []
    @Published private(set) var estimatedDistanceM: Double = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var message: String?
    var onAutomaticStop: (() -> Void)?

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var previous: CLLocation?
    private var lastSampleAt: Date?
    private var lastMovementAt: Date?
    private var requestingPrecision = false

    var isActive: Bool { phase == .locating || phase == .recording }
    var coordinates: [CLLocationCoordinate2D] {
        samples.filter { $0.accuracyM >= 0 && $0.accuracyM <= 30 }.map(\.coordinate)
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        guard !isActive else { return }
        samples = []
        estimatedDistanceM = 0
        startedAt = nil
        previous = nil
        lastSampleAt = nil
        lastMovementAt = nil
        message = nil
        phase = .locating
        startWhenAuthorized()
    }

    private func startWhenAuthorized() {
        guard isActive else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard manager.accuracyAuthorization == .fullAccuracy else {
                guard !requestingPrecision else { return }
                requestingPrecision = true
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WalkTracking") { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.requestingPrecision = false
                        guard self.isActive else { return }
                        if self.manager.accuracyAuthorization == .fullAccuracy {
                            self.startWhenAuthorized()
                        } else {
                            self.fail("Enable Precise Location in iPhone Settings to record a walk.")
                        }
                    }
                }
                return
            }
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkInactivity() }
                }
            }
        case .denied, .restricted:
            fail("Allow location access in iPhone Settings to record a walk.")
        @unknown default:
            fail("Location access is unavailable.")
        }
    }

    func stop() -> WalkCapture? {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        timer?.invalidate()
        timer = nil
        phase = .stopped
        guard let startedAt else { return nil }
        return WalkCapture(startedAt: startedAt, endedAt: Date(), samples: samples)
    }

    func discard() {
        _ = stop()
        phase = .idle
        samples = []
        previous = nil
        startedAt = nil
        estimatedDistanceM = 0
        message = nil
    }

    private func fail(_ text: String) {
        _ = stop()
        message = text
    }

    private func checkInactivity() {
        guard phase == .recording, let lastMovementAt else { return }
        if Date().timeIntervalSince(lastMovementAt) >= 300 {
            message = "Walk ended after 5 minutes without movement."
            onAutomaticStop?()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.startWhenAuthorized() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.record(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            if (error as? CLError)?.code == .denied {
                guard let self else { return }
                self.message = "Location permission was removed. Saving the recorded portion."
                if self.phase == .recording { self.onAutomaticStop?() }
                else { self.fail("Location permission was removed. The walk has stopped.") }
            } else {
                self?.message = "GPS is temporarily unavailable. Move outdoors for a better signal."
            }
        }
    }

    private func record(_ locations: [CLLocation]) {
        guard isActive else { return }
        for location in locations {
            guard location.timestamp <= Date(), Date().timeIntervalSince(location.timestamp) < 15 else { continue }
            guard lastSampleAt.map({ location.timestamp.timeIntervalSince($0) >= 5 }) ?? true else { continue }
            if location.sourceInformation?.isSimulatedBySoftware == true {
                fail("Simulated GPS cannot earn points. Test a real walk on your iPhone.")
                return
            }
            let accurate = (0...30).contains(location.horizontalAccuracy)
            if let lastMovementAt,
               location.timestamp.timeIntervalSince(lastMovementAt) >= 300 {
                message = "Walk ended after 5 minutes without movement."
                onAutomaticStop?()
                return
            }
            if startedAt == nil {
                guard accurate else {
                    message = "Waiting for GPS accuracy of 30 metres or better…"
                    continue
                }
                startedAt = location.timestamp
                lastMovementAt = location.timestamp
                phase = .recording
            }
            samples.append(WalkSample(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                recordedAt: WalkTimestamp.string(location.timestamp),
                accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : 100_000,
                isSimulated: false
            ))
            lastSampleAt = location.timestamp
            if accurate, let previous {
                let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
                let distance = location.distance(from: previous)
                if elapsed > 0 && elapsed <= 60 && distance / elapsed <= 3 {
                    estimatedDistanceM += distance
                    if distance >= 1 { lastMovementAt = location.timestamp }
                }
            }
            previous = accurate ? location : nil
            message = accurate ? nil : "Weak GPS. This segment will not earn points."
            if samples.count >= 5000 {
                message = "The recording limit was reached. Saving this walk."
                onAutomaticStop?()
                return
            }
            checkInactivity()
        }
    }
}
