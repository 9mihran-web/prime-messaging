import Foundation

struct AppChatRepository: ChatRepository {
    let onlineRepository: ChatRepository
    let offlineTransport: OfflineTransporting

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        switch mode {
        case .online:
            do {
                return try await onlineRepository.fetchChats(mode: mode, for: userID)
            } catch {
                return [makeSavedMessagesChat(for: userID, mode: .online)]
            }
        case .offline:
            return await offlineTransport.fetchChats(currentUserID: userID)
        }
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        switch mode {
        case .online:
            return try await onlineRepository.fetchMessages(chatID: chatID, mode: mode)
        case .offline:
            return await offlineTransport.fetchMessages(chatID: chatID)
        }
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        switch mode {
        case .online:
            return try await onlineRepository.sendMessage(text, in: chatID, mode: mode, senderID: senderID)
        case .offline:
            let chats = await offlineTransport.fetchChats(currentUserID: senderID)
            guard let chat = chats.first(where: { $0.id == chatID }) else {
                throw OfflineTransportError.chatUnavailable
            }
            return try await offlineTransport.sendMessage(text, in: chat, senderID: senderID)
        }
    }

    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat {
        switch mode {
        case .online:
            return try await onlineRepository.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: mode)
        case .offline:
            throw OfflineTransportError.nearbySelectionRequired
        }
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        try await offlineTransport.openChat(with: peer, currentUser: currentUser)
    }

    func saveDraft(_ draft: Draft) async throws {
        try await onlineRepository.saveDraft(draft)
    }

    private func makeSavedMessagesChat(for userID: UUID, mode: ChatMode) -> Chat {
        Chat(
            id: userID,
            mode: mode,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [userID],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: true,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )
    }
}
