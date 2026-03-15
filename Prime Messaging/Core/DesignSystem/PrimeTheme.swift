import SwiftUI

enum PrimeTheme {
    enum Colors {
        static let accent = Color(red: 0.55, green: 0.08, blue: 0.12)
        static let accentSoft = Color(red: 0.72, green: 0.22, blue: 0.24)
        static let background = Color(uiColor: .systemBackground)
        static let elevated = Color(uiColor: .secondarySystemBackground)
        static let bubbleOutgoing = Color(red: 0.56, green: 0.09, blue: 0.13)
        static let bubbleIncoming = Color(uiColor: .tertiarySystemBackground)
        static let offlineAccent = Color(red: 0.18, green: 0.20, blue: 0.22)
        static let separator = Color(uiColor: .separator)
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)
        static let success = Color.green
        static let warning = Color.orange
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 18
        static let bubble: CGFloat = 20
        static let pill: CGFloat = 999
    }
}
