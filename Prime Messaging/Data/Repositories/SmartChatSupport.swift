import CryptoKit
import Foundation

struct SmartConversationLink {
    let smartChatID: UUID
    let currentUserID: UUID
    let participantIDs: [UUID]
    let type: ChatType
    let onlineChat: Chat?
    let offlineChat: Chat?
}

struct SmartMessageRoute {
    let presentedMessageID: UUID
    let underlyingMessageID: UUID
    let underlyingChatID: UUID
    let sourceMode: ChatMode
}

actor SmartConversationStore {
    static let shared = SmartConversationStore()

    private var linksBySmartChatID: [UUID: SmartConversationLink] = [:]
    private var routesBySmartChatID: [UUID: [UUID: SmartMessageRoute]] = [:]

    func replaceLinks(_ links: [SmartConversationLink]) {
        var nextLinks: [UUID: SmartConversationLink] = [:]
        for link in links {
            nextLinks[link.smartChatID] = link
        }
        linksBySmartChatID = nextLinks
        routesBySmartChatID = routesBySmartChatID.filter { nextLinks[$0.key] != nil }
    }

    func upsertLink(_ link: SmartConversationLink) {
        linksBySmartChatID[link.smartChatID] = link
    }

    func link(for smartChatID: UUID) -> SmartConversationLink? {
        linksBySmartChatID[smartChatID]
    }

    func removeLink(for smartChatID: UUID) {
        linksBySmartChatID.removeValue(forKey: smartChatID)
        routesBySmartChatID.removeValue(forKey: smartChatID)
    }

    func storeRoutes(_ routes: [SmartMessageRoute], for smartChatID: UUID) {
        routesBySmartChatID[smartChatID] = Dictionary(uniqueKeysWithValues: routes.map { ($0.presentedMessageID, $0) })
    }

    func upsertRoute(_ route: SmartMessageRoute, for smartChatID: UUID) {
        var routes = routesBySmartChatID[smartChatID] ?? [:]
        routes[route.presentedMessageID] = route
        routesBySmartChatID[smartChatID] = routes
    }

    func route(for messageID: UUID, in smartChatID: UUID) -> SmartMessageRoute? {
        routesBySmartChatID[smartChatID]?[messageID]
    }
}

enum SmartChatSupport {
    static func smartChatID(for chat: Chat, currentUserID: UUID) -> UUID {
        switch chat.type {
        case .selfChat:
            return currentUserID
        case .direct:
            let sortedIDs = chat.participantIDs.map(\.uuidString).sorted().joined(separator: ":")
            return stableUUID(from: "smart-direct:\(sortedIDs)")
        case .group:
            return chat.id
        case .secret:
            return chat.id
        }
    }

    static func mergeChats(
        onlineChats: [Chat],
        offlineChats: [Chat],
        currentUserID: UUID
    ) -> (chats: [Chat], links: [SmartConversationLink]) {
        var groupedOnline: [UUID: Chat] = [:]
        var groupedOffline: [UUID: Chat] = [:]

        for chat in onlineChats {
            groupedOnline[smartChatID(for: chat, currentUserID: currentUserID)] = chat
        }
        for chat in offlineChats {
            groupedOffline[smartChatID(for: chat, currentUserID: currentUserID)] = chat
        }

        let allIDs = Set(groupedOnline.keys).union(groupedOffline.keys)
        var chats: [Chat] = []
        var links: [SmartConversationLink] = []

        for smartChatID in allIDs {
            let onlineChat = groupedOnline[smartChatID]
            let offlineChat = groupedOffline[smartChatID]
            guard let merged = mergedChat(
                smartChatID: smartChatID,
                onlineChat: onlineChat,
                offlineChat: offlineChat,
                currentUserID: currentUserID
            ) else {
                continue
            }
            chats.append(merged)
            links.append(
                SmartConversationLink(
                    smartChatID: smartChatID,
                    currentUserID: currentUserID,
                    participantIDs: merged.participantIDs,
                    type: merged.type,
                    onlineChat: onlineChat,
                    offlineChat: offlineChat
                )
            )
        }

        chats.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }

        return (chats, links)
    }

    static func mergeMessages(
        onlineMessages: [Message],
        offlineMessages: [Message],
        smartChatID: UUID
    ) -> (messages: [Message], routes: [SmartMessageRoute]) {
        let onlineCandidates = onlineMessages.map {
            RoutedMessage(
                message: normalized($0, smartChatID: smartChatID, visibleMode: .smart, fallbackState: .online),
                route: SmartMessageRoute(
                    presentedMessageID: $0.id,
                    underlyingMessageID: $0.id,
                    underlyingChatID: $0.chatID,
                    sourceMode: .online
                )
            )
        }

        let offlineCandidates = offlineMessages.map {
            RoutedMessage(
                message: normalized($0, smartChatID: smartChatID, visibleMode: .smart, fallbackState: .offline),
                route: SmartMessageRoute(
                    presentedMessageID: $0.id,
                    underlyingMessageID: $0.id,
                    underlyingChatID: $0.chatID,
                    sourceMode: .offline
                )
            )
        }

        let candidates = onlineCandidates + offlineCandidates
        let grouped = Dictionary(grouping: candidates) { candidate in
            candidate.message.clientMessageID
        }

        var merged: [Message] = []
        var routes: [SmartMessageRoute] = []

        for group in grouped.values {
            guard let winner = group.max(by: { lhs, rhs in
                messagePriority(lhs) < messagePriority(rhs)
            }) else { continue }
            merged.append(winner.message)
            routes.append(
                SmartMessageRoute(
                    presentedMessageID: winner.message.id,
                    underlyingMessageID: winner.route.underlyingMessageID,
                    underlyingChatID: winner.route.underlyingChatID,
                    sourceMode: winner.route.sourceMode
                )
            )
        }

        merged.sort(by: { $0.createdAt < $1.createdAt })
        return (merged, routes)
    }

    static func normalized(_ message: Message, smartChatID: UUID, visibleMode: ChatMode, fallbackState: MessageDeliveryState) -> Message {
        Message(
            id: message.id,
            chatID: smartChatID,
            senderID: message.senderID,
            clientMessageID: message.clientMessageID,
            senderDisplayName: message.senderDisplayName,
            mode: visibleMode,
            deliveryState: message.deliveryState,
            deliveryRoute: message.deliveryRoute,
            kind: message.kind,
            text: message.text,
            attachments: message.attachments,
            replyToMessageID: message.replyToMessageID,
            replyPreview: message.replyPreview,
            deliveryOptions: message.deliveryOptions,
            status: message.status,
            createdAt: message.createdAt,
            editedAt: message.editedAt,
            deletedForEveryoneAt: message.deletedForEveryoneAt,
            reactions: message.reactions,
            voiceMessage: message.voiceMessage,
            liveLocation: message.liveLocation
        )
    }

    private static func mergedChat(
        smartChatID: UUID,
        onlineChat: Chat?,
        offlineChat: Chat?,
        currentUserID: UUID
    ) -> Chat? {
        guard let baseChat = latestChat(onlineChat, offlineChat) ?? onlineChat ?? offlineChat else {
            return nil
        }

        let titleSource = preferredTitleChat(onlineChat, offlineChat) ?? baseChat
        let subtitleSource = preferredSubtitleChat(onlineChat, offlineChat) ?? baseChat
        let participants = (onlineChat?.participants.isEmpty == false ? onlineChat?.participants : offlineChat?.participants) ?? []
        let participantIDs = Array(Set((onlineChat?.participantIDs ?? []) + (offlineChat?.participantIDs ?? [])))
        let unreadCount = max(onlineChat?.unreadCount ?? 0, offlineChat?.unreadCount ?? 0)
        let isPinned = (onlineChat?.isPinned ?? false) || (offlineChat?.isPinned ?? false)
        let lastPreviewChat = latestChat(onlineChat, offlineChat) ?? baseChat

        return Chat(
            id: smartChatID,
            mode: .smart,
            type: baseChat.type,
            title: titleSource.displayTitle(for: currentUserID),
            subtitle: subtitleSource.subtitle,
            participantIDs: participantIDs.isEmpty ? baseChat.participantIDs : participantIDs,
            participants: participants,
            group: onlineChat?.group ?? offlineChat?.group,
            lastMessagePreview: lastPreviewChat.lastMessagePreview,
            lastActivityAt: lastPreviewChat.lastActivityAt,
            unreadCount: unreadCount,
            isPinned: isPinned,
            draft: onlineChat?.draft ?? offlineChat?.draft,
            disappearingPolicy: onlineChat?.disappearingPolicy ?? offlineChat?.disappearingPolicy,
            notificationPreferences: onlineChat?.notificationPreferences ?? offlineChat?.notificationPreferences ?? baseChat.notificationPreferences,
            guestRequest: onlineChat?.guestRequest ?? offlineChat?.guestRequest,
            eventDetails: onlineChat?.eventDetails ?? offlineChat?.eventDetails ?? baseChat.eventDetails,
            communityDetails: onlineChat?.communityDetails ?? offlineChat?.communityDetails ?? baseChat.communityDetails,
            moderationSettings: onlineChat?.moderationSettings ?? offlineChat?.moderationSettings ?? baseChat.moderationSettings
        )
    }

    private static func latestChat(_ lhs: Chat?, _ rhs: Chat?) -> Chat? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs.lastActivityAt >= rhs.lastActivityAt ? lhs : rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func preferredTitleChat(_ onlineChat: Chat?, _ offlineChat: Chat?) -> Chat? {
        if let onlineChat, onlineChat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return onlineChat
        }
        return offlineChat ?? onlineChat
    }

    private static func preferredSubtitleChat(_ onlineChat: Chat?, _ offlineChat: Chat?) -> Chat? {
        if let onlineChat, onlineChat.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return onlineChat
        }
        return offlineChat ?? onlineChat
    }

    private static func messagePriority(_ candidate: RoutedMessage) -> Int {
        let statePriority: Int
        switch candidate.message.deliveryState {
        case .migrated:
            statePriority = 40
        case .online:
            statePriority = 30
        case .syncing:
            statePriority = 20
        case .offline:
            statePriority = 10
        }

        let routePriority: Int
        switch candidate.route.sourceMode {
        case .online:
            routePriority = 4
        case .smart:
            routePriority = 3
        case .offline:
            routePriority = 2
        }

        return statePriority + routePriority
    }

    private static func stableUUID(from value: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private struct RoutedMessage {
        let message: Message
        let route: SmartMessageRoute
    }
}
