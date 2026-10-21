import Combine
import CoreText
import SwiftUI
import UIKit

enum AppColors {
    // Vitail neo-retro palette (UI refresh). Light mode follows the design
    // system board; dark mode keeps the warm-dark surfaces from before.
    // Primary actions use Terracotta Dark so card-coloured labels stay ≥ 4.5:1.
    static let brand = adaptive(light: 0xA94C2F, dark: 0xE8876A)
    static let brandForeground = adaptive(light: 0xFFF8EA, dark: 0x281A0D)
    static let background = adaptive(light: 0xF7EEDB, dark: 0x211B15)   // Paper
    static let surface = adaptive(light: 0xFFF8EA, dark: 0x30261D)      // Card
    static let inset = adaptive(light: 0xEFE4C7, dark: 0x2A2119)        // Paper Alt: empty states, inset panels
    static let primaryText = adaptive(light: 0x3B2A1A, dark: 0xFFF2DB)  // Ink
    static let secondaryText = adaptive(light: 0x6E5B48, dark: 0xD4BFA0) // Ink Soft
    static let border = adaptive(light: 0xDCCBA6, dark: 0x685440)       // Line: dividers
    /// Heavy outline and hard offset shadow used on cards, buttons and fields.
    static let outline = adaptive(light: 0x3B2A1A, dark: 0x8E7A60)
    // Accent fills. Pair them with primaryText (Ink), never with white text.
    static let honey = Color(vitailHex: 0xE8A53B)
    static let terracotta = Color(vitailHex: 0xC9603E)
    static let sage = Color(vitailHex: 0x8CA37B)
    static let sky = Color(vitailHex: 0x5C84A0)
    static let rose = Color(vitailHex: 0xD9A08C)
    /// Text that sits on a Honey / Sage / Rose fill.
    static let onAccent = Color(vitailHex: 0x3B2A1A)
    // Status colors stay distinct from the brand. Never rely on color alone.
    static let warning = adaptive(light: 0x8C5900, dark: 0xF2C36B)
    static let success = adaptive(light: 0x4F6142, dark: 0x90CF9F)
    static let information = adaptive(light: 0x466A82, dark: 0x8EC5EA)
    static let error = Color(uiColor: .systemRed)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension Color {
    init(vitailHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Fredoka (headings, buttons, numbers) and Work Sans (body), bundled in
/// Vitail/Fonts. If a font is ever missing the helpers fall back to the
/// rounded system font.
enum AppFont {
    enum Weight { case regular, medium, semibold, bold }

    // Fredoka ships renamed as "Vitail Display" (PostScript VitailDisplay-*):
    // SwiftUI would not draw the face under its original "Fredoka" name.
    private static let fontNames = ["VitailDisplay-Medium", "VitailDisplay-SemiBold", "VitailDisplay-Bold",
                                    "WorkSans-Regular", "WorkSans-Medium", "WorkSans-SemiBold", "WorkSans-Bold"]

    /// Fonts are bundled in Vitail/Fonts and listed under UIAppFonts in
    /// Info.plist, so iOS registers them at launch. In Debug builds this logs
    /// once whether each face is available.
    static let registerOnce: Void = {
        #if DEBUG
        print("[Vitail fonts]", fontNames.map { "\($0)=\(UIFont(name: $0, size: 12) != nil ? "ok" : "MISSING")" }
            .joined(separator: " "))
        #endif
    }()

    /// Fredoka. Scales with Dynamic Type relative to `style`.
    static func heading(_ size: CGFloat, _ weight: Weight = .semibold,
                        relativeTo style: Font.TextStyle = .headline) -> Font {
        let name: String
        switch weight {
        case .regular, .medium: name = "VitailDisplay-Medium"
        case .semibold: name = "VitailDisplay-SemiBold"
        case .bold: name = "VitailDisplay-Bold"
        }
        return custom(name, size: size, weight: weight, relativeTo: style)
    }

    /// Work Sans. Scales with Dynamic Type relative to `style`.
    static func body(_ size: CGFloat = 15, _ weight: Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .regular: name = "WorkSans-Regular"
        case .medium: name = "WorkSans-Medium"
        case .semibold: name = "WorkSans-SemiBold"
        case .bold: name = "WorkSans-Bold"
        }
        return custom(name, size: size, weight: weight, relativeTo: style)
    }

    private static func custom(_ name: String, size: CGFloat, weight: Weight,
                               relativeTo style: Font.TextStyle) -> Font {
        _ = registerOnce
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size, relativeTo: style)
        }
        let fallback: Font.Weight
        switch weight {
        case .regular: fallback = .regular
        case .medium: fallback = .medium
        case .semibold: fallback = .semibold
        case .bold: fallback = .bold
        }
        return .system(size: size, weight: fallback, design: .rounded)
    }

    /// Navigation bar titles use Fredoka too. Applied once, on the main actor.
    static let configureBarsOnce: Void = {
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyBarAppearance() }
        } else {
            Task { @MainActor in applyBarAppearance() }
        }
    }()

    @MainActor private static func applyBarAppearance() {
        _ = registerOnce
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppColors.background)
        // Prototype header: paper background, no hairline under the bar.
        appearance.shadowColor = .clear
        let ink = UIColor(AppColors.primaryText)
        // Back button: outlined circle with a chevron, no "Back" text.
        let back = backIndicatorImage()
        appearance.setBackIndicatorImage(back, transitionMaskImage: back)
        let hidden: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear,
                                                     .font: UIFont.systemFont(ofSize: 0.1)]
        appearance.backButtonAppearance.normal.titleTextAttributes = hidden
        appearance.backButtonAppearance.highlighted.titleTextAttributes = hidden
        let buttonFont = UIFont(name: "VitailDisplay-SemiBold", size: 17).map {
            UIFontMetrics(forTextStyle: .body).scaledFont(for: $0)
        }
        if let buttonFont {
            appearance.buttonAppearance.normal.titleTextAttributes = [.font: buttonFont]
            appearance.doneButtonAppearance.normal.titleTextAttributes = [.font: buttonFont]
        }
        if let title = UIFont(name: "VitailDisplay-SemiBold", size: 18) {
            appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: title),
                                              .foregroundColor: ink]
        }
        if let large = UIFont(name: "VitailDisplay-Bold", size: 32) {
            appearance.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                                                   .foregroundColor: ink]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    /// 36 pt outlined circle with a chevron, drawn for light and dark mode.
    @MainActor private static func backIndicatorImage() -> UIImage {
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let ink = UIColor(AppColors.outline).resolvedColor(with: traits)
            let fill = UIColor(AppColors.background).resolvedColor(with: traits)
            let chevronColor = UIColor(AppColors.primaryText).resolvedColor(with: traits)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 36)).image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(x: 7, y: 1, width: 34, height: 34))
                fill.setFill()
                circle.fill()
                ink.setStroke()
                circle.lineWidth = 2
                circle.stroke()
                let chevron = UIBezierPath()
                chevron.move(to: CGPoint(x: 26, y: 12))
                chevron.addLine(to: CGPoint(x: 20, y: 18))
                chevron.addLine(to: CGPoint(x: 26, y: 24))
                chevron.lineWidth = 2.2
                chevron.lineCapStyle = .round
                chevron.lineJoinStyle = .round
                chevronColor.setStroke()
                chevron.stroke()
            }.withRenderingMode(.alwaysOriginal)
            asset.register(image, with: traits)
        }
        return asset.image(with: UITraitCollection.current).withRenderingMode(.alwaysOriginal)
    }
}

extension View {
    func vitailAppearance() -> some View {
        _ = AppFont.configureBarsOnce
        return self
            .tint(AppColors.brand)
            .foregroundStyle(AppColors.primaryText)
            .fontDesign(.rounded)
            .background(AppColors.background)
    }
}

enum AppSpacing {
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32
}

enum AppRadius {
    static let field: CGFloat = 16
    static let card: CGFloat = 20
}

/// Hard offset shadow and outline weight shared by cards and buttons.
enum AppStroke {
    static let width: CGFloat = 2
    static let shadow: CGFloat = 4
}


enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let storageKey = "appearance.selectedMode"
    static let shared = AppearanceSettings()

    @Published var selection: AppAppearance {
        didSet { defaults.set(selection.rawValue, forKey: Self.storageKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.storageKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}

struct AppearanceSettingsSection: View {
    @ObservedObject var settings: AppearanceSettings

    init(settings: AppearanceSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.selection) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.menu)
        }
        .listRowBackground(AppColors.surface)
    }
}
