import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.small) {
                if isLoading {
                    ProgressView()
                        .tint(AppColors.brandForeground)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(AppColors.brandForeground)
            .background(AppColors.brand)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.55 : 1)
    }
}
struct AppTextField: View {
    let title: String
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?

    var body: some View {
        Group {
            if isSecure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        }
        .textContentType(textContentType)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(keyboardType == .emailAddress ? .never : .sentences)
        .autocorrectionDisabled(keyboardType == .emailAddress)
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: 50)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.field)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

struct LoadingView: View {
    var message = "Loading…"

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            ProgressView()
                .tint(AppColors.brand)
            Text(message)
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}

struct AppErrorView: View {
    let message: String
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(AppColors.error)
            Text("Could not restore your session")
                .font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColors.secondaryText)
            PrimaryButton(title: "Try Again", action: retry)
            Button("Sign Out", action: signOut)
                .foregroundStyle(AppColors.brand)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}
