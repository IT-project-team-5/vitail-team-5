import Combine
import Foundation

@MainActor
final class OwnerProfileViewModel: ObservableObject {
    @Published var photoData: Data?
    @Published var displayName: String
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private var originalDisplayName: String
    private let ownerID: Int

    init(user: User) {
        ownerID = user.id
        displayName = user.displayName
        originalDisplayName = user.displayName
    }

    var canSave: Bool {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && (value != originalDisplayName || photoData != nil)
    }

    func save(using session: SessionStore) async -> Bool {
        guard canSave, !isSaving else { return false }
        guard case let .signedIn(user) = session.state, user.id == ownerID else { return false }
        let revision = session.sessionRevision
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name != originalDisplayName {
                try await session.updateDisplayName(name)
                guard session.sessionRevision == revision else { throw APIError.missingSession }
                originalDisplayName = name
            }
            if let photoData {
                guard session.sessionRevision == revision else { throw APIError.missingSession }
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
