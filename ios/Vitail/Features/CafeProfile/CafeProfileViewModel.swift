import Combine
import Foundation

@MainActor
final class CafeProfileViewModel: ObservableObject {
    @Published var name = ""
    @Published var address = ""
    @Published var description = ""
    @Published var openingHours = ""
    @Published var googleMapsURL = ""
    @Published var photoData: Data?
    @Published private(set) var photo: String?
    @Published private(set) var mapsLink: String?
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
        let maps = googleMapsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if maps.count > 2048 { return "Google Maps link must be 2,048 characters or fewer." }
        if !maps.isEmpty {
            guard let url = URLComponents(string: maps),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                return "Enter a complete Google Maps link or leave it blank."
            }
        }
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
        var detailsWereSaved = false
        do {
            let profile = try await service.updateProfile(CafeProfileRequest(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                openingHours: openingHours.trimmingCharacters(in: .whitespacesAndNewlines),
                googleMapsURL: googleMapsURL.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            try Task.checkCancellation()
            apply(profile)
            detailsWereSaved = true
            if let photoData {
                let updatedProfile = try await service.uploadPhoto(photoData)
                try Task.checkCancellation()
                apply(updatedProfile)
                self.photoData = nil
            }
            successMessage = "Café details saved."
            do {
                try await session.reloadCurrentUser()
            } catch {
                errorMessage = "Details were saved, but the account could not refresh. Try signing in again."
            }
        } catch {
            if !Task.isCancelled {
                if detailsWereSaved {
                    // Keep the selected photo for retry while reflecting the saved café name.
                    try? await session.reloadCurrentUser()
                    errorMessage = "Café details saved. The photo could not upload: \(error.localizedDescription)"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ profile: CafeProfile) {
        name = profile.name
        email = profile.email
        address = profile.address
        description = profile.description
        openingHours = profile.openingHours
        googleMapsURL = profile.googleMapsURL ?? ""
        photo = profile.photo
        mapsLink = profile.mapsLink
    }
}
