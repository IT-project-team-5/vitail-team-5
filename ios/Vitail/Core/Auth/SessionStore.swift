import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(User)
        case restoreFailed(String)
    }

    @Published private(set) var state: State = .restoring
    var beforeLogout: (@MainActor () async -> Void)?

    private let authService: any AuthServing
    private var credentialEventsTask: Task<Void, Never>?
    private var isLoggingOut = false
    private var generation = 0
    private var credentialWrite: Task<Void, Error>?
    var sessionRevision: Int { generation }

    init(authService: any AuthServing = AuthService()) {
        self.authService = authService
        let credentialEvents = authService.credentialEvents
        credentialEventsTask = Task { @MainActor [weak self] in
            for await event in credentialEvents {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch event {
                case .sessionExpired:
                    generation += 1
                    beforeLogout = nil
                    state = .signedOut
                }
            }
        }
    }

    deinit {
        credentialEventsTask?.cancel()
    }

    func restore() async {
        guard !isLoggingOut else { return }
        generation += 1
        let request = generation
        state = .restoring

        do {
            let restoredUser = try await authService.restoreUser()
            guard generation == request, !Task.isCancelled else { return }
            guard let user = restoredUser else {
                state = .signedOut
                return
            }
            try validateMobileRole(user)
            state = .signedIn(user)
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            if error as? APIError == .missingSession {
                state = .signedOut
                return
            }
            if error as? APIError == .unsupportedRole {
                // Use the same serialized teardown as logout, so a new login
                // cannot install credentials while this clear is suspended.
                let cleanupRequest = generation + 1
                await logout()
                guard generation == cleanupRequest else { return }
            }
            state = .restoreFailed(error.localizedDescription)
        }
    }

    func login(email: String, password: String, expectedRole: UserRole) async throws {
        guard !isLoggingOut else { throw APIError.missingSession }
        generation += 1
        let request = generation
        let response = try await authService.login(email: email, password: password)
        try await accept(response, expectedRole: expectedRole, generation: request)
    }

    func register(email: String, password: String, displayName: String) async throws {
        guard !isLoggingOut else { throw APIError.missingSession }
        generation += 1
        let request = generation
        let response = try await authService.register(
            email: email,
            password: password,
            displayName: displayName
        )
        try await accept(response, expectedRole: .owner, generation: request)
    }

    func logout() async {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        generation += 1
        defer { isLoggingOut = false }
        await beforeLogout?()
        beforeLogout = nil
        // Finish an already-started Keychain install before deleting credentials.
        _ = try? await credentialWrite?.value
        credentialWrite = nil
        try? await authService.clearSession()
        state = .signedOut
    }

    func updateDisplayName(_ displayName: String) async throws {
        let request = generation
        guard case let .signedIn(originalUser) = state else {
            throw APIError.missingSession
        }
        let updatedUser = try await authService.updateProfile(displayName: displayName)
        try validateMobileRole(updatedUser)
        guard generation == request, !isLoggingOut, case let .signedIn(currentUser) = state,
              currentUser.id == originalUser.id else { throw APIError.missingSession }
        state = .signedIn(updatedUser)
    }

    func updatePhoto(_ data: Data) async throws {
        let request = generation
        guard case let .signedIn(originalUser) = state else { throw APIError.missingSession }
        let updatedUser = try await authService.uploadPhoto(data)
        try validateMobileRole(updatedUser)
        guard generation == request, !isLoggingOut, case let .signedIn(currentUser) = state,
              currentUser.id == originalUser.id else { throw APIError.missingSession }
        state = .signedIn(updatedUser)
    }

    func reloadCurrentUser() async throws {
        let request = generation
        guard case let .signedIn(originalUser) = state,
              let updatedUser = try await authService.restoreUser() else {
            throw APIError.missingSession
        }
        try validateMobileRole(updatedUser)
        guard generation == request, !isLoggingOut, case let .signedIn(currentUser) = state,
              currentUser.id == originalUser.id else { throw APIError.missingSession }
        state = .signedIn(updatedUser)
    }

    private func accept(_ response: AuthResponse, expectedRole: UserRole, generation request: Int) async throws {
        try Task.checkCancellation()
        guard generation == request, !isLoggingOut else { throw APIError.missingSession }
        try validateMobileRole(response.user)
        guard response.user.role == expectedRole else {
            throw APIError.roleMismatch(expected: expectedRole, actual: response.user.role)
        }
        _ = try? await credentialWrite?.value
        guard generation == request, !isLoggingOut else { throw APIError.missingSession }
        let task = Task { [authService] in try await authService.persist(response.tokens) }
        credentialWrite = task
        defer { if generation == request { credentialWrite = nil } }
        try await task.value
        guard generation == request, !isLoggingOut else { throw APIError.missingSession }
        state = .signedIn(response.user)
    }

    private func validateMobileRole(_ user: User) throws {
        guard user.role.isSupportedOnMobile else {
            throw APIError.unsupportedRole
        }
    }
}
