import Foundation

struct GroupModerationSettings: Codable, Hashable {
    var requiresJoinApproval: Bool
    var welcomeMessage: String
    var rules: String
    var entryQuestions: [String]
    var slowModeSeconds: Int
    var restrictMedia: Bool
    var restrictLinks: Bool
    var antiSpamEnabled: Bool

    init(
        requiresJoinApproval: Bool = false,
        welcomeMessage: String = "",
        rules: String = "",
        entryQuestions: [String] = [],
        slowModeSeconds: Int = 0,
        restrictMedia: Bool = false,
        restrictLinks: Bool = false,
        antiSpamEnabled: Bool = false
    ) {
        self.requiresJoinApproval = requiresJoinApproval
        self.welcomeMessage = welcomeMessage
        self.rules = rules
        self.entryQuestions = entryQuestions
        self.slowModeSeconds = slowModeSeconds
        self.restrictMedia = restrictMedia
        self.restrictLinks = restrictLinks
        self.antiSpamEnabled = antiSpamEnabled
    }

    nonisolated var normalizedWelcomeMessage: String? {
        let trimmed = welcomeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated var normalizedRules: String? {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated var normalizedEntryQuestions: [String] {
        entryQuestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    nonisolated var hasActiveProtection: Bool {
        requiresJoinApproval
            || normalizedWelcomeMessage != nil
            || normalizedRules != nil
            || normalizedEntryQuestions.isEmpty == false
            || slowModeSeconds > 0
            || restrictMedia
            || restrictLinks
            || antiSpamEnabled
    }
}

enum GroupJoinRequestStatus: String, Codable, Hashable {
    case pending
    case approved
    case declined
}

struct GroupJoinRequest: Identifiable, Codable, Hashable {
    let id: UUID
    let requesterUserID: UUID
    var requesterDisplayName: String?
    var requesterUsername: String?
    var answers: [String]
    var status: GroupJoinRequestStatus
    let createdAt: Date
    var resolvedAt: Date?
    var reviewedByUserID: UUID?
}

enum ModerationReportReason: String, Codable, CaseIterable, Hashable, Identifiable {
    case spam
    case abuse
    case harassment
    case impersonation
    case misinformation
    case illegal
    case offTopic = "off_topic"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:
            return "Spam"
        case .abuse:
            return "Abuse"
        case .harassment:
            return "Harassment"
        case .impersonation:
            return "Impersonation"
        case .misinformation:
            return "Misinformation"
        case .illegal:
            return "Illegal content"
        case .offTopic:
            return "Off-topic"
        case .other:
            return "Other"
        }
    }
}

struct BlockRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let blockerUserID: UUID
    let blockedUserID: UUID
    let createdAt: Date
}

struct ReportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let reporterUserID: UUID
    var reporterDisplayName: String?
    var reporterUsername: String?
    let targetChatID: UUID?
    let targetMessageID: UUID?
    let targetUserID: UUID?
    let reason: String
    var details: String?
    var targetPreview: String?
    let createdAt: Date
}

struct GroupBanRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    var displayName: String?
    var username: String?
    var reason: String?
    let createdAt: Date
    var bannedUntil: Date?
    let bannedByUserID: UUID

    var isActive: Bool {
        guard let bannedUntil else { return true }
        return bannedUntil > .now
    }
}

struct ModerationDashboard: Codable, Hashable {
    var joinRequests: [GroupJoinRequest]
    var reports: [ReportRecord]
    var bans: [GroupBanRecord]

    init(
        joinRequests: [GroupJoinRequest] = [],
        reports: [ReportRecord] = [],
        bans: [GroupBanRecord] = []
    ) {
        self.joinRequests = joinRequests
        self.reports = reports
        self.bans = bans
    }

    var pendingJoinRequests: [GroupJoinRequest] {
        joinRequests
            .filter { $0.status == .pending }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    var activeBans: [GroupBanRecord] {
        bans
            .filter(\.isActive)
            .sorted(by: { ($0.bannedUntil ?? .distantFuture) > ($1.bannedUntil ?? .distantFuture) })
    }
}
