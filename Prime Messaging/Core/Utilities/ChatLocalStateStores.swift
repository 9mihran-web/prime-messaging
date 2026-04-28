import Foundation

actor HiddenMessageStore {
    static let shared = HiddenMessageStore()

    private enum StorageKeys {
        static let hiddenMessages = "chat.hidden_messages"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hideMessage(_ messageID: UUID, ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        var hidden = records[key, default: []]
        hidden.insert(messageID)
        records[key] = hidden
        persist(records)
    }

    func hiddenMessageIDs(ownerUserID: UUID, chatID: UUID) -> Set<UUID> {
        loadRecords()[storageKey(ownerUserID: ownerUserID, chatID: chatID), default: []]
    }

    func purgeChat(ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        records.removeValue(forKey: storageKey(ownerUserID: ownerUserID, chatID: chatID))
        persist(records)
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: Set<UUID>] {
        guard let data = defaults.data(forKey: StorageKeys.hiddenMessages) else { return [:] }
        return (try? decoder.decode([String: Set<UUID>].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: Set<UUID>]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.hiddenMessages)
    }
}

actor PinnedMessageStore {
    static let shared = PinnedMessageStore()

    private enum StorageKeys {
        static let pinnedMessages = "chat.pinned_messages"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pinMessage(_ messageID: UUID?, ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        records[key] = messageID
        persist(records)
    }

    func pinnedMessageID(ownerUserID: UUID, chatID: UUID) -> UUID? {
        loadRecords()[storageKey(ownerUserID: ownerUserID, chatID: chatID)] ?? nil
    }

    func purgeChat(ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        records.removeValue(forKey: storageKey(ownerUserID: ownerUserID, chatID: chatID))
        persist(records)
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: UUID?] {
        guard let data = defaults.data(forKey: StorageKeys.pinnedMessages) else { return [:] }
        return (try? decoder.decode([String: UUID?].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: UUID?]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.pinnedMessages)
    }
}

struct ChatThreadLocalState: Codable, Hashable {
    var isPinned: Bool?
    var muteState: ChatMuteState?
    var isHidden: Bool
    var clearedAt: Date?
}

actor ChatThreadStateStore {
    static let shared = ChatThreadStateStore()

    private enum StorageKeys {
        static let threadStates = "chat.thread_states"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func apply(to chat: Chat, ownerUserID: UUID) -> Chat? {
        let key = storageKey(ownerUserID: ownerUserID, mode: chat.mode, chatID: chat.id)
        guard let state = loadRecords()[key] else {
            return chat
        }
        guard state.isHidden == false else {
            return nil
        }

        var updatedChat = chat
        if let isPinned = state.isPinned {
            updatedChat.isPinned = isPinned
        }
        if let muteState = state.muteState {
            updatedChat.notificationPreferences.muteState = muteState
        }
        return updatedChat
    }

    func setPinned(_ isPinned: Bool, ownerUserID: UUID, mode: ChatMode, chatID: UUID) {
        updateState(ownerUserID: ownerUserID, mode: mode, chatID: chatID) { state in
            state.isPinned = isPinned
        }
    }

    func setMuteState(_ muteState: ChatMuteState, ownerUserID: UUID, mode: ChatMode, chatID: UUID) {
        updateState(ownerUserID: ownerUserID, mode: mode, chatID: chatID) { state in
            state.muteState = muteState
        }
    }

    func hideChat(ownerUserID: UUID, mode: ChatMode, chatID: UUID) {
        updateState(ownerUserID: ownerUserID, mode: mode, chatID: chatID) { state in
            state.isHidden = true
        }
    }

    func clearChat(ownerUserID: UUID, mode: ChatMode, chatID: UUID) {
        updateState(ownerUserID: ownerUserID, mode: mode, chatID: chatID) { state in
            state.isHidden = false
            state.clearedAt = .now
        }
    }

    func purgeChat(ownerUserID: UUID, mode: ChatMode, chatID: UUID) {
        var records = loadRecords()
        records.removeValue(forKey: storageKey(ownerUserID: ownerUserID, mode: mode, chatID: chatID))
        persist(records)
    }

    func clearedAt(ownerUserID: UUID, mode: ChatMode, chatID: UUID) -> Date? {
        let key = storageKey(ownerUserID: ownerUserID, mode: mode, chatID: chatID)
        return loadRecords()[key]?.clearedAt
    }

    private func updateState(
        ownerUserID: UUID,
        mode: ChatMode,
        chatID: UUID,
        mutate: (inout ChatThreadLocalState) -> Void
    ) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, mode: mode, chatID: chatID)
        var state = records[key] ?? ChatThreadLocalState(isPinned: nil, muteState: nil, isHidden: false, clearedAt: nil)
        mutate(&state)
        records[key] = state
        persist(records)
    }

    private func storageKey(ownerUserID: UUID, mode: ChatMode, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(mode.rawValue)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: ChatThreadLocalState] {
        guard let data = defaults.data(forKey: StorageKeys.threadStates) else { return [:] }
        return (try? decoder.decode([String: ChatThreadLocalState].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: ChatThreadLocalState]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.threadStates)
    }
}

struct OfflineChatArchiveSnapshot: Codable {
    struct MessageBucket: Codable {
        var chatID: UUID
        var messages: [Message]
    }

    var chats: [Chat]
    var messageBuckets: [MessageBucket]
}

actor OfflineChatArchiveStore {
    static let shared = OfflineChatArchiveStore()

    private enum StorageKeys {
        static let archives = "chat.offline_archives"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(ownerUserID: UUID) -> (chatsByID: [UUID: Chat], messagesByChatID: [UUID: [Message]]) {
        let snapshot = loadRecords()[ownerUserID.uuidString] ?? OfflineChatArchiveSnapshot(chats: [], messageBuckets: [])
        let chatsByID = Dictionary(uniqueKeysWithValues: snapshot.chats.map { ($0.id, $0) })
        let messagesByChatID = Dictionary(uniqueKeysWithValues: snapshot.messageBuckets.map { ($0.chatID, $0.messages) })
        return (chatsByID, messagesByChatID)
    }

    func save(chatsByID: [UUID: Chat], messagesByChatID: [UUID: [Message]], ownerUserID: UUID) {
        var records = loadRecords()
        let snapshot = OfflineChatArchiveSnapshot(
            chats: chatsByID.values.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }),
            messageBuckets: messagesByChatID
                .map { OfflineChatArchiveSnapshot.MessageBucket(chatID: $0.key, messages: $0.value) }
                .sorted(by: { $0.chatID.uuidString < $1.chatID.uuidString })
        )
        records[ownerUserID.uuidString] = snapshot
        persist(records)
    }

    func purgeChats(_ chatIDs: Set<UUID>, ownerUserID: UUID) {
        guard chatIDs.isEmpty == false else { return }
        var records = loadRecords()
        guard var snapshot = records[ownerUserID.uuidString] else { return }
        snapshot.chats.removeAll { chatIDs.contains($0.id) }
        snapshot.messageBuckets.removeAll { chatIDs.contains($0.chatID) }
        records[ownerUserID.uuidString] = snapshot
        persist(records)
    }

    private func loadRecords() -> [String: OfflineChatArchiveSnapshot] {
        guard let data = defaults.data(forKey: StorageKeys.archives) else { return [:] }
        return (try? decoder.decode([String: OfflineChatArchiveSnapshot].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: OfflineChatArchiveSnapshot]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.archives)
    }
}

actor EventChatMetadataStore {
    static let shared = EventChatMetadataStore()

    private enum StorageKeys {
        static let eventChats = "chat.event_metadata"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func metadata(ownerUserID: UUID, chatID: UUID) -> EventChatDetails? {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        guard let details = records[key] else { return nil }
        if details.isExpired {
            records.removeValue(forKey: key)
            persist(records)
            return nil
        }
        return details
    }

    func setMetadata(_ details: EventChatDetails?, ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        records[key] = details
        persist(records)
    }

    func purgeChat(ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        records.removeValue(forKey: storageKey(ownerUserID: ownerUserID, chatID: chatID))
        persist(records)
    }

    func apply(to chat: Chat, ownerUserID: UUID) -> Chat? {
        guard let details = metadata(ownerUserID: ownerUserID, chatID: chat.id) else {
            return chat
        }

        var updatedChat = chat
        updatedChat.eventDetails = details
        return updatedChat
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: EventChatDetails] {
        guard let data = defaults.data(forKey: StorageKeys.eventChats) else { return [:] }
        return (try? decoder.decode([String: EventChatDetails].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: EventChatDetails]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.eventChats)
    }
}

actor NearbyPeersVisibilityStore {
    static let shared = NearbyPeersVisibilityStore()

    private enum StorageKeys {
        static let records = "settings.nearby_peers_visibility"
    }

    private struct Record: Codable {
        var showHomeCard: Bool
        var offlineOnly: Bool
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferences(ownerUserID: UUID) -> (showHomeCard: Bool, offlineOnly: Bool) {
        let record = loadRecords()[ownerUserID.uuidString] ?? Record(showHomeCard: true, offlineOnly: true)
        return (record.showHomeCard, record.offlineOnly)
    }

    func setShowHomeCard(_ isEnabled: Bool, ownerUserID: UUID) {
        update(ownerUserID: ownerUserID) { record in
            record.showHomeCard = isEnabled
        }
    }

    func setOfflineOnly(_ isEnabled: Bool, ownerUserID: UUID) {
        update(ownerUserID: ownerUserID) { record in
            record.offlineOnly = isEnabled
        }
    }

    private func update(ownerUserID: UUID, mutate: (inout Record) -> Void) {
        var records = loadRecords()
        var record = records[ownerUserID.uuidString] ?? Record(showHomeCard: true, offlineOnly: true)
        mutate(&record)
        records[ownerUserID.uuidString] = record
        persist(records)
    }

    private func loadRecords() -> [String: Record] {
        guard let data = defaults.data(forKey: StorageKeys.records) else { return [:] }
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: Record]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.records)
    }
}

actor CommunityChatMetadataStore {
    static let shared = CommunityChatMetadataStore()

    private enum StorageKeys {
        static let communityChats = "chat.community_metadata"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func details(ownerUserID: UUID, chatID: UUID) -> CommunityChatDetails? {
        loadRecords()[storageKey(ownerUserID: ownerUserID, chatID: chatID)]
    }

    func setDetails(_ details: CommunityChatDetails?, ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        records[key] = details
        persist(records)
    }

    func apply(to chat: Chat, ownerUserID: UUID) -> Chat {
        guard let details = details(ownerUserID: ownerUserID, chatID: chat.id) else {
            return chat
        }

        var updatedChat = chat
        updatedChat.communityDetails = details
        return updatedChat
    }

    func normalize(_ chat: Chat, ownerUserID: UUID) -> Chat {
        var normalizedChat = chat

        if let incomingDetails = chat.communityDetails {
            var records = loadRecords()
            records[storageKey(ownerUserID: ownerUserID, chatID: chat.id)] = incomingDetails
            persist(records)
            normalizedChat.communityDetails = incomingDetails
            return normalizedChat
        }

        if let storedDetails = details(ownerUserID: ownerUserID, chatID: chat.id) {
            normalizedChat.communityDetails = storedDetails
        }

        return normalizedChat
    }

    func normalize(_ chats: [Chat], ownerUserID: UUID) -> [Chat] {
        chats.map { normalize($0, ownerUserID: ownerUserID) }
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: CommunityChatDetails] {
        guard let data = defaults.data(forKey: StorageKeys.communityChats) else { return [:] }
        return (try? decoder.decode([String: CommunityChatDetails].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: CommunityChatDetails]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.communityChats)
    }
}

actor GroupModerationSettingsStore {
    static let shared = GroupModerationSettingsStore()

    private enum StorageKeys {
        static let moderationSettings = "chat.moderation_settings"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(ownerUserID: UUID, chatID: UUID) -> GroupModerationSettings? {
        loadRecords()[storageKey(ownerUserID: ownerUserID, chatID: chatID)]
    }

    func setSettings(_ settings: GroupModerationSettings?, ownerUserID: UUID, chatID: UUID) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID)
        records[key] = settings
        persist(records)
    }

    func apply(to chat: Chat, ownerUserID: UUID) -> Chat {
        guard let settings = settings(ownerUserID: ownerUserID, chatID: chat.id) else {
            return chat
        }

        var updatedChat = chat
        updatedChat.moderationSettings = settings
        return updatedChat
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)"
    }

    private func loadRecords() -> [String: GroupModerationSettings] {
        guard let data = defaults.data(forKey: StorageKeys.moderationSettings) else { return [:] }
        return (try? decoder.decode([String: GroupModerationSettings].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: GroupModerationSettings]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.moderationSettings)
    }
}

private struct ModerationMessageEvent: Codable, Hashable {
    var createdAt: Date
    var signature: String
}

private struct ModerationThrottleState: Codable, Hashable {
    var lastSentAt: Date?
    var events: [ModerationMessageEvent]
}

actor GroupModerationThrottleStore {
    static let shared = GroupModerationThrottleStore()

    private enum StorageKeys {
        static let throttles = "chat.moderation_throttles"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func remainingSlowModeDelay(
        ownerUserID: UUID,
        chatID: UUID,
        senderID: UUID,
        slowModeSeconds: Int,
        now: Date = .now
    ) -> Int {
        guard slowModeSeconds > 0 else { return 0 }
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID, senderID: senderID)
        guard let lastSentAt = loadRecords()[key]?.lastSentAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastSentAt)
        let remaining = Int(ceil(Double(slowModeSeconds) - elapsed))
        return max(remaining, 0)
    }

    func wouldTriggerSpamProtection(
        ownerUserID: UUID,
        chatID: UUID,
        senderID: UUID,
        signature: String,
        now: Date = .now
    ) -> Bool {
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID, senderID: senderID)
        let state = prunedState(for: key, now: now)

        let matchingRecentDuplicates = state.events.filter {
            $0.signature == signature && now.timeIntervalSince($0.createdAt) <= 45
        }.count
        if matchingRecentDuplicates >= 2 {
            return true
        }

        let burstCount = state.events.filter { now.timeIntervalSince($0.createdAt) <= 20 }.count
        return burstCount >= 5
    }

    func recordOutgoingMessage(
        ownerUserID: UUID,
        chatID: UUID,
        senderID: UUID,
        signature: String,
        createdAt: Date = .now
    ) {
        var records = loadRecords()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID, senderID: senderID)
        var state = prunedState(from: records[key] ?? ModerationThrottleState(lastSentAt: nil, events: []), now: createdAt)
        state.lastSentAt = createdAt
        state.events.append(ModerationMessageEvent(createdAt: createdAt, signature: signature))
        state = prunedState(from: state, now: createdAt)
        records[key] = state
        persist(records)
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID, senderID: UUID) -> String {
        "\(ownerUserID.uuidString)-\(chatID.uuidString)-\(senderID.uuidString)"
    }

    private func prunedState(for key: String, now: Date) -> ModerationThrottleState {
        let state = loadRecords()[key] ?? ModerationThrottleState(lastSentAt: nil, events: [])
        return prunedState(from: state, now: now)
    }

    private func prunedState(from state: ModerationThrottleState, now: Date) -> ModerationThrottleState {
        let retainedEvents = state.events.filter { now.timeIntervalSince($0.createdAt) <= 60 }
        return ModerationThrottleState(lastSentAt: state.lastSentAt, events: retainedEvents)
    }

    private func loadRecords() -> [String: ModerationThrottleState] {
        guard let data = defaults.data(forKey: StorageKeys.throttles) else { return [:] }
        return (try? decoder.decode([String: ModerationThrottleState].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: ModerationThrottleState]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.throttles)
    }
}

actor ChatNavigationStateStore {
    static let shared = ChatNavigationStateStore()

    private enum StorageKeys {
        static let readingAnchors = "chat.navigation.reading_anchors"
        static let messageSearches = "chat.navigation.message_searches"
        static let globalSearches = "chat.navigation.global_searches"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readingAnchorMessageID(ownerUserID: UUID, chatID: UUID, mode: ChatMode) -> UUID? {
        loadReadingAnchors()[storageKey(ownerUserID: ownerUserID, chatID: chatID, mode: mode)] ?? nil
    }

    func saveReadingAnchorMessageID(_ messageID: UUID?, ownerUserID: UUID, chatID: UUID, mode: ChatMode) {
        var anchors = loadReadingAnchors()
        anchors[storageKey(ownerUserID: ownerUserID, chatID: chatID, mode: mode)] = messageID
        persistReadingAnchors(anchors)
    }

    func recentMessageSearches(ownerUserID: UUID, chatID: UUID, mode: ChatMode, limit: Int = 6) -> [String] {
        Array(
            loadMessageSearches()[storageKey(ownerUserID: ownerUserID, chatID: chatID, mode: mode), default: []]
                .prefix(limit)
        )
    }

    func saveMessageSearch(_ query: String, ownerUserID: UUID, chatID: UUID, mode: ChatMode, limit: Int = 6) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else { return }

        var searches = loadMessageSearches()
        let key = storageKey(ownerUserID: ownerUserID, chatID: chatID, mode: mode)
        var values = searches[key, default: []]
        values.removeAll(where: { $0.caseInsensitiveCompare(normalizedQuery) == .orderedSame })
        values.insert(normalizedQuery, at: 0)
        searches[key] = Array(values.prefix(limit))
        persistMessageSearches(searches)
    }

    func recentGlobalSearches(ownerUserID: UUID, limit: Int = 6) -> [String] {
        Array(loadGlobalSearches()[ownerUserID.uuidString, default: []].prefix(limit))
    }

    func saveGlobalSearch(_ query: String, ownerUserID: UUID, limit: Int = 6) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else { return }

        var searches = loadGlobalSearches()
        let key = ownerUserID.uuidString
        var values = searches[key, default: []]
        values.removeAll(where: { $0.caseInsensitiveCompare(normalizedQuery) == .orderedSame })
        values.insert(normalizedQuery, at: 0)
        searches[key] = Array(values.prefix(limit))
        persistGlobalSearches(searches)
    }

    private func storageKey(ownerUserID: UUID, chatID: UUID, mode: ChatMode) -> String {
        "\(ownerUserID.uuidString)-\(mode.rawValue)-\(chatID.uuidString)"
    }

    private func loadReadingAnchors() -> [String: UUID?] {
        guard let data = defaults.data(forKey: StorageKeys.readingAnchors) else { return [:] }
        return (try? decoder.decode([String: UUID?].self, from: data)) ?? [:]
    }

    private func persistReadingAnchors(_ values: [String: UUID?]) {
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: StorageKeys.readingAnchors)
    }

    private func loadMessageSearches() -> [String: [String]] {
        guard let data = defaults.data(forKey: StorageKeys.messageSearches) else { return [:] }
        return (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
    }

    private func persistMessageSearches(_ values: [String: [String]]) {
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: StorageKeys.messageSearches)
    }

    private func loadGlobalSearches() -> [String: [String]] {
        guard let data = defaults.data(forKey: StorageKeys.globalSearches) else { return [:] }
        return (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
    }

    private func persistGlobalSearches(_ values: [String: [String]]) {
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: StorageKeys.globalSearches)
    }
}

actor OnboardingProgressStore {
    static let shared = OnboardingProgressStore()

    struct StoredLookup: Codable, Hashable {
        var exists: Bool
        var accountKindRawValue: String?
        var displayName: String?
    }

    struct StoredState: Codable, Hashable {
        var modeRawValue: String
        var stepRawValue: String
        var isContactSyncEnabled: Bool?
        var selectedCountryCode: String
        var localIdentifierInput: String
        var email: String
        var displayName: String
        var username: String
        var bio: String
        var birthDate: Date
        var pendingIdentifier: String
        var pendingContactValue: String
        var pendingIdentifierKindRawValue: String
        var loginCredentialModeRawValue: String?
        var pendingLookup: StoredLookup?
    }

    private enum StorageKeys {
        static let onboardingProgress = "onboarding.progress"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StoredState? {
        guard let data = defaults.data(forKey: StorageKeys.onboardingProgress) else { return nil }
        return try? decoder.decode(StoredState.self, from: data)
    }

    func save(_ state: StoredState) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: StorageKeys.onboardingProgress)
    }

    func clear() {
        defaults.removeObject(forKey: StorageKeys.onboardingProgress)
    }
}
