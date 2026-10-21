import SwiftUI

// MARK: - Buttons

/// Neo-retro press: an outlined capsule sitting on a hard ink shadow. When
/// pressed, the button drops onto its shadow.
struct VitailPressStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var isEnabled = true
    var shadow: CGFloat = AppStroke.shadow

    func makeBody(configuration: Configuration) -> some View {
        let drop = isEnabled ? shadow : 0
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(isEnabled ? AppColors.outline : AppColors.border,
                                            lineWidth: AppStroke.width))
            .offset(x: pressed ? drop : 0, y: pressed ? drop : 0)
            .background(Capsule().fill(AppColors.outline).offset(x: drop, y: drop))
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

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
                    .font(AppFont.heading(17, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(VitailPressStyle(
            fill: isDisabled ? AppColors.border.opacity(0.45) : AppColors.brand,
            foreground: isDisabled ? AppColors.secondaryText : AppColors.brandForeground,
            isEnabled: !isDisabled
        ))
        .padding(.trailing, isDisabled ? 0 : AppStroke.shadow)
        .padding(.bottom, isDisabled ? 0 : AppStroke.shadow)
        .disabled(isDisabled || isLoading)
    }
}

/// Outlined card-coloured button for secondary actions ("View history").
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
                    .font(AppFont.heading(16, .semibold))
            }
            .padding(.horizontal, AppSpacing.medium)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(VitailPressStyle(fill: AppColors.surface, foreground: AppColors.primaryText, shadow: 3))
        .padding(.trailing, 3)
        .padding(.bottom, 3)
    }
}

// MARK: - Fields

struct AppTextField: View {
    let title: String
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    /// Small uppercase caption shown above the field ("EMAIL"). The placeholder
    /// becomes `prompt` when one is given.
    var label: String? = nil
    var prompt: String? = nil

    var body: some View {
        if let label {
            VStack(alignment: .leading, spacing: 6) {
                VitailSectionLabel(text: label)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
                field
            }
        } else {
            field
        }
    }

    private var field: some View {
        Group {
            if isSecure {
                SecureField(title, text: $text, prompt: Text(prompt ?? title).foregroundStyle(AppColors.secondaryText))
            } else {
                TextField(title, text: $text, prompt: Text(prompt ?? title).foregroundStyle(AppColors.secondaryText))
            }
        }
        .font(AppFont.body(16))
        .textContentType(textContentType)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(keyboardType == .emailAddress ? .never : .sentences)
        .autocorrectionDisabled(keyboardType == .emailAddress)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .frame(minHeight: 52)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.field)
                .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Card surface without padding: card fill, ink outline and a hard offset shadow.
    func vitailCardBackground(radius: CGFloat = AppRadius.card, shadow: Bool = true) -> some View {
        self
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
            }
            .background {
                if shadow {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(AppColors.outline)
                        .offset(x: AppStroke.shadow, y: AppStroke.shadow)
                }
            }
    }

    /// Tappable / primary card with padding.
    func vitailCard(padding: CGFloat = AppSpacing.medium, shadow: Bool = true) -> some View {
        self
            .padding(padding)
            .vitailCardBackground(shadow: shadow)
    }

    /// Inset panel for empty states and info: Paper Alt, outline, no shadow.
    func vitailInset(padding: CGFloat = AppSpacing.medium) -> some View {
        self
            .padding(padding)
            .background(AppColors.inset, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
            }
    }
}

/// Paper background with the brand motifs in the empty space at the bottom.
/// Use as `.background { VitailScreenBackground() }` on a screen's root.
struct VitailScreenBackground: View {
    var layout: VitailBackdrop.Layout = .trailingDog

    var body: some View {
        ZStack {
            AppColors.background
            VitailBackdrop(layout: layout)
        }
    }
}

/// Small outlined pill ("+58 today", "Registration required").
struct VitailChip: View {
    let text: String
    var systemImage: String?
    var fill: Color = AppColors.inset
    var foreground: Color = AppColors.primaryText

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(AppFont.body(12, .semibold, relativeTo: .caption))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
    }
}

/// Section caption: small uppercase label above a group.
struct VitailSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(AppFont.body(11, .semibold, relativeTo: .caption2))
            .tracking(0.6)
            .foregroundStyle(AppColors.secondaryText)
    }
}

// MARK: - Illustration layer

/// The four brand motifs (sitting dog, running dog, paw trail, bone) placed in
/// the empty space at the bottom of a screen, behind the content. Decorative
/// only: hidden from VoiceOver and never intercepts touches.
struct VitailBackdrop: View {
    enum Layout { case trailingDog, leadingDog }
    var layout: Layout = .trailingDog

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mirror = layout == .leadingDog
            ZStack {
                motif("MotifDogSit", color: AppColors.honey, opacity: 0.3)
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(mirror ? 6 : -6))
                    .position(x: mirror ? 62 : size.width - 62, y: size.height - 96)
                motif("MotifDogRun", color: AppColors.terracotta, opacity: 0.3)
                    .frame(width: 130, height: 74)
                    .rotationEffect(.degrees(-4))
                    .position(x: mirror ? size.width - 86 : 86, y: size.height - 196)
                motif("MotifBone", color: AppColors.sky, opacity: 0.35)
                    .frame(width: 54, height: 22)
                    .rotationEffect(.degrees(-16))
                    .position(x: size.width * 0.52, y: size.height - 226)
                ForEach(0..<3, id: \.self) { index in
                    motif("MotifPaw", color: AppColors.sage, opacity: 0.45)
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(30))
                        .position(x: (mirror ? size.width - 150 : 40) + CGFloat(index) * 38,
                                  y: size.height - (index.isMultiple(of: 2) ? 70 : 98))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func motif(_ name: String, color: Color, opacity: Double) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .opacity(opacity)
    }
}

// MARK: - Prototype building blocks

/// The colour-on-paper mascot used on Sign In and Welcome.
struct VitailMascot: View {
    var size: CGFloat = 92

    var body: some View {
        Image("MascotDog")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Centered "🐾 Vitail" wordmark for the navigation bar.
struct VitailNavTitle: View {
    var title = "Vitail"

    var body: some View {
        HStack(spacing: 6) {
            Image("MotifPaw")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(AppColors.terracotta)
                .accessibilityHidden(true)
            Text(title)
                .font(AppFont.heading(18, .semibold))
                .foregroundStyle(AppColors.primaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Honey-pill segmented control inside an outlined capsule.
struct VitailSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var label = "Options"

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(AppFont.heading(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(isSelected ? AppColors.onAccent : AppColors.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if isSelected { Capsule().fill(AppColors.honey) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(AppColors.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Rounded square icon tile ("cup" on café rows, "doc" on Account rows).
struct VitailIconTile: View {
    let systemImage: String
    var fill: Color = AppColors.inset
    var foreground: Color = AppColors.primaryText
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
            }
            .accessibilityHidden(true)
    }
}

/// Big number with a small unit and an uppercase caption ("2.3 km / DISTANCE").
struct VitailStat: View {
    let value: String
    var unit: String? = nil
    let label: String
    var size: CGFloat = 22

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(AppFont.heading(size, .bold, relativeTo: .title3))
                if let unit {
                    Text(unit).font(AppFont.heading(size * 0.55, .semibold, relativeTo: .caption))
                }
            }
            .foregroundStyle(AppColors.primaryText)
            VitailSectionLabel(text: label)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Honey check badge with a hard shadow ("Order confirmed", "Walk complete!").
struct VitailSuccessBadge: View {
    var systemImage = "checkmark"
    var size: CGFloat = 80

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(AppColors.onAccent)
            .frame(width: size, height: size)
            .background(AppColors.honey, in: Circle())
            .overlay(Circle().strokeBorder(AppColors.outline, lineWidth: AppStroke.width + 1))
            .background(Circle().fill(AppColors.outline).offset(x: AppStroke.shadow, y: AppStroke.shadow))
            .accessibilityHidden(true)
    }
}

/// Two-part progress bar used by onboarding steps.
struct VitailStepBar: View {
    let step: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index < step ? AppColors.honey : AppColors.surface)
                        .overlay(Capsule().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
                        .frame(height: 8)
                }
            }
            VitailSectionLabel(text: "Step \(step) of \(total)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(total)")
    }
}

/// Outlined progress track with a sage fill.
struct VitailProgressBar: View {
    let value: Double
    var fill: Color = AppColors.sage

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColors.surface)
                Capsule().fill(fill)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
                Capsule().strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(max(0, min(1, value)).formatted(.percent.precision(.fractionLength(0)))))
    }
}

/// Text-only action in brand colour ("Skip for now", "Back to Redeem").
struct VitailTextButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(AppFont.heading(16, .semibold))
            .foregroundStyle(AppColors.brand)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Dashed hairline used inside receipts and point breakdowns.
struct VitailDashedDivider: View {
    var body: some View {
        Line()
            .stroke(AppColors.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(height: 1.5)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 0, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

extension View {
    /// Paper-card input look for custom fields (pickers, date buttons, focused text fields).
    func vitailFieldStyle() -> some View {
        self
            .font(AppFont.body(16))
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.field)
                    .strokeBorder(AppColors.outline, lineWidth: AppStroke.width)
            }
    }
}

extension Text {
    /// Fredoka display title ("Tell us about your dog", "Walk complete!").
    func vitailTitle(_ size: CGFloat = 26) -> some View {
        font(AppFont.heading(size, .bold, relativeTo: .title))
            .foregroundStyle(AppColors.primaryText)
    }
}

// MARK: - Brand

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
                .font(AppFont.body(15))
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
                .font(AppFont.heading(22, .bold, relativeTo: .title3))
            Text(message)
                .font(AppFont.body(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColors.secondaryText)
            PrimaryButton(title: "Try Again", action: retry)
            Button("Sign Out", action: signOut)
                .font(AppFont.heading(16, .semibold))
                .foregroundStyle(AppColors.brand)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}
