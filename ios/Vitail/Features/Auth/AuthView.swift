import SwiftUI

struct AuthView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var viewModel = AuthViewModel()

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
}
