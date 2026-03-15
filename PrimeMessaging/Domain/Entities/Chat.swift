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
    static func mock(mode: ChatMode, currentUserID: UUID) -> [Chat] {
        let otherUser = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        let offlinePeer = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

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
            ),
            Chat(
                id: UUID(),
                mode: mode,
                type: .direct,
                title: mode == .online ? "Mariam Petrosyan" : "Nearby: Mariam",
                subtitle: mode == .online ? "last seen recently" : "reachable over Bluetooth",
                participantIDs: [currentUserID, mode == .online ? otherUser : offlinePeer],
                group: nil,
                lastMessagePreview: mode == .online ? "Let's finalize the launch copy." : "I am in the next room.",
                lastActivityAt: .now.addingTimeInterval(-1_800),
                unreadCount: 2,
                isPinned: false,
                draft: Draft(id: UUID(), chatID: UUID(), mode: mode, text: "Draft message...", updatedAt: .now.addingTimeInterval(-1_200)),
                disappearingPolicy: mode == .offline ? DisappearingMessagePolicy(durationSeconds: 3600, startsOnRead: true) : nil,
                notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
            )
        ]
    }
}
