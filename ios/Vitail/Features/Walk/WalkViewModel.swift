import Combine
import Foundation

@MainActor
final class WalkViewModel: ObservableObject {
    let recorder: WalkRecorder
    @Published private(set) var dogs: [Dog] = []
    @Published var selectedDogIDs: Set<Int> = []
    @Published private(set) var walks: [WalkSummary] = []
    @Published private(set) var isSaving = false
    @Published private(set) var isLoading = false
    @Published private(set) var pendingRequest: WalkRequest?
    @Published private(set) var lastSavedWalk: WalkSummary?
    @Published var errorMessage: String?
    var onWalletChanged: (@MainActor () async -> Void)?

    private let service: any WalkServing
    private let dogService: any DogServicing
    private var recordingDogIDs: [Int] = []

    init(service: any WalkServing = WalkService(), dogService: any DogServicing = DogService()) {
        self.service = service
        self.dogService = dogService
        recorder = WalkRecorder()
        recorder.onAutomaticStop = { [weak self] in
            Task { @MainActor in await self?.finish() }
        }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let dogsResult = dogService.getDogs()
            async let walksResult = service.getWalks()
            (dogs, walks) = try await (dogsResult, walksResult)
            if !recorder.isActive {
                selectedDogIDs.formIntersection(Set(dogs.map(\.id)))
                if selectedDogIDs.isEmpty, let first = dogs.first { selectedDogIDs.insert(first.id) }
            }
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func start() {
        guard !selectedDogIDs.isEmpty, !isSaving, pendingRequest == nil else { return }
        recordingDogIDs = selectedDogIDs.sorted()
        errorMessage = nil
        lastSavedWalk = nil
        recorder.start()
    }

    func finish() async {
        guard !isSaving else { return }
        if pendingRequest == nil {
            guard recorder.isActive else { return }
            guard let capture = recorder.stop(), capture.samples.count >= 2 else {
                errorMessage = "The walk needs at least two GPS readings. Walk outdoors, then try again."
                return
            }
            pendingRequest = WalkRequest(
                requestID: UUID(), startedAt: WalkTimestamp.string(capture.startedAt),
                endedAt: WalkTimestamp.string(capture.endedAt), dogIDs: recordingDogIDs,
                samples: capture.samples
            )
        }
        await retryUpload()
    }

    func retryUpload() async {
        guard let request = pendingRequest, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let walk = try await service.submit(request)
            lastSavedWalk = walk
            walks.removeAll { $0.id == walk.id }
            walks.insert(walk, at: 0)
            pendingRequest = nil
            await onWalletChanged?()
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func finishForLogout() async {
        if recorder.isActive { await finish() }
        else if pendingRequest != nil { await retryUpload() }
        discard()
    }

    func discard() {
        recorder.discard()
        pendingRequest = nil
        recordingDogIDs = []
    }
}
