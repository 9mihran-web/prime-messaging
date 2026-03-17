import Foundation

enum ChatRepositoryError: LocalizedError {
    case backendUnavailable
    case chatNotFound
    case userNotFound
    case messageNotFound
    case editNotAllowed
    case deleteNotAllowed
    case messageDeleted
    case editNotSupported
    case emptyMessage
    case senderNotInChat
    case chatModeMismatch
    case invalidDirectChat
    case groupPermissionDenied
    case unsupportedOfflineAction
    case invalidGroupOperation

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Messaging server is unavailable."
        case .chatNotFound:
            return "Chat not found."
        case .userNotFound:
            return "User not found."
        case .messageNotFound:
            return "Message not found."
        case .editNotAllowed:
            return "You can edit only your own text messages."
        case .deleteNotAllowed:
            return "You can delete only your own messages."
        case .messageDeleted:
            return "This message was already deleted."
        case .editNotSupported:
            return "Only text messages can be edited."
        case .emptyMessage:
            return "Message cannot be empty."
        case .senderNotInChat:
            return "You are not a member of this chat."
        case .chatModeMismatch:
            return "This action is not available in the current chat mode."
        case .invalidDirectChat:
            return "Could not open this direct chat."
        case .groupPermissionDenied:
            return "Only group managers can do that."
        case .unsupportedOfflineAction:
            return "This action is available only for online groups."
        case .invalidGroupOperation:
            return "Could not update the group."
        }
    }
}

struct BackendChatRepository: ChatRepository {
    private enum StorageKeys {
        static let cachedChatsPrefix = "online.cached_chats"
        static let cachedMessagesPrefix = "online.cached_messages"
    }

    let fallback: ChatRepository
    private let decoder = BackendChatRepository.makeDecoder()

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL
        else {
            return try await fallback.fetchChats(mode: mode, for: userID)
        }

        do {
            let chats = try await fetchChatsUsingCompatibleTransport(baseURL: baseURL, mode: mode, userID: userID)
            let preparedChats = injectingSavedMessages(into: chats, mode: mode, userID: userID)
            saveCachedChats(preparedChats, mode: mode, userID: userID, baseURL: baseURL)
            return preparedChats
        } catch {
            if let cachedChats = loadCachedChats(mode: mode, userID: userID, baseURL: baseURL) {
                return injectingSavedMessages(into: cachedChats, mode: mode, userID: userID)
            }

            if mode == .online {
                return injectingSavedMessages(into: [], mode: mode, userID: userID)
            }

            throw error
        }
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL
        else {
            return try await fallback.fetchMessages(chatID: chatID, mode: mode)
        }

        do {
            let messages = try await fetchMessagesUsingCompatibleTransport(baseURL: baseURL, chatID: chatID)
            saveCachedMessages(messages, chatID: chatID, mode: mode, baseURL: baseURL)
            return messages
        } catch {
            if let cachedMessages = loadCachedMessages(chatID: chatID, mode: mode, baseURL: baseURL) {
                return cachedMessages
            }

            throw error
        }
    }

    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws {
        let body = MarkChatReadRequest(
            readerID: readerID.uuidString,
            mode: mode.rawValue
        )
        let _: BackendMutationOKResponse = try await request(
            path: "/chats/\(chatID.uuidString)/read",
            method: "POST",
            body: body,
            userID: readerID,
            fallback: nil
        )
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        try await sendMessage(
            OutgoingMessageDraft(text: text),
            in: chatID,
            mode: mode,
            senderID: senderID
        )
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        let body = try makeSendMessageRequest(from: draft, chatID: chatID, senderID: senderID, mode: mode)
        return try await request(
            path: "/messages/send",
            method: "POST",
            body: body,
            userID: senderID,
            fallback: {
                try await fallback.sendMessage(draft, in: chatID, mode: mode, senderID: senderID)
            }
        )
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message {
        let body = EditMessageRequest(
            chatID: chatID.uuidString,
            editorID: editorID.uuidString,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try await request(
            path: "/messages/\(messageID.uuidString)",
            method: "PATCH",
            body: body,
            userID: editorID,
            fallback: nil
        )
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message {
        let body = DeleteMessageRequest(
            chatID: chatID.uuidString,
            requesterID: requesterID.uuidString
        )
        return try await request(
            path: "/messages/\(messageID.uuidString)",
            method: "DELETE",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat {
        let body = DirectChatRequest(currentUserID: currentUserID.uuidString, otherUserID: otherUserID.uuidString, mode: mode.rawValue)
        return try await request(
            path: "/chats/direct",
            method: "POST",
            body: body,
            userID: currentUserID,
            fallback: {
                try await fallback.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: mode)
            }
        )
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        throw OfflineTransportError.nearbySelectionRequired
    }

    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat {
        let body = GroupChatRequest(
            title: title,
            ownerID: ownerID.uuidString,
            memberIDs: memberIDs.map(\.uuidString),
            mode: mode.rawValue
        )
        return try await request(
            path: "/chats/group",
            method: "POST",
            body: body,
            userID: ownerID,
            fallback: {
                try await fallback.createGroupChat(title: title, memberIDs: memberIDs, ownerID: ownerID, mode: mode)
            }
        )
    }

    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat {
        let body = UpdateGroupRequest(
            requesterID: requesterID.uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group",
            method: "PATCH",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupAvatarRequest(
            requesterID: requesterID.uuidString,
            imageBase64: imageData.base64EncodedString()
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/avatar",
            method: "POST",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupAvatarDeleteRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/avatar",
            method: "DELETE",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupMembersRequest(
            requesterID: requesterID.uuidString,
            memberIDs: memberIDs.map(\.uuidString)
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/members",
            method: "POST",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupMemberRemoveRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/members/\(memberID.uuidString)",
            method: "DELETE",
            body: body,
            userID: requesterID,
            fallback: nil
        )
    }

    func saveDraft(_ draft: Draft) async throws {
        try await fallback.saveDraft(draft)
    }

    private func injectingSavedMessages(into chats: [Chat], mode: ChatMode, userID: UUID) -> [Chat] {
        guard chats.contains(where: { $0.type == .selfChat }) == false else {
            return chats
        }

        let savedMessages = Chat(
            id: userID,
            mode: mode,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [userID],
            participants: [],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: true,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(
                muteState: .active,
                previewEnabled: true,
                customSoundName: nil,
                badgeEnabled: true
            )
        )

        return [savedMessages] + chats
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        userID: UUID?,
        fallback: (() async throws -> Response)?
    ) async throws -> Response {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            if let fallback {
                return try await fallback()
            }
            throw ChatRepositoryError.backendUnavailable
        }

        let bodyData = try JSONEncoder().encode(body)

        let strategy = await BackendTransportStrategyStore.shared.strategy(for: baseURL)

        switch strategy {
        case .legacy:
            return try await requestWithLegacyPrimary(
                baseURL: baseURL,
                path: path,
                method: method,
                bodyData: bodyData,
                userID: userID
            )
        case .authenticated:
            return try await requestWithAuthenticatedPrimary(
                baseURL: baseURL,
                path: path,
                method: method,
                bodyData: bodyData,
                userID: userID
            )
        case .unknown:
            let prefersLegacyTransport = await shouldUseLegacyTransport(for: userID)
            if prefersLegacyTransport {
                return try await requestWithLegacyPrimary(
                    baseURL: baseURL,
                    path: path,
                    method: method,
                    bodyData: bodyData,
                    userID: userID
                )
            }

            return try await requestWithAuthenticatedPrimary(
                baseURL: baseURL,
                path: path,
                method: method,
                bodyData: bodyData,
                userID: userID
            )
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw mappedError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    private func makeSendMessageRequest(
        from draft: OutgoingMessageDraft,
        chatID: UUID,
        senderID: UUID,
        mode: ChatMode
    ) throws -> SendMessageRequest {
        let attachments = try draft.attachments.map { attachment in
            SendAttachmentRequest(
                type: attachment.type.rawValue,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                byteSize: attachment.byteSize,
                dataBase64: try loadBase64(from: attachment.localURL)
            )
        }

        let voiceMessage = try draft.voiceMessage.map { voiceMessage in
            SendVoiceMessageRequest(
                durationSeconds: voiceMessage.durationSeconds,
                waveformSamples: voiceMessage.waveformSamples,
                fileName: voiceMessage.localFileURL?.lastPathComponent ?? "voice.m4a",
                dataBase64: try loadBase64(from: voiceMessage.localFileURL)
            )
        }

        return SendMessageRequest(
            chatID: chatID.uuidString,
            senderID: senderID.uuidString,
            senderDisplayName: resolvedCurrentSenderDisplayName(for: senderID),
            text: draft.normalizedText,
            mode: mode.rawValue,
            kind: resolvedKind(for: draft).rawValue,
            attachments: attachments,
            voiceMessage: voiceMessage
        )
    }

    private func resolvedCurrentSenderDisplayName(for senderID: UUID) -> String? {
        let decoder = JSONDecoder()
        guard
            let data = UserDefaults.standard.data(forKey: "app_state.current_user"),
            let user = try? decoder.decode(User.self, from: data),
            user.id == senderID
        else {
            return nil
        }

        let trimmedDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDisplayName.isEmpty ? user.profile.username : trimmedDisplayName
    }

    private func loadBase64(from url: URL?) throws -> String? {
        guard let url else { return nil }
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
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

    private func mappedError(statusCode: Int, data: Data) -> Error {
        let serverError = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error

        switch (statusCode, serverError) {
        case (404, "chat_not_found"):
            return ChatRepositoryError.chatNotFound
        case (404, "user_not_found"):
            return ChatRepositoryError.userNotFound
        case (404, "message_not_found"):
            return ChatRepositoryError.messageNotFound
        case (403, "edit_not_allowed"):
            return ChatRepositoryError.editNotAllowed
        case (403, "delete_not_allowed"):
            return ChatRepositoryError.deleteNotAllowed
        case (403, "sender_not_in_chat"):
            return ChatRepositoryError.senderNotInChat
        case (403, "group_permission_denied"):
            return ChatRepositoryError.groupPermissionDenied
        case (409, "message_deleted"):
            return ChatRepositoryError.messageDeleted
        case (409, "edit_not_supported"):
            return ChatRepositoryError.editNotSupported
        case (409, "empty_message"):
            return ChatRepositoryError.emptyMessage
        case (409, "chat_mode_mismatch"):
            return ChatRepositoryError.chatModeMismatch
        case (409, "invalid_direct_chat"):
            return ChatRepositoryError.invalidDirectChat
        case (409, "invalid_group_operation"), (409, "invalid_group_chat"), (409, "user_already_in_group"):
            return ChatRepositoryError.invalidGroupOperation
        default:
            return ChatRepositoryError.backendUnavailable
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        BackendJSONDecoder.make()
    }

    private func shouldUseLegacyTransport(for userID: UUID?) async -> Bool {
        if let userID {
            if await AuthSessionStore.shared.session(for: userID) != nil {
                return false
            }
            if await LocalAccountStore.shared.credentials(for: userID) != nil {
                return false
            }
            return true
        }

        if let activeStoredUserID = activeStoredUserID() {
            if await AuthSessionStore.shared.session(for: activeStoredUserID) != nil {
                return false
            }
            if await LocalAccountStore.shared.credentials(for: activeStoredUserID) != nil {
                return false
            }
            return true
        }

        return await AuthSessionStore.shared.mostRecentSession() == nil
    }

    private func fetchChatsUsingCompatibleTransport(baseURL: URL, mode: ChatMode, userID: UUID) async throws -> [Chat] {
        let strategy = await BackendTransportStrategyStore.shared.strategy(for: baseURL)

        switch strategy {
        case .legacy:
            return try await fetchChatsWithLegacyPrimary(baseURL: baseURL, mode: mode, userID: userID)
        case .authenticated:
            return try await fetchChatsWithAuthenticatedPrimary(baseURL: baseURL, mode: mode, userID: userID)
        case .unknown:
            if await shouldUseLegacyTransport(for: userID) {
                return try await fetchChatsWithLegacyPrimary(baseURL: baseURL, mode: mode, userID: userID)
            }

            return try await fetchChatsWithAuthenticatedPrimary(baseURL: baseURL, mode: mode, userID: userID)
        }
    }

    private func authenticatedFetchChats(baseURL: URL, mode: ChatMode, userID: UUID) async throws -> [Chat] {
        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/chats",
            method: "GET",
            queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)],
            userID: userID
        )
        try validate(response: response, data: data)
        return try decoder.decode([Chat].self, from: data)
    }

    private func fetchMessagesUsingCompatibleTransport(baseURL: URL, chatID: UUID) async throws -> [Message] {
        let strategy = await BackendTransportStrategyStore.shared.strategy(for: baseURL)

        switch strategy {
        case .legacy:
            return try await fetchMessagesWithLegacyPrimary(baseURL: baseURL, chatID: chatID)
        case .authenticated:
            return try await fetchMessagesWithAuthenticatedPrimary(baseURL: baseURL, chatID: chatID)
        case .unknown:
            if await shouldUseLegacyTransport(for: activeStoredUserID()) {
                return try await fetchMessagesWithLegacyPrimary(baseURL: baseURL, chatID: chatID)
            }

            return try await fetchMessagesWithAuthenticatedPrimary(baseURL: baseURL, chatID: chatID)
        }
    }

    private func legacyFetchMessages(baseURL: URL, chatID: UUID) async throws -> [Message] {
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/messages",
            method: "GET",
            queryItems: [URLQueryItem(name: "chat_id", value: chatID.uuidString)]
        )
        try validate(response: response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    private func authenticatedFetchMessages(baseURL: URL, chatID: UUID) async throws -> [Message] {
        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/messages",
            method: "GET",
            queryItems: [URLQueryItem(name: "chat_id", value: chatID.uuidString)],
            userID: activeStoredUserID()
        )
        try validate(response: response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    private func legacyFetchChats(baseURL: URL, mode: ChatMode, userID: UUID) async throws -> [Chat] {
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/chats",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "user_id", value: userID.uuidString),
                URLQueryItem(name: "mode", value: mode.rawValue),
            ]
        )
        try validate(response: response, data: data)
        let chats = try decodeLossyArray(Chat.self, from: data)
        return try await hydrateLegacyParticipantsIfNeeded(in: chats, baseURL: baseURL, currentUserID: userID)
    }

    private func hydrateLegacyParticipantsIfNeeded(
        in chats: [Chat],
        baseURL: URL,
        currentUserID: UUID
    ) async throws -> [Chat] {
        var hydratedChats = chats

        for index in hydratedChats.indices where hydratedChats[index].type == .direct && hydratedChats[index].participants.isEmpty {
            let participantIDs = hydratedChats[index].participantIDs
            var participants: [ChatParticipant] = []
            for participantID in participantIDs {
                if let participant = try? await legacyFetchUser(baseURL: baseURL, userID: participantID) {
                    participants.append(participant)
                }
            }
            hydratedChats[index].participants = participants

            if let otherParticipant = hydratedChats[index].directParticipant(for: currentUserID) {
                let resolvedTitle = (otherParticipant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (otherParticipant.displayName ?? otherParticipant.username)
                    : otherParticipant.username
                hydratedChats[index].title = resolvedTitle
                hydratedChats[index].subtitle = "@\(otherParticipant.username)"
            }
        }

        return hydratedChats
    }

    private func legacyFetchUser(baseURL: URL, userID: UUID) async throws -> ChatParticipant? {
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/users/\(userID.uuidString)",
            method: "GET"
        )
        try validate(response: response, data: data)
        let user = try decoder.decode(User.self, from: data)
        return ChatParticipant(
            id: user.id,
            username: user.profile.username,
            displayName: user.profile.displayName
        )
    }

    private func fetchChatsWithLegacyPrimary(baseURL: URL, mode: ChatMode, userID: UUID) async throws -> [Chat] {
        do {
            let chats = try await legacyFetchChats(baseURL: baseURL, mode: mode, userID: userID)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return chats
        } catch {
            let chats = try await authenticatedFetchChats(baseURL: baseURL, mode: mode, userID: userID)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return chats
        }
    }

    private func fetchChatsWithAuthenticatedPrimary(baseURL: URL, mode: ChatMode, userID: UUID) async throws -> [Chat] {
        do {
            let chats = try await authenticatedFetchChats(baseURL: baseURL, mode: mode, userID: userID)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return chats
        } catch {
            let chats = try await legacyFetchChats(baseURL: baseURL, mode: mode, userID: userID)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return chats
        }
    }

    private func fetchMessagesWithLegacyPrimary(baseURL: URL, chatID: UUID) async throws -> [Message] {
        do {
            let messages = try await legacyFetchMessages(baseURL: baseURL, chatID: chatID)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return messages
        } catch {
            let messages = try await authenticatedFetchMessages(baseURL: baseURL, chatID: chatID)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return messages
        }
    }

    private func fetchMessagesWithAuthenticatedPrimary(baseURL: URL, chatID: UUID) async throws -> [Message] {
        do {
            let messages = try await authenticatedFetchMessages(baseURL: baseURL, chatID: chatID)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return messages
        } catch {
            let messages = try await legacyFetchMessages(baseURL: baseURL, chatID: chatID)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return messages
        }
    }

    private func requestWithLegacyPrimary<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        bodyData: Data,
        userID: UUID?
    ) async throws -> Response {
        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData
            )
            try validate(response: response, data: data)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return try decoder.decode(Response.self, from: data)
        } catch {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData,
                userID: userID
            )
            try validate(response: response, data: data)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func requestWithAuthenticatedPrimary<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        bodyData: Data,
        userID: UUID?
    ) async throws -> Response {
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData,
                userID: userID
            )
            try validate(response: response, data: data)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return try decoder.decode(Response.self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData
            )
            try validate(response: response, data: data)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func decodeLossyArray<Element: Decodable>(_ type: Element.Type, from data: Data) throws -> [Element] {
        try decoder.decode([LossyDecodable<Element>].self, from: data).compactMap(\.value)
    }

    private func saveCachedChats(_ chats: [Chat], mode: ChatMode, userID: UUID, baseURL: URL, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(chats) else { return }
        defaults.set(data, forKey: cachedChatsKey(mode: mode, userID: userID, baseURL: baseURL))
    }

    private func loadCachedChats(mode: ChatMode, userID: UUID, baseURL: URL, defaults: UserDefaults = .standard) -> [Chat]? {
        guard let data = defaults.data(forKey: cachedChatsKey(mode: mode, userID: userID, baseURL: baseURL)) else {
            return nil
        }

        return try? decoder.decode([Chat].self, from: data)
    }

    private func saveCachedMessages(_ messages: [Message], chatID: UUID, mode: ChatMode, baseURL: URL, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        defaults.set(data, forKey: cachedMessagesKey(chatID: chatID, mode: mode, baseURL: baseURL))
    }

    private func loadCachedMessages(chatID: UUID, mode: ChatMode, baseURL: URL, defaults: UserDefaults = .standard) -> [Message]? {
        guard let data = defaults.data(forKey: cachedMessagesKey(chatID: chatID, mode: mode, baseURL: baseURL)) else {
            return nil
        }

        return try? decoder.decode([Message].self, from: data)
    }

    private func cachedChatsKey(mode: ChatMode, userID: UUID, baseURL: URL) -> String {
        "\(StorageKeys.cachedChatsPrefix).\(baseURL.absoluteString).\(mode.rawValue).\(userID.uuidString)"
    }

    private func cachedMessagesKey(chatID: UUID, mode: ChatMode, baseURL: URL) -> String {
        "\(StorageKeys.cachedMessagesPrefix).\(baseURL.absoluteString).\(mode.rawValue).\(chatID.uuidString)"
    }

    private func legacyRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> (Data, URLResponse) {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw ChatRepositoryError.backendUnavailable
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ChatRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        return try await URLSession.shared.data(for: request)
    }

    private func activeStoredUserID(defaults: UserDefaults = .standard) -> UUID? {
        guard let data = defaults.data(forKey: "app_state.current_user") else {
            return nil
        }

        return try? JSONDecoder().decode(User.self, from: data).id
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Value.self)
    }
}

private enum BackendTransportStrategy {
    case unknown
    case legacy
    case authenticated
}

private actor BackendTransportStrategyStore {
    static let shared = BackendTransportStrategyStore()

    private var strategiesByBaseURL: [String: BackendTransportStrategy] = [:]

    func strategy(for baseURL: URL) -> BackendTransportStrategy {
        strategiesByBaseURL[baseURL.absoluteString] ?? .unknown
    }

    func set(_ strategy: BackendTransportStrategy, for baseURL: URL) {
        strategiesByBaseURL[baseURL.absoluteString] = strategy
    }
}

private struct SendMessageRequest: Encodable {
    let chatID: String
    let senderID: String
    let senderDisplayName: String?
    let text: String?
    let mode: String
    let kind: String
    let attachments: [SendAttachmentRequest]
    let voiceMessage: SendVoiceMessageRequest?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case senderID = "sender_id"
        case senderDisplayName = "sender_display_name"
        case text
        case mode
        case kind
        case attachments
        case voiceMessage = "voice_message"
    }
}

private struct SendAttachmentRequest: Encodable {
    let type: String
    let fileName: String
    let mimeType: String
    let byteSize: Int64
    let dataBase64: String?

    enum CodingKeys: String, CodingKey {
        case type
        case fileName = "file_name"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case dataBase64 = "data_base64"
    }
}

private struct SendVoiceMessageRequest: Encodable {
    let durationSeconds: Int
    let waveformSamples: [Float]
    let fileName: String
    let dataBase64: String?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case waveformSamples = "waveform_samples"
        case fileName = "file_name"
        case dataBase64 = "data_base64"
    }
}

private struct DirectChatRequest: Encodable {
    let currentUserID: String
    let otherUserID: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case currentUserID = "current_user_id"
        case otherUserID = "other_user_id"
        case mode
    }
}

private struct GroupChatRequest: Encodable {
    let title: String
    let ownerID: String
    let memberIDs: [String]
    let mode: String

    enum CodingKeys: String, CodingKey {
        case title
        case ownerID = "owner_id"
        case memberIDs = "member_ids"
        case mode
    }
}

private struct EditMessageRequest: Encodable {
    let chatID: String
    let editorID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case editorID = "editor_id"
        case text
    }
}

private struct DeleteMessageRequest: Encodable {
    let chatID: String
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case requesterID = "requester_id"
    }
}

private struct MarkChatReadRequest: Encodable {
    let readerID: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case readerID = "reader_id"
        case mode
    }
}

private struct BackendMutationOKResponse: Decodable {
    let ok: Bool
}

private struct UpdateGroupRequest: Encodable {
    let requesterID: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case title
    }
}

private struct GroupAvatarRequest: Encodable {
    let requesterID: String
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case imageBase64 = "image_base64"
    }
}

private struct GroupAvatarDeleteRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct GroupMembersRequest: Encodable {
    let requesterID: String
    let memberIDs: [String]

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case memberIDs = "member_ids"
    }
}

private struct GroupMemberRemoveRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}
