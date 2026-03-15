import Foundation

struct Chat: Identifiable, Codable, Hashable {
    let id: UUID
    var mode: ChatMode
    var type: ChatType
    var title: String
    var subtitle: String
    var participantIDs: [UUID]
    var group: Group?
    var lastMessagePreview: String?
    var lastActivityAt: Date
    var unreadCount: Int
    var isPinned: Bool
    var draft: Draft?
    var disappearingPolicy: DisappearingMessagePolicy?
    var notificationPreferences: NotificationPreferences
}

struct Group: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var photoURL: URL?
    var ownerID: UUID
    var members: [GroupMember]
}

struct GroupMember: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    var role: GroupMemberRole
    var joinedAt: Date
}

struct Draft: Identifiable, Codable, Hashable {
    let id: UUID
    var chatID: UUID
    var mode: ChatMode
    var text: String
    var updatedAt: Date
}

struct NotificationPreferences: Codable, Hashable {
    var muteState: ChatMuteState
    var previewEnabled: Bool
    var customSoundName: String?
    var badgeEnabled: Bool
}

extension Chat {
    var resolvedDisplayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == .direct else {
            return trimmedTitle.isEmpty ? title : trimmedTitle
        }

        let isGenericTitle = trimmedTitle.isEmpty || trimmedTitle.caseInsensitiveCompare("Direct Chat") == .orderedSame
        guard isGenericTitle else {
            return trimmedTitle
        }

        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubtitle.hasPrefix("@") {
            return String(trimmedSubtitle.dropFirst())
        }

        if !trimmedSubtitle.isEmpty && trimmedSubtitle.caseInsensitiveCompare("Direct conversation") != .orderedSame {
            return trimmedSubtitle
        }

        return "Chat"
    }

    static func mock(mode: ChatMode, currentUserID: UUID) -> [Chat] {
        return [
            Chat(
                id: UUID(),
                mode: mode,
                type: .selfChat,
                title: "Saved Messages",
                subtitle: "Notes, links, and drafts",
                participantIDs: [currentUserID],
                group: nil,
                lastMessagePreview: "Product notes for Prime Messaging",
                lastActivityAt: .now,
                unreadCount: 0,
                isPinned: true,
                draft: nil,
                disappearingPolicy: nil,
                notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
            )
        ]
    }
}
