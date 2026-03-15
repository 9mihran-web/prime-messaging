import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case armenian = "hy"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .armenian:
            return "Հայերեն"
        case .english:
            return "English"
        }
    }
}
