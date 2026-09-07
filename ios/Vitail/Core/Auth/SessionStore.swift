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

    private let authService: any AuthServing
    private var credentialEventsTask: Task<Void, Never>?

    init(authService: any AuthServing = AuthService()) {
        self.authService = authService
        let credentialEvents = authService.credentialEvents
        credentialEventsTask = Task { @MainActor [weak self] in
            for await event in credentialEvents {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch event {
                case .sessionExpired:
                    state = .signedOut
                }
            }
        }
    }

    deinit {
        credentialEventsTask?.cancel()
    }

    func restore() async {
        state = .restoring

        do {
            guard let user = try await authService.restoreUser() else {
                state = .signedOut
                return
            }
            try validateMobileRole(user)
            state = .signedIn(user)
        } catch {
            if error as? APIError == .missingSession {
                state = .signedOut
                return
            }
            if error as? APIError == .unsupportedRole {
                try? await authService.clearSession()
            }
            state = .restoreFailed(error.localizedDescription)
        }
    }

    func login(email: String, password: String, expectedRole: UserRole) async throws {
        let response = try await authService.login(email: email, password: password)
        try await accept(response, expectedRole: expectedRole)
    }

    func register(email: String, password: String, displayName: String) async throws {
        let response = try await authService.register(
            email: email,
            password: password,
            displayName: displayName
        )
        try await accept(response, expectedRole: .owner)
    }

    func logout() async {
        try? await authService.clearSession()
        state = .signedOut
    }

    private func accept(_ response: AuthResponse, expectedRole: UserRole) async throws {
        try validateMobileRole(response.user)
        guard response.user.role == expectedRole else {
            throw APIError.roleMismatch(expected: expectedRole, actual: response.user.role)
        }
        try await authService.persist(response.tokens)
        state = .signedIn(response.user)
    }

    private func validateMobileRole(_ user: User) throws {
        guard user.role.isSupportedOnMobile else {
            throw APIError.unsupportedRole
        }
    }
}
