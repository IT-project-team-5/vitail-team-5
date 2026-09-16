import CryptoKit
import Foundation

/// A durable checkpoint, not a running clock. Recovery must resume from this
/// duration in a paused state rather than counting time while the app was gone.
struct WalkDraft: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let checkpointAt: Date
    let activeDuration: TimeInterval
    let distanceMetres: Double
    let dogs: [Dog]
    let routeSegments: [[WalkRoutePoint]]
    var finishedRecord: WalkRecord? = nil

    var isValid: Bool {
        guard startedAt.timeIntervalSince1970.isFinite,
              checkpointAt.timeIntervalSince1970.isFinite,
              checkpointAt >= startedAt,
              activeDuration.isFinite, activeDuration >= 0,
              distanceMetres.isFinite, distanceMetres >= 0,
              !dogs.isEmpty,
              Set(dogs.map(\.id)).count == dogs.count,
              dogs.allSatisfy({ dog in
                  dog.id > 0 && !dog.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && dog.ageMonths >= 0 && dog.breed.id > 0
                      && !dog.breed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return false }

        // CLLocation timestamps can predate the Start tap or arrive in batches;
        // require ordered, valid points without tying them to UI callback times.
        var previousTimestamp: Date?
        for segment in routeSegments {
            guard !segment.isEmpty else { return false }
            for point in segment {
                guard point.isValid else { return false }
                if let previousTimestamp, point.timestamp <= previousTimestamp { return false }
                previousTimestamp = point.timestamp
            }
        }

        if let finishedRecord {
            // Keep precisely the same finish result for an idempotent retry if
            // the process stops between saving this draft and saving history.
            guard finishedRecord.isValid,
                  finishedRecord.id == id,
                  finishedRecord.startedAt == startedAt,
                  finishedRecord.endedAt <= checkpointAt,
                  finishedRecord.activeDuration == activeDuration,
                  finishedRecord.distanceMetres == distanceMetres,
                  finishedRecord.dogs == dogs.map({ WalkDogSnapshot(id: $0.id, name: $0.name) }),
                  finishedRecord.routeSegments == routeSegments else { return false }
        }
        return true
    }
}

@MainActor
protocol WalkDraftPersisting {
    func load() throws -> WalkDraft?
    func save(_ draft: WalkDraft) throws
    func clear() throws
}

/// Account- and backend-scoped active walks live only in app-owned storage.
/// This protection class permits checkpoint writes while a walker's phone is
/// locked, after the first unlock following a device restart.
@MainActor
struct WalkDraftFileStore: WalkDraftPersisting {
    let fileURL: URL

    init(ownerID: Int, serverURL: URL?, directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("WalkDrafts", isDirectory: true)
        let server = serverURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? "unconfigured"
        let scope = Data("\(server)|owner:\(ownerID)".utf8)
        let filename = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        fileURL = baseDirectory.appendingPathComponent("\(filename).draft.json")
    }

    func load() throws -> WalkDraft? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.draft.isValid else {
            throw DraftFileError.invalidData
        }
        return archive.draft
    }

    func save(_ draft: WalkDraft) throws {
        guard draft.isValid else { throw DraftFileError.invalidData }
        let data = try JSONEncoder().encode(Archive(version: 1, draft: draft))
        // A damaged, unsupported, or temporarily inaccessible checkpoint must
        // not silently disappear when a caller attempts to save a new one.
        _ = try load()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Clearing a draft after history has already saved is idempotent.
        }
    }

    private struct Archive: Codable {
        let version: Int
        let draft: WalkDraft
    }

    private enum DraftFileError: LocalizedError {
        case invalidData

        var errorDescription: String? {
            "The saved walk checkpoint is damaged or uses an unsupported format."
        }
    }
}
