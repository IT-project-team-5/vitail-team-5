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
                        .tint(isDisabled ? AppColors.secondaryText : AppColors.brandForeground)
                }
                Text(title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .foregroundStyle(isDisabled ? AppColors.secondaryText : AppColors.brandForeground)
            .background(isDisabled ? AppColors.border.opacity(0.45) : AppColors.brand)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
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
                SecureField(title, text: $text, prompt: Text(title).foregroundStyle(AppColors.secondaryText))
            } else {
                TextField(title, text: $text, prompt: Text(title).foregroundStyle(AppColors.secondaryText))
            }
        }
        .textContentType(textContentType)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(keyboardType == .emailAddress ? .never : .sentences)
        .autocorrectionDisabled(keyboardType == .emailAddress)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .frame(minHeight: 50)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.field)
                .stroke(AppColors.border, lineWidth: 1)
        }
    }
}

/// The approved full-color brand artwork, also used for the Home Screen icon.
struct VitailBrandMark: View {
    var size: CGFloat = 80

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
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
