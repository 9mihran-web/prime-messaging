import Foundation

struct Chat: Identifiable, Codable, Hashable {
    let id: UUID
    var mode: ChatMode
    var type: ChatType
    var title: String
    var subtitle: String
    var participantIDs: [UUID]
    var participants: [ChatParticipant] = []
    var group: Group?
    var lastMessagePreview: String?
    var lastActivityAt: Date
    var unreadCount: Int
    var isPinned: Bool
    var draft: Draft?
    var disappearingPolicy: DisappearingMessagePolicy?
    var notificationPreferences: NotificationPreferences
    var guestRequest: GuestRequest?
    var eventDetails: EventChatDetails?
    var communityDetails: CommunityChatDetails?
    var moderationSettings: GroupModerationSettings?
    var primePremiumActivity: PrimePremiumChatActivity?

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case type
        case title
        case subtitle
        case participantIDs
        case participants
        case group
        case lastMessagePreview
        case lastActivityAt
        case unreadCount
        case isPinned
        case draft
        case disappearingPolicy
        case notificationPreferences
        case guestRequest
        case eventDetails
        case communityDetails
        case moderationSettings
        case primePremiumActivity
    }

    init(
        id: UUID,
        mode: ChatMode,
        type: ChatType,
        title: String,
        subtitle: String,
        participantIDs: [UUID],
        participants: [ChatParticipant] = [],
        group: Group?,
        lastMessagePreview: String?,
        lastActivityAt: Date,
        unreadCount: Int,
        isPinned: Bool,
        draft: Draft?,
        disappearingPolicy: DisappearingMessagePolicy?,
        notificationPreferences: NotificationPreferences,
        guestRequest: GuestRequest? = nil,
        eventDetails: EventChatDetails? = nil,
        communityDetails: CommunityChatDetails? = nil,
        moderationSettings: GroupModerationSettings? = nil,
        primePremiumActivity: PrimePremiumChatActivity? = nil
    ) {
        self.id = id
        self.mode = mode
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.participantIDs = participantIDs
        self.participants = participants
        self.group = group
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityAt = lastActivityAt
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.draft = draft
        self.disappearingPolicy = disappearingPolicy
        self.notificationPreferences = notificationPreferences
        self.guestRequest = guestRequest
        self.eventDetails = eventDetails
        self.communityDetails = communityDetails
        self.moderationSettings = moderationSettings
        self.primePremiumActivity = primePremiumActivity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(ChatMode.self, forKey: .mode)
        type = try container.decode(ChatType.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        participantIDs = try container.decode([UUID].self, forKey: .participantIDs)
        participants = try container.decodeIfPresent([ChatParticipant].self, forKey: .participants) ?? []
        group = try container.decodeIfPresent(Group.self, forKey: .group)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        unreadCount = try container.decode(Int.self, forKey: .unreadCount)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        draft = try container.decodeIfPresent(Draft.self, forKey: .draft)
        disappearingPolicy = try container.decodeIfPresent(DisappearingMessagePolicy.self, forKey: .disappearingPolicy)
        notificationPreferences = try container.decode(NotificationPreferences.self, forKey: .notificationPreferences)
        guestRequest = try container.decodeIfPresent(GuestRequest.self, forKey: .guestRequest)
        eventDetails = try container.decodeIfPresent(EventChatDetails.self, forKey: .eventDetails)
        communityDetails = try container.decodeIfPresent(CommunityChatDetails.self, forKey: .communityDetails)
        moderationSettings = try container.decodeIfPresent(GroupModerationSettings.self, forKey: .moderationSettings)
        primePremiumActivity = try container.decodeIfPresent(PrimePremiumChatActivity.self, forKey: .primePremiumActivity)
    }
}

struct PrimePremiumChatActivity: Codable, Hashable {
    var actorUserID: UUID
    var isViewingNow: Bool
    var openedAt: Date?
    var closedAt: Date?
    var viewedDurationSeconds: Int?
    var lastEventAt: Date?
    var lastEventKind: String?
    var lastScreenshotAt: Date?
    var lastScreenRecordingAt: Date?
}

enum CommunityKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case group
    case supergroup
    case channel
    case community

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .group:
            return "community.kind.group".localized
        case .supergroup:
            return "community.kind.supergroup".localized
        case .channel:
            return "community.kind.channel".localized
        case .community:
            return "community.kind.community".localized
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .group:
            return "person.3.fill"
        case .supergroup:
            return "person.3.sequence.fill"
        case .channel:
            return "megaphone.fill"
        case .community:
            return "bubble.left.and.bubble.right.fill"
        }
    }
}

struct CommunityTopic: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var symbolName: String
    var unreadCount: Int
    var isPinned: Bool
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        symbolName: String = "number",
        unreadCount: Int = 0,
        isPinned: Bool = false,
        lastActivityAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.lastActivityAt = lastActivityAt
    }
}

struct CommunityChatDetails: Codable, Hashable {
    var kind: CommunityKind
    var forumModeEnabled: Bool
    var commentsEnabled: Bool
    var isPublic: Bool
    var topics: [CommunityTopic]
    var inviteCode: String?
    var inviteLink: URL?
    var publicHandle: String?
    var isOfficial: Bool
    var isBlockedByAdmin: Bool?

    init(
        kind: CommunityKind,
        forumModeEnabled: Bool = false,
        commentsEnabled: Bool = false,
        isPublic: Bool = false,
        topics: [CommunityTopic] = [],
        inviteCode: String? = nil,
        inviteLink: URL? = nil,
        publicHandle: String? = nil,
        isOfficial: Bool = false,
        isBlockedByAdmin: Bool? = nil
    ) {
        self.kind = kind
        self.forumModeEnabled = forumModeEnabled
        self.commentsEnabled = commentsEnabled
        self.isPublic = isPublic
        self.topics = topics
        self.inviteCode = inviteCode
        self.inviteLink = inviteLink
        self.publicHandle = publicHandle
        self.isOfficial = isOfficial
        self.isBlockedByAdmin = isBlockedByAdmin
    }

    var badgeTitle: String {
        kind.title
    }

    var symbolName: String {
        kind.symbolName
    }
}

enum EventChatKind: String, Codable, CaseIterable, Hashable {
    case eventRoom
    case temporaryRoom
}

struct EventChatDetails: Codable, Hashable {
    var kind: EventChatKind
    var startsAt: Date
    var endsAt: Date?
    var createdByUserID: UUID

    nonisolated var isExpired: Bool {
        guard let endsAt else { return false }
        return endsAt <= .now
    }

    nonisolated var badgeTitle: String {
        switch kind {
        case .eventRoom:
            return "Event"
        case .temporaryRoom:
            return "Temp"
        }
    }

    nonisolated var symbolName: String {
        switch kind {
        case .eventRoom:
            return "calendar"
        case .temporaryRoom:
            return "timer"
        }
    }
}

struct GuestRequest: Codable, Hashable {
    var requesterUserID: UUID
    var recipientUserID: UUID
    var status: GuestRequestStatus
    var introText: String?
    var createdAt: Date
    var respondedAt: Date?
}

enum ChatGuestRequestState: Hashable {
    case pendingOutgoing(canSubmitIntro: Bool)
    case pendingIncoming
    case declinedOutgoing
    case declinedIncoming
}

struct ChatParticipant: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var displayName: String?
    var photoURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName
        case photoURL
    }

    nonisolated init(id: UUID, username: String, displayName: String?, photoURL: URL? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.photoURL = photoURL
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        photoURL = container.decodeLossyURLIfPresent(forKey: .photoURL)
    }
}

struct Group: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var photoURL: URL?
    var ownerID: UUID
    var members: [GroupMember]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case photoURL
        case ownerID
        case members
    }

    init(id: UUID, title: String, photoURL: URL?, ownerID: UUID, members: [GroupMember]) {
        self.id = id
        self.title = title
        self.photoURL = photoURL
        self.ownerID = ownerID
        self.members = members
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        photoURL = container.decodeLossyURLIfPresent(forKey: .photoURL)
        ownerID = try container.decode(UUID.self, forKey: .ownerID)
        members = try container.decode([GroupMember].self, forKey: .members)
    }
}

struct GroupMember: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    var displayName: String?
    var username: String?
    var role: GroupMemberRole
    var joinedAt: Date
}

struct Draft: Identifiable, Codable, Hashable {
    let id: UUID
    var chatID: UUID
    var mode: ChatMode
    var text: String
    var updatedAt: Date
}

struct NotificationPreferences: Codable, Hashable {
    var muteState: ChatMuteState
    var previewEnabled: Bool
    var customSoundName: String?
    var badgeEnabled: Bool
}

extension Chat {
    nonisolated func isAvailable(in visibleMode: ChatMode) -> Bool {
        guard visibleMode == .offline else { return true }
        guard type == .group else { return true }
        return communityDetails?.kind ?? .group == .group
    }

    nonisolated var hasActiveEventDetails: Bool {
        guard let eventDetails else { return false }
        return eventDetails.isExpired == false
    }

    nonisolated var hasCommunityDetails: Bool {
        communityDetails != nil
    }

    nonisolated var hasModerationSettings: Bool {
        moderationSettings?.hasActiveProtection == true
    }

    nonisolated func eventStatusText(now: Date = .now) -> String? {
        guard let eventDetails, eventDetails.isExpired == false else { return nil }
        switch eventDetails.kind {
        case .eventRoom:
            if let endsAt = eventDetails.endsAt {
                return "Event room until \(endsAt.formatted(.dateTime.day().month().hour().minute()))"
            }
            return "Event room"
        case .temporaryRoom:
            guard let endsAt = eventDetails.endsAt else {
                return "Temporary room"
            }
            let remainingSeconds = max(0, Int(endsAt.timeIntervalSince(now)))
            let hours = remainingSeconds / 3600
            if hours >= 24 {
                let days = max(1, hours / 24)
                return "Temporary room · \(days)d left"
            }
            let roundedHours = max(1, hours)
            return "Temporary room · \(roundedHours)h left"
        }
    }

    nonisolated func guestRequestState(for currentUserID: UUID) -> ChatGuestRequestState? {
        guard type == .direct, let guestRequest else { return nil }

        switch guestRequest.status {
        case .approved:
            return nil
        case .pending:
            if guestRequest.requesterUserID == currentUserID {
                let hasIntro = guestRequest.introText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                return .pendingOutgoing(canSubmitIntro: hasIntro == false)
            }
            if guestRequest.recipientUserID == currentUserID {
                return .pendingIncoming
            }
            return nil
        case .declined:
            if guestRequest.requesterUserID == currentUserID {
                return .declinedOutgoing
            }
            if guestRequest.recipientUserID == currentUserID {
                return .declinedIncoming
            }
            return nil
        }
    }

    nonisolated func communityStatusText() -> String? {
        guard let communityDetails else { return nil }

        var fragments: [String] = [communityDetails.kind.title]
        if communityDetails.forumModeEnabled {
            fragments.append("Forum")
        }
        if communityDetails.commentsEnabled {
            fragments.append("Comments")
        }
        if communityDetails.isPublic {
            fragments.append("Public")
        }
        if communityDetails.topics.isEmpty == false {
            fragments.append("\(communityDetails.topics.count) topics")
        }
        return fragments.joined(separator: " · ")
    }

    nonisolated func moderationStatusText() -> String? {
        guard let moderationSettings, moderationSettings.hasActiveProtection else { return nil }

        var fragments: [String] = []
        if moderationSettings.requiresJoinApproval {
            fragments.append("Approval")
        }
        if moderationSettings.slowModeSeconds > 0 {
            fragments.append("Slow mode")
        }
        if moderationSettings.restrictLinks {
            fragments.append("Links restricted")
        }
        if moderationSettings.restrictMedia {
            fragments.append("Media restricted")
        }
        if moderationSettings.antiSpamEnabled {
            fragments.append("Anti-spam")
        }
        return fragments.isEmpty ? "Moderation enabled" : fragments.joined(separator: " · ")
    }

    nonisolated func directParticipant(for currentUserID: UUID) -> ChatParticipant? {
        guard type == .direct else { return nil }
        return participants.first(where: { $0.id != currentUserID })
    }

    nonisolated func displayTitle(for currentUserID: UUID) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == .direct else {
            return trimmedTitle.isEmpty ? title : trimmedTitle
        }

        if let participant = directParticipant(for: currentUserID) {
            let displayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !displayName.isEmpty {
                return displayName
            }

            let username = participant.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                return username
            }
        }

        if !trimmedTitle.isEmpty,
           trimmedTitle.caseInsensitiveCompare("Direct Chat") != .orderedSame,
           trimmedTitle.caseInsensitiveCompare("Chat") != .orderedSame {
            return trimmedTitle
        }

        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubtitle.hasPrefix("@") {
            return String(trimmedSubtitle.dropFirst())
        }

        return "Missing User"
    }

    nonisolated var resolvedDisplayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == .direct else {
            return trimmedTitle.isEmpty ? title : trimmedTitle
        }

        if let firstParticipant = participants.first {
            let displayName = firstParticipant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !displayName.isEmpty {
                return displayName
            }

            let username = firstParticipant.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                return username
            }
        }

        if !trimmedTitle.isEmpty,
           trimmedTitle.caseInsensitiveCompare("Direct Chat") != .orderedSame,
           trimmedTitle.caseInsensitiveCompare("Chat") != .orderedSame {
            return trimmedTitle
        }

        return "Missing User"
    }

    static func mock(mode: ChatMode, currentUserID: UUID) -> [Chat] {
        return [
            Chat(
                id: UUID(),
                mode: mode,
                type: .selfChat,
                title: "Saved Messages",
                subtitle: "Notes, links, and drafts",
                participantIDs: [currentUserID],
                participants: [
                    ChatParticipant(id: currentUserID, username: "primeuser", displayName: "Prime User")
                ],
                group: nil,
                lastMessagePreview: "Product notes for Prime Messaging",
                lastActivityAt: .now,
                unreadCount: 0,
                isPinned: false,
                draft: nil,
                disappearingPolicy: nil,
                notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true),
                guestRequest: nil,
                communityDetails: nil,
                moderationSettings: nil
            )
        ]
    }
}
