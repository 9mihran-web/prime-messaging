import AVFoundation
import Foundation
import OSLog

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
    case guestRequestsBlocked
    case guestRequestPending
    case guestRequestApprovalRequired
    case guestRequestIntroRequired
    case guestRequestIntroTooLong
    case guestRequestDeclined
    case groupPermissionDenied
    case groupInvitesBlocked
    case unsupportedOfflineAction
    case invalidGroupOperation
    case groupSlowMode(secondsRemaining: Int)
    case groupMediaRestricted
    case groupLinksRestricted
    case spamProtectionTriggered
    case channelPostingRestricted
    case channelCommentsDisabled
    case cellularSyncDisabled
    case cellularMediaUploadsDisabled
    case inviteNotFound
    case chatNotPublic
    case joinApprovalRequired
    case userBanned
    case officialBadgePermissionDenied

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
        case .guestRequestsBlocked:
            return "This user does not accept guest message requests."
        case .guestRequestPending:
            return "Your guest request is waiting for approval."
        case .guestRequestApprovalRequired:
            return "Approve or decline the guest request first."
        case .guestRequestIntroRequired:
            return "Send a short introduction up to 150 characters."
        case .guestRequestIntroTooLong:
            return "Guest request introduction must be 150 characters or less."
        case .guestRequestDeclined:
            return "This guest request was declined."
        case .groupPermissionDenied:
            return "Only group managers can do that."
        case .groupInvitesBlocked:
            return "This user accepts group invites only from saved contacts."
        case .unsupportedOfflineAction:
            return "This action is available only for online groups."
        case .invalidGroupOperation:
            return "Could not update the group."
        case let .groupSlowMode(secondsRemaining):
            return "Slow mode is active. Try again in \(secondsRemaining)s."
        case .groupMediaRestricted:
            return "Media messages are restricted in this group."
        case .groupLinksRestricted:
            return "Links are restricted in this group."
        case .spamProtectionTriggered:
            return "Please slow down. Anti-spam protection is active."
        case .channelPostingRestricted:
            return "Only channel managers can post here."
        case .channelCommentsDisabled:
            return "Comments are disabled for this channel."
        case .cellularSyncDisabled:
            return "Cellular data is disabled for chat sync. Connect to Wi-Fi or enable cellular sync in Data and Storage."
        case .cellularMediaUploadsDisabled:
            return "Cellular data is disabled for media uploads. Connect to Wi-Fi or enable media uploads in Data and Storage."
        case .inviteNotFound:
            return "Invite link not found."
        case .chatNotPublic:
            return "This chat is not public."
        case .joinApprovalRequired:
            return "This chat requires approval before joining."
        case .userBanned:
            return "This user is banned from the group right now."
        case .officialBadgePermissionDenied:
            return "Only Mihran can mark a channel as official right now."
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
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "BackendChatRepository")

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL
        else {
            return try await fallback.fetchChats(mode: mode, for: userID)
        }

        let cachedChats = loadCachedChats(mode: mode, userID: userID, baseURL: baseURL) ?? []

        do {
            let chats = try await fetchChatsUsingCompatibleTransport(baseURL: baseURL, mode: mode, userID: userID)
            let mergedChats = mergeChats(cached: cachedChats, incoming: chats)
            let preparedChats = injectingSavedMessages(into: mergedChats, mode: mode, userID: userID)
            let normalizedChats = await CommunityChatMetadataStore.shared.normalize(preparedChats, ownerUserID: userID)
            saveCachedChats(normalizedChats, mode: mode, userID: userID, baseURL: baseURL)
            return normalizedChats
        } catch {
            if cachedChats.isEmpty == false {
                let preparedChats = injectingSavedMessages(into: cachedChats, mode: mode, userID: userID)
                return await CommunityChatMetadataStore.shared.normalize(preparedChats, ownerUserID: userID)
            }

            if mode == .online {
                let preparedChats = injectingSavedMessages(into: [], mode: mode, userID: userID)
                return await CommunityChatMetadataStore.shared.normalize(preparedChats, ownerUserID: userID)
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

        let currentUserID = activeStoredUserID()
        let cachedMessages = loadCachedMessages(chatID: chatID, mode: mode, userID: currentUserID, baseURL: baseURL) ?? []

        do {
            let messages = try await fetchMessagesUsingCompatibleTransport(
                baseURL: baseURL,
                chatID: chatID,
                currentUserID: currentUserID
            )
            let mergedMessages = mergeMessages(cached: cachedMessages, incoming: messages)
            saveCachedMessages(
                mergedMessages,
                chatID: chatID,
                mode: mode,
                userID: currentUserID,
                baseURL: baseURL
            )
            return mergedMessages
        } catch {
            if cachedMessages.isEmpty == false {
                return cachedMessages
            }

            throw error
        }
    }

    func cachedChats(mode: ChatMode, for userID: UUID) async -> [Chat] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return (try? await fallback.fetchChats(mode: mode, for: userID)) ?? []
        }

        let cached = loadCachedChats(mode: mode, userID: userID, baseURL: baseURL) ?? []
        let preparedChats = injectingSavedMessages(into: cached, mode: mode, userID: userID)
        return await CommunityChatMetadataStore.shared.normalize(preparedChats, ownerUserID: userID)
    }

    func cachedMessages(chatID: UUID, mode: ChatMode) async -> [Message] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return (try? await fallback.fetchMessages(chatID: chatID, mode: mode)) ?? []
        }

        return loadCachedMessages(
            chatID: chatID,
            mode: mode,
            userID: activeStoredUserID(),
            baseURL: baseURL
        ) ?? []
    }

    func purgeLocalChatArtifacts(chatIDs: [UUID], currentUserID: UUID) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else { return }
        guard chatIDs.isEmpty == false else { return }

        var cachedChats = loadCachedChats(mode: .online, userID: currentUserID, baseURL: baseURL) ?? []
        let chatIDSet = Set(chatIDs)
        cachedChats.removeAll { chatIDSet.contains($0.id) }
        saveCachedChats(cachedChats, mode: .online, userID: currentUserID, baseURL: baseURL)

        for chatID in chatIDSet {
            UserDefaults.standard.removeObject(
                forKey: cachedMessagesKey(
                    chatID: chatID,
                    mode: .online,
                    userID: currentUserID,
                    baseURL: baseURL
                )
            )
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
            networkAccessKind: .chatSync,
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

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        try await sendMessage(draft, in: chat.id, mode: chat.mode, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        let stabilizedDraft = ChatMediaPersistentStore.persist(draft)
        let networkAccessKind = resolvedNetworkAccessKind(for: stabilizedDraft)
        let body = try await makeSendMessageRequest(from: stabilizedDraft, chatID: chatID, senderID: senderID, mode: mode)
        let response: Message = try await request(
            path: "/messages/send",
            method: "POST",
            body: body,
            userID: senderID,
            networkAccessKind: networkAccessKind,
            fallback: {
                try await fallback.sendMessage(stabilizedDraft, in: chatID, mode: mode, senderID: senderID)
            }
        )
        return ChatMediaPersistentStore.persist(response.applyingDraftObjectState(from: stabilizedDraft))
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, mode: ChatMode, userID: UUID) async throws -> Message {
        let body = MessageReactionRequest(
            chatID: chatID.uuidString,
            userID: userID.uuidString,
            emoji: emoji
        )
        return try await request(
            path: "/messages/\(messageID.uuidString)/reactions",
            method: "POST",
            body: body,
            userID: userID,
            networkAccessKind: .chatSync,
            fallback: nil
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
            networkAccessKind: .chatSync,
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
            networkAccessKind: .chatSync,
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
            networkAccessKind: .chatSync,
            fallback: {
                try await fallback.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: mode)
            }
        )
    }

    func submitGuestRequest(introText: String, in chatID: UUID, senderID: UUID) async throws -> Chat {
        let body = GuestRequestSubmitRequest(
            requesterID: senderID.uuidString,
            introText: introText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try await request(
            path: "/chats/\(chatID.uuidString)/guest-request",
            method: "POST",
            body: body,
            userID: senderID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func respondToGuestRequest(in chatID: UUID, approve: Bool, responderID: UUID) async throws -> Chat {
        let body = GuestRequestResponseRequest(
            responderID: responderID.uuidString,
            action: approve ? "approve" : "decline"
        )
        return try await request(
            path: "/chats/\(chatID.uuidString)/guest-request",
            method: "PATCH",
            body: body,
            userID: responderID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        throw OfflineTransportError.nearbySelectionRequired
    }

    func createGroupChat(
        title: String,
        memberIDs: [UUID],
        ownerID: UUID,
        mode: ChatMode,
        communityDetails: CommunityChatDetails?
    ) async throws -> Chat {
        let body = GroupChatRequest(
            title: title,
            ownerID: ownerID.uuidString,
            memberIDs: memberIDs.map(\.uuidString),
            mode: mode.rawValue,
            communityDetails: communityDetails.map(CommunityChatDetailsRequest.init)
        )
        return try await request(
            path: "/chats/group",
            method: "POST",
            body: body,
            userID: ownerID,
            networkAccessKind: .chatSync,
            fallback: {
                try await fallback.createGroupChat(
                    title: title,
                    memberIDs: memberIDs,
                    ownerID: ownerID,
                    mode: mode,
                    communityDetails: communityDetails
                )
            }
        )
    }

    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat {
        let body = UpdateGroupRequest(
            requesterID: requesterID.uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            moderationSettings: chat.moderationSettings.map(GroupModerationSettingsRequest.init)
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group",
            method: "PATCH",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func deleteGroup(_ chat: Chat, requesterID: UUID) async throws {
        let body = GroupDeleteRequest(requesterID: requesterID.uuidString)
        let _: BackendMutationOKResponse = try await request(
            path: "/chats/\(chat.id.uuidString)/group",
            method: "DELETE",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func updateCommunityDetails(_ details: CommunityChatDetails, for chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = UpdateCommunityDetailsRequest(
            requesterID: requesterID.uuidString,
            communityDetails: CommunityChatDetailsRequest(details)
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/community",
            method: "PATCH",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: {
                try await fallback.updateCommunityDetails(details, for: chat, requesterID: requesterID)
            }
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
            networkAccessKind: .mediaUploads,
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
            networkAccessKind: .chatSync,
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
            networkAccessKind: .chatSync,
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
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func updateMemberRole(_ role: GroupMemberRole, for memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupMemberRoleRequest(
            requesterID: requesterID.uuidString,
            role: role.rawValue
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/members/\(memberID.uuidString)/role",
            method: "PATCH",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func transferGroupOwnership(to memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = GroupTransferOwnershipRequest(
            requesterID: requesterID.uuidString,
            memberID: memberID.uuidString
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/group/owner",
            method: "PATCH",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func leaveGroup(_ chat: Chat, requesterID: UUID) async throws {
        let body = GroupLeaveRequest(requesterID: requesterID.uuidString)
        let _: BackendMutationOKResponse = try await request(
            path: "/chats/\(chat.id.uuidString)/group/leave",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func searchDiscoverableChats(query: String, mode: ChatMode, currentUserID: UUID) async throws -> [Chat] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.searchDiscoverableChats(query: query, mode: mode, currentUserID: currentUserID)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return [] }

        let (data, response): (Data, URLResponse)
        if await shouldUseLegacyTransport(for: currentUserID) {
            (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/communities/search",
                method: "GET",
                queryItems: [
                    URLQueryItem(name: "query", value: trimmedQuery),
                    URLQueryItem(name: "mode", value: mode.rawValue),
                    URLQueryItem(name: "user_id", value: currentUserID.uuidString),
                ],
                networkAccessKind: .chatSync
            )
        } else {
            (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/communities/search",
                method: "GET",
                queryItems: [
                    URLQueryItem(name: "query", value: trimmedQuery),
                    URLQueryItem(name: "mode", value: mode.rawValue),
                ],
                userID: currentUserID,
                networkAccessKind: .chatSync
            )
        }

        try validate(response: response, data: data)
        return try decodeLossyArray(Chat.self, from: data)
    }

    func joinDiscoverableChat(_ chat: Chat, requesterID: UUID) async throws -> Chat {
        let body = JoinChatRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/chats/\(chat.id.uuidString)/join",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: {
                try await fallback.joinDiscoverableChat(chat, requesterID: requesterID)
            }
        )
    }

    func joinChat(inviteCode: String, mode: ChatMode, requesterID: UUID) async throws -> Chat {
        let body = JoinChatRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/invites/\(inviteCode)/join",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: {
                try await fallback.joinChat(inviteCode: inviteCode, mode: mode, requesterID: requesterID)
            }
        )
    }

    func submitJoinRequest(for chat: Chat, requesterID: UUID, answers: [String]) async throws {
        let body = JoinRequestSubmissionRequest(
            requesterID: requesterID.uuidString,
            answers: answers
        )
        let _: BackendMutationOKResponse = try await request(
            path: "/chats/\(chat.id.uuidString)/join-request",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func fetchModerationDashboard(for chat: Chat, requesterID: UUID) async throws -> ModerationDashboard {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchModerationDashboard(for: chat, requesterID: requesterID)
        }

        let (data, response): (Data, URLResponse)
        if await shouldUseLegacyTransport(for: requesterID) {
            (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/chats/\(chat.id.uuidString)/moderation/dashboard",
                method: "GET",
                queryItems: [
                    URLQueryItem(name: "user_id", value: requesterID.uuidString)
                ],
                networkAccessKind: .chatSync
            )
        } else {
            (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/chats/\(chat.id.uuidString)/moderation/dashboard",
                method: "GET",
                userID: requesterID,
                networkAccessKind: .chatSync
            )
        }

        try validate(response: response, data: data)
        return try Self.makeDecoder().decode(ModerationDashboard.self, from: data)
    }

    func resolveJoinRequest(
        for requesterUserID: UUID,
        approve: Bool,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        let body = GroupModerationActorRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/chats/\(chat.id.uuidString)/join-requests/\(requesterUserID.uuidString)/\(approve ? "approve" : "decline")",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func reportChatContent(
        in chat: Chat,
        requesterID: UUID,
        targetMessageID: UUID?,
        targetUserID: UUID?,
        reason: ModerationReportReason,
        details: String?
    ) async throws {
        let body = ReportChatContentRequest(
            requesterID: requesterID.uuidString,
            targetMessageID: targetMessageID?.uuidString,
            targetUserID: targetUserID?.uuidString,
            reason: reason.rawValue,
            details: details?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let _: BackendMutationOKResponse = try await request(
            path: "/chats/\(chat.id.uuidString)/reports",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func banMember(
        _ memberID: UUID,
        duration: TimeInterval,
        reason: String?,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        let body = BanMemberRequest(
            requesterID: requesterID.uuidString,
            memberID: memberID.uuidString,
            durationSeconds: max(3600, Int(duration)),
            reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try await request(
            path: "/chats/\(chat.id.uuidString)/bans",
            method: "POST",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
            fallback: nil
        )
    }

    func removeBan(
        for memberID: UUID,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        let body = GroupModerationActorRequest(requesterID: requesterID.uuidString)
        return try await request(
            path: "/chats/\(chat.id.uuidString)/bans/\(memberID.uuidString)",
            method: "DELETE",
            body: body,
            userID: requesterID,
            networkAccessKind: .chatSync,
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

        return [savedMessages] + chats
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        userID: UUID?,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .chatSync,
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
                userID: userID,
                networkAccessKind: networkAccessKind
            )
        case .authenticated:
            return try await requestWithAuthenticatedPrimary(
                baseURL: baseURL,
                path: path,
                method: method,
                bodyData: bodyData,
                userID: userID,
                networkAccessKind: networkAccessKind
            )
        case .unknown:
            let prefersLegacyTransport = await shouldUseLegacyTransport(for: userID)
            if prefersLegacyTransport {
                return try await requestWithLegacyPrimary(
                    baseURL: baseURL,
                    path: path,
                    method: method,
                    bodyData: bodyData,
                    userID: userID,
                    networkAccessKind: networkAccessKind
                )
            }

            return try await requestWithAuthenticatedPrimary(
                baseURL: baseURL,
                path: path,
                method: method,
                bodyData: bodyData,
                userID: userID,
                networkAccessKind: networkAccessKind
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
    ) async throws -> SendMessageRequest {
        var attachments: [SendAttachmentRequest] = []
        attachments.reserveCapacity(draft.attachments.count)
        for attachment in draft.attachments {
            attachments.append(try await makeSendAttachmentRequest(from: attachment, senderID: senderID))
        }

        let voiceMessage: SendVoiceMessageRequest?
        if let draftVoiceMessage = draft.voiceMessage {
            voiceMessage = try await makeSendVoiceMessageRequest(from: draftVoiceMessage, senderID: senderID)
        } else {
            voiceMessage = nil
        }

        return SendMessageRequest(
            chatID: chatID.uuidString,
            senderID: senderID.uuidString,
            clientMessageID: draft.clientMessageID?.uuidString,
            senderDisplayName: resolvedCurrentSenderDisplayName(for: senderID),
            text: draft.normalizedText,
            createdAt: draft.createdAt?.ISO8601Format(),
            deliveryState: (draft.deliveryStateOverride ?? .online).rawValue,
            mode: mode.rawValue,
            kind: resolvedKind(for: draft).rawValue,
            attachments: attachments,
            voiceMessage: voiceMessage,
            replyToMessageID: draft.replyToMessageID?.uuidString,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext?.hasRoutingContext == true ? draft.communityContext : nil,
            deliveryOptions: draft.deliveryOptions.hasAdvancedBehavior ? draft.deliveryOptions : nil
        )
    }

    private func makeSendAttachmentRequest(from attachment: Attachment, senderID: UUID) async throws -> SendAttachmentRequest {
        let sourceURL = ChatMediaPersistentStore.isUsableLocalMediaURL(attachment.localURL)
            ? attachment.localURL
            : attachment.remoteURL
        let localFileURL = sourceURL?.isFileURL == true ? sourceURL : nil
        if let sourceURL {
            logMediaUploadPreparation(
                label: "attachment.upload.prepare",
                sourceURL: sourceURL,
                declaredByteSize: attachment.byteSize,
                kind: attachment.type.rawValue
            )
        }

        if shouldUseUploadedMediaReference(for: attachment) {
            if let remoteURL = attachment.remoteURL, localFileURL == nil {
                return SendAttachmentRequest(
                    type: attachment.type.rawValue,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    byteSize: attachment.byteSize,
                    dataBase64: nil,
                    remoteURL: remoteURL
                )
            }

            if let sourceURL = localFileURL {
                if let uploadedMedia = try await uploadMediaReference(
                    sourceURL: sourceURL,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    byteSize: attachment.byteSize,
                    kind: attachment.type.rawValue,
                    senderID: senderID
                ) {
                    return SendAttachmentRequest(
                        type: attachment.type.rawValue,
                        fileName: uploadedMedia.fileName,
                        mimeType: uploadedMedia.mimeType,
                        byteSize: uploadedMedia.byteSize,
                        dataBase64: nil,
                        remoteURL: uploadedMedia.remoteURL
                    )
                }
            }
        }

        return SendAttachmentRequest(
            type: attachment.type.rawValue,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize,
            dataBase64: try loadBase64(from: localFileURL),
            remoteURL: attachment.remoteURL
        )
    }

    private func makeSendVoiceMessageRequest(from voiceMessage: VoiceMessage, senderID: UUID) async throws -> SendVoiceMessageRequest {
        let sourceURL = ChatMediaPersistentStore.isUsableLocalMediaURL(voiceMessage.localFileURL)
            ? voiceMessage.localFileURL
            : voiceMessage.remoteFileURL
        let localFileURL = sourceURL?.isFileURL == true ? sourceURL : nil
        let resolvedDurationSeconds: Int
        if let localFileURL {
            let assetDuration = AVURLAsset(url: localFileURL).duration.seconds
            if assetDuration.isFinite, assetDuration > 0 {
                resolvedDurationSeconds = max(Int(assetDuration.rounded(.up)), voiceMessage.durationSeconds)
            } else {
                resolvedDurationSeconds = voiceMessage.durationSeconds
            }
        } else {
            resolvedDurationSeconds = voiceMessage.durationSeconds
        }
        if let sourceURL {
            logMediaUploadPreparation(
                label: "voice.upload.prepare",
                sourceURL: sourceURL,
                declaredByteSize: voiceMessage.byteSize,
                kind: "voice"
            )
        }

        if let remoteURL = voiceMessage.remoteFileURL, localFileURL == nil {
            return SendVoiceMessageRequest(
                durationSeconds: resolvedDurationSeconds,
                waveformSamples: voiceMessage.waveformSamples,
                byteSize: voiceMessage.byteSize,
                fileName: remoteURL.lastPathComponent.isEmpty ? "voice.m4a" : remoteURL.lastPathComponent,
                dataBase64: nil,
                remoteURL: remoteURL
            )
        }

        if let sourceURL = localFileURL,
           let uploadedMedia = try await uploadMediaReference(
            sourceURL: sourceURL,
            fileName: sourceURL.lastPathComponent,
            mimeType: "audio/mp4",
            byteSize: voiceMessage.byteSize,
            kind: "voice",
            senderID: senderID
           ) {
            return SendVoiceMessageRequest(
                durationSeconds: resolvedDurationSeconds,
                waveformSamples: voiceMessage.waveformSamples,
                byteSize: uploadedMedia.byteSize,
                fileName: uploadedMedia.fileName,
                dataBase64: nil,
                remoteURL: uploadedMedia.remoteURL
            )
        }

        return SendVoiceMessageRequest(
            durationSeconds: resolvedDurationSeconds,
            waveformSamples: voiceMessage.waveformSamples,
            byteSize: voiceMessage.byteSize,
            fileName: voiceMessage.localFileURL?.lastPathComponent ?? "voice.m4a",
            dataBase64: try loadBase64(from: localFileURL),
            remoteURL: voiceMessage.remoteFileURL
        )
    }

    private func shouldUseUploadedMediaReference(for attachment: Attachment) -> Bool {
        attachment.type == .video
    }

    private func uploadMediaReference(
        sourceURL: URL,
        fileName: String,
        mimeType: String,
        byteSize: Int64,
        kind: String,
        senderID: UUID
    ) async throws -> UploadedMediaResponse? {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return nil
        }

        let actualByteSize = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        logger.info("media.upload.begin kind=\(kind, privacy: .public) file=\(fileName, privacy: .public) actualBytes=\(actualByteSize, privacy: .public) declaredBytes=\(byteSize, privacy: .public)")

        do {
            let uploaded = try await uploadMediaWithCompatibleTransport(
                baseURL: baseURL,
                sourceURL: sourceURL,
                fileName: fileName,
                mimeType: mimeType,
                kind: kind,
                senderID: senderID
            )
            logger.info("media.upload.complete kind=\(kind, privacy: .public) file=\(uploaded.fileName, privacy: .public) byteSize=\(uploaded.byteSize, privacy: .public) remoteURL=\(uploaded.remoteURL.absoluteString, privacy: .public)")
            return uploaded
        } catch {
            logger.error("media.upload.failed kind=\(kind, privacy: .public) file=\(fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func uploadMediaWithCompatibleTransport(
        baseURL: URL,
        sourceURL: URL,
        fileName: String,
        mimeType: String,
        kind: String,
        senderID: UUID
    ) async throws -> UploadedMediaResponse {
        try validateNetworkAccess(for: .mediaUploads)
        let uploaded = try await authenticatedUploadMedia(
            baseURL: baseURL,
            sourceURL: sourceURL,
            fileName: fileName,
            mimeType: mimeType,
            kind: kind,
            senderID: senderID
        )
        await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
        return uploaded
    }

    private func authenticatedUploadMedia(
        baseURL: URL,
        sourceURL: URL,
        fileName: String,
        mimeType: String,
        kind: String,
        senderID: UUID
    ) async throws -> UploadedMediaResponse {
        let (data, response) = try await BackendRequestTransport.authorizedUploadRequest(
            baseURL: baseURL,
            path: "/media/upload",
            sourceFileURL: sourceURL,
            userID: senderID,
            networkAccessKind: .mediaUploads,
            contentType: mimeType,
            additionalHeaders: [
                "X-Prime-Upload-File-Name": fileName,
                "X-Prime-Upload-Mime-Type": mimeType,
                "X-Prime-Upload-Kind": kind,
            ]
        )
        try validate(response: response, data: data)
        return try Self.makeDecoder().decode(UploadedMediaResponse.self, from: data)
    }

    private func legacyUploadMedia(
        baseURL: URL,
        sourceURL: URL,
        fileName: String,
        mimeType: String,
        kind: String,
        senderID: UUID
    ) async throws -> UploadedMediaResponse {
        guard var components = URLComponents(url: baseURL.appending(path: "/media/upload"), resolvingAgainstBaseURL: false) else {
            throw ChatRepositoryError.backendUnavailable
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: senderID.uuidString)]
        guard let url = components.url else {
            throw ChatRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: .mediaUploads)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(fileName, forHTTPHeaderField: "X-Prime-Upload-File-Name")
        request.setValue(mimeType, forHTTPHeaderField: "X-Prime-Upload-Mime-Type")
        request.setValue(kind, forHTTPHeaderField: "X-Prime-Upload-Kind")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: sourceURL)
        try validate(response: response, data: data)
        return try Self.makeDecoder().decode(UploadedMediaResponse.self, from: data)
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
        logger.info("media.base64.loaded file=\(url.lastPathComponent, privacy: .public) bytes=\(data.count, privacy: .public)")
        return data.base64EncodedString()
    }

    private func logMediaUploadPreparation(label: String, sourceURL: URL, declaredByteSize: Int64?, kind: String) {
        let actualByteSize = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let asset = AVURLAsset(url: sourceURL)
        let duration = asset.duration.seconds
        let durationText = duration.isFinite && duration > 0 ? String(format: "%.3f", duration) : "n/a"
        let declaredText = declaredByteSize.map(String.init) ?? "n/a"
        logger.info("\(label, privacy: .public) kind=\(kind, privacy: .public) file=\(sourceURL.lastPathComponent, privacy: .public) actualBytes=\(actualByteSize, privacy: .public) declaredBytes=\(declaredText, privacy: .public) duration=\(durationText, privacy: .public)")
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
        case (403, "guest_requests_blocked"):
            return ChatRepositoryError.guestRequestsBlocked
        case (403, "group_permission_denied"):
            return ChatRepositoryError.groupPermissionDenied
        case (403, "group_invites_blocked"):
            return ChatRepositoryError.groupInvitesBlocked
        case (403, "chat_not_public"):
            return ChatRepositoryError.chatNotPublic
        case (403, "user_banned"):
            return ChatRepositoryError.userBanned
        case (403, "official_badge_permission_denied"):
            return ChatRepositoryError.officialBadgePermissionDenied
        case (409, "guest_request_pending"):
            return ChatRepositoryError.guestRequestPending
        case (409, "guest_request_approval_required"):
            return ChatRepositoryError.guestRequestApprovalRequired
        case (409, "guest_request_intro_required"):
            return ChatRepositoryError.guestRequestIntroRequired
        case (409, "guest_request_intro_too_long"):
            return ChatRepositoryError.guestRequestIntroTooLong
        case (409, "guest_request_declined"):
            return ChatRepositoryError.guestRequestDeclined
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
        case (409, "channel_comments_disabled"):
            return ChatRepositoryError.channelCommentsDisabled
        case (409, "invalid_group_operation"), (409, "invalid_group_chat"), (409, "user_already_in_group"):
            return ChatRepositoryError.invalidGroupOperation
        case (409, "join_approval_required"):
            return ChatRepositoryError.joinApprovalRequired
        case (404, "invite_not_found"):
            return ChatRepositoryError.inviteNotFound
        default:
            return ChatRepositoryError.backendUnavailable
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        BackendJSONDecoder.make()
    }

    private func shouldUseLegacyTransport(for userID: UUID?) async -> Bool {
        _ = userID
        return false
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
            userID: userID,
            networkAccessKind: .chatSync
        )
        try validate(response: response, data: data)
        return try decoder.decode([Chat].self, from: data)
    }

    private func fetchMessagesUsingCompatibleTransport(baseURL: URL, chatID: UUID, currentUserID: UUID?) async throws -> [Message] {
        let strategy = await BackendTransportStrategyStore.shared.strategy(for: baseURL)

        switch strategy {
        case .legacy:
            return try await fetchMessagesWithLegacyPrimary(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
        case .authenticated:
            return try await fetchMessagesWithAuthenticatedPrimary(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
        case .unknown:
            if await shouldUseLegacyTransport(for: currentUserID) {
                return try await fetchMessagesWithLegacyPrimary(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
            }

            return try await fetchMessagesWithAuthenticatedPrimary(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
        }
    }

    private func legacyFetchMessages(baseURL: URL, chatID: UUID, currentUserID: UUID?) async throws -> [Message] {
        var queryItems = [URLQueryItem(name: "chat_id", value: chatID.uuidString)]
        if let currentUserID {
            queryItems.append(URLQueryItem(name: "user_id", value: currentUserID.uuidString))
        }
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/messages",
            method: "GET",
            queryItems: queryItems,
            networkAccessKind: .chatSync
        )
        try validate(response: response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    private func authenticatedFetchMessages(baseURL: URL, chatID: UUID, currentUserID: UUID?) async throws -> [Message] {
        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/messages",
            method: "GET",
            queryItems: [URLQueryItem(name: "chat_id", value: chatID.uuidString)],
            userID: currentUserID,
            networkAccessKind: .chatSync
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
            ],
            networkAccessKind: .chatSync
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
            method: "GET",
            networkAccessKind: .chatSync
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
        let chats = try await authenticatedFetchChats(baseURL: baseURL, mode: mode, userID: userID)
        await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
        return chats
    }

    private func fetchMessagesWithLegacyPrimary(baseURL: URL, chatID: UUID, currentUserID: UUID?) async throws -> [Message] {
        do {
            let messages = try await legacyFetchMessages(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
            await BackendTransportStrategyStore.shared.set(.legacy, for: baseURL)
            return messages
        } catch {
            let messages = try await authenticatedFetchMessages(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
            await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
            return messages
        }
    }

    private func fetchMessagesWithAuthenticatedPrimary(baseURL: URL, chatID: UUID, currentUserID: UUID?) async throws -> [Message] {
        let messages = try await authenticatedFetchMessages(baseURL: baseURL, chatID: chatID, currentUserID: currentUserID)
        await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
        return messages
    }

    private func requestWithLegacyPrimary<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        bodyData: Data,
        userID: UUID?,
        networkAccessKind: NetworkUsagePolicy.AccessKind
    ) async throws -> Response {
        try validateNetworkAccess(for: networkAccessKind)
        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData,
                networkAccessKind: networkAccessKind
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
                userID: userID,
                networkAccessKind: networkAccessKind
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
        userID: UUID?,
        networkAccessKind: NetworkUsagePolicy.AccessKind
    ) async throws -> Response {
        try validateNetworkAccess(for: networkAccessKind)
        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: bodyData,
            userID: userID,
            networkAccessKind: networkAccessKind
        )
        try validate(response: response, data: data)
        await BackendTransportStrategyStore.shared.set(.authenticated, for: baseURL)
        return try decoder.decode(Response.self, from: data)
    }

    private func decodeLossyArray<Element: Decodable>(_ type: Element.Type, from data: Data) throws -> [Element] {
        try decoder.decode([LossyDecodable<Element>].self, from: data).compactMap(\.value)
    }

    private func mergeChats(cached: [Chat], incoming: [Chat]) -> [Chat] {
        guard incoming.isEmpty == false else { return [] }

        var mergedByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        if cached.isEmpty == false {
            for cachedChat in cached {
                guard let incomingChat = mergedByID[cachedChat.id] else { continue }
                mergedByID[cachedChat.id] = mergeChatState(cached: cachedChat, incoming: incomingChat)
            }
        }

        return mergedByID.values.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private func mergeChatState(cached: Chat, incoming: Chat) -> Chat {
        var merged = incoming
        if merged.draft == nil {
            merged.draft = cached.draft
        }
        if merged.eventDetails == nil {
            merged.eventDetails = cached.eventDetails
        }
        if merged.communityDetails == nil {
            merged.communityDetails = cached.communityDetails
        }
        if merged.moderationSettings == nil {
            merged.moderationSettings = cached.moderationSettings
        }
        return merged
    }

    private func mergeMessages(cached: [Message], incoming: [Message]) -> [Message] {
        guard incoming.isEmpty == false else {
            return cached
                .filter(shouldRetainCachedOnlyMessage)
                .sorted(by: { $0.createdAt < $1.createdAt })
        }
        guard cached.isEmpty == false else { return incoming.sorted(by: { $0.createdAt < $1.createdAt }) }

        let cachedByClientID = Dictionary(uniqueKeysWithValues: cached.map { ($0.clientMessageID, $0) })
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })

        var mergedByClientID: [UUID: Message] = [:]
        mergedByClientID.reserveCapacity(incoming.count)
        for incomingMessage in incoming {
            let cachedMatch = cachedByClientID[incomingMessage.clientMessageID] ?? cachedByID[incomingMessage.id]
            let mergedMessage = cachedMatch.map { incomingMessage.mergingLocalObjectState(from: $0) } ?? incomingMessage
            mergedByClientID[incomingMessage.clientMessageID] = mergedMessage
        }

        for cachedMessage in cached where shouldRetainCachedOnlyMessage(cachedMessage) {
            if mergedByClientID[cachedMessage.clientMessageID] != nil {
                continue
            }
            if incoming.contains(where: { $0.id == cachedMessage.id }) {
                continue
            }
            mergedByClientID[cachedMessage.clientMessageID] = cachedMessage
        }

        return mergedByClientID.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func shouldRetainCachedOnlyMessage(_ message: Message) -> Bool {
        switch message.status {
        case .localPending, .sending, .failed:
            return true
        case .sent, .delivered, .read:
            break
        }
        return message.deliveryRoute == .queued
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

    private func saveCachedMessages(
        _ messages: [Message],
        chatID: UUID,
        mode: ChatMode,
        userID: UUID?,
        baseURL: URL,
        defaults: UserDefaults = .standard
    ) {
        let stabilizedMessages = messages.map(ChatMediaPersistentStore.persist)
        guard let data = try? JSONEncoder().encode(stabilizedMessages) else { return }
        defaults.set(data, forKey: cachedMessagesKey(chatID: chatID, mode: mode, userID: userID, baseURL: baseURL))
    }

    private func loadCachedMessages(
        chatID: UUID,
        mode: ChatMode,
        userID: UUID?,
        baseURL: URL,
        defaults: UserDefaults = .standard
    ) -> [Message]? {
        guard let data = defaults.data(forKey: cachedMessagesKey(chatID: chatID, mode: mode, userID: userID, baseURL: baseURL)) else {
            return nil
        }

        return try? decoder.decode([Message].self, from: data)
    }

    private func cachedChatsKey(mode: ChatMode, userID: UUID, baseURL: URL) -> String {
        "\(StorageKeys.cachedChatsPrefix).\(baseURL.absoluteString).\(mode.rawValue).\(userID.uuidString)"
    }

    private func cachedMessagesKey(chatID: UUID, mode: ChatMode, userID: UUID?, baseURL: URL) -> String {
        "\(StorageKeys.cachedMessagesPrefix).\(baseURL.absoluteString).\(mode.rawValue).\(userID?.uuidString ?? "anonymous").\(chatID.uuidString)"
    }

    private func legacyRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = [],
        networkAccessKind: NetworkUsagePolicy.AccessKind = .chatSync
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
        request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: networkAccessKind)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        return try await URLSession.shared.data(for: request)
    }

    private func validateNetworkAccess(for accessKind: NetworkUsagePolicy.AccessKind) throws {
        guard NetworkUsagePolicy.canUseNetwork(for: accessKind) else {
            if NetworkUsagePolicy.isCellularBlocked(for: accessKind) {
                switch accessKind {
                case .chatSync:
                    throw ChatRepositoryError.cellularSyncDisabled
                case .mediaUploads:
                    throw ChatRepositoryError.cellularMediaUploadsDisabled
                case .general, .mediaDownloads, .autoDownload(_):
                    break
                }
            }
            throw ChatRepositoryError.backendUnavailable
        }
    }

    private func resolvedNetworkAccessKind(for draft: OutgoingMessageDraft) -> NetworkUsagePolicy.AccessKind {
        if draft.attachments.isEmpty == false || draft.voiceMessage != nil {
            return .mediaUploads
        }
        return .chatSync
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
    let clientMessageID: String?
    let senderDisplayName: String?
    let text: String?
    let createdAt: String?
    let deliveryState: String
    let mode: String
    let kind: String
    let attachments: [SendAttachmentRequest]
    let voiceMessage: SendVoiceMessageRequest?
    let replyToMessageID: String?
    let replyPreview: ReplyPreviewSnapshot?
    let communityContext: CommunityMessageContext?
    let deliveryOptions: MessageDeliveryOptions?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case senderDisplayName = "sender_display_name"
        case text
        case createdAt = "created_at"
        case deliveryState = "delivery_state"
        case mode
        case kind
        case attachments
        case voiceMessage = "voice_message"
        case replyToMessageID = "reply_to_message_id"
        case replyPreview = "reply_preview"
        case communityContext = "community_context"
        case deliveryOptions = "delivery_options"
    }
}

private struct SendAttachmentRequest: Encodable {
    let type: String
    let fileName: String
    let mimeType: String
    let byteSize: Int64
    let dataBase64: String?
    let remoteURL: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case fileName = "file_name"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case dataBase64 = "data_base64"
        case remoteURL = "remote_url"
    }
}

private struct SendVoiceMessageRequest: Encodable {
    let durationSeconds: Int
    let waveformSamples: [Float]
    let byteSize: Int64
    let fileName: String
    let dataBase64: String?
    let remoteURL: URL?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case waveformSamples = "waveform_samples"
        case byteSize = "byte_size"
        case fileName = "file_name"
        case dataBase64 = "data_base64"
        case remoteURL = "remote_url"
    }
}

private struct UploadedMediaResponse: Decodable {
    let fileName: String
    let mimeType: String
    let byteSize: Int64
    let remoteURL: URL
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case fileName
        case mimeType
        case byteSize
        case remoteURL
        case sha256
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

private struct GuestRequestSubmitRequest: Encodable {
    let requesterID: String
    let introText: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case introText = "intro_text"
    }
}

private struct GuestRequestResponseRequest: Encodable {
    let responderID: String
    let action: String

    enum CodingKeys: String, CodingKey {
        case responderID = "responder_id"
        case action
    }
}

private struct GroupChatRequest: Encodable {
    let title: String
    let ownerID: String
    let memberIDs: [String]
    let mode: String
    let communityDetails: CommunityChatDetailsRequest?

    enum CodingKeys: String, CodingKey {
        case title
        case ownerID = "owner_id"
        case memberIDs = "member_ids"
        case mode
        case communityDetails = "community_details"
    }
}

private struct CommunityChatDetailsRequest: Encodable {
    let kind: String
    let forumModeEnabled: Bool
    let commentsEnabled: Bool
    let isPublic: Bool
    let topics: [CommunityTopicRequest]
    let inviteCode: String?
    let isOfficial: Bool

    nonisolated init(_ details: CommunityChatDetails) {
        kind = details.kind.rawValue
        forumModeEnabled = details.forumModeEnabled
        commentsEnabled = details.commentsEnabled
        isPublic = details.isPublic
        topics = details.topics.map(CommunityTopicRequest.init)
        inviteCode = details.inviteCode
        isOfficial = details.isOfficial
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case forumModeEnabled = "forum_mode_enabled"
        case commentsEnabled = "comments_enabled"
        case isPublic = "is_public"
        case topics
        case inviteCode = "invite_code"
        case isOfficial = "is_official"
    }
}

private struct CommunityTopicRequest: Encodable {
    let id: String
    let title: String
    let symbolName: String
    let unreadCount: Int
    let isPinned: Bool
    let lastActivityAt: String

    nonisolated init(_ topic: CommunityTopic) {
        id = topic.id.uuidString
        title = topic.title
        symbolName = topic.symbolName
        unreadCount = topic.unreadCount
        isPinned = topic.isPinned
        lastActivityAt = topic.lastActivityAt.ISO8601Format()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case symbolName = "symbol_name"
        case unreadCount = "unread_count"
        case isPinned = "is_pinned"
        case lastActivityAt = "last_activity_at"
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

private struct MessageReactionRequest: Encodable {
    let chatID: String
    let userID: String
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case userID = "user_id"
        case emoji
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
    let moderationSettings: GroupModerationSettingsRequest?

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case title
        case moderationSettings = "moderation_settings"
    }
}

private struct GroupModerationSettingsRequest: Encodable {
    let requiresJoinApproval: Bool
    let welcomeMessage: String
    let rules: String
    let entryQuestions: [String]
    let slowModeSeconds: Int
    let restrictMedia: Bool
    let restrictLinks: Bool
    let antiSpamEnabled: Bool

    init(_ settings: GroupModerationSettings) {
        requiresJoinApproval = settings.requiresJoinApproval
        welcomeMessage = settings.welcomeMessage
        rules = settings.rules
        entryQuestions = settings.entryQuestions
        slowModeSeconds = settings.slowModeSeconds
        restrictMedia = settings.restrictMedia
        restrictLinks = settings.restrictLinks
        antiSpamEnabled = settings.antiSpamEnabled
    }

    enum CodingKeys: String, CodingKey {
        case requiresJoinApproval = "requires_join_approval"
        case welcomeMessage = "welcome_message"
        case rules
        case entryQuestions = "entry_questions"
        case slowModeSeconds = "slow_mode_seconds"
        case restrictMedia = "restrict_media"
        case restrictLinks = "restrict_links"
        case antiSpamEnabled = "anti_spam_enabled"
    }
}

private struct GroupDeleteRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct UpdateCommunityDetailsRequest: Encodable {
    let requesterID: String
    let communityDetails: CommunityChatDetailsRequest

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case communityDetails = "community_details"
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

private struct JoinChatRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct JoinRequestSubmissionRequest: Encodable {
    let requesterID: String
    let answers: [String]

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case answers
    }
}

private struct GroupModerationActorRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct ReportChatContentRequest: Encodable {
    let requesterID: String
    let targetMessageID: String?
    let targetUserID: String?
    let reason: String
    let details: String?

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case targetMessageID = "target_message_id"
        case targetUserID = "target_user_id"
        case reason
        case details
    }
}

private struct BanMemberRequest: Encodable {
    let requesterID: String
    let memberID: String
    let durationSeconds: Int
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case memberID = "member_id"
        case durationSeconds = "duration_seconds"
        case reason
    }
}

private struct GroupMemberRemoveRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct GroupMemberRoleRequest: Encodable {
    let requesterID: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case role
    }
}

private struct GroupTransferOwnershipRequest: Encodable {
    let requesterID: String
    let memberID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
        case memberID = "member_id"
    }
}

private struct GroupLeaveRequest: Encodable {
    let requesterID: String

    enum CodingKeys: String, CodingKey {
        case requesterID = "requester_id"
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}
