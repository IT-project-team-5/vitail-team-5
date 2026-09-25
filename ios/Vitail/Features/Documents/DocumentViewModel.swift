import Combine
import Foundation

@MainActor
final class DocumentViewModel: ObservableObject {
    @Published private(set) var dashboard: DocumentDashboard?
    @Published private(set) var receipt: DocumentReceipt?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isActive = true
    @Published private(set) var collectingID: Int?
    @Published private(set) var lastCollection: DocumentCollectionReceipt?
    @Published private(set) var confirmedCollections: [Int: DocumentCollectionReceipt] = [:]
    @Published var errorMessage: String?

    private let service: any DocumentServing
    private weak var session: SessionStore?
    private let requiresSession: Bool
    private let ownerID: Int?
    private var sessionObservation: AnyCancellable?
    private var generation = 0
    private var pending: (draft: DocumentDraft, request: DocumentRequest)?
    private var loadTask: Task<Void, Never>?
    private var submissionTask: Task<Bool, Never>?
    private var downloadTask: Task<Data, Error>?
    private var collectionTask: Task<Bool, Never>?

    init(service: any DocumentServing = DocumentService(), session: SessionStore? = nil) {
        self.service = service
        self.session = session
        requiresSession = session != nil
        if case let .signedIn(user) = session?.state, user.role == .owner {
            ownerID = user.id
        } else {
            ownerID = nil
            isActive = session == nil
        }
        sessionObservation = session?.$state.sink { [weak self] state in
            guard let self else { return }
            guard case let .signedIn(user) = state,
                  user.role == .owner, user.id == ownerID else {
                stop()
                return
            }
        }
    }

    deinit {
        loadTask?.cancel()
        submissionTask?.cancel()
        downloadTask?.cancel()
        collectionTask?.cancel()
    }

    func load() async {
        guard checkOwner(), !Task.isCancelled else { return }
        if let loadTask { await loadTask.value; return }
        guard !isSubmitting, collectingID == nil else { return }
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadSnapshot(generation: requestGeneration)
        }
        loadTask = task
        await task.value
        if accepts(requestGeneration) {
            isLoading = false
            loadTask = nil
        }
    }

    func submit(_ draft: DocumentDraft) async -> Bool {
        guard checkOwner(), !Task.isCancelled, !isSubmitting, !isLoading, collectingID == nil else { return false }
        let requestGeneration = generation
        isSubmitting = true
        errorMessage = nil
        receipt = nil
        // An ambiguous network failure retries the exact original operation.
        if pending?.draft != draft {
            pending = (draft, DocumentRequest(draft: draft))
        }
        guard let request = pending?.request else { isSubmitting = false; return false }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                let result = try await service.submit(request)
                guard accepts(requestGeneration), !Task.isCancelled else { return false }
                try validate(result, for: request)
                receipt = result
                pending = nil
                isLoading = true
                await loadSnapshot(generation: requestGeneration, afterSubmission: true)
                return accepts(requestGeneration) && !Task.isCancelled
            } catch {
                if accepts(requestGeneration), !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        submissionTask = task
        let submitted = await task.value
        if accepts(requestGeneration) {
            isSubmitting = false
            isLoading = false
            submissionTask = nil
        }
        return submitted && !Task.isCancelled
    }

    func download(_ submission: DocumentSubmission) async throws -> Data {
        guard checkOwner(), !Task.isCancelled else { throw CancellationError() }
        let requestGeneration = generation
        downloadTask?.cancel()
        let task = Task { try await service.download(submissionID: submission.id) }
        downloadTask = task
        do {
            let result = try await task.value
            guard accepts(requestGeneration), !Task.isCancelled, !task.isCancelled else {
                throw CancellationError()
            }
            downloadTask = nil
            return result
        } catch {
            if accepts(requestGeneration) { downloadTask = nil }
            throw error
        }
    }

    func entitlement(for submission: DocumentSubmission) -> DocumentEntitlement? {
        guard let id = submission.entitlementID else { return nil }
        if let current = dashboard?.entitlements?.first(where: { $0.id == id }) { return current }
        guard let status = submission.rewardStatus, let points = submission.rewardPoints else { return nil }
        return DocumentEntitlement(id: id, dogID: submission.dogID, dogName: submission.dogName,
            kind: submission.kind, rewardStatus: status, rewardPoints: points, collectedAt: submission.collectedAt,
            canCollect: status == .ready && dashboard?.dogs.contains(where: { $0.id == submission.dogID }) == true)
    }

    func isCollected(_ entitlement: DocumentEntitlement) -> Bool {
        entitlement.rewardStatus == .collected || confirmedCollections[entitlement.id] != nil
    }

    func canCollect(_ entitlement: DocumentEntitlement) -> Bool {
        isActive && isCurrentOwner && entitlement.canCollect && !isCollected(entitlement)
            && entitlement.id > 0 && entitlement.rewardPoints == entitlement.kind.points
            && !isLoading && !isSubmitting && collectingID == nil
    }

    func collect(_ entitlement: DocumentEntitlement) async -> Bool {
        guard checkOwner(), !Task.isCancelled, canCollect(entitlement) else { return false }
        let requestGeneration = generation
        collectingID = entitlement.id
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                let result = try await service.collect(entitlementID: entitlement.id)
                guard accepts(requestGeneration), !Task.isCancelled else { return false }
                guard result.entitlementID == entitlement.id, result.kind == entitlement.kind,
                      result.dogID == entitlement.dogID, result.points == entitlement.kind.points,
                      result.balance >= 0, Self.collectionDate(result.collectedAt) != nil else {
                    throw APIError.invalidResponse
                }
                confirmedCollections[entitlement.id] = result
                lastCollection = result
                isLoading = true
                await loadSnapshot(generation: requestGeneration, afterCollection: true)
                return accepts(requestGeneration) && !Task.isCancelled
            } catch {
                if accepts(requestGeneration), !Task.isCancelled { errorMessage = error.localizedDescription }
                return false
            }
        }
        collectionTask = task
        let collected = await task.value
        if accepts(requestGeneration) {
            collectingID = nil
            isLoading = false
            collectionTask = nil
        }
        return collected && !Task.isCancelled
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        generation += 1
        loadTask?.cancel()
        submissionTask?.cancel()
        downloadTask?.cancel()
        collectionTask?.cancel()
        loadTask = nil
        submissionTask = nil
        downloadTask = nil
        collectionTask = nil
        sessionObservation?.cancel()
        sessionObservation = nil
        dashboard = nil
        receipt = nil
        lastCollection = nil
        confirmedCollections = [:]
        collectingID = nil
        pending = nil
        errorMessage = nil
        isLoading = false
        isSubmitting = false
    }

    private func checkOwner() -> Bool {
        guard isActive, isCurrentOwner else { stop(); return false }
        return true
    }

    private var isCurrentOwner: Bool {
        guard requiresSession else { return true }
        guard case let .signedIn(user) = session?.state else { return false }
        return user.id == ownerID && user.role == .owner
    }

    private func accepts(_ requestGeneration: Int) -> Bool {
        isActive && generation == requestGeneration && isCurrentOwner
    }

    private func loadSnapshot(generation requestGeneration: Int, afterSubmission: Bool = false, afterCollection: Bool = false) async {
        guard accepts(requestGeneration), !Task.isCancelled else { return }
        do {
            let result = try await service.fetchDocuments()
            guard accepts(requestGeneration), !Task.isCancelled else { return }
            dashboard = result
            errorMessage = nil
        } catch {
            if accepts(requestGeneration), !Task.isCancelled {
                errorMessage = afterCollection ? "Your points were collected. Refresh to update your documents."
                    : (afterSubmission ? "Your evidence was submitted. Refresh to update your documents." : error.localizedDescription)
            }
        }
    }

    private func validate(_ result: DocumentReceipt, for request: DocumentRequest) throws {
        let submission = result.submission
        guard submission.id > 0, submission.requestID == request.requestID,
              submission.dogID == request.dogID, submission.kind == request.kind,
              submission.status == "SELF_REPORTED",
              submission.eventDate == request.eventDate,
              submission.registrationNumber == (request.registrationNumber ?? ""),
              (submission.councilName ?? "") == (request.councilName ?? ""),
              submission.registrationYear == request.registrationYear,
              submission.awardedPoints == result.awardedPoints,
              result.awardedPoints == 0 || result.awardedPoints == request.kind.points,
              result.balance >= 0 else { throw APIError.invalidResponse }
        if let id = result.entitlementID {
            guard id > 0, submission.entitlementID == id,
                  result.rewardStatus != nil, result.rewardStatus == submission.rewardStatus,
                  result.rewardPoints == request.kind.points, submission.rewardPoints == result.rewardPoints,
                  result.awardedPoints == 0 else { throw APIError.invalidResponse }
        }
    }

    private static func collectionDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
