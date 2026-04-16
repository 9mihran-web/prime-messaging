import Foundation

enum IdentityMethodType: String, Codable, CaseIterable {
    case email
    case phone
    case username
    case qrCode
}

enum AccountKind: String, Codable, CaseIterable {
    case standard
    case offlineOnly
    case guest
}

enum GuestMessageRequestPolicy: String, Codable, CaseIterable {
    case approvalRequired
    case blocked
}

enum GuestRequestStatus: String, Codable, CaseIterable {
    case pending
    case approved
    case declined
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

enum MessageDeliveryState: String, Codable, CaseIterable {
    case offline
    case online
    case syncing
    case migrated
}

enum MessageDeliveryRoute: String, Codable, CaseIterable {
    case online
    case bluetooth
    case localNetwork
    case meshRelay
    case queued
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

    var suppressesNotifications: Bool {
        self != .active
    }
}

enum BluetoothSessionState: String, Codable {
    case idle
    case scanning
    case connecting
    case connected
    case interrupted
    case disconnected
}

enum EmergencyModeStatus: String, Codable, CaseIterable {
    case safe
    case needHelp
    case peopleNearby

    var title: String {
        switch self {
        case .safe:
            return "I'm safe"
        case .needHelp:
            return "Need help"
        case .peopleNearby:
            return "People here"
        }
    }

    var systemImage: String {
        switch self {
        case .safe:
            return "checkmark.shield.fill"
        case .needHelp:
            return "cross.case.fill"
        case .peopleNearby:
            return "person.3.fill"
        }
    }

    var profileStatusText: String {
        switch self {
        case .safe:
            return "I'm safe"
        case .needHelp:
            return "Need help"
        case .peopleNearby:
            return "There are people here"
        }
    }
}
