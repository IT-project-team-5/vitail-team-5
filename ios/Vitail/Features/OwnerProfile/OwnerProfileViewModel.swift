import Combine
import Foundation

@MainActor
final class OwnerProfileViewModel: ObservableObject {
    @Published var displayName: String
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let originalDisplayName: String

    init(user: User) {
        displayName = user.displayName
        originalDisplayName = user.displayName
    }

    var canSave: Bool {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != originalDisplayName
    }

    func save(using session: SessionStore) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await session.updateDisplayName(
                displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
