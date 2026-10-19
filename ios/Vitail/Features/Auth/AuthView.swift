import SwiftUI

struct AuthView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var viewModel: AuthViewModel
    @ScaledMetric(relativeTo: .body) private var accountIconWidth = 24.0
    #if DEBUG
    @State private var debugBackendURL = AppConfiguration.debugAPIBaseURLText
    @State private var debugBackendMessage: String?
    @State private var debugBackendHasError = false
    #endif

    init(session: SessionStore, viewModel: AuthViewModel? = nil) {
        self.session = session
        _viewModel = StateObject(wrappedValue: viewModel ?? AuthViewModel())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.extraLarge) {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                                .padding(.bottom, 4)
                            accountTypeMenu
                            authenticationForm
                            Spacer(minLength: AppSpacing.extraLarge)
                        }
                        .frame(minHeight: max(geometry.size.height - AppSpacing.large * 2, 0), alignment: .top)

                        #if DEBUG
                        debugBackendURLSection
                            .padding(.top, AppSpacing.extraLarge)
                        #endif
                    }
                    .padding(.horizontal, AppSpacing.large)
                    .padding(.vertical, AppSpacing.large)
                }
                .background { signInBackdrop }
                .disabled(viewModel.isLoading)
                .onAppear {
                    // The prototype opens with Dog Owner already chosen.
                    if viewModel.accountType == nil { viewModel.select(.dogOwner) }
                }
            }
        }
    }

    private var selectedType: AuthViewModel.AccountType { viewModel.accountType ?? .dogOwner }

    /// Two very faint ink dogs, as on the prototype's sign-in screen.
    private var signInBackdrop: some View {
        GeometryReader { proxy in
            ZStack {
                AppColors.background
                Image("MotifDogRun").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(AppColors.primaryText.opacity(0.07))
                    .frame(width: 110, height: 63)
                    .rotationEffect(.degrees(-8))
                    .position(x: proxy.size.width - 35, y: 50)
                Image("MotifDogSit").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(AppColors.primaryText.opacity(0.06))
                    .frame(width: 90, height: 90)
                    .rotationEffect(.degrees(6))
                    .position(x: 23, y: proxy.size.height - 59)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var authenticationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.accountType == .dogOwner {
                VitailSegmentedControl(
                    selection: $viewModel.mode,
                    options: AuthViewModel.Mode.allCases.map { (value: $0, title: $0.rawValue) },
                    label: "Authentication mode"
                )
                .padding(.bottom, 4)
            }
            if viewModel.mode == .register {
                AppTextField(title: "Display name", text: $viewModel.displayName, textContentType: .name,
                             label: "Name", prompt: "Your name")
            }
            AppTextField(title: "Email", text: $viewModel.email,
                         keyboardType: .emailAddress, textContentType: .emailAddress,
                         label: "Email", prompt: "you@example.com")
            AppTextField(title: "Password", text: $viewModel.password, isSecure: true,
                         textContentType: viewModel.mode == .login ? .password : .newPassword,
                         label: "Password", prompt: "••••••••")
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(AppFont.body(14, .medium))
                    .foregroundStyle(AppColors.error)
                    .accessibilityIdentifier("authError")
            }
            PrimaryButton(title: viewModel.mode.rawValue, isLoading: viewModel.isLoading,
                          isDisabled: !viewModel.canSubmit) {
                Task { await viewModel.submit(using: session) }
            }
            .padding(.top, 8)
            if viewModel.accountType == .cafeOwner {
                Text("Café accounts are created by a Vitail administrator.")
                    .font(AppFont.body(12, relativeTo: .footnote))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.mode)
    }

    /// Account type card ("🐾 Dog Owner ⌄"); opens a menu to switch to Cafe.
    private var accountTypeMenu: some View {
        Menu {
            ForEach(AuthViewModel.AccountType.allCases) { accountType in
                Button {
                    // select() toggles when the same type is chosen again; keep one selected.
                    guard viewModel.accountType != accountType else { return }
                    withAnimation { viewModel.select(accountType) }
                } label: {
                    if viewModel.accountType == accountType {
                        Label(accountType.rawValue, systemImage: "checkmark")
                    } else {
                        Text(accountType.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if selectedType == .dogOwner {
                        Image("MotifPaw").renderingMode(.template).resizable().scaledToFit()
                    } else {
                        Image(systemName: "cup.and.saucer.fill").resizable().scaledToFit()
                    }
                }
                .foregroundStyle(AppColors.terracotta)
                .frame(width: accountIconWidth * 0.85, height: accountIconWidth * 0.85)
                Text(selectedType.rawValue)
                    .font(AppFont.heading(16, .semibold))
                    .foregroundStyle(AppColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .vitailCardBackground(radius: 18)
            .contentShape(Rectangle())
        }
        .padding(.trailing, AppStroke.shadow)
        .padding(.bottom, AppStroke.shadow)
        .accessibilityLabel("Account type")
        .accessibilityValue(selectedType.rawValue)
        .accessibilityHint("Choose Dog Owner or Cafe")
    }

    private var header: some View {
        VStack(spacing: 10) {
            // The approved brand artwork (same as the Home Screen icon).
            VitailBrandMark(size: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 120 * 0.22, style: .continuous)
                        .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
                }
            Text("Walk more. Earn local rewards.")
                .font(AppFont.body(13, relativeTo: .subheadline))
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vitail. Walk more. Earn local rewards.")
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
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.field)
                        .strokeBorder(AppColors.border, lineWidth: 1.5)
                }
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
        .vitailCardBackground(shadow: false)
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
