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

    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws {
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
                        displayName: memberID == ownerID ? "Prime User" : "Prime Contact",
                        username: memberID == ownerID ? "primeuser" : "primecontact",
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

    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedChat.title = normalizedTitle.isEmpty ? chat.title : normalizedTitle
        updatedChat.group?.title = updatedChat.title
        updatedChat.subtitle = "\(updatedChat.group?.members.count ?? updatedChat.participantIDs.count) members"
        return updatedChat
    }

    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("PrimeMessagingGroupAvatars", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let avatarURL = directoryURL.appendingPathComponent("\(chat.id.uuidString).jpg")
        try imageData.write(to: avatarURL, options: .atomic)
        updatedChat.group?.photoURL = avatarURL
        return updatedChat
    }

    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        updatedChat.group?.photoURL = nil
        return updatedChat
    }

    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        guard var group = updatedChat.group else { return updatedChat }

        for memberID in memberIDs where updatedChat.participantIDs.contains(memberID) == false {
            updatedChat.participantIDs.append(memberID)
            group.members.append(
                GroupMember(
                    id: UUID(),
                    userID: memberID,
                    displayName: "Prime Contact",
                    username: "primecontact",
                    role: .member,
                    joinedAt: .now
                )
            )
        }

        updatedChat.group = group
        updatedChat.subtitle = "\(group.members.count) members"
        return updatedChat
    }

    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        guard var group = updatedChat.group else { return updatedChat }
        guard group.ownerID != memberID else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        updatedChat.participantIDs.removeAll { $0 == memberID }
        group.members.removeAll { $0.userID == memberID }
        updatedChat.group = group
        updatedChat.subtitle = "\(group.members.count) members"
        return updatedChat
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
