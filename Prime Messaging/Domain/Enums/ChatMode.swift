import Foundation

enum ChatMode: String, Codable, CaseIterable, Identifiable {
    case online
    case offline

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .online:
            return "mode.online"
        case .offline:
            return "mode.offline"
        }
    }

    var subtitleKey: String {
        switch self {
        case .online:
            return "mode.online.subtitle"
        case .offline:
            return "mode.offline.subtitle"
        }
    }
}
