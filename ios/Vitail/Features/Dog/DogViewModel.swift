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

    init(service: any DogServicing = DogService()) {
        self.service = service
    }

    var canAddDog: Bool { dogs.count < Self.maximumDogs }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let dogsRequest = service.getDogs()
            async let breedsRequest = service.getBreeds()
            (dogs, breeds) = try await (dogsRequest, breedsRequest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(dog: Dog?, request: DogWriteRequest, photoData: Data? = nil) async -> Bool {
        guard !isSaving else { return false }
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
                if let index = dogs.firstIndex(where: { $0.id == dog.id }) {
                    dogs[index] = savedDog
                }
            } else {
                savedDog = try await service.createDog(request)
                dogs.append(savedDog)
            }
            lastSavedDog = savedDog
            if let photoData {
                let updatedDog = try await service.uploadPhoto(dogID: savedDog.id, data: photoData)
                if let index = dogs.firstIndex(where: { $0.id == savedDog.id }) { dogs[index] = updatedDog }
                lastSavedDog = updatedDog
            }
            return true
        } catch {
            errorMessage = lastSavedDog == nil ? error.localizedDescription
                : "Dog details saved. The photo could not upload: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ dog: Dog) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await service.deleteDog(id: dog.id)
            dogs.removeAll { $0.id == dog.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
