import Foundation

enum InternetCallKind: String, Codable, Hashable {
    case audio
    case video
}

enum InternetCallState: String, Codable, Hashable {
    case ringing
    case active
    case ended
    case rejected
    case cancelled
    case missed
}

enum InternetCallDirection: String, Codable, Hashable {
    case incoming
    case outgoing
}

enum InternetCallEventType: String, Codable, Hashable {
    case created
    case accepted
    case rejected
    case ended
    case offer
    case answer
    case ice
    case mediaState = "media_state"
}

struct InternetCallParticipant: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var displayName: String?
    var profilePhotoURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName
        case profilePhotoURL
    }

    nonisolated init(id: UUID, username: String, displayName: String?, profilePhotoURL: URL?) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.profilePhotoURL = profilePhotoURL
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        profilePhotoURL = container.decodeLossyURLIfPresent(forKey: .profilePhotoURL)
    }
}

struct InternetCallEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let callID: UUID
    let sequence: Int
    let type: InternetCallEventType
    let senderID: UUID?
    let targetUserID: UUID?
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int?
    let isMuted: Bool?
    let isVideoEnabled: Bool?
    let createdAt: Date
}

struct InternetCall: Identifiable, Codable, Hashable {
    let id: UUID
    var mode: ChatMode
    var kind: InternetCallKind
    var state: InternetCallState
    var chatID: UUID?
    var callerID: UUID
    var calleeID: UUID
    var participants: [InternetCallParticipant]
    var joinedParticipantIDs: [UUID]?
    var createdAt: Date
    var answeredAt: Date?
    var endedAt: Date?
    var lastEventSequence: Int
    var latestRemoteOfferSDP: String?
    var latestRemoteOfferSequence: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case kind
        case state
        case chatID
        case callerID
        case calleeID
        case participants
        case joinedParticipantIDs
        case createdAt
        case answeredAt
        case endedAt
        case lastEventSequence
        case latestRemoteOfferSDP
        case latestRemoteOfferSequence
    }
}

extension InternetCall {
    nonisolated var isGroupCall: Bool {
        joinedParticipantIDs != nil || participants.count > 2
    }

    nonisolated var joinedParticipantIDSet: Set<UUID> {
        Set(joinedParticipantIDs ?? [])
    }

    nonisolated func direction(for currentUserID: UUID) -> InternetCallDirection {
        callerID == currentUserID ? .outgoing : .incoming
    }

    nonisolated func effectiveState(for currentUserID: UUID) -> InternetCallState {
        if state == .cancelled, direction(for: currentUserID) == .incoming, answeredAt == nil {
            return .missed
        }

        return state
    }

    nonisolated func otherParticipant(for currentUserID: UUID) -> InternetCallParticipant? {
        participants.first(where: { $0.id != currentUserID })
    }

    nonisolated func otherParticipants(for currentUserID: UUID) -> [InternetCallParticipant] {
        participants.filter { $0.id != currentUserID }
    }

    nonisolated func joinedParticipants(excluding currentUserID: UUID? = nil) -> [InternetCallParticipant] {
        let joinedIDs = joinedParticipantIDSet
        let baseParticipants: [InternetCallParticipant]
        if joinedIDs.isEmpty {
            baseParticipants = participants
        } else {
            baseParticipants = participants.filter { joinedIDs.contains($0.id) }
        }

        guard let currentUserID else {
            return baseParticipants
        }

        return baseParticipants.filter { $0.id != currentUserID }
    }

    nonisolated private func participantLabel(_ participant: InternetCallParticipant) -> String {
        let trimmedDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedDisplayName.isEmpty == false {
            return trimmedDisplayName
        }
        return participant.username
    }

    nonisolated func displayName(for currentUserID: UUID) -> String {
        if isGroupCall {
            let activeRemoteParticipants = joinedParticipants(excluding: currentUserID)
            let fallbackRemoteParticipants = otherParticipants(for: currentUserID)
            let remoteParticipants = activeRemoteParticipants.isEmpty ? fallbackRemoteParticipants : activeRemoteParticipants
            let labels = remoteParticipants.map(participantLabel)

            switch labels.count {
            case 0:
                return "Group call"
            case 1:
                return labels[0]
            case 2:
                return "\(labels[0]), \(labels[1])"
            default:
                return "\(labels[0]), \(labels[1]) +\(labels.count - 2)"
            }
        }

        guard let participant = otherParticipant(for: currentUserID) else {
            return "Unknown"
        }

        return participantLabel(participant)
    }

    nonisolated var activityDate: Date {
        endedAt ?? answeredAt ?? createdAt
    }
}
