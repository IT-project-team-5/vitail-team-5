import Combine
import Foundation

@MainActor
final class DogViewModel: ObservableObject {
    static let maximumDogs = 10

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

    func save(dog: Dog?, request: DogWriteRequest) async -> Bool {
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
