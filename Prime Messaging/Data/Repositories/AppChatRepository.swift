import Foundation

struct AppChatRepository: ChatRepository {
    let onlineRepository: ChatRepository
    let offlineTransport: OfflineTransporting

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        let chats: [Chat]
        switch mode {
        case .online:
            chats = try await onlineRepository.fetchChats(mode: mode, for: userID)
        case .offline:
            chats = await offlineTransport.fetchChats(currentUserID: userID)
        }

        return await chats.asyncMap { chat in
            await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: userID)
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

    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws {
        switch mode {
        case .online:
            try await onlineRepository.markChatRead(chatID: chatID, mode: mode, readerID: readerID)
        case .offline:
            return
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
            let chat = try await onlineRepository.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: mode)
            return await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: currentUserID)
        case .offline:
            throw OfflineTransportError.nearbySelectionRequired
        }
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        let chat = try await offlineTransport.openChat(with: peer, currentUser: currentUser)
        return await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: currentUser.id)
    }

    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat {
        switch mode {
        case .online:
            return try await onlineRepository.createGroupChat(title: title, memberIDs: memberIDs, ownerID: ownerID, mode: mode)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .online:
            return try await onlineRepository.updateGroup(chat, title: title, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .online:
            return try await onlineRepository.uploadGroupAvatar(imageData: imageData, for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .online:
            return try await onlineRepository.removeGroupAvatar(for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .online:
            return try await onlineRepository.addMembers(memberIDs, to: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .online:
            return try await onlineRepository.removeMember(memberID, from: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func saveDraft(_ draft: Draft) async throws {
        try await onlineRepository.saveDraft(draft)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)

        for element in self {
            results.append(await transform(element))
        }

        return results
    }
}
