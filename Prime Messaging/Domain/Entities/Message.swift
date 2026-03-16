import Foundation

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    var senderDisplayName: String?
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

struct OutgoingMessageDraft: Hashable {
    var text: String
    var attachments: [Attachment]
    var voiceMessage: VoiceMessage?

    init(text: String = "", attachments: [Attachment] = [], voiceMessage: VoiceMessage? = nil) {
        self.text = text
        self.attachments = attachments
        self.voiceMessage = voiceMessage
    }

    var normalizedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasContent: Bool {
        normalizedText != nil || attachments.isEmpty == false || voiceMessage != nil
    }
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
    var isDeleted: Bool {
        deletedForEveryoneAt != nil
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
