import Foundation

struct AppChatRepository: ChatRepository {
    let onlineRepository: ChatRepository
    let offlineTransport: OfflineTransporting

    func cachedChats(mode: ChatMode, for userID: UUID) async -> [Chat] {
        let snapshotChats = await ChatSnapshotStore.shared.loadChats(userID: userID, mode: mode)
        let sharedSnapshotChats = await ChatSnapshotStore.shared.loadSharedChats(userID: userID)
        let mergedVisibleChats: [Chat]
        switch mode {
        case .smart:
            let cached = await cachedSmartChats(for: userID)
            let modeScoped = mergeChatSnapshots(primary: cached, fallback: snapshotChats)
            mergedVisibleChats =
                mergeVisibleChatSnapshots(
                    primary: modeScoped,
                    fallback: sharedSnapshotChats,
                    currentUserID: userID,
                    visibleMode: mode
                )
        case .online:
            let cached = await onlineRepository.cachedChats(mode: .online, for: userID)
            let modeScoped = mergeChatSnapshots(primary: cached, fallback: snapshotChats)
            mergedVisibleChats =
                mergeVisibleChatSnapshots(
                    primary: modeScoped,
                    fallback: sharedSnapshotChats,
                    currentUserID: userID,
                    visibleMode: mode
                )
        case .offline:
            let cached = await offlineTransport.fetchChats(currentUserID: userID)
            let modeScoped = mergeChatSnapshots(primary: cached, fallback: snapshotChats)
            mergedVisibleChats =
                mergeVisibleChatSnapshots(
                    primary: modeScoped,
                    fallback: sharedSnapshotChats,
                    currentUserID: userID,
                    visibleMode: mode
                )
        }

        let normalizedChats = await CommunityChatMetadataStore.shared.normalize(mergedVisibleChats, ownerUserID: userID)
        return sanitizeChatsForVisibleMode(normalizedChats, visibleMode: mode)
    }

    func cachedMessages(chatID: UUID, mode: ChatMode) async -> [Message] {
        guard let userID = activeStoredUserID() else {
            switch mode {
            case .smart:
                return await cachedSmartMessages(chatID: chatID)
            case .online:
                return await onlineRepository.cachedMessages(chatID: chatID, mode: .online)
            case .offline:
                return await offlineTransport.fetchMessages(chatID: chatID)
            }
        }

        let snapshotMessages = await ChatSnapshotStore.shared.loadMessages(chatID: chatID, userID: userID, mode: mode)
        let sharedSnapshotMessages = await ChatSnapshotStore.shared.loadSharedMessages(chatID: chatID, userID: userID)
        switch mode {
        case .smart:
            let cached = await cachedSmartMessages(chatID: chatID)
            let modeScoped = mergeMessageSnapshots(primary: cached, fallback: snapshotMessages)
            return mergeMessageSnapshots(primary: modeScoped, fallback: sharedSnapshotMessages)
        case .online:
            let cached = await onlineRepository.cachedMessages(chatID: chatID, mode: .online)
            let modeScoped = mergeMessageSnapshots(primary: cached, fallback: snapshotMessages)
            return mergeMessageSnapshots(primary: modeScoped, fallback: sharedSnapshotMessages)
        case .offline:
            let cached = await offlineTransport.fetchMessages(chatID: chatID)
            let modeScoped = mergeMessageSnapshots(primary: cached, fallback: snapshotMessages)
            return mergeMessageSnapshots(primary: modeScoped, fallback: sharedSnapshotMessages)
        }
    }

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        try await ChatRepositoryExecutionCoordinator.shared.runChatsFetch(
            key: chatsFetchKey(mode: mode, userID: userID)
        ) {
            await retryPendingOutgoingMessages(currentUserID: userID)

            let chats: [Chat]
            do {
                switch mode {
                case .smart:
                    chats = try await fetchSmartChats(for: userID)
                case .online:
                    chats = try await onlineRepository.fetchChats(mode: .online, for: userID)
                    await offlineTransport.synchronizeArchivedChats(with: onlineRepository, currentUserID: userID)
                case .offline:
                    chats = await offlineTransport.fetchChats(currentUserID: userID)
                }
            } catch {
                let fallbackChats = await fallbackChatsAfterFetchFailure(mode: mode, userID: userID)
                if fallbackChats.isEmpty == false {
                    return sanitizeChatsForVisibleMode(fallbackChats, visibleMode: mode)
                }
                throw error
            }

            let aliasedChats = await chats.asyncMap { chat in
                await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: userID)
            }
            let mergedChats = mergeVisibleChatSnapshots(
                    primary: aliasedChats,
                    fallback: await visibleSnapshotChats(mode: mode, userID: userID),
                    currentUserID: userID,
                    visibleMode: mode
            )
            let normalizedChats = await CommunityChatMetadataStore.shared.normalize(mergedChats, ownerUserID: userID)
            let sanitizedChats = sanitizeChatsForVisibleMode(normalizedChats, visibleMode: mode)
            await ChatSnapshotStore.shared.saveChats(sanitizedChats, userID: userID, mode: mode)
            await mirrorOfflineContinuitySeedIfNeeded(chats: sanitizedChats, userID: userID, sourceMode: mode)
            return sanitizedChats
        }
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        try await ChatRepositoryExecutionCoordinator.shared.runMessagesFetch(
            key: messagesFetchKey(chatID: chatID, mode: mode, userID: activeStoredUserID())
        ) {
            if let userID = activeStoredUserID() {
                await retryPendingOutgoingMessages(currentUserID: userID)
            }

            let messages: [Message]
            do {
                switch mode {
                case .smart:
                    messages = try await fetchSmartMessages(chatID: chatID)
                case .online:
                    messages = try await onlineRepository.fetchMessages(chatID: chatID, mode: .online)
                case .offline:
                    messages = await offlineTransport.fetchMessages(chatID: chatID)
                }
            } catch {
                if let userID = activeStoredUserID() {
                    let fallbackMessages = await fallbackMessagesAfterFetchFailure(
                        chatID: chatID,
                        mode: mode,
                        userID: userID
                    )
                    if fallbackMessages.isEmpty == false {
                        return fallbackMessages
                    }
                }
                throw error
            }

            if let userID = activeStoredUserID() {
                let mergedMessages = mergeMessageSnapshots(
                    primary: messages,
                    fallback: await visibleSnapshotMessages(chatID: chatID, mode: mode, userID: userID)
                )
                await ChatSnapshotStore.shared.saveMessages(mergedMessages, chatID: chatID, userID: userID, mode: mode)
                if let sourceChat = await resolvedOfflineContinuitySourceChat(chatID: chatID, mode: mode, userID: userID) {
                    await mirrorOfflineContinuityHistoryIfNeeded(
                        messages: mergedMessages,
                        in: sourceChat,
                        userID: userID,
                        sourceMode: mode
                    )
                }
                return mergedMessages
            }
            return messages
        }
    }

    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws {
        switch mode {
        case .smart:
            if let link = try await smartLink(for: chatID, currentUserID: readerID),
               let onlineChat = link.onlineChat {
                try await onlineRepository.markChatRead(chatID: onlineChat.id, mode: .online, readerID: readerID)
            }
        case .online:
            try await onlineRepository.markChatRead(chatID: chatID, mode: .online, readerID: readerID)
        case .offline:
            return
        }
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        try await sendMessage(OutgoingMessageDraft(text: text), in: chatID, mode: mode, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        let moderatedChat = await moderationDecoratedChat(chat, ownerUserID: senderID)
        try await validateOutgoingMessageDraft(
            draft,
            in: moderatedChat,
            senderID: senderID,
            includeTemporalRules: draft.isScheduledForFuture() == false
        )

        if draft.isScheduledForFuture() {
            let message = await enqueuePendingOutgoingMessage(draft, in: moderatedChat, senderID: senderID)
            await cacheMessageMutation(message, in: moderatedChat, userID: senderID, mode: moderatedChat.mode)
            return message
        }

        let sentMessage: Message
        switch moderatedChat.mode {
        case .smart:
            sentMessage = try await sendSmartMessage(draft, in: moderatedChat, senderID: senderID)
        case .online:
            sentMessage = try await sendOnlineMessage(draft, in: moderatedChat, senderID: senderID, allowQueueFallback: true)
        case .offline:
            let preparedDraft = normalizedDraft(draft, fallbackState: .offline)
            sentMessage = try await offlineTransport.sendMessage(preparedDraft, in: moderatedChat, senderID: senderID)
        }

        await cacheMessageMutation(sentMessage, in: moderatedChat, userID: senderID, mode: moderatedChat.mode)
        await recordModeratedOutgoingMessageIfNeeded(
            draft,
            chat: moderatedChat,
            senderID: senderID,
            createdAt: sentMessage.createdAt
        )
        return sentMessage
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        switch mode {
        case .smart:
            let currentUser = currentStoredUser()
            let resolvedChat = await resolveSmartChatSnapshot(chatID: chatID, currentUserID: senderID)
                ?? Chat(
                    id: chatID,
                    mode: .smart,
                    type: .selfChat,
                    title: "Saved Messages",
                    subtitle: "Notes, links, and drafts",
                    participantIDs: currentUser.map { [$0.id] } ?? [senderID],
                    participants: [],
                    group: nil,
                    lastMessagePreview: nil,
                    lastActivityAt: .distantPast,
                    unreadCount: 0,
                    isPinned: false,
                    draft: nil,
                    disappearingPolicy: nil,
                    notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
                )
            return try await sendMessage(draft, in: resolvedChat, senderID: senderID)
        case .online:
            let resolvedChat = await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: senderID)
                ?? Chat(
                    id: chatID,
                    mode: .online,
                    type: .selfChat,
                    title: "Saved Messages",
                    subtitle: "Notes, links, and drafts",
                    participantIDs: [senderID],
                    participants: [],
                    group: nil,
                    lastMessagePreview: nil,
                    lastActivityAt: .distantPast,
                    unreadCount: 0,
                    isPinned: false,
                    draft: nil,
                    disappearingPolicy: nil,
                    notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
                )
            return try await sendMessage(draft, in: resolvedChat, senderID: senderID)
        case .offline:
            let chats = await offlineTransport.fetchChats(currentUserID: senderID)
            guard let chat = chats.first(where: { $0.id == chatID }) else {
                throw OfflineTransportError.chatUnavailable
            }
            return try await sendMessage(draft, in: chat, senderID: senderID)
        }
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, mode: ChatMode, userID: UUID) async throws -> Message {
        switch mode {
        case .smart:
            guard let route = await resolveSmartRoute(messageID: messageID, smartChatID: chatID, currentUserID: userID) else {
                throw ChatRepositoryError.messageNotFound
            }
            switch route.sourceMode {
            case .online:
                let updated = try await onlineRepository.toggleReaction(emoji, on: route.underlyingMessageID, in: route.underlyingChatID, mode: .online, userID: userID)
                let normalized = SmartChatSupport.normalized(updated, smartChatID: chatID, visibleMode: .smart, fallbackState: .online)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: updated.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .online
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: userID) {
                    await cacheMessageMutation(normalized, in: chat, userID: userID, mode: .smart)
                }
                return normalized
            case .offline, .smart:
                let updated = try await offlineTransport.toggleReaction(emoji, on: route.underlyingMessageID, in: route.underlyingChatID, userID: userID)
                let normalized = SmartChatSupport.normalized(updated, smartChatID: chatID, visibleMode: .smart, fallbackState: .offline)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: updated.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .offline
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: userID) {
                    await cacheMessageMutation(normalized, in: chat, userID: userID, mode: .smart)
                }
                return normalized
            }
        case .online:
            let updated = try await onlineRepository.toggleReaction(emoji, on: messageID, in: chatID, mode: .online, userID: userID)
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: userID) {
                await cacheMessageMutation(updated, in: chat, userID: userID, mode: .online)
            }
            return updated
        case .offline:
            let updated = try await offlineTransport.toggleReaction(emoji, on: messageID, in: chatID, userID: userID)
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .offline, userID: userID) {
                await cacheMessageMutation(updated, in: chat, userID: userID, mode: .offline)
            }
            return updated
        }
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message {
        switch mode {
        case .smart:
            guard let route = await resolveSmartRoute(messageID: messageID, smartChatID: chatID, currentUserID: editorID) else {
                throw ChatRepositoryError.messageNotFound
            }
            switch route.sourceMode {
            case .online:
                let updated = try await onlineRepository.editMessage(route.underlyingMessageID, text: text, in: route.underlyingChatID, mode: .online, editorID: editorID)
                let normalized = SmartChatSupport.normalized(updated, smartChatID: chatID, visibleMode: .smart, fallbackState: .online)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: updated.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .online
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: editorID) {
                    await cacheMessageMutation(normalized, in: chat, userID: editorID, mode: .smart)
                }
                return normalized
            case .offline, .smart:
                let updated = try await offlineTransport.editMessage(route.underlyingMessageID, text: text, in: route.underlyingChatID, editorID: editorID)
                let normalized = SmartChatSupport.normalized(updated, smartChatID: chatID, visibleMode: .smart, fallbackState: .offline)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: updated.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .offline
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: editorID) {
                    await cacheMessageMutation(normalized, in: chat, userID: editorID, mode: .smart)
                }
                return normalized
            }
        case .online:
            let updated = try await onlineRepository.editMessage(messageID, text: text, in: chatID, mode: .online, editorID: editorID)
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: editorID) {
                await cacheMessageMutation(updated, in: chat, userID: editorID, mode: .online)
            }
            return updated
        case .offline:
            let updated = try await offlineTransport.editMessage(messageID, text: text, in: chatID, editorID: editorID)
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .offline, userID: editorID) {
                await cacheMessageMutation(updated, in: chat, userID: editorID, mode: .offline)
            }
            return updated
        }
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message {
        switch mode {
        case .smart:
            guard let route = await resolveSmartRoute(messageID: messageID, smartChatID: chatID, currentUserID: requesterID) else {
                if let deleted = await localDeletedMessageFallback(
                    messageID: messageID,
                    chatID: chatID,
                    mode: .smart,
                    requesterID: requesterID
                ) {
                    if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: requesterID) {
                        await cacheMessageMutation(deleted, in: chat, userID: requesterID, mode: .smart)
                    }
                    return deleted
                }
                throw ChatRepositoryError.messageNotFound
            }
            switch route.sourceMode {
            case .online:
                let deleted: Message
                do {
                    deleted = try await onlineRepository.deleteMessage(route.underlyingMessageID, in: route.underlyingChatID, mode: .online, requesterID: requesterID)
                } catch {
                    if case ChatRepositoryError.messageNotFound = error,
                       let fallbackDeleted = await localDeletedMessageFallback(
                        messageID: messageID,
                        chatID: chatID,
                        mode: .smart,
                        requesterID: requesterID
                       ) {
                        if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: requesterID) {
                            await cacheMessageMutation(fallbackDeleted, in: chat, userID: requesterID, mode: .smart)
                        }
                        return fallbackDeleted
                    }
                    throw error
                }
                let normalized = SmartChatSupport.normalized(deleted, smartChatID: chatID, visibleMode: .smart, fallbackState: .online)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: deleted.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .online
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: requesterID) {
                    await cacheMessageMutation(normalized, in: chat, userID: requesterID, mode: .smart)
                }
                return normalized
            case .offline, .smart:
                let deleted: Message
                do {
                    deleted = try await offlineTransport.deleteMessage(route.underlyingMessageID, in: route.underlyingChatID, requesterID: requesterID)
                } catch {
                    if case ChatRepositoryError.messageNotFound = error,
                       let fallbackDeleted = await localDeletedMessageFallback(
                        messageID: messageID,
                        chatID: chatID,
                        mode: .smart,
                        requesterID: requesterID
                       ) {
                        if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: requesterID) {
                            await cacheMessageMutation(fallbackDeleted, in: chat, userID: requesterID, mode: .smart)
                        }
                        return fallbackDeleted
                    }
                    throw error
                }
                let normalized = SmartChatSupport.normalized(deleted, smartChatID: chatID, visibleMode: .smart, fallbackState: .offline)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: deleted.id,
                        underlyingChatID: route.underlyingChatID,
                        sourceMode: .offline
                    ),
                    for: chatID
                )
                if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .smart, userID: requesterID) {
                    await cacheMessageMutation(normalized, in: chat, userID: requesterID, mode: .smart)
                }
                return normalized
            }
        case .online:
            let deleted: Message
            do {
                deleted = try await onlineRepository.deleteMessage(messageID, in: chatID, mode: .online, requesterID: requesterID)
            } catch {
                if case ChatRepositoryError.messageNotFound = error,
                   let fallbackDeleted = await localDeletedMessageFallback(
                    messageID: messageID,
                    chatID: chatID,
                    mode: .online,
                    requesterID: requesterID
                   ) {
                    if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: requesterID) {
                        await cacheMessageMutation(fallbackDeleted, in: chat, userID: requesterID, mode: .online)
                    }
                    return fallbackDeleted
                }
                throw error
            }
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: requesterID) {
                await cacheMessageMutation(deleted, in: chat, userID: requesterID, mode: .online)
            }
            return deleted
        case .offline:
            let deleted = try await offlineTransport.deleteMessage(messageID, in: chatID, requesterID: requesterID)
            if let chat = await resolveCachedChatSnapshot(chatID: chatID, mode: .offline, userID: requesterID) {
                await cacheMessageMutation(deleted, in: chat, userID: requesterID, mode: .offline)
            }
            return deleted
        }
    }

    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat {
        switch mode {
        case .smart:
            let onlineChat = try? await onlineRepository.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: .online)
            let offlineChat = try await resolveSmartOfflineChat(
                otherUserID: otherUserID,
                currentUser: currentStoredUser() ?? .mockCurrentUser,
                existingOfflineChat: nil
            )
            let merged = SmartChatSupport.mergeChats(
                onlineChats: onlineChat.map { [$0] } ?? [],
                offlineChats: offlineChat.map { [$0] } ?? [],
                currentUserID: currentUserID
            )
            guard let chat = merged.chats.first else {
                throw ChatRepositoryError.invalidDirectChat
            }
            if let link = merged.links.first {
                await SmartConversationStore.shared.upsertLink(link)
            }
            let aliasedChat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: currentUserID)
            await ChatSnapshotStore.shared.upsertChat(aliasedChat, userID: currentUserID, mode: .smart)
            await mirrorOfflineContinuitySeedIfNeeded(chats: [aliasedChat], userID: currentUserID, sourceMode: .smart)
            return aliasedChat
        case .online:
            if let cachedDirectChat = await cachedVisibleDirectChat(
                with: otherUserID,
                currentUserID: currentUserID,
                mode: .online
            ) {
                let aliasedChat = await ContactAliasStore.shared.applyAlias(to: cachedDirectChat, currentUserID: currentUserID)
                await ChatSnapshotStore.shared.upsertChat(aliasedChat, userID: currentUserID, mode: .online)
                await mirrorOfflineContinuitySeedIfNeeded(chats: [aliasedChat], userID: currentUserID, sourceMode: .online)
                return aliasedChat
            }

            let chat: Chat
            do {
                chat = try await onlineRepository.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: .online)
            } catch {
                if let cachedDirectChat = await cachedVisibleDirectChat(
                    with: otherUserID,
                    currentUserID: currentUserID,
                    mode: .online
                ) {
                    let aliasedChat = await ContactAliasStore.shared.applyAlias(to: cachedDirectChat, currentUserID: currentUserID)
                    await ChatSnapshotStore.shared.upsertChat(aliasedChat, userID: currentUserID, mode: .online)
                    await mirrorOfflineContinuitySeedIfNeeded(chats: [aliasedChat], userID: currentUserID, sourceMode: .online)
                    return aliasedChat
                }
                throw error
            }

            let aliasedChat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: currentUserID)
            await ChatSnapshotStore.shared.upsertChat(aliasedChat, userID: currentUserID, mode: .online)
            await mirrorOfflineContinuitySeedIfNeeded(chats: [aliasedChat], userID: currentUserID, sourceMode: .online)
            return aliasedChat
        case .offline:
            throw OfflineTransportError.nearbySelectionRequired
        }
    }

    func submitGuestRequest(introText: String, in chatID: UUID, senderID: UUID) async throws -> Chat {
        let routeChatID: UUID
        if let route = await SmartConversationStore.shared.link(for: chatID), let onlineChat = route.onlineChat {
            routeChatID = onlineChat.id
        } else {
            routeChatID = chatID
        }

        let chat = try await onlineRepository.submitGuestRequest(introText: introText, in: routeChatID, senderID: senderID)
        return await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: senderID)
    }

    func respondToGuestRequest(in chatID: UUID, approve: Bool, responderID: UUID) async throws -> Chat {
        let routeChatID: UUID
        if let route = await SmartConversationStore.shared.link(for: chatID), let onlineChat = route.onlineChat {
            routeChatID = onlineChat.id
        } else {
            routeChatID = chatID
        }

        let chat = try await onlineRepository.respondToGuestRequest(in: routeChatID, approve: approve, responderID: responderID)
        return await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: responderID)
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        let chat = try await offlineTransport.openChat(with: peer, currentUser: currentUser)
        return await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: currentUser.id)
    }

    func retryPendingOutgoingMessages(currentUserID: UUID) async {
        guard ChatRepositoryExecutionCoordinator.shared.beginRetryIfNeeded(ownerUserID: currentUserID) else {
            return
        }
        defer {
            ChatRepositoryExecutionCoordinator.shared.finishRetry(ownerUserID: currentUserID)
        }

        let queuedMessages = await QueuedOutgoingMessageStore.shared.claimReadyQueuedMessages(ownerUserID: currentUserID)
        guard queuedMessages.isEmpty == false else {
            scheduleDeferredQueuedRetryIfNeeded(ownerUserID: currentUserID)
            return
        }

        for queuedMessage in queuedMessages {
            await ChatSnapshotStore.shared.updateMessageStatus(
                clientMessageID: queuedMessage.draft.clientMessageID ?? queuedMessage.id,
                in: queuedMessage.chat.id,
                userID: currentUserID,
                mode: queuedMessage.chat.mode,
                status: .sending
            )
            do {
                let sentMessage = try await resendQueuedMessage(queuedMessage)
                await QueuedOutgoingMessageStore.shared.complete(messageID: queuedMessage.id, ownerUserID: currentUserID)
                let chatSnapshot = await resolveCachedChatSnapshot(
                    chatID: queuedMessage.chat.id,
                    mode: queuedMessage.chat.mode,
                    userID: currentUserID
                ) ?? queuedMessage.chat
                await cacheMessageMutation(sentMessage, in: chatSnapshot, userID: currentUserID, mode: queuedMessage.chat.mode)
            } catch {
                await QueuedOutgoingMessageStore.shared.release(messageID: queuedMessage.id)
                await ChatSnapshotStore.shared.updateMessageStatus(
                    clientMessageID: queuedMessage.draft.clientMessageID ?? queuedMessage.id,
                    in: queuedMessage.chat.id,
                    userID: currentUserID,
                    mode: queuedMessage.chat.mode,
                    status: .localPending
                )
            }
        }

        scheduleDeferredQueuedRetryIfNeeded(ownerUserID: currentUserID)
    }

    func cancelPendingOutgoingMessage(clientMessageID: UUID, in chat: Chat, ownerUserID: UUID) async {
        await QueuedOutgoingMessageStore.shared.remove(messageID: clientMessageID, ownerUserID: ownerUserID)
        await ChatSnapshotStore.shared.removeMessage(
            clientMessageID: clientMessageID,
            chatID: chat.id,
            userID: ownerUserID,
            mode: chat.mode
        )
    }

    func createGroupChat(
        title: String,
        memberIDs: [UUID],
        ownerID: UUID,
        mode: ChatMode,
        communityDetails: CommunityChatDetails?
    ) async throws -> Chat {
        switch mode {
        case .smart:
            let onlineChat = try await onlineRepository.createGroupChat(
                title: title,
                memberIDs: memberIDs,
                ownerID: ownerID,
                mode: .online,
                communityDetails: communityDetails
            )
            let smartChatID = SmartChatSupport.smartChatID(for: onlineChat, currentUserID: ownerID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: ownerID,
                    participantIDs: onlineChat.participantIDs,
                    type: onlineChat.type,
                    onlineChat: onlineChat,
                    offlineChat: nil
                )
            )
            return smartWrappedChat(onlineChat, smartChatID: smartChatID)
        case .online:
            return try await onlineRepository.createGroupChat(
                title: title,
                memberIDs: memberIDs,
                ownerID: ownerID,
                mode: .online,
                communityDetails: communityDetails
            )
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.updateGroup(targetChat, title: title, requesterID: requesterID)
            let smartChatID = SmartChatSupport.smartChatID(for: updated, currentUserID: requesterID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: requesterID,
                    participantIDs: updated.participantIDs,
                    type: updated.type,
                    onlineChat: updated,
                    offlineChat: await SmartConversationStore.shared.link(for: chat.id)?.offlineChat
                )
            )
            return smartWrappedChat(updated, smartChatID: smartChatID)
        case .online:
            return try await onlineRepository.updateGroup(chat, title: title, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func deleteGroup(_ chat: Chat, requesterID: UUID) async throws {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            try await onlineRepository.deleteGroup(targetChat, requesterID: requesterID)
            await clearLocalGroupState(chatID: chat.id, currentUserID: requesterID)
        case .online:
            try await onlineRepository.deleteGroup(chat, requesterID: requesterID)
            await clearLocalGroupState(chatID: chat.id, currentUserID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func updateCommunityDetails(_ details: CommunityChatDetails, for chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.updateCommunityDetails(details, for: targetChat, requesterID: requesterID)
            let smartChatID = SmartChatSupport.smartChatID(for: updated, currentUserID: requesterID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: requesterID,
                    participantIDs: updated.participantIDs,
                    type: updated.type,
                    onlineChat: updated,
                    offlineChat: await SmartConversationStore.shared.link(for: chat.id)?.offlineChat
                )
            )
            return smartWrappedChat(updated, smartChatID: smartChatID)
        case .online:
            return try await onlineRepository.updateCommunityDetails(details, for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.uploadGroupAvatar(imageData: imageData, for: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.uploadGroupAvatar(imageData: imageData, for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.removeGroupAvatar(for: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.removeGroupAvatar(for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.addMembers(memberIDs, to: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.addMembers(memberIDs, to: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.removeMember(memberID, from: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.removeMember(memberID, from: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func updateMemberRole(_ role: GroupMemberRole, for memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.updateMemberRole(role, for: memberID, in: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.updateMemberRole(role, for: memberID, in: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func transferGroupOwnership(to memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.transferGroupOwnership(to: memberID, in: targetChat, requesterID: requesterID)
            return smartWrappedChat(updated, smartChatID: chat.id)
        case .online:
            return try await onlineRepository.transferGroupOwnership(to: memberID, in: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func leaveGroup(_ chat: Chat, requesterID: UUID) async throws {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            try await onlineRepository.leaveGroup(targetChat, requesterID: requesterID)
            await clearLocalGroupState(chatID: chat.id, currentUserID: requesterID)
        case .online:
            try await onlineRepository.leaveGroup(chat, requesterID: requesterID)
            await clearLocalGroupState(chatID: chat.id, currentUserID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func searchDiscoverableChats(query: String, mode: ChatMode, currentUserID: UUID) async throws -> [Chat] {
        switch mode {
        case .smart:
            let chats = try await onlineRepository.searchDiscoverableChats(query: query, mode: .online, currentUserID: currentUserID)
            return await chats.asyncMap { chat in
                let smartChatID = SmartChatSupport.smartChatID(for: chat, currentUserID: currentUserID)
                await SmartConversationStore.shared.upsertLink(
                    SmartConversationLink(
                        smartChatID: smartChatID,
                        currentUserID: currentUserID,
                        participantIDs: chat.participantIDs,
                        type: chat.type,
                        onlineChat: chat,
                        offlineChat: await SmartConversationStore.shared.link(for: smartChatID)?.offlineChat
                    )
                )
                return smartWrappedChat(chat, smartChatID: smartChatID)
            }
        case .online:
            return try await onlineRepository.searchDiscoverableChats(query: query, mode: .online, currentUserID: currentUserID)
        case .offline:
            return []
        }
    }

    func joinDiscoverableChat(_ chat: Chat, requesterID: UUID) async throws -> Chat {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            let updated = try await onlineRepository.joinDiscoverableChat(targetChat, requesterID: requesterID)
            let smartChatID = SmartChatSupport.smartChatID(for: updated, currentUserID: requesterID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: requesterID,
                    participantIDs: updated.participantIDs,
                    type: updated.type,
                    onlineChat: updated,
                    offlineChat: await SmartConversationStore.shared.link(for: chat.id)?.offlineChat
                )
            )
            return smartWrappedChat(updated, smartChatID: smartChatID)
        case .online:
            return try await onlineRepository.joinDiscoverableChat(chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func joinChat(inviteCode: String, mode: ChatMode, requesterID: UUID) async throws -> Chat {
        switch mode {
        case .smart:
            let updated = try await onlineRepository.joinChat(inviteCode: inviteCode, mode: .online, requesterID: requesterID)
            let smartChatID = SmartChatSupport.smartChatID(for: updated, currentUserID: requesterID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: requesterID,
                    participantIDs: updated.participantIDs,
                    type: updated.type,
                    onlineChat: updated,
                    offlineChat: await SmartConversationStore.shared.link(for: smartChatID)?.offlineChat
                )
            )
            return smartWrappedChat(updated, smartChatID: smartChatID)
        case .online:
            return try await onlineRepository.joinChat(inviteCode: inviteCode, mode: .online, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func submitJoinRequest(for chat: Chat, requesterID: UUID, answers: [String]) async throws {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            try await onlineRepository.submitJoinRequest(for: targetChat, requesterID: requesterID, answers: answers)
        case .online:
            try await onlineRepository.submitJoinRequest(for: chat, requesterID: requesterID, answers: answers)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func fetchModerationDashboard(for chat: Chat, requesterID: UUID) async throws -> ModerationDashboard {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            return try await onlineRepository.fetchModerationDashboard(for: targetChat, requesterID: requesterID)
        case .online:
            return try await onlineRepository.fetchModerationDashboard(for: chat, requesterID: requesterID)
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func resolveJoinRequest(
        for requesterUserID: UUID,
        approve: Bool,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            return try await onlineRepository.resolveJoinRequest(
                for: requesterUserID,
                approve: approve,
                in: targetChat,
                requesterID: requesterID
            )
        case .online:
            return try await onlineRepository.resolveJoinRequest(
                for: requesterUserID,
                approve: approve,
                in: chat,
                requesterID: requesterID
            )
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func reportChatContent(
        in chat: Chat,
        requesterID: UUID,
        targetMessageID: UUID?,
        targetUserID: UUID?,
        reason: ModerationReportReason,
        details: String?
    ) async throws {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            try await onlineRepository.reportChatContent(
                in: targetChat,
                requesterID: requesterID,
                targetMessageID: targetMessageID,
                targetUserID: targetUserID,
                reason: reason,
                details: details
            )
        case .online:
            try await onlineRepository.reportChatContent(
                in: chat,
                requesterID: requesterID,
                targetMessageID: targetMessageID,
                targetUserID: targetUserID,
                reason: reason,
                details: details
            )
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func banMember(
        _ memberID: UUID,
        duration: TimeInterval,
        reason: String?,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            return try await onlineRepository.banMember(
                memberID,
                duration: duration,
                reason: reason,
                in: targetChat,
                requesterID: requesterID
            )
        case .online:
            return try await onlineRepository.banMember(
                memberID,
                duration: duration,
                reason: reason,
                in: chat,
                requesterID: requesterID
            )
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func removeBan(
        for memberID: UUID,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        switch chat.mode {
        case .smart:
            let targetChat = await SmartConversationStore.shared.link(for: chat.id)?.onlineChat ?? chat
            return try await onlineRepository.removeBan(
                for: memberID,
                in: targetChat,
                requesterID: requesterID
            )
        case .online:
            return try await onlineRepository.removeBan(
                for: memberID,
                in: chat,
                requesterID: requesterID
            )
        case .offline:
            throw ChatRepositoryError.unsupportedOfflineAction
        }
    }

    func saveDraft(_ draft: Draft) async throws {
        try await onlineRepository.saveDraft(draft)
    }

    func prepareModeTransition(_ request: ChatModeTransitionRequest) async throws -> ChatModeTransitionResult {
        switch (request.fromMode, request.toMode) {
        case (.smart, .online):
            try await migrateSmartHistoryToOnline(currentUser: request.currentUser)
            let routedChat = try await routedChatForTransitionToOnline(
                activeChat: request.activeChat,
                currentUser: request.currentUser
            )
            return ChatModeTransitionResult(routedChat: routedChat)
        case (.smart, .offline):
            return try await saveSmartHistoryForOfflineMode(currentUser: request.currentUser, preferredChat: request.activeChat)
        case (.online, .smart):
            await offlineTransport.synchronizeArchivedChats(with: onlineRepository, currentUserID: request.currentUser.id)
            let routedChat = try await routedChatForTransitionToSmart(
                activeChat: request.activeChat,
                currentUser: request.currentUser
            )
            return ChatModeTransitionResult(routedChat: routedChat)
        case (.online, .offline):
            return try await saveOnlineHistoryForOfflineMode(currentUser: request.currentUser, preferredChat: request.activeChat)
        case (.offline, .smart):
            let routedChat = try await routedChatForTransitionToSmart(
                activeChat: request.activeChat,
                currentUser: request.currentUser
            )
            return ChatModeTransitionResult(routedChat: routedChat)
        case (.offline, .online):
            await offlineTransport.synchronizeArchivedChats(with: onlineRepository, currentUserID: request.currentUser.id)
            let routedChat = try await routedChatForTransitionToOnline(
                activeChat: request.activeChat,
                currentUser: request.currentUser
            )
            return ChatModeTransitionResult(routedChat: routedChat)
        default:
            return ChatModeTransitionResult(routedChat: nil)
        }
    }

    private func fetchSmartChats(for userID: UUID) async throws -> [Chat] {
        let onlineChats = (try? await onlineRepository.fetchChats(mode: .online, for: userID)) ?? []
        let offlineChats = await offlineTransport.fetchChats(currentUserID: userID)
        return await mergeSmartChats(
            onlineChats: onlineChats,
            offlineChats: offlineChats,
            currentUserID: userID
        )
    }

    private func cachedSmartChats(for userID: UUID) async -> [Chat] {
        let onlineChats = await onlineRepository.cachedChats(mode: .online, for: userID)
        let offlineChats = await offlineTransport.fetchChats(currentUserID: userID)
        return await mergeSmartChats(
            onlineChats: onlineChats,
            offlineChats: offlineChats,
            currentUserID: userID
        )
    }

    private func mergeSmartChats(onlineChats: [Chat], offlineChats: [Chat], currentUserID: UUID) async -> [Chat] {
        let merged = SmartChatSupport.mergeChats(
            onlineChats: onlineChats,
            offlineChats: offlineChats,
            currentUserID: currentUserID
        )
        await SmartConversationStore.shared.replaceLinks(merged.links)
        return merged.chats
    }

    private func fetchSmartMessages(chatID: UUID) async throws -> [Message] {
        let currentUserID = activeStoredUserID()
        let link = try await smartLink(for: chatID, currentUserID: currentUserID)
        let onlineMessages: [Message]
        if let onlineChat = link?.onlineChat {
            onlineMessages = (try? await onlineRepository.fetchMessages(chatID: onlineChat.id, mode: .online)) ?? []
        } else {
            onlineMessages = []
        }

        let offlineMessages: [Message]
        if let offlineChat = link?.offlineChat {
            offlineMessages = await offlineTransport.fetchMessages(chatID: offlineChat.id)
        } else {
            offlineMessages = []
        }

        return await mergeSmartMessages(
            chatID: chatID,
            link: link,
            onlineMessages: onlineMessages,
            offlineMessages: offlineMessages
        )
    }

    private func cachedSmartMessages(chatID: UUID) async -> [Message] {
        let currentUserID = activeStoredUserID()
        let link = await cachedSmartLink(for: chatID, currentUserID: currentUserID)
        let onlineMessages: [Message]
        if let onlineChat = link?.onlineChat {
            onlineMessages = await onlineRepository.cachedMessages(chatID: onlineChat.id, mode: .online)
        } else {
            onlineMessages = []
        }

        let offlineMessages: [Message]
        if let offlineChat = link?.offlineChat {
            offlineMessages = await offlineTransport.fetchMessages(chatID: offlineChat.id)
        } else {
            offlineMessages = []
        }

        return await mergeSmartMessages(
            chatID: chatID,
            link: link,
            onlineMessages: onlineMessages,
            offlineMessages: offlineMessages
        )
    }

    private func mergeSmartMessages(
        chatID: UUID,
        link: SmartConversationLink?,
        onlineMessages: [Message],
        offlineMessages: [Message]
    ) async -> [Message] {
        guard link != nil || onlineMessages.isEmpty == false || offlineMessages.isEmpty == false else { return [] }

        let merged = SmartChatSupport.mergeMessages(
            onlineMessages: onlineMessages,
            offlineMessages: offlineMessages,
            smartChatID: chatID
        )
        await SmartConversationStore.shared.storeRoutes(merged.routes, for: chatID)
        return merged.messages
    }

    private struct SmartOfflineDeliveryAssessment {
        var policyKey: UUID?
        var availablePaths: [OfflineTransportPath]
        var preferredPath: OfflineTransportPath?
        var shouldPreferOnline: Bool
        var canAttemptOffline: Bool
    }

    private func sendSmartMessage(
        _ draft: OutgoingMessageDraft,
        in smartChat: Chat,
        senderID: UUID,
        allowQueueFallback: Bool = true
    ) async throws -> Message {
        guard let currentUser = currentStoredUser(), currentUser.id == senderID else {
            do {
                return try await sendSmartOnlineMessage(
                    normalizedDraft(draft, fallbackState: .online),
                    in: smartChat.id,
                    senderID: senderID,
                    existingLink: nil
                )
            } catch {
                if allowQueueFallback, shouldQueueMessageForLater(error) {
                    return await enqueuePendingOutgoingMessage(draft, in: smartChat, senderID: senderID)
                }
                throw error
            }
        }

        let smartChatID = smartChat.id
        let link = await resolveSmartLinkForSending(chat: smartChat, currentUserID: senderID)
        let preparedDraft = normalizedDraft(draft, fallbackState: .offline)
        let deliveryAssessment = await smartOfflineDeliveryAssessment(for: link, smartChat: smartChat, currentUserID: senderID)
        let networkAllowed = NetworkUsagePolicy.canUseChatSyncNetwork()

        if deliveryAssessment.shouldPreferOnline, networkAllowed {
            return try await sendSmartOnlineMessage(preparedDraft, in: smartChatID, senderID: senderID, existingLink: link)
        }

        if deliveryAssessment.canAttemptOffline,
           let offlineChat = try await resolveOfflineChat(for: link, smartChat: smartChat, currentUser: currentUser) {
            if networkAllowed {
                let timeoutDraft = preparedDraft
                let offlineAttemptStartedAt = Date()
                let offlineTask = Task {
                    try await offlineTransport.sendMessage(timeoutDraft, in: offlineChat, senderID: senderID)
                }

                do {
                    let sentOffline = try await withTimeout(seconds: 4) {
                        try await offlineTask.value
                    }
                    if shouldFallbackSmartMessageToOnline(sentOffline) {
                        if let policyKey = deliveryAssessment.policyKey {
                            await SmartDeliveryPolicyStore.shared.recordOfflineFailure(
                                for: policyKey,
                                path: deliveryAssessment.preferredPath
                            )
                            _ = await SmartDeliveryPolicyStore.shared.recordSlowFallback(for: policyKey)
                        }
                        return try await sendSmartOnlineMessage(preparedDraft, in: smartChatID, senderID: senderID, existingLink: link)
                    }
                    if let policyKey = deliveryAssessment.policyKey,
                       let successfulPath = deliveryAssessment.preferredPath ?? deliveryAssessment.availablePaths.first,
                       sentOffline.status != .localPending {
                        await SmartDeliveryPolicyStore.shared.recordOfflineSuccess(
                            for: policyKey,
                            path: successfulPath,
                            latency: Date().timeIntervalSince(offlineAttemptStartedAt)
                        )
                    }
                    await upsertSmartLink(
                        from: link,
                        smartChat: smartChat,
                        currentUserID: senderID,
                        offlineChat: offlineChat
                    )
                    let normalized = SmartChatSupport.normalized(sentOffline, smartChatID: smartChatID, visibleMode: .smart, fallbackState: .offline)
                    await SmartConversationStore.shared.upsertRoute(
                        SmartMessageRoute(
                            presentedMessageID: normalized.id,
                            underlyingMessageID: sentOffline.id,
                            underlyingChatID: offlineChat.id,
                            sourceMode: .offline
                        ),
                        for: smartChatID
                    )
                    return normalized
                } catch TimeoutError.operationTimedOut {
                    if let policyKey = deliveryAssessment.policyKey {
                        await SmartDeliveryPolicyStore.shared.recordOfflineFailure(
                            for: policyKey,
                            path: deliveryAssessment.preferredPath
                        )
                        _ = await SmartDeliveryPolicyStore.shared.recordSlowFallback(for: policyKey)
                    }
                    do {
                        return try await sendSmartOnlineMessage(preparedDraft, in: smartChatID, senderID: senderID, existingLink: link)
                    } catch {
                        if allowQueueFallback, shouldQueueMessageForLater(error) {
                            return await enqueuePendingOutgoingMessage(preparedDraft, in: smartChat, senderID: senderID)
                        }
                        throw error
                    }
                } catch {
                    if let policyKey = deliveryAssessment.policyKey {
                        await SmartDeliveryPolicyStore.shared.recordOfflineFailure(
                            for: policyKey,
                            path: deliveryAssessment.preferredPath
                        )
                    }
                    // fall through to normal graceful fallback
                }
            }

            do {
                let offlineAttemptStartedAt = Date()
                let sentOffline = try await offlineTransport.sendMessage(preparedDraft, in: offlineChat, senderID: senderID)
                if shouldFallbackSmartMessageToOnline(sentOffline), networkAllowed {
                    if let policyKey = deliveryAssessment.policyKey {
                        await SmartDeliveryPolicyStore.shared.recordOfflineFailure(
                            for: policyKey,
                            path: deliveryAssessment.preferredPath
                        )
                        _ = await SmartDeliveryPolicyStore.shared.recordSlowFallback(for: policyKey)
                    }
                    return try await sendSmartOnlineMessage(preparedDraft, in: smartChatID, senderID: senderID, existingLink: link)
                }
                if let policyKey = deliveryAssessment.policyKey,
                   let successfulPath = deliveryAssessment.preferredPath ?? deliveryAssessment.availablePaths.first,
                   sentOffline.status != .localPending {
                    await SmartDeliveryPolicyStore.shared.recordOfflineSuccess(
                        for: policyKey,
                        path: successfulPath,
                        latency: Date().timeIntervalSince(offlineAttemptStartedAt)
                    )
                }
                await upsertSmartLink(
                    from: link,
                    smartChat: smartChat,
                    currentUserID: senderID,
                    offlineChat: offlineChat
                )
                let normalized = SmartChatSupport.normalized(sentOffline, smartChatID: smartChatID, visibleMode: .smart, fallbackState: .offline)
                await SmartConversationStore.shared.upsertRoute(
                    SmartMessageRoute(
                        presentedMessageID: normalized.id,
                        underlyingMessageID: sentOffline.id,
                        underlyingChatID: offlineChat.id,
                        sourceMode: .offline
                    ),
                    for: smartChatID
                )
                return normalized
            } catch {
                if let policyKey = deliveryAssessment.policyKey {
                    await SmartDeliveryPolicyStore.shared.recordOfflineFailure(
                        for: policyKey,
                        path: deliveryAssessment.preferredPath
                    )
                }
                // Smart Mode should degrade into server delivery without surfacing
                // a transport-specific failure when nearby delivery is unavailable
                // for the current content or peer state.
            }
        }

        do {
            return try await sendSmartOnlineMessage(preparedDraft, in: smartChatID, senderID: senderID, existingLink: link)
        } catch {
            if allowQueueFallback, shouldQueueMessageForLater(error) {
                return await enqueuePendingOutgoingMessage(preparedDraft, in: smartChat, senderID: senderID)
            }
            throw error
        }
    }

    private func sendSmartOnlineMessage(
        _ draft: OutgoingMessageDraft,
        in smartChatID: UUID,
        senderID: UUID,
        existingLink: SmartConversationLink?
    ) async throws -> Message {
        let onlineChat = try await resolveOnlineChat(for: existingLink, smartChatID: smartChatID, currentUserID: senderID)
        let onlineState = draft.deliveryStateOverride == .migrated ? MessageDeliveryState.migrated : .online
        let preparedDraft = normalizedDraft(draft, fallbackState: onlineState)
        let sentOnline = applyDraftDeliveryOptions(
            preparedDraft,
            to: try await onlineRepository.sendMessage(preparedDraft, in: onlineChat.id, mode: .online, senderID: senderID)
        )

        let refreshedLink = SmartConversationLink(
            smartChatID: smartChatID,
            currentUserID: senderID,
            participantIDs: existingLink?.participantIDs ?? onlineChat.participantIDs,
            type: existingLink?.type ?? onlineChat.type,
            onlineChat: onlineChat,
            offlineChat: existingLink?.offlineChat
        )
        await SmartConversationStore.shared.upsertLink(refreshedLink)

        let normalized = SmartChatSupport.normalized(
            sentOnline.withDeliveryRoute(.online),
            smartChatID: smartChatID,
            visibleMode: .smart,
            fallbackState: onlineState
        )
        await SmartConversationStore.shared.upsertRoute(
            SmartMessageRoute(
                presentedMessageID: normalized.id,
                underlyingMessageID: sentOnline.id,
                underlyingChatID: onlineChat.id,
                sourceMode: .online
            ),
            for: smartChatID
        )
        return normalized
    }

    private func shouldFallbackSmartMessageToOnline(_ message: Message) -> Bool {
        message.status == .localPending
    }

    private func resolveSmartRoute(messageID: UUID, smartChatID: UUID, currentUserID: UUID) async -> SmartMessageRoute? {
        if let stored = await SmartConversationStore.shared.route(for: messageID, in: smartChatID) {
            return stored
        }

        _ = try? await fetchSmartMessages(chatID: smartChatID)
        return await SmartConversationStore.shared.route(for: messageID, in: smartChatID)
    }

    private func smartLink(for smartChatID: UUID, currentUserID: UUID?) async throws -> SmartConversationLink? {
        if let stored = await SmartConversationStore.shared.link(for: smartChatID) {
            return stored
        }

        if let currentUserID {
            _ = try await fetchSmartChats(for: currentUserID)
            return await SmartConversationStore.shared.link(for: smartChatID)
        }

        return nil
    }

    private func cachedSmartLink(for smartChatID: UUID, currentUserID: UUID?) async -> SmartConversationLink? {
        if let stored = await SmartConversationStore.shared.link(for: smartChatID) {
            return stored
        }

        if let currentUserID {
            _ = await cachedSmartChats(for: currentUserID)
            return await SmartConversationStore.shared.link(for: smartChatID)
        }

        return nil
    }

    private func resolveOnlineChat(for link: SmartConversationLink?, smartChatID: UUID, currentUserID: UUID) async throws -> Chat {
        if let onlineChat = link?.onlineChat {
            return onlineChat
        }

        let type = link?.type ?? .direct
        switch type {
        case .group:
            throw ChatRepositoryError.invalidGroupOperation
        case .selfChat:
            let chats = try await onlineRepository.fetchChats(mode: .online, for: currentUserID)
            if let savedMessages = chats.first(where: { $0.type == .selfChat || $0.id == currentUserID }) {
                return savedMessages
            }
            return Chat(
                id: currentUserID,
                mode: .online,
                type: .selfChat,
                title: "Saved Messages",
                subtitle: "Notes, links, and drafts",
                participantIDs: [currentUserID],
                participants: [],
                group: nil,
                lastMessagePreview: nil,
                lastActivityAt: .distantPast,
                unreadCount: 0,
                isPinned: false,
                draft: nil,
                disappearingPolicy: nil,
                notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
            )
        case .direct:
            guard let otherUserID = link?.participantIDs.first(where: { $0 != currentUserID }) else {
                throw ChatRepositoryError.invalidDirectChat
            }
            let directChat = try await onlineRepository.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: .online)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: currentUserID,
                    participantIDs: directChat.participantIDs,
                    type: .direct,
                    onlineChat: directChat,
                    offlineChat: link?.offlineChat
                )
            )
            return directChat
        case .secret:
            throw ChatRepositoryError.invalidDirectChat
        }
    }

    private func smartOfflineDeliveryAssessment(
        for link: SmartConversationLink?,
        smartChat: Chat,
        currentUserID: UUID
    ) async -> SmartOfflineDeliveryAssessment {
        let effectiveType = link?.type ?? smartChat.type

        switch effectiveType {
        case .selfChat:
            return SmartOfflineDeliveryAssessment(
                policyKey: nil,
                availablePaths: [],
                preferredPath: nil,
                shouldPreferOnline: false,
                canAttemptOffline: true
            )
        case .group:
            return SmartOfflineDeliveryAssessment(
                policyKey: nil,
                availablePaths: [],
                preferredPath: nil,
                shouldPreferOnline: false,
                canAttemptOffline: false
            )
        case .direct:
            let participantIDs = link?.participantIDs.isEmpty == false ? link?.participantIDs ?? [] : smartChat.participantIDs
            guard let otherUserID = participantIDs.first(where: { $0 != currentUserID }) else {
                return SmartOfflineDeliveryAssessment(
                    policyKey: nil,
                    availablePaths: [],
                    preferredPath: nil,
                    shouldPreferOnline: false,
                    canAttemptOffline: false
                )
            }

            var availablePaths: Set<OfflineTransportPath> = []
            if let reachablePeer = await offlineTransport.reachablePeer(userID: otherUserID) {
                availablePaths.formUnion(reachablePeer.availablePaths)
            }

            let nearbyPeers = await offlineTransport.discoveredPeers()
            if let directlyDiscoveredPeer = nearbyPeers.first(where: { $0.id == otherUserID }) {
                availablePaths.formUnion(directlyDiscoveredPeer.availablePaths)
            }
            if nearbyPeers.contains(where: { $0.id != otherUserID && $0.relayCapable }) {
                availablePaths.insert(.meshRelay)
            }

            let normalizedPaths = availablePaths.sorted { lhs, rhs in
                lhs.priority < rhs.priority
            }
            let networkAllowed = NetworkUsagePolicy.canUseChatSyncNetwork()
            let preferredPath = await SmartDeliveryPolicyStore.shared.preferredOfflinePath(
                for: otherUserID,
                availablePaths: normalizedPaths
            )
            let shouldPreferOnline = await SmartDeliveryPolicyStore.shared.shouldPreferOnline(
                for: otherUserID,
                availablePaths: normalizedPaths,
                networkAllowed: networkAllowed
            )

            return SmartOfflineDeliveryAssessment(
                policyKey: otherUserID,
                availablePaths: normalizedPaths,
                preferredPath: preferredPath,
                shouldPreferOnline: shouldPreferOnline,
                canAttemptOffline: normalizedPaths.isEmpty == false || networkAllowed == false
            )
        case .secret:
            return SmartOfflineDeliveryAssessment(
                policyKey: nil,
                availablePaths: [],
                preferredPath: nil,
                shouldPreferOnline: false,
                canAttemptOffline: false
            )
        }
    }

    private func resolveOfflineChat(for link: SmartConversationLink?, smartChat: Chat, currentUser: User) async throws -> Chat? {
        let effectiveType = link?.type ?? smartChat.type

        if let offlineChat = link?.offlineChat {
            return offlineChat
        }

        switch effectiveType {
        case .selfChat:
            let chats = await offlineTransport.fetchChats(currentUserID: currentUser.id)
            if let existing = chats.first(where: { $0.type == .selfChat || $0.id == currentUser.id }) {
                return existing
            }
            return try await offlineTransport.importHistory([], into: smartChat, currentUser: currentUser)
        case .group:
            return nil
        case .direct:
            let participantIDs = link?.participantIDs.isEmpty == false ? link?.participantIDs ?? [] : smartChat.participantIDs
            guard let otherUserID = participantIDs.first(where: { $0 != currentUser.id }) else {
                return nil
            }
            if let resolved = try await resolveSmartOfflineChat(
                otherUserID: otherUserID,
                currentUser: currentUser,
                existingOfflineChat: nil
            ) {
                return resolved
            }
            return try await offlineTransport.importHistory([], into: smartChat, currentUser: currentUser)
        case .secret:
            return nil
        }
    }

    private func resolveSmartOfflineChat(otherUserID: UUID, currentUser: User, existingOfflineChat: Chat?) async throws -> Chat? {
        if let existingOfflineChat {
            return existingOfflineChat
        }

        let archivedChats = await offlineTransport.fetchChats(currentUserID: currentUser.id)
        if let archivedChat = archivedChats.first(where: {
            $0.type == .direct && $0.participantIDs.contains(currentUser.id) && $0.participantIDs.contains(otherUserID)
        }) {
            return archivedChat
        }

        guard let peer = await offlineTransport.reachablePeer(userID: otherUserID) else {
            return nil
        }

        return try await offlineTransport.openChat(with: peer, currentUser: currentUser)
    }

    private func migrateSmartHistoryToOnline(currentUser: User) async throws {
        let smartChats = try await fetchSmartChats(for: currentUser.id)

        for smartChat in smartChats {
            guard smartChat.type != .group else { continue }
            guard let link = await SmartConversationStore.shared.link(for: smartChat.id),
                  let offlineChat = link.offlineChat else {
                continue
            }

            let offlineMessages = await offlineTransport.fetchMessages(chatID: offlineChat.id)
            guard offlineMessages.isEmpty == false else { continue }

            let onlineChat = try await resolveOnlineChat(for: link, smartChatID: smartChat.id, currentUserID: currentUser.id)
            let onlineMessages = (try? await onlineRepository.fetchMessages(chatID: onlineChat.id, mode: .online)) ?? []
            let existingClientMessageIDs = Set(onlineMessages.map(\.clientMessageID))

            var rewrittenOfflineMessages = offlineMessages

            for index in rewrittenOfflineMessages.indices {
                let message = rewrittenOfflineMessages[index]
                guard message.senderID == currentUser.id else { continue }

                if existingClientMessageIDs.contains(message.clientMessageID) {
                    rewrittenOfflineMessages[index].deliveryState = .migrated
                } else {
                    rewrittenOfflineMessages[index].deliveryState = .syncing
                }
            }

            _ = try? await offlineTransport.importHistory(rewrittenOfflineMessages, into: smartChat, currentUser: currentUser)

            var finalizedOfflineMessages = rewrittenOfflineMessages

            for index in finalizedOfflineMessages.indices {
                let message = finalizedOfflineMessages[index]
                guard message.senderID == currentUser.id else { continue }
                guard existingClientMessageIDs.contains(message.clientMessageID) == false else {
                    finalizedOfflineMessages[index].deliveryState = .migrated
                    continue
                }
                guard message.isDeleted == false else {
                    finalizedOfflineMessages[index].deliveryState = .offline
                    continue
                }

                let draft = OutgoingMessageDraft(
                    text: message.text ?? "",
                    attachments: message.attachments,
                    voiceMessage: message.voiceMessage,
                    replyToMessageID: message.replyToMessageID,
                    replyPreview: message.replyPreview,
                    deliveryOptions: message.deliveryOptions,
                    clientMessageID: message.clientMessageID,
                    createdAt: message.createdAt,
                    deliveryStateOverride: .migrated
                )

                guard draft.hasContent else {
                    finalizedOfflineMessages[index].deliveryState = .migrated
                    continue
                }

                do {
                    _ = try await onlineRepository.sendMessage(draft, in: onlineChat.id, mode: .online, senderID: currentUser.id)
                    finalizedOfflineMessages[index].deliveryState = .migrated
                } catch {
                    finalizedOfflineMessages[index].deliveryState = .offline
                }
            }

            _ = try? await offlineTransport.importHistory(finalizedOfflineMessages, into: smartChat, currentUser: currentUser)
        }
    }

    private func saveSmartHistoryForOfflineMode(currentUser: User, preferredChat: Chat?) async throws -> ChatModeTransitionResult {
        if let preferredChat {
            let mergedMessages = await cachedMessages(chatID: preferredChat.id, mode: .smart)
            if mergedMessages.isEmpty == false {
                let offlineChat = try await offlineTransport.importHistory(mergedMessages, into: preferredChat, currentUser: currentUser)
                return ChatModeTransitionResult(routedChat: offlineChat)
            }
            return ChatModeTransitionResult(routedChat: nil)
        }

        let smartChats = await cachedChats(mode: .smart, for: currentUser.id)
        var routedChat: Chat?

        for smartChat in smartChats where smartChat.type != .group && smartChat.type != .secret {
            let mergedMessages = await cachedMessages(chatID: smartChat.id, mode: .smart)
            guard mergedMessages.isEmpty == false else { continue }

            let importedChat = try await offlineTransport.importHistory(mergedMessages, into: smartChat, currentUser: currentUser)
            if routedChat == nil {
                routedChat = importedChat
            }
        }

        return ChatModeTransitionResult(routedChat: routedChat)
    }

    private func saveOnlineHistoryForOfflineMode(currentUser: User, preferredChat: Chat?) async throws -> ChatModeTransitionResult {
        if let preferredChat, preferredChat.type != .group, preferredChat.type != .secret {
            let onlineMessages = await resolvedOnlineMessagesForOfflineImport(chatID: preferredChat.id)
            if onlineMessages.isEmpty == false {
                let offlineChat = try await offlineTransport.importHistory(onlineMessages, into: preferredChat, currentUser: currentUser)
                return ChatModeTransitionResult(routedChat: offlineChat)
            }
        }

        let onlineChats = await resolvedOnlineChatsForOfflineImport(currentUserID: currentUser.id)
        var routedChat: Chat?

        for onlineChat in onlineChats where onlineChat.type != .group && onlineChat.type != .secret {
            let onlineMessages = await resolvedOnlineMessagesForOfflineImport(chatID: onlineChat.id)
            guard onlineMessages.isEmpty == false else { continue }

            let importedChat = try await offlineTransport.importHistory(onlineMessages, into: onlineChat, currentUser: currentUser)
            if routedChat == nil {
                routedChat = importedChat
            }
        }

        return ChatModeTransitionResult(routedChat: routedChat)
    }

    private func routedChatForTransitionToOnline(activeChat: Chat?, currentUser: User) async throws -> Chat? {
        guard let activeChat else { return nil }

        switch activeChat.mode {
        case .online:
            return activeChat
        case .smart:
            let link = try await smartLink(for: activeChat.id, currentUserID: currentUser.id)
            guard let link else { return nil }
            let onlineChat = try await resolveOnlineChat(
                for: link,
                smartChatID: activeChat.id,
                currentUserID: currentUser.id
            )
            await ChatSnapshotStore.shared.upsertChat(onlineChat, userID: currentUser.id, mode: .online)
            return onlineChat
        case .offline:
            switch activeChat.type {
            case .selfChat:
                let onlineChat = try await resolvedSavedMessagesOnlineChat(currentUserID: currentUser.id)
                await ChatSnapshotStore.shared.upsertChat(onlineChat, userID: currentUser.id, mode: .online)
                return onlineChat
            case .direct:
                if let matchedOnlineChat = try await matchedOnlineChat(for: activeChat, currentUserID: currentUser.id) {
                    await ChatSnapshotStore.shared.upsertChat(matchedOnlineChat, userID: currentUser.id, mode: .online)
                    return matchedOnlineChat
                }

                guard let otherUserID = activeChat.participantIDs.first(where: { $0 != currentUser.id }) else {
                    return nil
                }
                let onlineChat = try await onlineRepository.createDirectChat(
                    with: otherUserID,
                    currentUserID: currentUser.id,
                    mode: .online
                )
                await ChatSnapshotStore.shared.upsertChat(onlineChat, userID: currentUser.id, mode: .online)
                return onlineChat
            case .group:
                if let matchedOnlineChat = try await matchedOnlineChat(for: activeChat, currentUserID: currentUser.id) {
                    await ChatSnapshotStore.shared.upsertChat(matchedOnlineChat, userID: currentUser.id, mode: .online)
                    return matchedOnlineChat
                }
                return nil
            case .secret:
                return nil
            }
        }
    }

    private func routedChatForTransitionToSmart(activeChat: Chat?, currentUser: User) async throws -> Chat? {
        guard let activeChat else { return nil }

        switch activeChat.mode {
        case .smart:
            return activeChat
        case .online:
            let smartChatID = SmartChatSupport.smartChatID(for: activeChat, currentUserID: currentUser.id)
            let offlineChat = await matchedOfflineChat(for: activeChat, currentUserID: currentUser.id)
            let wrappedChat = smartWrappedChat(activeChat, smartChatID: smartChatID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: currentUser.id,
                    participantIDs: activeChat.participantIDs,
                    type: activeChat.type,
                    onlineChat: activeChat,
                    offlineChat: offlineChat
                )
            )
            await ChatSnapshotStore.shared.upsertChat(wrappedChat, userID: currentUser.id, mode: .smart)
            return wrappedChat
        case .offline:
            let smartChatID = SmartChatSupport.smartChatID(for: activeChat, currentUserID: currentUser.id)
            let onlineChat = try await matchedOnlineChat(for: activeChat, currentUserID: currentUser.id)
            let wrappedChat = smartWrappedChat(onlineChat ?? activeChat, smartChatID: smartChatID)
            await SmartConversationStore.shared.upsertLink(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: currentUser.id,
                    participantIDs: wrappedChat.participantIDs,
                    type: wrappedChat.type,
                    onlineChat: onlineChat,
                    offlineChat: activeChat
                )
            )
            await ChatSnapshotStore.shared.upsertChat(wrappedChat, userID: currentUser.id, mode: .smart)
            return wrappedChat
        }
    }

    private func matchedOfflineChat(for chat: Chat, currentUserID: UUID) async -> Chat? {
        let offlineChats = await offlineTransport.fetchChats(currentUserID: currentUserID)
        let smartChatID = SmartChatSupport.smartChatID(for: chat, currentUserID: currentUserID)
        return offlineChats.first {
            SmartChatSupport.smartChatID(for: $0, currentUserID: currentUserID) == smartChatID
        }
    }

    private func matchedOnlineChat(for chat: Chat, currentUserID: UUID) async throws -> Chat? {
        let smartChatID = SmartChatSupport.smartChatID(for: chat, currentUserID: currentUserID)

        let cachedOnlineChats = await onlineRepository.cachedChats(mode: .online, for: currentUserID)
        if let cachedMatch = cachedOnlineChats.first(where: {
            SmartChatSupport.smartChatID(for: $0, currentUserID: currentUserID) == smartChatID
        }) {
            return cachedMatch
        }

        let fetchedOnlineChats = try await onlineRepository.fetchChats(mode: .online, for: currentUserID)
        return fetchedOnlineChats.first(where: {
            SmartChatSupport.smartChatID(for: $0, currentUserID: currentUserID) == smartChatID
        })
    }

    private func cachedVisibleDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async -> Chat? {
        let targetParticipantIDs = Set([currentUserID, otherUserID])
        let visibleChats = await visibleSnapshotChats(mode: mode, userID: currentUserID)
        if let visibleMatch = visibleChats.first(where: {
            $0.type == .direct && Set($0.participantIDs) == targetParticipantIDs
        }) {
            return visibleMatch
        }

        let cachedOnlineChats = await onlineRepository.cachedChats(mode: .online, for: currentUserID)
        return cachedOnlineChats.first(where: {
            $0.type == .direct && Set($0.participantIDs) == targetParticipantIDs
        })
    }

    private func resolvedSavedMessagesOnlineChat(currentUserID: UUID) async throws -> Chat {
        let cachedOnlineChats = await onlineRepository.cachedChats(mode: .online, for: currentUserID)
        if let cachedSavedMessages = cachedOnlineChats.first(where: { $0.type == .selfChat || $0.id == currentUserID }) {
            return cachedSavedMessages
        }

        let fetchedOnlineChats = try await onlineRepository.fetchChats(mode: .online, for: currentUserID)
        if let fetchedSavedMessages = fetchedOnlineChats.first(where: { $0.type == .selfChat || $0.id == currentUserID }) {
            return fetchedSavedMessages
        }

        return Chat(
            id: currentUserID,
            mode: .online,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [currentUserID],
            participants: [],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .distantPast,
            unreadCount: 0,
            isPinned: false,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(
                muteState: .active,
                previewEnabled: true,
                customSoundName: nil,
                badgeEnabled: true
            )
        )
    }

    private func resolvedOnlineChatsForOfflineImport(currentUserID: UUID) async -> [Chat] {
        let cached = await cachedChats(mode: .online, for: currentUserID)
        if cached.isEmpty == false {
            return cached
        }

        return await ChatSnapshotStore.shared.loadSharedChats(userID: currentUserID)
            .filter { $0.mode == .online || $0.mode == .smart }
    }

    private func resolvedOnlineMessagesForOfflineImport(chatID: UUID) async -> [Message] {
        let cached = await cachedMessages(chatID: chatID, mode: .online)
        if cached.isEmpty == false {
            return cached
        }

        guard let userID = activeStoredUserID() else { return [] }
        return await ChatSnapshotStore.shared.loadSharedMessages(chatID: chatID, userID: userID)
    }

    private func sendOnlineMessage(
        _ draft: OutgoingMessageDraft,
        in chat: Chat,
        senderID: UUID,
        allowQueueFallback: Bool
    ) async throws -> Message {
        let preparedDraft = normalizedDraft(draft, fallbackState: .online)

        do {
            let sentMessage = try await onlineRepository.sendMessage(preparedDraft, in: chat.id, mode: .online, senderID: senderID)
            let resolvedMessage = applyDraftDeliveryOptions(preparedDraft, to: sentMessage)
                .withDeliveryRoute(.online)
            await QueuedOutgoingMessageStore.shared.complete(messageID: preparedDraft.clientMessageID ?? resolvedMessage.clientMessageID, ownerUserID: senderID)
            await offlineTransport.synchronizeArchivedChats(with: onlineRepository, currentUserID: senderID)
            return resolvedMessage
        } catch {
            guard allowQueueFallback, shouldQueueMessageForLater(error) else {
                throw error
            }
            return await enqueuePendingOutgoingMessage(preparedDraft, in: chat, senderID: senderID)
        }
    }

    private func resendQueuedMessage(_ queuedMessage: QueuedOutgoingMessage) async throws -> Message {
        switch queuedMessage.chat.mode {
        case .smart:
            return try await sendSmartMessage(
                queuedMessage.draft,
                in: queuedMessage.chat,
                senderID: queuedMessage.ownerUserID,
                allowQueueFallback: false
            )
        case .online:
            return try await sendOnlineMessage(
                queuedMessage.draft,
                in: queuedMessage.chat,
                senderID: queuedMessage.ownerUserID,
                allowQueueFallback: false
            )
        case .offline:
            let preparedDraft = normalizedDraft(queuedMessage.draft, fallbackState: .offline)
            return try await offlineTransport.sendMessage(preparedDraft, in: queuedMessage.chat, senderID: queuedMessage.ownerUserID)
        }
    }

    private func enqueuePendingOutgoingMessage(
        _ draft: OutgoingMessageDraft,
        in chat: Chat,
        senderID: UUID
    ) async -> Message {
        let queuedDraft = OutgoingMessageDraft(
            text: draft.text,
            attachments: draft.attachments,
            voiceMessage: draft.voiceMessage,
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            clientMessageID: draft.clientMessageID ?? UUID(),
            createdAt: draft.createdAt ?? .now,
            deliveryStateOverride: nil
        )

        let queuedMessage = Message(
            id: queuedDraft.clientMessageID ?? UUID(),
            chatID: chat.id,
            senderID: senderID,
            clientMessageID: queuedDraft.clientMessageID,
            senderDisplayName: currentSenderDisplayName(for: senderID),
            mode: chat.mode,
            deliveryState: queuedDeliveryState(for: chat.mode),
            deliveryRoute: queuedDeliveryRoute(for: chat.mode),
            kind: resolvedKind(for: queuedDraft),
            text: queuedDraft.normalizedText,
            attachments: queuedDraft.attachments,
            replyToMessageID: queuedDraft.replyToMessageID,
            replyPreview: queuedDraft.replyPreview,
            communityContext: queuedDraft.communityContext,
            deliveryOptions: queuedDraft.deliveryOptions,
            status: .localPending,
            createdAt: queuedDraft.createdAt ?? .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: queuedDraft.voiceMessage,
            liveLocation: nil
        )

        await QueuedOutgoingMessageStore.shared.enqueue(
            QueuedOutgoingMessage(
                id: queuedDraft.clientMessageID ?? queuedMessage.clientMessageID,
                ownerUserID: senderID,
                chat: chat,
                draft: queuedDraft,
                createdAt: queuedDraft.createdAt ?? .now,
                lastAttemptAt: nil,
                attemptCount: 0
            )
        )

        scheduleDeferredQueuedRetryIfNeeded(ownerUserID: senderID)

        return queuedMessage
    }

    private func shouldQueueMessageForLater(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }

        if NetworkUsagePolicy.hasReachableNetwork() == false {
            return true
        }

        guard let repositoryError = error as? ChatRepositoryError else {
            return false
        }

        switch repositoryError {
        case .backendUnavailable:
            return true
        default:
            return false
        }
    }

    private func queuedDeliveryState(for mode: ChatMode) -> MessageDeliveryState {
        switch mode {
        case .smart:
            return .syncing
        case .online:
            return .online
        case .offline:
            return .offline
        }
    }

    private func queuedDeliveryRoute(for mode: ChatMode) -> MessageDeliveryRoute {
        switch mode {
        case .smart, .online:
            return .queued
        case .offline:
            return .bluetooth
        }
    }

    private func clearLocalGroupState(chatID: UUID, currentUserID: UUID) async {
        let linkedChatIDs = await relatedLocalChatIDs(for: chatID)
        await onlineRepository.purgeLocalChatArtifacts(chatIDs: Array(linkedChatIDs), currentUserID: currentUserID)
        for linkedChatID in linkedChatIDs {
            for mode in ChatMode.allCases {
                await ChatSnapshotStore.shared.removeChat(chatID: linkedChatID, userID: currentUserID, mode: mode)
                await ChatThreadStateStore.shared.clearChat(ownerUserID: currentUserID, mode: mode, chatID: linkedChatID)
            }
        }
        await SmartConversationStore.shared.removeLink(for: chatID)
    }

    private func relatedLocalChatIDs(for chatID: UUID) async -> Set<UUID> {
        var ids: Set<UUID> = [chatID]
        if let link = await SmartConversationStore.shared.link(for: chatID) {
            ids.insert(link.smartChatID)
            if let onlineChatID = link.onlineChat?.id {
                ids.insert(onlineChatID)
            }
            if let offlineChatID = link.offlineChat?.id {
                ids.insert(offlineChatID)
            }
        }
        return ids
    }

    private func currentSenderDisplayName(for senderID: UUID) -> String? {
        guard let currentUser = currentStoredUser(), currentUser.id == senderID else {
            return nil
        }

        let trimmedDisplayName = currentUser.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDisplayName.isEmpty ? currentUser.profile.username : trimmedDisplayName
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

    private func normalizedDraft(_ draft: OutgoingMessageDraft, fallbackState: MessageDeliveryState) -> OutgoingMessageDraft {
        ChatMediaPersistentStore.persist(OutgoingMessageDraft(
            text: draft.text,
            attachments: draft.attachments,
            voiceMessage: draft.voiceMessage,
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            clientMessageID: draft.clientMessageID ?? UUID(),
            createdAt: draft.createdAt ?? .now,
            deliveryStateOverride: draft.deliveryStateOverride ?? fallbackState
        ))
    }

    private func moderationDecoratedChat(_ chat: Chat, ownerUserID: UUID) async -> Chat {
        await GroupModerationSettingsStore.shared.apply(to: chat, ownerUserID: ownerUserID)
    }

    private func validateOutgoingMessageDraft(
        _ draft: OutgoingMessageDraft,
        in chat: Chat,
        senderID: UUID,
        includeTemporalRules: Bool
    ) async throws {
        guard chat.type == .group else { return }

        let senderRole = chat.group?.members.first(where: { $0.userID == senderID })?.role
        let canBypassRestrictions = senderRole == .owner || senderRole == .admin

        if chat.communityDetails?.kind == .channel, canBypassRestrictions == false {
            if draft.communityContext?.parentPostID != nil {
                guard chat.communityDetails?.commentsEnabled == true else {
                    throw ChatRepositoryError.channelCommentsDisabled
                }
            } else {
                throw ChatRepositoryError.channelPostingRestricted
            }
        }

        guard let moderationSettings = chat.moderationSettings, moderationSettings.hasActiveProtection else {
            return
        }

        if canBypassRestrictions == false {
            if moderationSettings.restrictMedia, (draft.attachments.isEmpty == false || draft.voiceMessage != nil) {
                throw ChatRepositoryError.groupMediaRestricted
            }

            if moderationSettings.restrictLinks, draftContainsLink(draft) {
                throw ChatRepositoryError.groupLinksRestricted
            }

            if includeTemporalRules, moderationSettings.slowModeSeconds > 0 {
                let remaining = await GroupModerationThrottleStore.shared.remainingSlowModeDelay(
                    ownerUserID: senderID,
                    chatID: chat.id,
                    senderID: senderID,
                    slowModeSeconds: moderationSettings.slowModeSeconds
                )
                if remaining > 0 {
                    throw ChatRepositoryError.groupSlowMode(secondsRemaining: remaining)
                }
            }

            if includeTemporalRules, moderationSettings.antiSpamEnabled {
                let wouldTriggerSpam = await GroupModerationThrottleStore.shared.wouldTriggerSpamProtection(
                    ownerUserID: senderID,
                    chatID: chat.id,
                    senderID: senderID,
                    signature: moderationSignature(for: draft)
                )
                if wouldTriggerSpam {
                    throw ChatRepositoryError.spamProtectionTriggered
                }
            }
        }
    }

    private func recordModeratedOutgoingMessageIfNeeded(
        _ draft: OutgoingMessageDraft,
        chat: Chat,
        senderID: UUID,
        createdAt: Date
    ) async {
        guard chat.type == .group else { return }
        guard let moderationSettings = chat.moderationSettings, moderationSettings.hasActiveProtection else { return }

        await GroupModerationThrottleStore.shared.recordOutgoingMessage(
            ownerUserID: senderID,
            chatID: chat.id,
            senderID: senderID,
            signature: moderationSignature(for: draft),
            createdAt: createdAt
        )
    }

    private func draftContainsLink(_ draft: OutgoingMessageDraft) -> Bool {
        guard let text = draft.normalizedText else { return false }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text.contains("http://") || text.contains("https://") || text.contains("www.")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range) != nil
    }

    private func moderationSignature(for draft: OutgoingMessageDraft) -> String {
        if let voiceMessage = draft.voiceMessage {
            return "voice:\(voiceMessage.durationSeconds)"
        }

        if draft.attachments.isEmpty == false {
            let kinds = draft.attachments.map(\.type.rawValue).joined(separator: ",")
            return "attachments:\(kinds)"
        }

        return draft.normalizedText?.lowercased() ?? "empty"
    }

    private func applyDraftDeliveryOptions(_ draft: OutgoingMessageDraft, to message: Message) -> Message {
        var resolvedMessage = message
        if resolvedMessage.deliveryOptions.hasAdvancedBehavior == false, draft.deliveryOptions.hasAdvancedBehavior {
            resolvedMessage.deliveryOptions = draft.deliveryOptions
        }
        if resolvedMessage.communityContext?.hasRoutingContext != true, draft.communityContext?.hasRoutingContext == true {
            resolvedMessage.communityContext = draft.communityContext
        }
        return resolvedMessage
    }

    private func currentStoredUser(defaults: UserDefaults = .standard) -> User? {
        guard let data = defaults.data(forKey: "app_state.current_user") else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func activeStoredUserID(defaults: UserDefaults = .standard) -> UUID? {
        currentStoredUser(defaults: defaults)?.id
    }

    private func chatsFetchKey(mode: ChatMode, userID: UUID) -> String {
        "chats:\(userID.uuidString):\(mode.rawValue)"
    }

    private func messagesFetchKey(chatID: UUID, mode: ChatMode, userID: UUID?) -> String {
        "messages:\(userID?.uuidString ?? "anonymous"):\(chatID.uuidString):\(mode.rawValue)"
    }

    private func mergeChatSnapshots(primary: [Chat], fallback: [Chat]) -> [Chat] {
        guard primary.isEmpty == false else { return fallback }
        guard fallback.isEmpty == false else { return primary }

        var mergedByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for chat in primary {
            if let fallbackChat = mergedByID[chat.id] {
                mergedByID[chat.id] = mergeChatState(existing: fallbackChat, incoming: chat)
            } else {
                mergedByID[chat.id] = chat
            }
        }

        return mergedByID.values.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    private func mergeVisibleChatSnapshots(
        primary: [Chat],
        fallback: [Chat],
        currentUserID: UUID,
        visibleMode: ChatMode
    ) -> [Chat] {
        guard primary.isEmpty == false || fallback.isEmpty == false else { return [] }

        var mergedByConversationKey: [String: Chat] = [:]

        for chat in fallback {
            mergedByConversationKey[conversationKey(for: chat, currentUserID: currentUserID)] = chatForVisibleMode(
                chat,
                visibleMode: visibleMode
            )
        }

        for chat in primary {
            let key = conversationKey(for: chat, currentUserID: currentUserID)
            let visibleChat = chatForVisibleMode(chat, visibleMode: visibleMode)
            if let fallbackChat = mergedByConversationKey[key] {
                mergedByConversationKey[key] = mergeChatState(existing: fallbackChat, incoming: visibleChat)
            } else {
                mergedByConversationKey[key] = visibleChat
            }
        }

        return mergedByConversationKey.values.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    private func chatForVisibleMode(_ chat: Chat, visibleMode: ChatMode) -> Chat {
        guard chat.mode != visibleMode else { return chat }

        return Chat(
            id: chat.id,
            mode: visibleMode,
            type: chat.type,
            title: chat.title,
            subtitle: chat.subtitle,
            participantIDs: chat.participantIDs,
            participants: chat.participants,
            group: chat.group,
            lastMessagePreview: chat.lastMessagePreview,
            lastActivityAt: chat.lastActivityAt,
            unreadCount: chat.unreadCount,
            isPinned: chat.isPinned,
            draft: chat.draft,
            disappearingPolicy: chat.disappearingPolicy,
            notificationPreferences: chat.notificationPreferences,
            guestRequest: chat.guestRequest,
            eventDetails: chat.eventDetails,
            communityDetails: chat.communityDetails,
            moderationSettings: chat.moderationSettings
        )
    }

    private func conversationKey(for chat: Chat, currentUserID: UUID) -> String {
        switch chat.type {
        case .selfChat:
            return "self:\(currentUserID.uuidString)"
        case .direct:
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "direct:\(participantKey)"
        case .group:
            if let groupID = chat.group?.id {
                return "group:\(groupID.uuidString)"
            }
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "group-fallback:\(participantKey)"
        case .secret:
            return "secret:\(chat.id.uuidString)"
        }
    }

    private func mergeMessageSnapshots(primary: [Message], fallback: [Message]) -> [Message] {
        guard primary.isEmpty == false else { return fallback.sorted(by: { $0.createdAt < $1.createdAt }) }
        guard fallback.isEmpty == false else { return primary.sorted(by: { $0.createdAt < $1.createdAt }) }

        var mergedByClientID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.clientMessageID, $0) })
        for message in primary {
            if let fallbackMessage = mergedByClientID[message.clientMessageID] {
                mergedByClientID[message.clientMessageID] = mergeMessageObjectState(primary: message, fallback: fallbackMessage)
            } else {
                mergedByClientID[message.clientMessageID] = message
            }
        }
        return mergedByClientID.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func mergeMessageObjectState(primary: Message, fallback: Message) -> Message {
        primary.mergingLocalObjectState(from: fallback)
    }

    private func scheduleDeferredQueuedRetryIfNeeded(ownerUserID: UUID) {
        Task {
            guard let nextScheduledDate = await QueuedOutgoingMessageStore.shared.nextScheduledDate(ownerUserID: ownerUserID) else {
                return
            }

            let delay = max(nextScheduledDate.timeIntervalSinceNow, 0)
            guard delay > 0 else {
                await retryPendingOutgoingMessages(currentUserID: ownerUserID)
                return
            }

            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            await retryPendingOutgoingMessages(currentUserID: ownerUserID)
        }
    }

    private func mergeChatState(existing: Chat, incoming: Chat) -> Chat {
        var merged = incoming
        if merged.draft == nil {
            merged.draft = existing.draft
        }
        if merged.eventDetails == nil {
            merged.eventDetails = existing.eventDetails
        }
        if merged.communityDetails == nil {
            merged.communityDetails = existing.communityDetails
        }
        if merged.moderationSettings == nil {
            merged.moderationSettings = existing.moderationSettings
        }
        return merged
    }

    private func cacheMessageMutation(_ message: Message, in chat: Chat, userID: UUID, mode: ChatMode) async {
        let stabilizedMessage = ChatMediaPersistentStore.persist(message)
        await ChatSnapshotStore.shared.upsertMessage(stabilizedMessage, in: chat, userID: userID, mode: mode)
        await mirrorOfflineContinuityHistoryIfNeeded(messages: [stabilizedMessage], in: chat, userID: userID, sourceMode: mode)
    }

    private func mirrorOfflineContinuitySeedIfNeeded(
        chats: [Chat],
        userID: UUID,
        sourceMode: ChatMode
    ) async {
        guard sourceMode != .offline else { return }
        guard let currentUser = currentStoredUser(), currentUser.id == userID else { return }

        let eligibleChats = chats
            .filter { shouldMirrorOfflineContinuity(for: $0, sourceMode: sourceMode) }
            .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })

        for chat in eligibleChats.prefix(24) {
            _ = try? await offlineTransport.importHistory([], into: chat, currentUser: currentUser)
        }
    }

    private func mirrorOfflineContinuityHistoryIfNeeded(
        messages: [Message],
        in chat: Chat,
        userID: UUID,
        sourceMode: ChatMode
    ) async {
        guard sourceMode != .offline else { return }
        guard shouldMirrorOfflineContinuity(for: chat, sourceMode: sourceMode) else { return }
        guard let currentUser = currentStoredUser(), currentUser.id == userID else { return }

        let normalizedMessages = messages.sorted(by: { $0.createdAt < $1.createdAt })
        _ = try? await offlineTransport.importHistory(normalizedMessages, into: chat, currentUser: currentUser)
    }

    private func shouldMirrorOfflineContinuity(for chat: Chat, sourceMode: ChatMode) -> Bool {
        guard sourceMode != .offline else { return false }
        switch chat.type {
        case .selfChat, .direct:
            return true
        case .group, .secret:
            return false
        }
    }

    private func resolvedOfflineContinuitySourceChat(
        chatID: UUID,
        mode: ChatMode,
        userID: UUID
    ) async -> Chat? {
        switch mode {
        case .smart:
            return await resolveSmartChatSnapshot(chatID: chatID, currentUserID: userID)
        case .online:
            return await resolveCachedChatSnapshot(chatID: chatID, mode: .online, userID: userID)
        case .offline:
            return nil
        }
    }

    private func resolveCachedChatSnapshot(chatID: UUID, mode: ChatMode, userID: UUID) async -> Chat? {
        let modeScopedChats = await ChatSnapshotStore.shared.loadChats(userID: userID, mode: mode)
        if let resolved = modeScopedChats.first(where: { $0.id == chatID }) {
            return resolved
        }

        let sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: userID)
        if let sharedMatch = sharedChats.first(where: { $0.id == chatID }) {
            return chatForVisibleMode(sharedMatch, visibleMode: mode)
        }

        return nil
    }

    private func visibleSnapshotChats(mode: ChatMode, userID: UUID) async -> [Chat] {
        let modeScopedChats = await ChatSnapshotStore.shared.loadChats(userID: userID, mode: mode)
        let sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: userID)
        return sanitizeChatsForVisibleMode(
            mergeVisibleChatSnapshots(
                primary: modeScopedChats,
                fallback: sharedChats,
                currentUserID: userID,
                visibleMode: mode
            ),
            visibleMode: mode
        )
    }

    private func sanitizeChatsForVisibleMode(_ chats: [Chat], visibleMode: ChatMode) -> [Chat] {
        chats.filter { $0.isAvailable(in: visibleMode) }
    }

    private func visibleSnapshotMessages(chatID: UUID, mode: ChatMode, userID: UUID) async -> [Message] {
        let modeScopedMessages = await ChatSnapshotStore.shared.loadMessages(chatID: chatID, userID: userID, mode: mode)
        let sharedMessages = await ChatSnapshotStore.shared.loadSharedMessages(chatID: chatID, userID: userID)
        return mergeMessageSnapshots(primary: modeScopedMessages, fallback: sharedMessages)
    }

    private func localDeletedMessageFallback(
        messageID: UUID,
        chatID: UUID,
        mode: ChatMode,
        requesterID: UUID
    ) async -> Message? {
        guard let existingMessage = await locallyVisibleMessage(
            messageID: messageID,
            chatID: chatID,
            mode: mode,
            userID: requesterID
        ) else {
            return nil
        }

        return Message(
            id: existingMessage.id,
            chatID: existingMessage.chatID,
            senderID: existingMessage.senderID,
            clientMessageID: existingMessage.clientMessageID,
            senderDisplayName: existingMessage.senderDisplayName,
            mode: mode,
            deliveryState: existingMessage.deliveryState,
            kind: existingMessage.kind,
            text: nil,
            attachments: [],
            replyToMessageID: existingMessage.replyToMessageID,
            replyPreview: existingMessage.replyPreview,
            status: existingMessage.status,
            createdAt: existingMessage.createdAt,
            editedAt: existingMessage.editedAt,
            deletedForEveryoneAt: .now,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )
    }

    private func locallyVisibleMessage(
        messageID: UUID,
        chatID: UUID,
        mode: ChatMode,
        userID: UUID
    ) async -> Message? {
        let visibleMessages = await visibleSnapshotMessages(chatID: chatID, mode: mode, userID: userID)
        if let visibleMatch = visibleMessages.first(where: { $0.id == messageID || $0.clientMessageID == messageID }) {
            return visibleMatch
        }

        let cached = await cachedMessages(chatID: chatID, mode: mode)
        return cached.first(where: { $0.id == messageID || $0.clientMessageID == messageID })
    }

    private func fallbackChatsAfterFetchFailure(mode: ChatMode, userID: UUID) async -> [Chat] {
        let visibleFallback = await visibleSnapshotChats(mode: mode, userID: userID)
        if visibleFallback.isEmpty == false {
            return visibleFallback
        }

        return await cachedChats(mode: mode, for: userID)
    }

    private func fallbackMessagesAfterFetchFailure(chatID: UUID, mode: ChatMode, userID: UUID) async -> [Message] {
        let visibleFallback = await visibleSnapshotMessages(chatID: chatID, mode: mode, userID: userID)
        if visibleFallback.isEmpty == false {
            return visibleFallback
        }

        return await cachedMessages(chatID: chatID, mode: mode)
    }

    private enum TimeoutError: Error {
        case operationTimedOut
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.operationTimedOut
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func resolveSmartLinkForSending(chat: Chat, currentUserID: UUID) async -> SmartConversationLink? {
        if let stored = await SmartConversationStore.shared.link(for: chat.id) {
            return stored
        }

        if let fetched = try? await smartLink(for: chat.id, currentUserID: currentUserID) {
            return fetched
        }

        if let cached = await cachedSmartLink(for: chat.id, currentUserID: currentUserID) {
            return cached
        }

        let derived = await deriveSmartLink(from: chat, currentUserID: currentUserID)
        if let derived {
            await SmartConversationStore.shared.upsertLink(derived)
        }
        return derived
    }

    private func resolveSmartChatSnapshot(chatID: UUID, currentUserID: UUID) async -> Chat? {
        if let stored = await SmartConversationStore.shared.link(for: chatID) {
            if let onlineChat = stored.onlineChat {
                return smartWrappedChat(onlineChat, smartChatID: chatID)
            }
            if let offlineChat = stored.offlineChat {
                return smartWrappedChat(offlineChat, smartChatID: chatID)
            }
        }

        let cachedChats = await cachedSmartChats(for: currentUserID)
        return cachedChats.first(where: { $0.id == chatID })
    }

    private func deriveSmartLink(from chat: Chat, currentUserID: UUID) async -> SmartConversationLink? {
        let offlineChat = await offlineTransport.fetchChats(currentUserID: currentUserID).first { candidate in
            switch chat.type {
            case .selfChat:
                return candidate.type == .selfChat || candidate.id == currentUserID
            case .direct:
                return candidate.type == .direct && Set(candidate.participantIDs) == Set(chat.participantIDs)
            case .group, .secret:
                return false
            }
        }

        guard chat.participantIDs.isEmpty == false || chat.type == .selfChat else {
            return nil
        }

        return SmartConversationLink(
            smartChatID: chat.id,
            currentUserID: currentUserID,
            participantIDs: chat.participantIDs.isEmpty ? [currentUserID] : chat.participantIDs,
            type: chat.type,
            onlineChat: nil,
            offlineChat: offlineChat
        )
    }

    private func upsertSmartLink(
        from existingLink: SmartConversationLink?,
        smartChat: Chat,
        currentUserID: UUID,
        offlineChat: Chat?
    ) async {
        let link = SmartConversationLink(
            smartChatID: smartChat.id,
            currentUserID: currentUserID,
            participantIDs: existingLink?.participantIDs.isEmpty == false ? existingLink?.participantIDs ?? [] : smartChat.participantIDs,
            type: existingLink?.type ?? smartChat.type,
            onlineChat: existingLink?.onlineChat,
            offlineChat: offlineChat ?? existingLink?.offlineChat
        )
        await SmartConversationStore.shared.upsertLink(link)
    }

    private func smartWrappedChat(_ chat: Chat, smartChatID: UUID) -> Chat {
        Chat(
            id: smartChatID,
            mode: .smart,
            type: chat.type,
            title: chat.title,
            subtitle: chat.subtitle,
            participantIDs: chat.participantIDs,
            participants: chat.participants,
            group: chat.group,
            lastMessagePreview: chat.lastMessagePreview,
            lastActivityAt: chat.lastActivityAt,
            unreadCount: chat.unreadCount,
            isPinned: chat.isPinned,
            draft: chat.draft,
            disappearingPolicy: chat.disappearingPolicy,
            notificationPreferences: chat.notificationPreferences,
            guestRequest: chat.guestRequest,
            eventDetails: chat.eventDetails,
            communityDetails: chat.communityDetails,
            moderationSettings: chat.moderationSettings
        )
    }
}

private final class ChatRepositoryExecutionCoordinator: @unchecked Sendable {
    static let shared = ChatRepositoryExecutionCoordinator()

    private struct RetryState {
        var isRunning = false
        var lastFinishedAt: Date?
    }

    private let lock = NSLock()
    private var chatsTasks: [String: (id: UUID, task: Task<[Chat], Error>)] = [:]
    private var messagesTasks: [String: (id: UUID, task: Task<[Message], Error>)] = [:]
    private var retryStates: [UUID: RetryState] = [:]
    private let retryCooldown: TimeInterval = 2.5

    func runChatsFetch(
        key: String,
        operation: @escaping () async throws -> [Chat]
    ) async throws -> [Chat] {
        let entry = resolveChatsTask(key: key, operation: operation)
        defer { clearChatsTaskIfNeeded(key: key, id: entry.id) }
        return try await entry.task.value
    }

    func runMessagesFetch(
        key: String,
        operation: @escaping () async throws -> [Message]
    ) async throws -> [Message] {
        let entry = resolveMessagesTask(key: key, operation: operation)
        defer { clearMessagesTaskIfNeeded(key: key, id: entry.id) }
        return try await entry.task.value
    }

    func beginRetryIfNeeded(ownerUserID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let state = retryStates[ownerUserID] ?? RetryState()
        if state.isRunning {
            return false
        }
        if let lastFinishedAt = state.lastFinishedAt, now.timeIntervalSince(lastFinishedAt) < retryCooldown {
            return false
        }

        retryStates[ownerUserID] = RetryState(isRunning: true, lastFinishedAt: state.lastFinishedAt)
        return true
    }

    func finishRetry(ownerUserID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        retryStates[ownerUserID] = RetryState(isRunning: false, lastFinishedAt: Date())
    }

    private func resolveChatsTask(
        key: String,
        operation: @escaping () async throws -> [Chat]
    ) -> (id: UUID, task: Task<[Chat], Error>) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = chatsTasks[key] {
            return existing
        }

        let entry = (id: UUID(), task: Task { try await operation() })
        chatsTasks[key] = entry
        return entry
    }

    private func resolveMessagesTask(
        key: String,
        operation: @escaping () async throws -> [Message]
    ) -> (id: UUID, task: Task<[Message], Error>) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = messagesTasks[key] {
            return existing
        }

        let entry = (id: UUID(), task: Task { try await operation() })
        messagesTasks[key] = entry
        return entry
    }

    private func clearChatsTaskIfNeeded(key: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard chatsTasks[key]?.id == id else { return }
        chatsTasks[key] = nil
    }

    private func clearMessagesTaskIfNeeded(key: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard messagesTasks[key]?.id == id else { return }
        messagesTasks[key] = nil
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
