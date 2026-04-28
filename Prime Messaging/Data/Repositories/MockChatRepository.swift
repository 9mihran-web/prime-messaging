import Foundation

struct MockChatRepository: ChatRepository {
    let localStore: LocalStore

    func cachedChats(mode: ChatMode, for userID: UUID) async -> [Chat] {
        let cached = await localStore.loadChats(for: mode)
        if cached.isEmpty == false {
            return cached.map(clearingMockDraft)
        }
        return Chat.mock(mode: mode, currentUserID: userID).map(clearingMockDraft)
    }

    func cachedMessages(chatID: UUID, mode: ChatMode) async -> [Message] {
        if mode == .online {
            return []
        }
        return Message.mock(chatID: chatID, mode: mode, currentUserID: User.mockCurrentUser.id)
    }

    func purgeLocalChatArtifacts(chatIDs: [UUID], currentUserID: UUID) async {
        _ = currentUserID
        guard chatIDs.isEmpty == false else { return }
        let chatIDSet = Set(chatIDs)
        var chats = await localStore.loadChats(for: .online)
        chats.removeAll { chatIDSet.contains($0.id) }
        await localStore.saveChats(chats, for: .online)
    }

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

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        try await sendMessage(draft, in: chat.id, mode: chat.mode, senderID: senderID)
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
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: draft.voiceMessage,
            liveLocation: nil
        )
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, mode: ChatMode, userID: UUID) async throws -> Message {
        Message(
            id: messageID,
            chatID: chatID,
            senderID: userID,
            senderDisplayName: userID == User.mockCurrentUser.id ? "Prime User" : "Prime Contact",
            mode: mode,
            kind: .text,
            text: "Mock reaction update",
            attachments: [],
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [
                MessageReaction(
                    id: UUID(),
                    emoji: emoji,
                    userIDs: [userID]
                )
            ],
            voiceMessage: nil,
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
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true),
            guestRequest: nil
        )
    }

    func importExternalHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat {
        let normalizedMessages = messages.map { message in
            Message(
                id: message.id,
                chatID: chat.id,
                senderID: message.senderID,
                clientMessageID: message.clientMessageID,
                senderDisplayName: message.senderDisplayName,
                mode: chat.mode,
                deliveryState: .migrated,
                kind: message.kind,
                text: message.text,
                attachments: message.attachments,
                replyToMessageID: message.replyToMessageID,
                replyPreview: message.replyPreview,
                communityContext: message.communityContext,
                deliveryOptions: message.deliveryOptions,
                status: .sent,
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                deletedForEveryoneAt: message.deletedForEveryoneAt,
                reactions: message.reactions,
                voiceMessage: message.voiceMessage,
                liveLocation: message.liveLocation
            )
        }

        await ChatSnapshotStore.shared.saveMessages(
            normalizedMessages,
            chatID: chat.id,
            userID: currentUser.id,
            mode: chat.mode
        )

        var updatedChat = chat
        if let latestMessage = normalizedMessages.last {
            updatedChat.lastActivityAt = latestMessage.createdAt
            updatedChat.lastMessagePreview = latestMessage.text ?? resolvedKind(for: OutgoingMessageDraft(attachments: latestMessage.attachments, voiceMessage: latestMessage.voiceMessage)).rawValue.capitalized
        }

        await ChatSnapshotStore.shared.upsertChat(updatedChat, userID: currentUser.id, mode: chat.mode)
        return updatedChat
    }

    func submitGuestRequest(introText: String, in chatID: UUID, senderID: UUID) async throws -> Chat {
        try await updateOnlineChat(chatID: chatID) { chat in
            let recipientID = chat.participantIDs.first(where: { $0 != senderID }) ?? senderID
            let existingCreatedAt = chat.guestRequest?.createdAt ?? .now
            chat.guestRequest = GuestRequest(
                requesterUserID: senderID,
                recipientUserID: recipientID,
                status: .pending,
                introText: introText.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: existingCreatedAt,
                respondedAt: nil
            )
            chat.lastMessagePreview = "Guest request sent"
            chat.lastActivityAt = .now
        }
    }

    func respondToGuestRequest(in chatID: UUID, approve: Bool, responderID: UUID) async throws -> Chat {
        try await updateOnlineChat(chatID: chatID) { chat in
            guard var guestRequest = chat.guestRequest else {
                throw ChatRepositoryError.invalidDirectChat
            }
            guard guestRequest.recipientUserID == responderID else {
                throw ChatRepositoryError.groupPermissionDenied
            }
            guestRequest.status = approve ? .approved : .declined
            guestRequest.respondedAt = .now
            chat.guestRequest = approve ? nil : guestRequest
            chat.lastMessagePreview = approve ? nil : "Guest request declined"
            chat.lastActivityAt = .now
        }
    }

    func createGroupChat(
        title: String,
        memberIDs: [UUID],
        ownerID: UUID,
        mode: ChatMode,
        communityDetails: CommunityChatDetails?
    ) async throws -> Chat {
        let groupID = UUID()
        let participantIDs = Array(Set([ownerID] + memberIDs))
        let memberCountText: String
        if communityDetails?.kind == .channel {
            memberCountText = "\(participantIDs.count) subscribers"
        } else {
            memberCountText = "\(participantIDs.count) members"
        }
        return Chat(
            id: groupID,
            mode: mode,
            type: .group,
            title: title,
            subtitle: memberCountText,
            participantIDs: participantIDs,
            group: Group(
                id: groupID,
                title: title,
                photoURL: nil,
                ownerID: ownerID,
                members: participantIDs.map { memberID in
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
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true),
            guestRequest: nil,
            eventDetails: nil,
            communityDetails: communityDetails
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

    func deleteGroup(_ chat: Chat, requesterID: UUID) async throws {
        guard let group = chat.group else {
            throw ChatRepositoryError.invalidGroupOperation
        }
        guard group.ownerID == requesterID else {
            throw ChatRepositoryError.groupPermissionDenied
        }

        var chats = await localStore.loadChats(for: .online)
        guard chats.contains(where: { $0.id == chat.id }) else {
            throw ChatRepositoryError.chatNotFound
        }
        chats.removeAll { $0.id == chat.id }
        await localStore.saveChats(chats, for: .online)
    }

    func updateCommunityDetails(_ details: CommunityChatDetails, for chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        updatedChat.communityDetails = details
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

    func updateMemberRole(_ role: GroupMemberRole, for memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        guard var group = updatedChat.group else { return updatedChat }
        guard group.ownerID == requesterID else {
            throw ChatRepositoryError.groupPermissionDenied
        }
        guard let index = group.members.firstIndex(where: { $0.userID == memberID }) else {
            throw ChatRepositoryError.userNotFound
        }
        guard group.members[index].userID != group.ownerID else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        group.members[index].role = role
        updatedChat.group = group
        return updatedChat
    }

    func transferGroupOwnership(to memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        guard var group = updatedChat.group else { return updatedChat }
        guard group.ownerID == requesterID else {
            throw ChatRepositoryError.groupPermissionDenied
        }
        guard let newOwnerIndex = group.members.firstIndex(where: { $0.userID == memberID }) else {
            throw ChatRepositoryError.userNotFound
        }
        guard memberID != requesterID else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        if let previousOwnerIndex = group.members.firstIndex(where: { $0.userID == requesterID }) {
            group.members[previousOwnerIndex].role = .admin
        }
        group.ownerID = memberID
        group.members[newOwnerIndex].role = .owner
        updatedChat.group = group
        return updatedChat
    }

    func leaveGroup(_ chat: Chat, requesterID: UUID) async throws {
        guard var group = chat.group else { return }
        guard group.ownerID != requesterID else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        group.members.removeAll { $0.userID == requesterID }

        var chats = await localStore.loadChats(for: .online)
        chats.removeAll { $0.id == chat.id }
        await localStore.saveChats(chats, for: .online)
    }

    func searchDiscoverableChats(query: String, mode: ChatMode, currentUserID: UUID) async throws -> [Chat] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return [] }

        let chats = await localStore.loadChats(for: .online)
        return chats.filter { chat in
            guard chat.communityDetails?.isPublic == true else { return false }
            guard chat.participantIDs.contains(currentUserID) == false else { return true }
            return chat.displayTitle(for: currentUserID).localizedCaseInsensitiveContains(trimmedQuery)
                || chat.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func joinDiscoverableChat(_ chat: Chat, requesterID: UUID) async throws -> Chat {
        var updatedChat = chat
        if updatedChat.participantIDs.contains(requesterID) == false {
            updatedChat.participantIDs.append(requesterID)
            if var group = updatedChat.group {
                group.members.append(
                    GroupMember(
                        id: UUID(),
                        userID: requesterID,
                        displayName: "Prime User",
                        username: "primeuser",
                        role: .member,
                        joinedAt: .now
                    )
                )
                updatedChat.group = group
                if updatedChat.communityDetails?.kind == .channel {
                    updatedChat.subtitle = "\(group.members.count) subscribers"
                } else {
                    updatedChat.subtitle = "\(group.members.count) members"
                }
            }
        }
        return updatedChat
    }

    func joinChat(inviteCode: String, mode: ChatMode, requesterID: UUID) async throws -> Chat {
        let chats = await localStore.loadChats(for: .online)
        guard let chat = chats.first(where: { $0.communityDetails?.inviteCode?.caseInsensitiveCompare(inviteCode) == .orderedSame }) else {
            throw ChatRepositoryError.chatNotFound
        }
        return try await joinDiscoverableChat(chat, requesterID: requesterID)
    }

    func submitJoinRequest(for chat: Chat, requesterID: UUID, answers: [String]) async throws {
        _ = chat
        _ = requesterID
        _ = answers
    }

    func fetchModerationDashboard(for chat: Chat, requesterID: UUID) async throws -> ModerationDashboard {
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func resolveJoinRequest(
        for requesterUserID: UUID,
        approve: Bool,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = requesterUserID
        _ = approve
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func reportChatContent(
        in chat: Chat,
        requesterID: UUID,
        targetMessageID: UUID?,
        targetUserID: UUID?,
        reason: ModerationReportReason,
        details: String?
    ) async throws {
        _ = chat
        _ = requesterID
        _ = targetMessageID
        _ = targetUserID
        _ = reason
        _ = details
    }

    func banMember(
        _ memberID: UUID,
        duration: TimeInterval,
        reason: String?,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = memberID
        _ = duration
        _ = reason
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func removeBan(
        for memberID: UUID,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = memberID
        _ = chat
        _ = requesterID
        return ModerationDashboard()
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
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true),
            guestRequest: nil
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

    private func updateOnlineChat(chatID: UUID, mutate: (inout Chat) throws -> Void) async throws -> Chat {
        var chats = await localStore.loadChats(for: .online)
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else {
            throw ChatRepositoryError.chatNotFound
        }
        try mutate(&chats[index])
        await localStore.saveChats(chats, for: .online)
        return chats[index]
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
