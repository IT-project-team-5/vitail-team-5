import SwiftUI
import UIKit

enum AppColors {
    // The icon's honey gold is decorative. Interactive gold is darker in light
    // mode so small text and white button labels remain readable.
    static let brand = adaptive(light: 0x8A561C, dark: 0xE3AD58)
    static let brandForeground = adaptive(light: 0xFFFFFF, dark: 0x281A0D)
    static let background = adaptive(light: 0xFFF8EA, dark: 0x211B15)
    static let surface = adaptive(light: 0xFFFDF7, dark: 0x30261D)
    static let primaryText = adaptive(light: 0x432D1B, dark: 0xFFF2DB)
    static let secondaryText = adaptive(light: 0x786149, dark: 0xD4BFA0)
    static let border = adaptive(light: 0xDDC9A9, dark: 0x685440)
    // Status colors stay distinct from the brand. Never rely on color alone.
    static let warning = adaptive(light: 0x8C5900, dark: 0xF2C36B)
    static let success = adaptive(light: 0x286241, dark: 0x90CF9F)
    static let information = adaptive(light: 0x23648C, dark: 0x8EC5EA)
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

extension View {
    func vitailAppearance() -> some View {
        self
            .tint(AppColors.brand)
            .foregroundStyle(AppColors.primaryText)
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
    static let field: CGFloat = 12
    static let card: CGFloat = 16
}
