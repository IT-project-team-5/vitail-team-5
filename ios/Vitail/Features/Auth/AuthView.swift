import SwiftUI

struct AuthView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var viewModel = AuthViewModel()
    #if DEBUG
    @State private var debugBackendURL = AppConfiguration.debugAPIBaseURLText
    @State private var debugBackendMessage: String?
    @State private var debugBackendHasError = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    header

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text("Choose your account type")
                            .font(.headline)

                        ForEach(AuthViewModel.AccountType.allCases) { accountType in
                            accountTypeButton(accountType)
                        }
                    }

                    if viewModel.accountType == .dogOwner {
                        Picker("Authentication mode", selection: $viewModel.mode) {
                            ForEach(AuthViewModel.Mode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(spacing: AppSpacing.medium) {
                        if viewModel.mode == .register {
                            AppTextField(
                                title: "Display name",
                                text: $viewModel.displayName,
                                textContentType: .name
                            )
                        }

                        AppTextField(
                            title: "Email",
                            text: $viewModel.email,
                            keyboardType: .emailAddress,
                            textContentType: .emailAddress
                        )

                        AppTextField(
                            title: "Password",
                            text: $viewModel.password,
                            isSecure: true,
                            textContentType: viewModel.mode == .login ? .password : .newPassword
                        )
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.error)
                            .accessibilityIdentifier("authError")
                    }

                    PrimaryButton(
                        title: viewModel.mode.rawValue,
                        isLoading: viewModel.isLoading,
                        isDisabled: !viewModel.canSubmit
                    ) {
                        Task {
                            await viewModel.submit(using: session)
                        }
                    }

                    Text(accountHelpText)
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)

                    #if DEBUG
                    debugBackendURLSection
                    #endif
                }
                .padding(AppSpacing.large)
            }
            .background(AppColors.background)
            .disabled(viewModel.isLoading)
        }
    }

    private var accountHelpText: String {
        switch viewModel.accountType {
        case .dogOwner:
            return "Dog owners can sign in or create an account."
        case .cafeOwner:
            return "Café accounts are created by a Vitail administrator and can sign in here."
        }
    }

    private func accountTypeButton(_ accountType: AuthViewModel.AccountType) -> some View {
        let isSelected = viewModel.accountType == accountType

        return Button {
            viewModel.select(accountType)
        } label: {
            HStack(spacing: AppSpacing.medium) {
                Image(systemName: accountType == .dogOwner ? "dog.fill" : "cup.and.saucer.fill")
                    .frame(width: 24)
                Text(accountType.rawValue)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            }
            .foregroundStyle(isSelected ? AppColors.brandForeground : AppColors.primaryText)
            .padding(.horizontal, AppSpacing.medium)
            .frame(height: 52)
            .background(isSelected ? AppColors.brand : AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.brand)
            Text("Vitail")
                .font(.largeTitle.bold())
            Text("Walk more. Earn local rewards.")
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(.top, AppSpacing.extraLarge)
    }

    #if DEBUG
    // TEMPORARY DEBUG BACKEND URL OVERRIDE. Remove with the matching block in
    // AppConfiguration when a shared staging server is ready.
    private var debugBackendURLSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Backend URL (Debug Only)")
                .font(.caption.bold())

            TextField("https://example.ngrok-free.app", text: $debugBackendURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, AppSpacing.medium)
                .frame(height: 44)
                .background(AppColors.background)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
                .accessibilityIdentifier("debugBackendURL")

            HStack {
                Button("Save") {
                    saveDebugBackendURL()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brand)

                Button("Reset") {
                    AppConfiguration.resetDebugAPIBaseURL()
                    debugBackendURL = AppConfiguration.debugAPIBaseURLText
                    debugBackendMessage = "Reset to the build setting."
                    debugBackendHasError = false
                }
                .buttonStyle(.bordered)
            }

            if let debugBackendMessage {
                Text(debugBackendMessage)
                    .font(.caption)
                    .foregroundStyle(
                        debugBackendHasError ? AppColors.error : AppColors.secondaryText
                    )
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private func saveDebugBackendURL() {
        do {
            let url = try AppConfiguration.saveDebugAPIBaseURL(debugBackendURL)
            debugBackendURL = url.absoluteString
            debugBackendMessage = "Saved. New requests use this URL."
            debugBackendHasError = false
        } catch {
            debugBackendMessage = error.localizedDescription
            debugBackendHasError = true
        }
    }
    #endif
}
