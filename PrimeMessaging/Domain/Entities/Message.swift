import Foundation

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    var mode: ChatMode
    var kind: MessageKind
    var text: String?
    var attachments: [Attachment]
    var replyToMessageID: UUID?
    var status: MessageStatus
    var createdAt: Date
    var editedAt: Date?
    var deletedForEveryoneAt: Date?
    var reactions: [MessageReaction]
    var voiceMessage: VoiceMessage?
    var liveLocation: LiveLocationSession?
}

struct Attachment: Identifiable, Codable, Hashable {
    let id: UUID
    var type: AttachmentType
    var fileName: String
    var mimeType: String
    var localURL: URL?
    var remoteURL: URL?
    var byteSize: Int64
}

struct MessageReaction: Identifiable, Codable, Hashable {
    let id: UUID
    var emoji: String
    var userIDs: [UUID]
}

struct VoiceMessage: Codable, Hashable {
    var durationSeconds: Int
    var waveformSamples: [Float]
    var localFileURL: URL?
    var remoteFileURL: URL?
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
    static func mock(chatID: UUID, mode: ChatMode, currentUserID: UUID) -> [Message] {
        let otherUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        return [
            Message(
                id: UUID(),
                chatID: chatID,
                senderID: otherUserID,
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
