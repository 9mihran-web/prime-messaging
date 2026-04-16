import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case arabic = "ar"
    case armenian = "hy"
    case french = "fr"
    case german = "de"
    case english = "en"
    case italian = "it"
    case korean = "ko"
    case portuguese = "pt"
    case russian = "ru"
    case spanish = "es"
    case ukrainian = "uk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arabic:
            return "العربية"
        case .armenian:
            return "Հայերեն"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .english:
            return "English"
        case .italian:
            return "Italiano"
        case .korean:
            return "한국어"
        case .portuguese:
            return "Português"
        case .russian:
            return "Русский"
        case .spanish:
            return "Español"
        case .ukrainian:
            return "Українська"
        }
    }
}
