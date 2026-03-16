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
        try await sendMessage(OutgoingMessageDraft(text: text), in: chatID, mode: mode, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        Message(
            id: UUID(),
            chatID: chatID,
            senderID: senderID,
            senderDisplayName: senderID == User.mockCurrentUser.id ? "Prime User" : "Prime Contact",
            mode: mode,
            kind: resolvedKind(for: draft),
            text: draft.normalizedText,
            attachments: draft.attachments,
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: draft.voiceMessage,
            liveLocation: nil
        )
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message {
        Message(
            id: messageID,
            chatID: chatID,
            senderID: editorID,
            senderDisplayName: editorID == User.mockCurrentUser.id ? "Prime User" : "Prime Contact",
            mode: mode,
            kind: .text,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: [],
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: .now,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message {
        Message(
            id: messageID,
            chatID: chatID,
            senderID: requesterID,
            senderDisplayName: requesterID == User.mockCurrentUser.id ? "Prime User" : "Prime Contact",
            mode: mode,
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

    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat {
        let groupID = UUID()
        return Chat(
            id: groupID,
            mode: mode,
            type: .group,
            title: title,
            subtitle: "\(memberIDs.count + 1) members",
            participantIDs: [ownerID] + memberIDs,
            group: Group(
                id: groupID,
                title: title,
                photoURL: nil,
                ownerID: ownerID,
                members: ([ownerID] + memberIDs).map { memberID in
                    GroupMember(
                        id: UUID(),
                        userID: memberID,
                        role: memberID == ownerID ? .owner : .member,
                        joinedAt: .now
                    )
                }
            ),
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

    private func resolvedKind(for draft: OutgoingMessageDraft) -> MessageKind {
        if draft.voiceMessage != nil {
            return .voice
        }

        if let firstAttachment = draft.attachments.first {
            switch firstAttachment.type {
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
            }
        }

        return .text
    }
}
