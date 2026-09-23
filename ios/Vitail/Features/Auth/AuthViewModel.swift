import Combine
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    enum AccountType: String, CaseIterable, Identifiable {
        case dogOwner = "Dog Owner"
        case cafeOwner = "Cafe"

        var id: Self { self }

        var role: UserRole {
            switch self {
            case .dogOwner:
                return .owner
            case .cafeOwner:
                return .cafe
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case login = "Sign In"
        case register = "Create Account"

        var id: Self { self }
    }

    @Published private(set) var accountType: AccountType? = nil
    @Published var mode: Mode = .login
    @Published var displayName = ""
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    var canSubmit: Bool {
        guard accountType != nil else { return false }
        let hasCredentials = !trimmedEmail.isEmpty && !password.isEmpty
        return mode == .login ? hasCredentials : hasCredentials && !trimmedDisplayName.isEmpty
    }

    func select(_ accountType: AccountType) {
        self.accountType = accountType
        errorMessage = nil

        if accountType == .cafeOwner {
            mode = .login
        }
    }

    func chooseAnotherAccount() {
        accountType = nil
        mode = .login
        password = ""
        errorMessage = nil
    }

    func submit(using session: SessionStore) async {
        guard canSubmit, let accountType else {
            errorMessage = "Please complete all fields."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch mode {
            case .login:
                try await session.login(
                    email: trimmedEmail,
                    password: password,
                    expectedRole: accountType.role
                )
            case .register:
                guard accountType == .dogOwner else {
                    errorMessage = "Café accounts are created by a Vitail administrator."
                    return
                }
                try await session.register(
                    email: trimmedEmail,
                    password: password,
                    displayName: trimmedDisplayName
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
