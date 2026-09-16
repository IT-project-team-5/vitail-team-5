import Combine
import Foundation

extension WalkRecord {
    /// A stable request reconstructed from the immutable, durable finished record.
    /// Legacy records without measured accuracy/source metadata stay local-only.
    var uploadRequest: WalkRequest? {
        let points = routeSegments.flatMap { $0 }
        guard (2...5000).contains(points.count),
              points.allSatisfy({ point in
                  point.isValid && point.accuracyM.map { $0.isFinite && $0 >= 0 } == true
                      && point.isSimulated != nil
              }) else { return nil }
        let segments = routeSegments.filter { !$0.isEmpty }
        let samples = segments.enumerated().flatMap { index, segment in
            segment.map { point in
                WalkSample(latitude: point.latitude, longitude: point.longitude,
                           recordedAt: WalkTimestamp.string(point.timestamp),
                           accuracyM: point.accuracyM!, isSimulated: point.isSimulated!, segmentID: index)
            }
        }
        return WalkRequest(requestID: id, startedAt: WalkTimestamp.string(startedAt),
                           endedAt: WalkTimestamp.string(max(endedAt, points.last!.timestamp)),
                           dogIDs: dogs.map(\.id), samples: samples)
    }

    var syncDescription: String {
        if let summary = serverSummary {
            return String(format: "Synced · +%d pts · %.2f km accepted", summary.pointsAwarded, summary.distanceM / 1000)
        }
        if let uploadFailure { return "Saved locally · \(uploadFailure)" }
        return uploadRequest == nil ? "Local history only · not eligible for upload" : "Saved locally · waiting to upload"
    }
}

/// Receipts are account-scoped; raw routes stay in protected local history.
/// No background network worker. Foreground refresh and Finish retry durable records.
@MainActor
final class WalkSyncStore: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var summaries: [WalkSummary] = []
    @Published private(set) var errorMessage: String?
    var onWalletChanged: (@MainActor () async -> Void)?
    private let history: WalkHistoryStore
    private let service: (any WalkServing)?
    private var isEnabled = true

    init(history: WalkHistoryStore, service: (any WalkServing)?) {
        self.history = history
        self.service = service
    }

    func stop() { isEnabled = false }

    func refreshAndUpload() async {
        guard isEnabled, !isSyncing, let service else { return }
        isSyncing = true
        defer { isSyncing = false }
        history.retry()
        do {
            // Reconcile first: a timed-out POST may already have credited the wallet.
            let remote = try await service.getWalks()
            guard isEnabled, !Task.isCancelled else { return }
            summaries = remote
            errorMessage = nil
            for receipt in remote {
                history.updateUpload(id: receipt.requestID, summary: receipt)
            }
            for record in history.records {
                guard isEnabled, !Task.isCancelled else { return }
                guard history.containsSavedRecord(id: record.id), record.serverSummary == nil,
                      record.uploadFailure == nil, let request = record.uploadRequest else { continue }
                do {
                    let receipt = try await service.submit(request)
                    guard isEnabled, !Task.isCancelled else { return }
                    guard receipt.requestID == record.id else {
                        errorMessage = "Unexpected server receipt. Your route is safe; refresh to check again."
                        break
                    }
                    history.updateUpload(id: record.id, summary: receipt)
                    summaries.removeAll { $0.requestID == receipt.requestID }
                    summaries.insert(receipt, at: 0)
                } catch {
                    guard isEnabled, !Task.isCancelled else { return }
                    if case let APIError.http(code, message) = error,
                       code == 400 || code == 409 {
                        history.updateUpload(id: record.id, failure: message)
                        continue
                    }
                    errorMessage = "Upload not confirmed. Your route is saved. Tap Retry when online."
                    break
                }
            }
            guard isEnabled, !Task.isCancelled else { return }
            await onWalletChanged?()
        } catch {
            guard isEnabled, !Task.isCancelled else { return }
            errorMessage = "Could not reach the server. Local walks are safe. Tap Retry when online."
        }
    }
}
