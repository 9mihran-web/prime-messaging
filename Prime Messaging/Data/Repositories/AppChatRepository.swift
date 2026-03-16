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
        try await sendMessage(OutgoingMessageDraft(text: text), in: chatID, mode: mode, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        switch mode {
        case .online:
            return try await onlineRepository.sendMessage(draft, in: chatID, mode: mode, senderID: senderID)
        case .offline:
            let chats = await offlineTransport.fetchChats(currentUserID: senderID)
            guard let chat = chats.first(where: { $0.id == chatID }) else {
                throw OfflineTransportError.chatUnavailable
            }
            return try await offlineTransport.sendMessage(draft, in: chat, senderID: senderID)
        }
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message {
        switch mode {
        case .online:
            return try await onlineRepository.editMessage(messageID, text: text, in: chatID, mode: mode, editorID: editorID)
        case .offline:
            return try await offlineTransport.editMessage(messageID, text: text, in: chatID, editorID: editorID)
        }
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message {
        switch mode {
        case .online:
            return try await onlineRepository.deleteMessage(messageID, in: chatID, mode: mode, requesterID: requesterID)
        case .offline:
            return try await offlineTransport.deleteMessage(messageID, in: chatID, requesterID: requesterID)
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

    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat {
        switch mode {
        case .online:
            return try await onlineRepository.createGroupChat(title: title, memberIDs: memberIDs, ownerID: ownerID, mode: mode)
        case .offline:
            throw OfflineTransportError.nearbySelectionRequired
        }
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
