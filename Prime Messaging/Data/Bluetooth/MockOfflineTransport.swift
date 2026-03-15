import Foundation

struct MockOfflineTransport: OfflineTransporting {
    private static var currentUser = User.mockCurrentUser
    private static var chats: [UUID: Chat] = [:]
    private static var messagesByChatID: [UUID: [Message]] = [:]

    func updateCurrentUser(_ user: User) async {
        Self.currentUser = user
    }

    func startScanning() async { }
    func stopScanning() async { }

    func discoveredPeers() async -> [OfflinePeer] {
        []
    }

    func connect(to peer: OfflinePeer) async throws -> BluetoothSession {
        BluetoothSession(id: UUID(), peerID: peer.id, state: .connected, negotiatedMTU: 180, lastActivityAt: .now)
    }

    func fetchChats(currentUserID: UUID) async -> [Chat] {
        let savedMessages = Chat(
            id: currentUserID,
            mode: .offline,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [currentUserID],
            group: nil,
            lastMessagePreview: Self.messagesByChatID[currentUserID]?.last?.text,
            lastActivityAt: Self.messagesByChatID[currentUserID]?.last?.createdAt ?? .now,
            unreadCount: 0,
            isPinned: true,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )

        let otherChats = Self.chats.values.filter { $0.id != currentUserID }
        return [savedMessages] + otherChats.sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
    }

    func openChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        let chatID = UUID()
        let chat = Chat(
            id: chatID,
            mode: .offline,
            type: .direct,
            title: peer.displayName,
            subtitle: "@\(peer.alias)",
            participantIDs: [currentUser.id, peer.id],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: false,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )
        Self.chats[chatID] = chat
        Self.messagesByChatID[chatID] = Self.messagesByChatID[chatID] ?? []
        return chat
    }

    func fetchMessages(chatID: UUID) async -> [Message] {
        Self.messagesByChatID[chatID] ?? []
    }

    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message {
        let message = Message(
            id: UUID(),
            chatID: chat.id,
            senderID: senderID,
            mode: .offline,
            kind: .text,
            text: text,
            attachments: [],
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )

        Self.messagesByChatID[chat.id, default: []].append(message)
        if chat.type != .selfChat {
            var updatedChat = chat
            updatedChat.lastMessagePreview = text
            updatedChat.lastActivityAt = message.createdAt
            Self.chats[chat.id] = updatedChat
        }
        return message
    }
}
