import SwiftUI

enum AppColors {
    static let brand = Color(red: 0.13, green: 0.49, blue: 0.31)
    static let brandForeground = Color.white
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let error = Color(uiColor: .systemRed)
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
