import Foundation

actor ChatSnapshotStore {
    static let shared = ChatSnapshotStore()

    private enum SharedStorageKeys {
        static let chatsFileName = "chats-shared.json"
        static func messagesFileName(chatID: UUID) -> String {
            "messages-shared-\(chatID.uuidString).json"
        }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootURL: URL
    private var snapshotNotificationScheduled = false

    init(directoryName: String = "PrimeMessagingChatSnapshots") {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func loadChats(userID: UUID, mode: ChatMode) -> [Chat] {
        load([Chat].self, from: chatsURL(userID: userID, mode: mode)) ?? []
    }

    func loadSharedChats(userID: UUID) -> [Chat] {
        load([Chat].self, from: sharedChatsURL(userID: userID)) ?? []
    }

    func loadDraft(chatID: UUID, userID: UUID, mode: ChatMode) -> Draft? {
        loadChats(userID: userID, mode: mode).first(where: { $0.id == chatID })?.draft
            ?? loadSharedChats(userID: userID).first(where: { $0.id == chatID })?.draft
    }

    func saveChats(_ chats: [Chat], userID: UUID, mode: ChatMode) {
        let merged = mergeChats(existing: loadChats(userID: userID, mode: mode), incoming: chats)
        save(merged, to: chatsURL(userID: userID, mode: mode))
        let sharedMerged = mergeChats(existing: loadSharedChats(userID: userID), incoming: chats)
        save(sharedMerged, to: sharedChatsURL(userID: userID))
        postChatSnapshotsChanged()
    }

    func upsertChat(_ chat: Chat, userID: UUID, mode: ChatMode) {
        var chats = loadChats(userID: userID, mode: mode)
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
        }
        chats.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
        save(chats, to: chatsURL(userID: userID, mode: mode))

        var sharedChats = loadSharedChats(userID: userID)
        if let index = sharedChats.firstIndex(where: { $0.id == chat.id }) {
            sharedChats[index] = chat
        } else {
            sharedChats.append(chat)
        }
        sharedChats.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
        save(sharedChats, to: sharedChatsURL(userID: userID))
        postChatSnapshotsChanged()
    }

    func removeChat(chatID: UUID, userID: UUID, mode: ChatMode) {
        removeChatFromFile(chatID: chatID, url: chatsURL(userID: userID, mode: mode))
        removeChatFromFile(chatID: chatID, url: sharedChatsURL(userID: userID))
        removeFileIfPresent(messagesURL(chatID: chatID, userID: userID, mode: mode))
        removeFileIfPresent(sharedMessagesURL(chatID: chatID, userID: userID))
        postChatSnapshotsChanged()
    }

    func updateDraft(_ draft: Draft?, chatID: UUID, userID: UUID, mode: ChatMode) {
        updateDraftInModeScopedChats(draft, chatID: chatID, userID: userID, mode: mode)
        updateDraftInSharedChats(draft, chatID: chatID, userID: userID)
        postChatSnapshotsChanged()
    }

    func loadMessages(chatID: UUID, userID: UUID, mode: ChatMode) -> [Message] {
        load([Message].self, from: messagesURL(chatID: chatID, userID: userID, mode: mode)) ?? []
    }

    func loadSharedMessages(chatID: UUID, userID: UUID) -> [Message] {
        load([Message].self, from: sharedMessagesURL(chatID: chatID, userID: userID)) ?? []
    }

    func saveMessages(_ messages: [Message], chatID: UUID, userID: UUID, mode: ChatMode) {
        let stabilizedMessages = messages.map(ChatMediaPersistentStore.persist)
        let merged = mergeMessages(existing: loadMessages(chatID: chatID, userID: userID, mode: mode), incoming: stabilizedMessages)
        save(merged, to: messagesURL(chatID: chatID, userID: userID, mode: mode))
        let sharedMerged = mergeMessages(existing: loadSharedMessages(chatID: chatID, userID: userID), incoming: stabilizedMessages)
        save(sharedMerged, to: sharedMessagesURL(chatID: chatID, userID: userID))
        postChatSnapshotsChanged()
    }

    func upsertMessage(_ message: Message, in chat: Chat, userID: UUID, mode: ChatMode) {
        let stabilizedMessage = ChatMediaPersistentStore.persist(message)
        let mergedMessages = mergeMessages(
            existing: loadMessages(chatID: chat.id, userID: userID, mode: mode),
            incoming: [stabilizedMessage]
        )
        save(mergedMessages, to: messagesURL(chatID: chat.id, userID: userID, mode: mode))

        let sharedMergedMessages = mergeMessages(
            existing: loadSharedMessages(chatID: chat.id, userID: userID),
            incoming: [stabilizedMessage]
        )
        save(sharedMergedMessages, to: sharedMessagesURL(chatID: chat.id, userID: userID))

        var snapshotChat = chat
        let latestVisibleMessage = latestChatSummaryMessage(in: mergedMessages)
        snapshotChat.lastActivityAt = latestVisibleMessage?.createdAt ?? chat.lastActivityAt
        snapshotChat.lastMessagePreview = latestVisibleMessage.flatMap { messageSummaryText(for: $0) }
        upsertChat(snapshotChat, userID: userID, mode: mode)
    }

    func updateMessageStatus(
        clientMessageID: UUID,
        in chatID: UUID,
        userID: UUID,
        mode: ChatMode,
        status: MessageStatus
    ) {
        updateMessageStatusInMessagesFile(
            clientMessageID: clientMessageID,
            chatID: chatID,
            userID: userID,
            mode: mode,
            status: status
        )
        updateMessageStatusInSharedMessagesFile(
            clientMessageID: clientMessageID,
            chatID: chatID,
            userID: userID,
            status: status
        )
        postChatSnapshotsChanged()
    }

    func removeMessage(clientMessageID: UUID, chatID: UUID, userID: UUID, mode: ChatMode) {
        removeMessageFromMessagesFile(
            clientMessageID: clientMessageID,
            chatID: chatID,
            userID: userID,
            mode: mode
        )
        removeMessageFromSharedMessagesFile(
            clientMessageID: clientMessageID,
            chatID: chatID,
            userID: userID
        )
        postChatSnapshotsChanged()
    }

    private func chatsURL(userID: UUID, mode: ChatMode) -> URL {
        userDirectory(userID).appendingPathComponent("chats-\(mode.rawValue).json")
    }

    private func sharedChatsURL(userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent(SharedStorageKeys.chatsFileName)
    }

    private func messagesURL(chatID: UUID, userID: UUID, mode: ChatMode) -> URL {
        userDirectory(userID).appendingPathComponent("messages-\(mode.rawValue)-\(chatID.uuidString).json")
    }

    private func sharedMessagesURL(chatID: UUID, userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent(SharedStorageKeys.messagesFileName(chatID: chatID))
    }

    private func userDirectory(_ userID: UUID) -> URL {
        let fileManager = FileManager.default
        let directory = rootURL.appendingPathComponent(userID.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func mergeChats(existing: [Chat], incoming: [Chat]) -> [Chat] {
        guard existing.isEmpty == false else { return incoming }
        guard incoming.isEmpty == false else { return existing }

        var mergedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for chat in incoming {
            if let existingChat = mergedByID[chat.id] {
                mergedByID[chat.id] = mergeChat(existing: existingChat, incoming: chat)
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

    private func updateDraftInModeScopedChats(_ draft: Draft?, chatID: UUID, userID: UUID, mode: ChatMode) {
        var chats = loadChats(userID: userID, mode: mode)
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].draft = draft
        save(chats, to: chatsURL(userID: userID, mode: mode))
    }

    private func updateDraftInSharedChats(_ draft: Draft?, chatID: UUID, userID: UUID) {
        var chats = loadSharedChats(userID: userID)
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].draft = draft
        save(chats, to: sharedChatsURL(userID: userID))
    }

    private func mergeChat(existing: Chat, incoming: Chat) -> Chat {
        _ = existing
        return incoming
    }

    private func updateMessageStatusInMessagesFile(
        clientMessageID: UUID,
        chatID: UUID,
        userID: UUID,
        mode: ChatMode,
        status: MessageStatus
    ) {
        let url = messagesURL(chatID: chatID, userID: userID, mode: mode)
        guard var messages = load([Message].self, from: url),
              let index = messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) else {
            return
        }
        messages[index].status = status
        save(messages, to: url)
    }

    private func updateMessageStatusInSharedMessagesFile(
        clientMessageID: UUID,
        chatID: UUID,
        userID: UUID,
        status: MessageStatus
    ) {
        let url = sharedMessagesURL(chatID: chatID, userID: userID)
        guard var messages = load([Message].self, from: url),
              let index = messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) else {
            return
        }
        messages[index].status = status
        save(messages, to: url)
    }

    private func removeMessageFromMessagesFile(
        clientMessageID: UUID,
        chatID: UUID,
        userID: UUID,
        mode: ChatMode
    ) {
        let url = messagesURL(chatID: chatID, userID: userID, mode: mode)
        guard var messages = load([Message].self, from: url) else { return }
        let originalCount = messages.count
        messages.removeAll(where: { $0.clientMessageID == clientMessageID })
        guard messages.count != originalCount else { return }
        save(messages, to: url)
        refreshChatSummary(chatID: chatID, chatsURL: chatsURL(userID: userID, mode: mode), remainingMessages: messages)
    }

    private func removeMessageFromSharedMessagesFile(
        clientMessageID: UUID,
        chatID: UUID,
        userID: UUID
    ) {
        let url = sharedMessagesURL(chatID: chatID, userID: userID)
        guard var messages = load([Message].self, from: url) else { return }
        let originalCount = messages.count
        messages.removeAll(where: { $0.clientMessageID == clientMessageID })
        guard messages.count != originalCount else { return }
        save(messages, to: url)
        refreshChatSummary(chatID: chatID, chatsURL: sharedChatsURL(userID: userID), remainingMessages: messages)
    }

    private func refreshChatSummary(chatID: UUID, chatsURL: URL, remainingMessages: [Message]) {
        guard var chats = load([Chat].self, from: chatsURL),
              let index = chats.firstIndex(where: { $0.id == chatID }) else {
            return
        }

        if let lastMessage = latestChatSummaryMessage(in: remainingMessages) {
            chats[index].lastMessagePreview = messageSummaryText(for: lastMessage)
            chats[index].lastActivityAt = lastMessage.createdAt
        } else {
            chats[index].lastMessagePreview = nil
        }

        save(chats, to: chatsURL)
    }

    private func mergeMessages(existing: [Message], incoming: [Message]) -> [Message] {
        guard existing.isEmpty == false else { return incoming.sorted(by: { $0.createdAt < $1.createdAt }) }
        guard incoming.isEmpty == false else { return existing.sorted(by: { $0.createdAt < $1.createdAt }) }

        var mergedByClientID = Dictionary(uniqueKeysWithValues: existing.map { ($0.clientMessageID, $0) })
        for message in incoming {
            mergedByClientID[message.clientMessageID] = message
        }
        return mergedByClientID.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func latestChatSummaryMessage(in messages: [Message]) -> Message? {
        messages.last(where: { $0.shouldHideDeletedPlaceholder == false })
    }

    private func messageSummaryText(for message: Message) -> String? {
        if message.deletedForEveryoneAt != nil {
            return message.shouldHideDeletedPlaceholder ? nil : "Message deleted"
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

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func removeChatFromFile(chatID: UUID, url: URL) {
        guard var chats = load([Chat].self, from: url) else { return }
        let originalCount = chats.count
        chats.removeAll(where: { $0.id == chatID })
        guard chats.count != originalCount else { return }
        save(chats, to: url)
    }

    private func removeFileIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func postChatSnapshotsChanged() {
        guard snapshotNotificationScheduled == false else { return }
        snapshotNotificationScheduled = true

        Task { @MainActor in
            NotificationCenter.default.post(name: .primeMessagingChatSnapshotsChanged, object: nil)
            await self.finishSnapshotNotificationDelivery()
        }
    }

    private func finishSnapshotNotificationDelivery() {
        snapshotNotificationScheduled = false
    }
}

extension Notification.Name {
    static let primeMessagingDraftsChanged = Notification.Name("primeMessagingDraftsChanged")
    static let primeMessagingChatSnapshotsChanged = Notification.Name("primeMessagingChatSnapshotsChanged")
}

struct QueuedOutgoingMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var ownerUserID: UUID
    var chat: Chat
    var draft: OutgoingMessageDraft
    var createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
}

actor QueuedOutgoingMessageStore {
    static let shared = QueuedOutgoingMessageStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootURL: URL
    private var inFlightIDs = Set<UUID>()

    init(directoryName: String = "PrimeMessagingQueuedOutgoingMessages") {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func loadQueuedMessages(ownerUserID: UUID) -> [QueuedOutgoingMessage] {
        loadQueuedMessagesSync(ownerUserID: ownerUserID)
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    func enqueue(_ message: QueuedOutgoingMessage) {
        var stabilizedMessage = message
        stabilizedMessage.draft = ChatMediaPersistentStore.persist(message.draft)
        var messages = loadQueuedMessagesSync(ownerUserID: stabilizedMessage.ownerUserID)
        messages.removeAll(where: { $0.id == stabilizedMessage.id })
        messages.append(stabilizedMessage)
        save(messages, ownerUserID: stabilizedMessage.ownerUserID)
    }

    func claimReadyQueuedMessages(ownerUserID: UUID, now: Date = .now) -> [QueuedOutgoingMessage] {
        var messages = loadQueuedMessagesSync(ownerUserID: ownerUserID)
        var claimed: [QueuedOutgoingMessage] = []

        for index in messages.indices {
            let messageID = messages[index].id
            guard inFlightIDs.contains(messageID) == false else { continue }
            if let scheduledAt = messages[index].draft.deliveryOptions.scheduledAt, scheduledAt > now {
                continue
            }
            inFlightIDs.insert(messageID)
            messages[index].attemptCount += 1
            messages[index].lastAttemptAt = .now
            claimed.append(messages[index])
        }

        save(messages, ownerUserID: ownerUserID)
        return claimed.sorted(by: { $0.createdAt < $1.createdAt })
    }

    func nextScheduledDate(ownerUserID: UUID, after date: Date = .now) -> Date? {
        let messages = loadQueuedMessagesSync(ownerUserID: ownerUserID)
        return messages
            .compactMap(\.draft.deliveryOptions.scheduledAt)
            .filter { $0 > date }
            .min()
    }

    func complete(messageID: UUID, ownerUserID: UUID) {
        var messages = loadQueuedMessagesSync(ownerUserID: ownerUserID)
        messages.removeAll(where: { $0.id == messageID })
        save(messages, ownerUserID: ownerUserID)
        inFlightIDs.remove(messageID)
    }

    func remove(messageID: UUID, ownerUserID: UUID) {
        var messages = loadQueuedMessagesSync(ownerUserID: ownerUserID)
        messages.removeAll(where: { $0.id == messageID })
        save(messages, ownerUserID: ownerUserID)
        inFlightIDs.remove(messageID)
    }

    func release(messageID: UUID) {
        inFlightIDs.remove(messageID)
    }

    private func loadQueuedMessagesSync(ownerUserID: UUID) -> [QueuedOutgoingMessage] {
        guard let data = try? Data(contentsOf: fileURL(ownerUserID: ownerUserID)) else {
            return []
        }
        return (try? decoder.decode([QueuedOutgoingMessage].self, from: data)) ?? []
    }

    private func save(_ messages: [QueuedOutgoingMessage], ownerUserID: UUID) {
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: fileURL(ownerUserID: ownerUserID), options: .atomic)
    }

    private func fileURL(ownerUserID: UUID) -> URL {
        rootURL.appendingPathComponent("\(ownerUserID.uuidString).json")
    }
}
