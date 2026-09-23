import Combine
import Foundation

@MainActor
final class OwnerProfileViewModel: ObservableObject {
    @Published var photoData: Data?
    @Published var displayName: String
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private var originalDisplayName: String

    init(user: User) {
        displayName = user.displayName
        originalDisplayName = user.displayName
    }

    var canSave: Bool {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && (value != originalDisplayName || photoData != nil)
    }

    func save(using session: SessionStore) async -> Bool {
        guard canSave, !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name != originalDisplayName {
                try await session.updateDisplayName(name)
                originalDisplayName = name
            }
            if let photoData {
                try await session.updatePhoto(photoData)
                self.photoData = nil
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
