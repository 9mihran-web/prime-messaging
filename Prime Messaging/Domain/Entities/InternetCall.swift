import Foundation

enum InternetCallKind: String, Codable, Hashable {
    case audio
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

    init(id: UUID, username: String, displayName: String?, profilePhotoURL: URL?) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.profilePhotoURL = profilePhotoURL
    }

    init(from decoder: any Decoder) throws {
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
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int?
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
    var createdAt: Date
    var answeredAt: Date?
    var endedAt: Date?
    var lastEventSequence: Int

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case kind
        case state
        case chatID
        case callerID
        case calleeID
        case participants
        case createdAt
        case answeredAt
        case endedAt
        case lastEventSequence
    }
}

extension InternetCall {
    func direction(for currentUserID: UUID) -> InternetCallDirection {
        callerID == currentUserID ? .outgoing : .incoming
    }

    func otherParticipant(for currentUserID: UUID) -> InternetCallParticipant? {
        participants.first(where: { $0.id != currentUserID })
    }

    func displayName(for currentUserID: UUID) -> String {
        guard let participant = otherParticipant(for: currentUserID) else {
            return "Unknown"
        }

        let trimmedDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedDisplayName.isEmpty == false {
            return trimmedDisplayName
        }

        return participant.username
    }
}
