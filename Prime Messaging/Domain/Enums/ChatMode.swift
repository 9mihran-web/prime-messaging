import Foundation

enum ChatMode: String, Codable, CaseIterable, Identifiable {
    case smart
    case online
    case offline

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .smart:
            return "mode.smart"
        case .online:
            return "mode.online"
        case .offline:
            return "mode.offline"
        }
    }

    var subtitleKey: String {
        switch self {
        case .smart:
            return "mode.smart.subtitle"
        case .online:
            return "mode.online.subtitle"
        case .offline:
            return "mode.offline.subtitle"
        }
    }
}
