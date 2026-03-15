import Foundation

struct MockChatRepository: ChatRepository {
    let localStore: LocalStore

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        let cached = await localStore.loadChats(for: mode)
        if !cached.isEmpty {
            let normalized = cached.map(clearingMockDraft)
            await localStore.saveChats(normalized, for: mode)
            return normalized
        }

        let generated = Chat.mock(mode: mode, currentUserID: userID).map(clearingMockDraft)
        await localStore.saveChats(generated, for: mode)
        return generated
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        if mode == .online {
            return []
        }

        return Message.mock(chatID: chatID, mode: mode, currentUserID: User.mockCurrentUser.id)
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        Message(
            id: UUID(),
            chatID: chatID,
            senderID: senderID,
            mode: mode,
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
    }

    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat {
        Chat(
            id: UUID(),
            mode: mode,
            type: .direct,
            title: "New Chat",
            subtitle: "Started just now",
            participantIDs: [currentUserID, otherUserID],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: false,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        Chat(
            id: UUID(),
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
    }

    func saveDraft(_ draft: Draft) async throws {
        await localStore.saveDraft(draft)
    }

    private func clearingMockDraft(_ chat: Chat) -> Chat {
        var chat = chat
        chat.draft = nil
        return chat
    }
}
