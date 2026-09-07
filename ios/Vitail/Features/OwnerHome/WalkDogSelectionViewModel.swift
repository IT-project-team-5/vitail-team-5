import Combine
import Foundation

@MainActor
final class WalkDogSelectionViewModel: ObservableObject {
    @Published private(set) var dogs: [Dog] = []
    @Published private(set) var selectedDogIDs: Set<Int> = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    private let session: WalkSessionTracker
    private let service: any DogServicing

    init(session: WalkSessionTracker, service: any DogServicing = DogService()) {
        self.session = session
        self.service = service
    }

    var selectedDogs: [Dog] {
        dogs.filter { selectedDogIDs.contains($0.id) }
    }

    var canEditSelection: Bool {
        session.canStart && hasLoaded && !isLoading && errorMessage == nil
    }

    var canStartWalk: Bool {
        canEditSelection && !selectedDogs.isEmpty
    }

    func load() async {
        guard session.canStart && !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedDogs = try await service.getDogs()
            try Task.checkCancellation()
            dogs = loadedDogs
            selectedDogIDs.formIntersection(Set(loadedDogs.map(\.id)))
            hasLoaded = true
        } catch is CancellationError {
            errorMessage = "Could not finish loading your dogs. Please try again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleDog(id: Int) {
        guard canEditSelection, dogs.contains(where: { $0.id == id }) else { return }
        if selectedDogIDs.contains(id) {
            selectedDogIDs.remove(id)
        } else {
            selectedDogIDs.insert(id)
        }
    }

    func selectAll() {
        guard canEditSelection else { return }
        selectedDogIDs = Set(dogs.map(\.id))
    }

    func clearSelection() {
        guard canEditSelection else { return }
        selectedDogIDs.removeAll()
    }
}
