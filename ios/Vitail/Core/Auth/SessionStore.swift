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

    private let authService: AuthService

    init(authService: AuthService = AuthService()) {
        self.authService = authService
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

    func updateDisplayName(_ displayName: String) async throws {
        let updatedUser = try await authService.updateProfile(displayName: displayName)
        try validateMobileRole(updatedUser)
        state = .signedIn(updatedUser)
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
