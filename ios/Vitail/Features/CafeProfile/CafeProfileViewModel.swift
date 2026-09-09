import Combine
import Foundation

@MainActor
final class CafeProfileViewModel: ObservableObject {
    @Published var name = ""
    @Published var address = ""
    @Published var description = ""
    @Published var openingHours = ""
    @Published private(set) var email = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?

    private let service: any CafeProfileServing

    init(service: any CafeProfileServing = CafeProfileService()) {
        self.service = service
    }

    var canSave: Bool {
        hasLoaded && validationMessage == nil && !isSaving && !isLoading
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a café name."
        }
        if name.count > 100 { return "Café name must be 100 characters or fewer." }
        if address.count > 255 { return "Address must be 255 characters or fewer." }
        if description.count > 2000 { return "Description must be 2,000 characters or fewer." }
        if openingHours.count > 500 { return "Opening hours must be 500 characters or fewer." }
        return nil
    }

    func load() async {
        guard !isLoading, !isSaving else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let profile = try await service.getProfile()
            try Task.checkCancellation()
            apply(profile)
            hasLoaded = true
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func save(using session: SessionStore) async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }
        do {
            let profile = try await service.updateProfile(CafeProfileRequest(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                openingHours: openingHours.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            try Task.checkCancellation()
            apply(profile)
            successMessage = "Café details saved."
            do {
                try await session.reloadCurrentUser()
            } catch {
                errorMessage = "Details were saved, but the account name could not refresh. Try signing in again."
            }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ profile: CafeProfile) {
        name = profile.name
        email = profile.email
        address = profile.address
        description = profile.description
        openingHours = profile.openingHours
    }
}
