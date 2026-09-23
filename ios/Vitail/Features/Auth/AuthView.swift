import SwiftUI

struct AuthView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var viewModel = AuthViewModel()
    @ScaledMetric(relativeTo: .body) private var accountIconWidth = 24.0
    #if DEBUG
    @State private var debugBackendURL = AppConfiguration.debugAPIBaseURLText
    @State private var debugBackendMessage: String?
    @State private var debugBackendHasError = false
    #endif

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.extraLarge) {
                        VStack(alignment: .leading, spacing: AppSpacing.large) {
                            header
                            if let accountType = viewModel.accountType {
                                Button {
                                    withAnimation { viewModel.chooseAnotherAccount() }
                                } label: {
                                    Label(accountType.rawValue, systemImage: "chevron.left")
                                        .font(.headline)
                                }
                                .foregroundStyle(AppColors.brand)
                                authenticationForm
                            } else {
                                VStack(spacing: AppSpacing.medium) {
                                    ForEach(AuthViewModel.AccountType.allCases) { accountType in
                                        accountTypeButton(accountType)
                                    }
                                }
                                .padding(.top, AppSpacing.large)
                            }
                            Spacer(minLength: AppSpacing.extraLarge)
                        }
                        .frame(minHeight: max(geometry.size.height - AppSpacing.large * 2, 0), alignment: .top)

                        #if DEBUG
                        debugBackendURLSection
                            .padding(.top, AppSpacing.extraLarge)
                        #endif
                    }
                    .padding(AppSpacing.large)
                }
                .background(AppColors.background)
                .disabled(viewModel.isLoading)
            }
        }
    }

    private var authenticationForm: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
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
                    AppTextField(title: "Display name", text: $viewModel.displayName, textContentType: .name)
                }
                AppTextField(title: "Email", text: $viewModel.email,
                             keyboardType: .emailAddress, textContentType: .emailAddress)
                AppTextField(title: "Password", text: $viewModel.password, isSecure: true,
                             textContentType: viewModel.mode == .login ? .password : .newPassword)
            }
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.error)
                    .accessibilityIdentifier("authError")
            }
            PrimaryButton(title: viewModel.mode.rawValue, isLoading: viewModel.isLoading,
                          isDisabled: !viewModel.canSubmit) {
                Task { await viewModel.submit(using: session) }
            }
            if viewModel.accountType == .cafeOwner {
                Text("Café accounts are created by a Vitail administrator.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private func accountTypeButton(_ accountType: AuthViewModel.AccountType) -> some View {
        Button {
            withAnimation { viewModel.select(accountType) }
        } label: {
            HStack(spacing: AppSpacing.medium) {
                Image(systemName: accountType == .dogOwner ? "dog.fill" : "cup.and.saucer.fill")
                    .frame(width: accountIconWidth)
                Text(accountType.rawValue)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.subheadline)
            }
            .foregroundStyle(AppColors.primaryText)
            .padding(AppSpacing.large)
            .frame(minHeight: 64)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            VitailBrandMark()
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
                .foregroundStyle(AppColors.brandForeground)

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
