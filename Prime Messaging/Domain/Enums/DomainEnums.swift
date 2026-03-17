import Foundation

enum IdentityMethodType: String, Codable, CaseIterable {
    case email
    case phone
    case username
    case qrCode
}

enum ChatType: String, Codable {
    case direct
    case group
    case selfChat
    case secret
}

enum GroupMemberRole: String, Codable, CaseIterable {
    case owner
    case admin
    case member

    var localizationKey: String {
        switch self {
        case .owner:
            return "group.role.owner"
        case .admin:
            return "group.role.admin"
        case .member:
            return "group.role.member"
        }
    }
}

enum MessageKind: String, Codable {
    case text
    case photo
    case video
    case document
    case audio
    case voice
    case contact
    case location
    case liveLocation
    case system
}

enum MessageStatus: String, Codable, CaseIterable {
    case localPending
    case sending
    case sent
    case delivered
    case read
    case failed
}

enum AttachmentType: String, Codable {
    case photo
    case video
    case document
    case audio
    case contact
    case location
}

enum PresenceState: String, Codable {
    case online
    case offline
    case recently
    case lastSeen
}

enum ChatMuteState: String, Codable {
    case active
    case mutedTemporarily
    case mutedPermanently
}

enum BluetoothSessionState: String, Codable {
    case idle
    case scanning
    case connecting
    case connected
    case interrupted
    case disconnected
}
