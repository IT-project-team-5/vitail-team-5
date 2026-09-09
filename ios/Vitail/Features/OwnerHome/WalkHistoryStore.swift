import Combine
import CoreLocation
import CryptoKit
import Foundation

struct WalkRoutePoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && CLLocationCoordinate2DIsValid(coordinate)
            && timestamp.timeIntervalSince1970.isFinite
    }
}

struct WalkDogSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
}

struct WalkRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let activeDuration: TimeInterval
    let distanceMetres: Double
    let dogs: [WalkDogSnapshot]
    let routeSegments: [[WalkRoutePoint]]

    var distanceKilometres: Double { distanceMetres / 1_000 }

    var isValid: Bool {
        startedAt.timeIntervalSince1970.isFinite && endedAt.timeIntervalSince1970.isFinite
            && endedAt >= startedAt && activeDuration.isFinite && activeDuration >= 0
            && distanceMetres.isFinite && distanceMetres >= 0
            && routeSegments.joined().allSatisfy(\.isValid)
    }
}

@MainActor
protocol WalkHistoryPersisting {
    func load() throws -> [WalkRecord]
    func save(_ records: [WalkRecord]) throws
}

/// Finished walks stay in the app's protected storage, separated by account and backend.
@MainActor
struct WalkHistoryFileStore: WalkHistoryPersisting {
    let fileURL: URL

    init(ownerID: Int, serverURL: URL?, directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("WalkHistory", isDirectory: true)
        let server = serverURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? "unconfigured"
        let scope = Data("\(server)|owner:\(ownerID)".utf8)
        let filename = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        fileURL = baseDirectory.appendingPathComponent("\(filename).json")
    }

    func load() throws -> [WalkRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.records.allSatisfy(\.isValid) else {
            throw HistoryFileError.invalidData
        }
        return archive.records
    }

    func save(_ records: [WalkRecord]) throws {
        guard records.allSatisfy(\.isValid) else { throw HistoryFileError.invalidData }
        let data = try JSONEncoder().encode(Archive(version: 1, records: records))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private struct Archive: Codable {
        let version: Int
        let records: [WalkRecord]
    }

    private enum HistoryFileError: Error {
        case invalidData
    }
}

@MainActor
final class WalkHistoryStore: ObservableObject {
    @Published private(set) var records: [WalkRecord] = []
    @Published private(set) var errorMessage: String?

    private let persistence: any WalkHistoryPersisting
    private var savedRecords: [WalkRecord] = []
    private var pendingRecords: [UUID: WalkRecord] = [:]
    private var hasLoaded = false

    init(persistence: any WalkHistoryPersisting) {
        self.persistence = persistence
        retry()
    }

    func append(_ record: WalkRecord) {
        guard record.isValid else {
            errorMessage = "This walk could not be saved because its data is invalid."
            return
        }
        guard !records.contains(where: { $0.id == record.id }) else { return }
        pendingRecords[record.id] = record
        updateRecords()
        if hasLoaded {
            savePendingRecords()
        } else {
            errorMessage = "Could not read your saved walks. New walks are kept in memory. Tap Retry before closing the app."
        }
    }

    func containsSavedRecord(id: UUID) -> Bool {
        savedRecords.contains { $0.id == id }
    }

    func retry() {
        if !hasLoaded {
            do {
                savedRecords = try persistence.load()
                hasLoaded = true
                errorMessage = nil
                updateRecords()
            } catch {
                errorMessage = "Could not read your saved walks. Tap Retry. New walks cannot be saved until this is resolved."
                return
            }
        }
        savePendingRecords()
    }

    private func updateRecords() {
        var byID: [UUID: WalkRecord] = [:]
        for record in savedRecords { byID[record.id] = record }
        for (id, record) in pendingRecords { byID[id] = record }
        records = byID.values.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.startedAt > $1.startedAt
        }
    }

    private func savePendingRecords() {
        guard hasLoaded, !pendingRecords.isEmpty else { return }
        do {
            try persistence.save(records)
            savedRecords = records
            pendingRecords.removeAll()
            errorMessage = nil
        } catch {
            errorMessage = "Could not save your latest walks. They are kept in memory. Tap Retry before closing the app."
        }
    }
}
