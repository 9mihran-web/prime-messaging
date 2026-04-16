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
            lastActivityAt: Self.messagesByChatID[currentUserID]?.last?.createdAt ?? .distantPast,
            unreadCount: 0,
            isPinned: false,
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

    func importHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat {
        let targetChatID: UUID
        switch chat.type {
        case .selfChat:
            targetChatID = currentUser.id
        case .direct:
            targetChatID = chat.id
        case .group:
            throw ChatRepositoryError.unsupportedOfflineAction
        case .secret:
            throw ChatRepositoryError.unsupportedOfflineAction
        }

        var mergedByClientMessageID: [UUID: Message] = [:]
        for message in Self.messagesByChatID[targetChatID] ?? [] {
            mergedByClientMessageID[message.clientMessageID] = message
        }
        for message in messages {
            mergedByClientMessageID[message.clientMessageID] = Message(
                id: message.id,
                chatID: targetChatID,
                senderID: message.senderID,
                clientMessageID: message.clientMessageID,
                senderDisplayName: message.senderDisplayName,
                mode: .offline,
                deliveryState: message.deliveryState,
                kind: message.kind,
                text: message.text,
                attachments: message.attachments,
                replyToMessageID: message.replyToMessageID,
                replyPreview: message.replyPreview,
                status: message.status,
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                deletedForEveryoneAt: message.deletedForEveryoneAt,
                reactions: message.reactions,
                voiceMessage: message.voiceMessage,
                liveLocation: message.liveLocation
            )
        }

        let importedChat = Chat(
            id: targetChatID,
            mode: .offline,
            type: chat.type,
            title: chat.title,
            subtitle: chat.subtitle,
            participantIDs: chat.type == .selfChat ? [currentUser.id] : chat.participantIDs,
            participants: chat.participants,
            group: nil,
            lastMessagePreview: mergedByClientMessageID.values.sorted(by: { $0.createdAt < $1.createdAt }).last?.text,
            lastActivityAt: mergedByClientMessageID.values.sorted(by: { $0.createdAt < $1.createdAt }).last?.createdAt ?? .now,
            unreadCount: 0,
            isPinned: chat.isPinned,
            draft: chat.draft,
            disappearingPolicy: chat.disappearingPolicy,
            notificationPreferences: chat.notificationPreferences,
            guestRequest: nil
        )

        Self.chats[targetChatID] = importedChat
        Self.messagesByChatID[targetChatID] = mergedByClientMessageID.values.sorted(by: { $0.createdAt < $1.createdAt })
        return importedChat
    }

    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message {
        try await sendMessage(OutgoingMessageDraft(text: text), in: chat, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        let message = Message(
            id: UUID(),
            chatID: chat.id,
            senderID: senderID,
            clientMessageID: draft.clientMessageID,
            senderDisplayName: senderID == Self.currentUser.id ? Self.currentUser.profile.displayName : chat.title,
            mode: .offline,
            deliveryState: draft.deliveryStateOverride ?? .offline,
            deliveryRoute: chat.type == .selfChat ? nil : .bluetooth,
            kind: resolvedKind(for: draft),
            text: draft.normalizedText,
            attachments: draft.attachments,
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            status: .sent,
            createdAt: draft.createdAt ?? .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: draft.voiceMessage,
            liveLocation: nil
        )

        Self.messagesByChatID[chat.id, default: []].append(message)
        if chat.type != .selfChat {
            var updatedChat = chat
            updatedChat.lastMessagePreview = draft.normalizedText ?? mediaSummary(for: message)
            updatedChat.lastActivityAt = message.createdAt
            Self.chats[chat.id] = updatedChat
        }
        return message
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, userID: UUID) async throws -> Message {
        guard var messages = Self.messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        if let reactionIndex = messages[index].reactions.firstIndex(where: { $0.emoji == emoji }) {
            if messages[index].reactions[reactionIndex].userIDs.contains(userID) {
                messages[index].reactions[reactionIndex].userIDs.removeAll { $0 == userID }
                if messages[index].reactions[reactionIndex].userIDs.isEmpty {
                    messages[index].reactions.remove(at: reactionIndex)
                }
            } else {
                messages[index].reactions[reactionIndex].userIDs.append(userID)
            }
        } else {
            messages[index].reactions.append(
                MessageReaction(id: UUID(), emoji: emoji, userIDs: [userID])
            )
        }

        Self.messagesByChatID[chatID] = messages
        return messages[index]
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, editorID: UUID) async throws -> Message {
        guard var messages = Self.messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID && $0.senderID == editorID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            throw OfflineTransportError.emptyMessage
        }

        messages[index].text = normalizedText
        messages[index].editedAt = .now
        Self.messagesByChatID[chatID] = messages
        refreshChatPreview(chatID: chatID)
        return messages[index]
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, requesterID: UUID) async throws -> Message {
        guard var messages = Self.messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID && $0.senderID == requesterID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        messages[index].text = nil
        messages[index].attachments = []
        messages[index].voiceMessage = nil
        messages[index].deletedForEveryoneAt = .now
        Self.messagesByChatID[chatID] = messages
        refreshChatPreview(chatID: chatID)
        return messages[index]
    }

    func synchronizeArchivedChats(with onlineRepository: ChatRepository, currentUserID: UUID) async { }

    private func resolvedKind(for draft: OutgoingMessageDraft) -> MessageKind {
        if draft.voiceMessage != nil {
            return .voice
        }

        switch draft.attachments.first?.type {
        case .photo:
            return .photo
        case .audio:
            return .audio
        case .video:
            return .video
        case .document:
            return .document
        case .contact:
            return .contact
        case .location:
            return .location
        case nil:
            return .text
        }
    }

    private func mediaSummary(for message: Message) -> String {
        if message.deletedForEveryoneAt != nil {
            return "Message deleted"
        }

        if message.voiceMessage != nil {
            return "Voice message"
        }

        switch message.attachments.first?.type {
        case .photo:
            return "Photo"
        case .audio:
            return "Audio"
        case .video:
            return "Video"
        case .document:
            return "Document"
        case .contact:
            return "Contact"
        case .location:
            return "Location"
        case nil:
            return "Message"
        }
    }

    private func refreshChatPreview(chatID: UUID) {
        guard var chat = Self.chats[chatID] else { return }
        let latestMessage = Self.messagesByChatID[chatID]?.last
        chat.lastMessagePreview = latestMessage?.text ?? mediaSummary(for: latestMessage ?? Message(
            id: UUID(),
            chatID: chatID,
            senderID: Self.currentUser.id,
            senderDisplayName: Self.currentUser.profile.displayName,
            mode: .offline,
            deliveryState: .offline,
            kind: .text,
            text: nil,
            attachments: [],
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: .now,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        ))
        chat.lastActivityAt = latestMessage?.createdAt ?? chat.lastActivityAt
        Self.chats[chatID] = chat
    }
}
