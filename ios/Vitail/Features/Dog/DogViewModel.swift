import Combine
import Foundation

@MainActor
final class DogViewModel: ObservableObject {
    static let maximumDogs = 10

    @Published private(set) var lastSavedDog: Dog?
    @Published private(set) var dogs: [Dog] = []
    @Published private(set) var breeds: [Breed] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let service: any DogServicing
    private weak var session: SessionStore?
    private let requiresSession: Bool
    private let ownerID: Int?
    private var loadRevision = 0

    init(service: any DogServicing = DogService(), session: SessionStore? = nil) {
        self.service = service
        self.session = session
        requiresSession = session != nil
        if case let .signedIn(user) = session?.state { ownerID = user.id } else { ownerID = nil }
    }

    private func accepts(_ revision: Int?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard requiresSession else { return true }
        guard case let .signedIn(user) = session?.state else { return false }
        return user.id == ownerID && user.role == .owner && session?.sessionRevision == revision
    }

    var canAddDog: Bool { dogs.count < Self.maximumDogs }

    func load() async {
        let sessionRevision = session?.sessionRevision
        guard accepts(sessionRevision), !isSaving else { return }
        loadRevision += 1
        let request = loadRevision
        isLoading = true
        errorMessage = nil
        defer { if loadRevision == request { isLoading = false } }

        do {
            async let dogsRequest = service.getDogs()
            async let breedsRequest = service.getBreeds()
            let (loadedDogs, loadedBreeds) = try await (dogsRequest, breedsRequest)
            guard accepts(sessionRevision), loadRevision == request else { return }
            (dogs, breeds) = (loadedDogs, loadedBreeds)
        } catch {
            guard accepts(sessionRevision), loadRevision == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func save(dog: Dog?, request: DogWriteRequest, photoData: Data? = nil) async -> Bool {
        let sessionRevision = session?.sessionRevision
        guard !isSaving, accepts(sessionRevision) else { return false }
        loadRevision += 1
        isLoading = false
        lastSavedDog = nil
        guard dog != nil || canAddDog else {
            errorMessage = "An account can have at most 10 dogs."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let savedDog: Dog
            if let dog {
                savedDog = try await service.updateDog(id: dog.id, request: request)
                guard accepts(sessionRevision) else { return false }
                if let index = dogs.firstIndex(where: { $0.id == dog.id }) {
                    dogs[index] = savedDog
                }
            } else {
                savedDog = try await service.createDog(request)
                guard accepts(sessionRevision) else { return false }
                dogs.append(savedDog)
            }
            lastSavedDog = savedDog
            if let photoData {
                let updatedDog = try await service.uploadPhoto(dogID: savedDog.id, data: photoData)
                guard accepts(sessionRevision) else { return false }
                if let index = dogs.firstIndex(where: { $0.id == savedDog.id }) { dogs[index] = updatedDog }
                lastSavedDog = updatedDog
            }
            return true
        } catch {
            guard accepts(sessionRevision) else { return false }
            errorMessage = lastSavedDog == nil ? error.localizedDescription
                : "Dog details saved. The photo could not upload: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ dog: Dog) async -> Bool {
        let sessionRevision = session?.sessionRevision
        guard !isSaving, accepts(sessionRevision) else { return false }
        loadRevision += 1
        isLoading = false
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await service.deleteDog(id: dog.id)
            guard accepts(sessionRevision) else { return false }
            dogs.removeAll { $0.id == dog.id }
            return true
        } catch {
            guard accepts(sessionRevision) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
final class DogGoalViewModel: ObservableObject {
    @Published private(set) var preview: DogGoalPreview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var saved = false
    @Published private(set) var errorMessage: String?
    private let service: any DogServicing
    private var generation = 0
    private var previewPercentage: Int?

    init(service: any DogServicing = DogService()) { self.service = service }

    func canSave(percentage: Int) -> Bool {
        preview?.eligible == true && previewPercentage == percentage && !isLoading && !isSaving && !saved
    }

    func load(dogID: Int, percentage: Int) async {
        generation += 1
        let request = generation
        isLoading = true
        preview = nil
        previewPercentage = nil
        saved = false
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let result = try await service.previewGoal(dogID: dogID, percentage: percentage)
            guard request == generation, !Task.isCancelled else { return }
            preview = result
            previewPercentage = percentage
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func save(dogID: Int, percentage: Int) async -> Bool {
        guard canSave(percentage: percentage), let preview else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            self.preview = try await service.saveGoal(dogID: dogID,
                request: DogGoalRequest(ownerAdjustment: preview.ownerAdjustment, effectiveFrom: preview.effectiveFrom))
            saved = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
