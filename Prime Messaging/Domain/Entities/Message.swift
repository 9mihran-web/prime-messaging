import Foundation

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    var clientMessageID: UUID
    var senderDisplayName: String?
    var mode: ChatMode
    var deliveryState: MessageDeliveryState
    var deliveryRoute: MessageDeliveryRoute?
    var kind: MessageKind
    var text: String?
    var attachments: [Attachment]
    var linkPreview: MessageLinkPreview?
    var replyToMessageID: UUID?
    var replyPreview: ReplyPreviewSnapshot?
    var communityContext: CommunityMessageContext?
    var deliveryOptions: MessageDeliveryOptions
    var status: MessageStatus
    var createdAt: Date
    var editedAt: Date?
    var deletedForEveryoneAt: Date?
    var reactions: [MessageReaction]
    var voiceMessage: VoiceMessage?
    var liveLocation: LiveLocationSession?

    enum CodingKeys: String, CodingKey {
        case id
        case chatID
        case senderID
        case clientMessageID
        case senderDisplayName
        case mode
        case deliveryState
        case deliveryRoute
        case kind
        case text
        case attachments
        case linkPreview
        case replyToMessageID
        case replyPreview
        case communityContext
        case deliveryOptions
        case status
        case createdAt
        case editedAt
        case deletedForEveryoneAt
        case reactions
        case voiceMessage
        case liveLocation
    }

    init(
        id: UUID,
        chatID: UUID,
        senderID: UUID,
        clientMessageID: UUID? = nil,
        senderDisplayName: String?,
        mode: ChatMode,
        deliveryState: MessageDeliveryState? = nil,
        deliveryRoute: MessageDeliveryRoute? = nil,
        kind: MessageKind,
        text: String?,
        attachments: [Attachment],
        linkPreview: MessageLinkPreview? = nil,
        replyToMessageID: UUID?,
        replyPreview: ReplyPreviewSnapshot? = nil,
        communityContext: CommunityMessageContext? = nil,
        deliveryOptions: MessageDeliveryOptions = MessageDeliveryOptions(),
        status: MessageStatus,
        createdAt: Date,
        editedAt: Date?,
        deletedForEveryoneAt: Date?,
        reactions: [MessageReaction],
        voiceMessage: VoiceMessage?,
        liveLocation: LiveLocationSession?
    ) {
        self.id = id
        self.chatID = chatID
        self.senderID = senderID
        self.clientMessageID = clientMessageID ?? id
        self.senderDisplayName = senderDisplayName
        self.mode = mode
        self.deliveryState = deliveryState ?? Message.defaultDeliveryState(for: mode)
        self.deliveryRoute = deliveryRoute
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.linkPreview = linkPreview
        self.replyToMessageID = replyToMessageID
        self.replyPreview = replyPreview
        self.communityContext = communityContext
        self.deliveryOptions = deliveryOptions
        self.status = status
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedForEveryoneAt = deletedForEveryoneAt
        self.reactions = reactions
        self.voiceMessage = voiceMessage
        self.liveLocation = liveLocation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        chatID = try container.decode(UUID.self, forKey: .chatID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        let modeValue = try container.decode(ChatMode.self, forKey: .mode)
        mode = modeValue
        clientMessageID = try container.decodeIfPresent(UUID.self, forKey: .clientMessageID) ?? id
        senderDisplayName = try container.decodeIfPresent(String.self, forKey: .senderDisplayName)
        deliveryState = try container.decodeIfPresent(MessageDeliveryState.self, forKey: .deliveryState) ?? Message.defaultDeliveryState(for: modeValue)
        deliveryRoute = try container.decodeIfPresent(MessageDeliveryRoute.self, forKey: .deliveryRoute)
        kind = try container.decode(MessageKind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        linkPreview = try container.decodeIfPresent(MessageLinkPreview.self, forKey: .linkPreview)
        replyToMessageID = try container.decodeIfPresent(UUID.self, forKey: .replyToMessageID)
        replyPreview = try container.decodeIfPresent(ReplyPreviewSnapshot.self, forKey: .replyPreview)
        communityContext = try container.decodeIfPresent(CommunityMessageContext.self, forKey: .communityContext)
        deliveryOptions = try container.decodeIfPresent(MessageDeliveryOptions.self, forKey: .deliveryOptions) ?? MessageDeliveryOptions()
        status = try container.decode(MessageStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        deletedForEveryoneAt = try container.decodeIfPresent(Date.self, forKey: .deletedForEveryoneAt)
        reactions = try container.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
        voiceMessage = try container.decodeIfPresent(VoiceMessage.self, forKey: .voiceMessage)
        liveLocation = try container.decodeIfPresent(LiveLocationSession.self, forKey: .liveLocation)
    }

    private static func defaultDeliveryState(for mode: ChatMode) -> MessageDeliveryState {
        switch mode {
        case .smart:
            return .online
        case .online:
            return .online
        case .offline:
            return .offline
        }
    }
}

struct OutgoingMessageDraft: Codable, Hashable {
    var text: String
    var attachments: [Attachment]
    var linkPreview: MessageLinkPreview?
    var voiceMessage: VoiceMessage?
    var replyToMessageID: UUID?
    var replyPreview: ReplyPreviewSnapshot?
    var communityContext: CommunityMessageContext?
    var deliveryOptions: MessageDeliveryOptions
    var clientMessageID: UUID?
    var createdAt: Date?
    var deliveryStateOverride: MessageDeliveryState?

    init(
        text: String = "",
        attachments: [Attachment] = [],
        linkPreview: MessageLinkPreview? = nil,
        voiceMessage: VoiceMessage? = nil,
        replyToMessageID: UUID? = nil,
        replyPreview: ReplyPreviewSnapshot? = nil,
        communityContext: CommunityMessageContext? = nil,
        deliveryOptions: MessageDeliveryOptions = MessageDeliveryOptions(),
        clientMessageID: UUID? = nil,
        createdAt: Date? = nil,
        deliveryStateOverride: MessageDeliveryState? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.linkPreview = linkPreview
        self.voiceMessage = voiceMessage
        self.replyToMessageID = replyToMessageID
        self.replyPreview = replyPreview
        self.communityContext = communityContext
        self.deliveryOptions = deliveryOptions
        self.clientMessageID = clientMessageID
        self.createdAt = createdAt
        self.deliveryStateOverride = deliveryStateOverride
    }

    var normalizedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasContent: Bool {
        normalizedText != nil || attachments.isEmpty == false || voiceMessage != nil
    }

    func isScheduledForFuture(relativeTo date: Date = .now) -> Bool {
        guard let scheduledAt = deliveryOptions.scheduledAt else { return false }
        return scheduledAt > date
    }
}

struct MessageLinkPreview: Codable, Hashable {
    var selectedURL: URL?
    var isDisabled: Bool

    init(selectedURL: URL? = nil, isDisabled: Bool = false) {
        self.selectedURL = selectedURL
        self.isDisabled = isDisabled
    }

    func resolvedURL(in rawText: String?) -> URL? {
        if let selectedURL {
            return selectedURL
        }
        return RichMessageText.detectedURLs(in: rawText).first
    }
}

struct MessageDeliveryOptions: Codable, Hashable {
    var isSilent: Bool
    var scheduledAt: Date?
    var selfDestructSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case isSilent
        case scheduledAt
        case selfDestructSeconds
    }

    init(isSilent: Bool = false, scheduledAt: Date? = nil, selfDestructSeconds: Int? = nil) {
        self.isSilent = isSilent
        self.scheduledAt = scheduledAt
        if let selfDestructSeconds, selfDestructSeconds > 0 {
            self.selfDestructSeconds = selfDestructSeconds
        } else {
            self.selfDestructSeconds = nil
        }
    }

    var hasAdvancedBehavior: Bool {
        isSilent || scheduledAt != nil || selfDestructSeconds != nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSilent = try container.decodeIfPresent(Bool.self, forKey: .isSilent) ?? false

        if let isoValue = try container.decodeIfPresent(String.self, forKey: .scheduledAt) {
            scheduledAt = ISO8601DateFormatter().date(from: isoValue)
        } else if let numericValue = try container.decodeIfPresent(Double.self, forKey: .scheduledAt) {
            scheduledAt = Date(timeIntervalSinceReferenceDate: numericValue)
        } else {
            scheduledAt = nil
        }

        if let value = try container.decodeIfPresent(Int.self, forKey: .selfDestructSeconds), value > 0 {
            selfDestructSeconds = value
        } else {
            selfDestructSeconds = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isSilent, forKey: .isSilent)
        try container.encodeIfPresent(scheduledAt?.ISO8601Format(), forKey: .scheduledAt)
        try container.encodeIfPresent(selfDestructSeconds, forKey: .selfDestructSeconds)
    }
}

struct CommunityMessageContext: Codable, Hashable {
    var topicID: UUID?
    var parentPostID: UUID?

    init(topicID: UUID? = nil, parentPostID: UUID? = nil) {
        self.topicID = topicID
        self.parentPostID = parentPostID
    }

    var hasRoutingContext: Bool {
        topicID != nil || parentPostID != nil
    }
}

extension Message {
    var isSilentDelivery: Bool {
        deliveryOptions.isSilent
    }

    var scheduledAt: Date? {
        deliveryOptions.scheduledAt
    }

    var selfDestructSeconds: Int? {
        deliveryOptions.selfDestructSeconds
    }

    func selfDestructAt(referenceCreatedAt: Date? = nil) -> Date? {
        guard let selfDestructSeconds, selfDestructSeconds > 0 else { return nil }
        return (referenceCreatedAt ?? createdAt).addingTimeInterval(TimeInterval(selfDestructSeconds))
    }

    func isExpiredForSelfDestruct(relativeTo date: Date = .now) -> Bool {
        guard let expiresAt = selfDestructAt() else { return false }
        return date >= expiresAt
    }

    var communityTopicID: UUID? {
        communityContext?.topicID
    }

    var communityParentPostID: UUID? {
        communityContext?.parentPostID
    }

    var isCommunityComment: Bool {
        communityParentPostID != nil
    }

    func withDeliveryRoute(_ route: MessageDeliveryRoute?) -> Message {
        var copy = self
        copy.deliveryRoute = route
        return copy
    }
}

struct ReplyPreviewSnapshot: Codable, Hashable {
    var senderID: UUID?
    var senderDisplayName: String?
    var previewText: String
}

struct Attachment: Identifiable, Codable, Hashable {
    let id: UUID
    var type: AttachmentType
    var fileName: String
    var mimeType: String
    var localURL: URL?
    var remoteURL: URL?
    var byteSize: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case fileName
        case mimeType
        case localURL
        case remoteURL
        case byteSize
    }

    init(
        id: UUID,
        type: AttachmentType,
        fileName: String,
        mimeType: String,
        localURL: URL?,
        remoteURL: URL?,
        byteSize: Int64
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.mimeType = mimeType
        self.localURL = localURL
        self.remoteURL = remoteURL
        self.byteSize = byteSize
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(AttachmentType.self, forKey: .type)
        fileName = try container.decode(String.self, forKey: .fileName)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        localURL = container.decodeLossyURLIfPresent(forKey: .localURL)
        remoteURL = container.decodeLossyURLIfPresent(forKey: .remoteURL)
        byteSize = try container.decode(Int64.self, forKey: .byteSize)
    }
}

struct MessageReaction: Identifiable, Codable, Hashable {
    let id: UUID
    var emoji: String
    var userIDs: [UUID]
}

struct VoiceMessage: Codable, Hashable {
    var durationSeconds: Int
    var waveformSamples: [Float]
    var byteSize: Int64
    var localFileURL: URL?
    var remoteFileURL: URL?

    enum CodingKeys: String, CodingKey {
        case durationSeconds
        case waveformSamples
        case byteSize
        case localFileURL
        case remoteFileURL
    }

    init(durationSeconds: Int, waveformSamples: [Float], byteSize: Int64 = 0, localFileURL: URL?, remoteFileURL: URL?) {
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
        self.byteSize = byteSize
        self.localFileURL = localFileURL
        self.remoteFileURL = remoteFileURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        waveformSamples = try container.decode([Float].self, forKey: .waveformSamples)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
        localFileURL = container.decodeLossyURLIfPresent(forKey: .localFileURL)
        remoteFileURL = container.decodeLossyURLIfPresent(forKey: .remoteFileURL)
    }
}

extension Message {
    func mergingLocalObjectState(from fallback: Message) -> Message {
        var merged = self

        if merged.senderDisplayName == nil {
            merged.senderDisplayName = fallback.senderDisplayName
        }
        if merged.replyPreview == nil {
            merged.replyPreview = fallback.replyPreview
        }
        if merged.communityContext == nil {
            merged.communityContext = fallback.communityContext
        }
        if merged.deliveryRoute == nil {
            merged.deliveryRoute = fallback.deliveryRoute
        }
        if merged.liveLocation == nil {
            merged.liveLocation = fallback.liveLocation
        }
        if merged.deliveryOptions.hasAdvancedBehavior == false, fallback.deliveryOptions.hasAdvancedBehavior {
            merged.deliveryOptions = fallback.deliveryOptions
        }

        merged.attachments = merged.attachments.mergingLocalObjectState(from: fallback.attachments)
        merged.voiceMessage = merged.voiceMessage.mergingLocalObjectState(from: fallback.voiceMessage)
        return merged
    }

    func applyingDraftObjectState(from draft: OutgoingMessageDraft) -> Message {
        var merged = self

        if merged.deliveryOptions.hasAdvancedBehavior == false, draft.deliveryOptions.hasAdvancedBehavior {
            merged.deliveryOptions = draft.deliveryOptions
        }

        merged.attachments = merged.attachments.mergingLocalObjectState(from: draft.attachments)
        merged.voiceMessage = merged.voiceMessage.mergingLocalObjectState(from: draft.voiceMessage)
        return merged
    }
}

extension Array where Element == Attachment {
    func mergingLocalObjectState(from fallback: [Attachment]) -> [Attachment] {
        guard isEmpty == false else { return fallback }
        guard fallback.isEmpty == false else { return self }

        let maximumCount = Swift.max(count, fallback.count)
        var merged: [Attachment] = []
        merged.reserveCapacity(maximumCount)

        for index in 0 ..< maximumCount {
            let primary = index < count ? self[index] : nil
            let fallbackAttachment = index < fallback.count ? fallback[index] : nil

            if let primary, let fallbackAttachment {
                merged.append(primary.mergingLocalObjectState(from: fallbackAttachment))
            } else if let primary {
                merged.append(primary)
            } else if let fallbackAttachment {
                merged.append(fallbackAttachment)
            }
        }

        return merged
    }
}

extension Attachment {
    func mergingLocalObjectState(from fallback: Attachment) -> Attachment {
        var merged = self

        if merged.localURL.isUsableLocalMediaURL == false {
            merged.localURL = fallback.localURL.isUsableLocalMediaURL ? fallback.localURL : merged.localURL
        }
        if merged.remoteURL == nil {
            merged.remoteURL = fallback.remoteURL
        }
        if merged.fileName.isEmpty {
            merged.fileName = fallback.fileName
        }
        if merged.mimeType.isEmpty {
            merged.mimeType = fallback.mimeType
        }
        if merged.byteSize <= 0 {
            merged.byteSize = fallback.byteSize
        }

        return merged
    }
}

extension Optional where Wrapped == VoiceMessage {
    func mergingLocalObjectState(from fallback: VoiceMessage?) -> VoiceMessage? {
        switch (self, fallback) {
        case let (primary?, fallback?):
            return primary.mergingLocalObjectState(from: fallback)
        case let (primary?, nil):
            return primary
        case let (nil, fallback?):
            return fallback
        case (nil, nil):
            return nil
        }
    }
}

extension VoiceMessage {
    func mergingLocalObjectState(from fallback: VoiceMessage) -> VoiceMessage {
        var merged = self

        if merged.localFileURL.isUsableLocalMediaURL == false {
            merged.localFileURL = fallback.localFileURL.isUsableLocalMediaURL ? fallback.localFileURL : merged.localFileURL
        }
        if merged.remoteFileURL == nil {
            merged.remoteFileURL = fallback.remoteFileURL
        }
        if merged.durationSeconds <= 0 {
            merged.durationSeconds = fallback.durationSeconds
        }
        if merged.byteSize <= 0 {
            merged.byteSize = fallback.byteSize
        }
        if merged.waveformSamples.isEmpty {
            merged.waveformSamples = fallback.waveformSamples
        }

        return merged
    }
}

private extension Optional where Wrapped == URL {
    var isUsableLocalMediaURL: Bool {
        guard let url = self else { return false }
        guard url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

struct LiveLocationSession: Identifiable, Codable, Hashable {
    let id: UUID
    var senderID: UUID
    var latitude: Double
    var longitude: Double
    var accuracyMeters: Double
    var startedAt: Date
    var endsAt: Date
    var isActive: Bool
}

struct SecretChat: Identifiable, Codable, Hashable {
    let id: UUID
    let baseChatID: UUID
    var isActive: Bool
    var deviceKeyFingerprint: String?
    var createdAt: Date
}

struct DisappearingMessagePolicy: Codable, Hashable {
    var durationSeconds: Int
    var startsOnRead: Bool
}

extension Message {
    nonisolated static let hiddenDeletePlaceholderWindow: TimeInterval = 7 * 24 * 60 * 60

    nonisolated var isDeleted: Bool {
        deletedForEveryoneAt != nil
    }

    nonisolated var shouldHideDeletedPlaceholder: Bool {
        guard let deletedForEveryoneAt else { return false }
        return deletedForEveryoneAt.timeIntervalSince(createdAt) <= Self.hiddenDeletePlaceholderWindow
    }

    var editableText: String? {
        guard isDeleted == false else { return nil }
        guard attachments.isEmpty, voiceMessage == nil else { return nil }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canEditText: Bool {
        guard let editableText else { return false }
        return editableText.isEmpty == false
    }

    static func mock(chatID: UUID, mode: ChatMode, currentUserID: UUID) -> [Message] {
        let otherUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        return [
            Message(
                id: UUID(),
                chatID: chatID,
                senderID: otherUserID,
                senderDisplayName: "Prime Contact",
                mode: mode,
                kind: .text,
                text: mode == .online ? "We should keep online and offline chats separate." : "Bluetooth session is stable now.",
                attachments: [],
                replyToMessageID: nil,
                status: .read,
                createdAt: .now.addingTimeInterval(-2_400),
                editedAt: nil,
                deletedForEveryoneAt: nil,
                reactions: [],
                voiceMessage: nil,
                liveLocation: nil
            ),
            Message(
                id: UUID(),
                chatID: chatID,
                senderID: currentUserID,
                senderDisplayName: "Prime User",
                mode: mode,
                kind: .text,
                text: mode == .online ? "Agreed. That keeps trust and clarity." : "Good. Keep me posted if the range drops.",
                attachments: [],
                replyToMessageID: nil,
                status: .delivered,
                createdAt: .now.addingTimeInterval(-1_500),
                editedAt: nil,
                deletedForEveryoneAt: nil,
                reactions: [MessageReaction(id: UUID(), emoji: "👍", userIDs: [otherUserID])],
                voiceMessage: nil,
                liveLocation: nil
            )
        ]
    }
}
