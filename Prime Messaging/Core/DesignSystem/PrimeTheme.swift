import SwiftUI

enum PrimeTheme {
    enum Colors {
        static let accent = Color(red: 0.55, green: 0.08, blue: 0.12)
        static let accentSoft = Color(red: 0.72, green: 0.22, blue: 0.24)
        static let smartAccent = Color(red: 0.14, green: 0.38, blue: 0.86)
        static let background = Color(uiColor: UIColor { traitCollection in
            #if os(tvOS)
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
            }
            return UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
            #else
            return UIColor.systemBackground
            #endif
        })
        static let elevated = Color(uiColor: UIColor { traitCollection in
            #if os(tvOS)
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
            }
            return UIColor(red: 0.89, green: 0.89, blue: 0.91, alpha: 1)
            #else
            return UIColor.secondarySystemBackground
            #endif
        })
        static let chatWallpaperBase = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.06, green: 0.05, blue: 0.05, alpha: 1)
            }
            return UIColor(red: 0.985, green: 0.986, blue: 0.982, alpha: 1)
        })
        static let chatWallpaperStroke = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.83, green: 0.76, blue: 0.67, alpha: 0.58)
            }
            return UIColor(red: 0.37, green: 0.46, blue: 0.58, alpha: 0.48)
        })
        static let chatWallpaperOverlay = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor.black.withAlphaComponent(0.16)
            }
            return UIColor.white.withAlphaComponent(0.26)
        })
        static let bubbleOutgoing = Color(red: 0.66, green: 0.25, blue: 0.29)
        static let bubbleIncoming = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.19, green: 0.22, blue: 0.27, alpha: 1)
            }
            return UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
        })
        static let voiceOutgoingSurface = Color(red: 0.91, green: 0.98, blue: 0.82)
        static let voiceOutgoingSurfaceOffline = Color(red: 0.83, green: 0.89, blue: 0.75)
        static let voiceOutgoingSurfaceSyncing = Color(red: 0.87, green: 0.94, blue: 0.78)
        static let voiceOutgoingAccent = Color(red: 0.24, green: 0.78, blue: 0.20)
        static let voiceOutgoingText = Color(red: 0.19, green: 0.63, blue: 0.17)
        static let voiceIncomingSurface = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.21, green: 0.24, blue: 0.29, alpha: 1)
            }
            return UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1)
        })
        static let voiceIncomingAccent = Color(red: 0.36, green: 0.47, blue: 0.60)
        static let voiceIncomingText = Color(red: 0.30, green: 0.39, blue: 0.51)
        static let bubbleSmartOffline = Color(red: 0.23, green: 0.25, blue: 0.28)
        static let bubbleSmartOnline = accent
        static let bubbleSmartMigrated = smartAccent
        static let bubbleSmartSyncing = Color(red: 0.35, green: 0.38, blue: 0.46)
        static let bubbleIncomingBorder = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor.separator.withAlphaComponent(0.18)
            }
            return UIColor(red: 0.76, green: 0.79, blue: 0.84, alpha: 1)
        })
        static let glassTint = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.05)
            }
            return UIColor.white.withAlphaComponent(0.42)
        })
        static let glassStroke = Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.14)
            }
            return UIColor.white.withAlphaComponent(0.62)
        })
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
