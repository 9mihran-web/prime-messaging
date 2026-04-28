import Foundation
import UniformTypeIdentifiers

struct ShareIncomingFilePayload: Codable {
    let id: UUID
    let typeRawValue: String
    let fileName: String
    let mimeType: String
    let relativePath: String
    let byteSize: Int64
}

struct ShareIncomingPayload: Codable {
    let id: UUID
    let createdAt: Date
    let text: String
    let files: [ShareIncomingFilePayload]
    let sourceApplicationBundleID: String?
    let preferredDestinationChatID: UUID?
}

struct ShareChatDestination: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case direct
        case group
        case channel
        case community
        case saved
    }

    enum Mode: String, Codable {
        case online
        case offline
        case smart
    }

    let id: UUID
    let title: String
    let subtitle: String
    let previewText: String
    let kind: Kind
    let mode: Mode
    let isPinned: Bool
    let unreadCount: Int
    let lastActivityAt: Date
}

struct ShareChatDestinationExport: Codable, Hashable {
    let ownerUserID: UUID?
    let chats: [ShareChatDestination]
}

enum ShareAttachmentKind: String {
    case photo
    case video
    case document
    case audio
}

enum SharePayloadBridge {
    static let appGroupIdentifier = "group.prime1.prime-Messaging.shared"
    private static let destinationsFileName = "share-chat-destinations.json"
    private static let acknowledgmentFileName = "incoming-share-ack.txt"
    private static let mirroredCurrentUserFileName = "current-user.json"

    static func rootURL() -> URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let directory = containerURL.appendingPathComponent("IncomingShare", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func metadataURL() -> URL? {
        rootURL()?.appendingPathComponent("incoming-share-payload.json", isDirectory: false)
    }

    static func destinationsURL() -> URL? {
        rootURL()?.appendingPathComponent(destinationsFileName, isDirectory: false)
    }

    static func acknowledgmentURL() -> URL? {
        rootURL()?.appendingPathComponent(acknowledgmentFileName, isDirectory: false)
    }

    static func mirroredCurrentUserURL() -> URL? {
        rootURL()?.appendingPathComponent(mirroredCurrentUserFileName, isDirectory: false)
    }

    static func payloadDirectoryURL(for payloadID: UUID) -> URL? {
        guard let rootURL = rootURL() else { return nil }
        let directory = rootURL.appendingPathComponent(payloadID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func inferAttachmentKind(for type: UTType?, mimeType: String) -> ShareAttachmentKind {
        if let type {
            if type.conforms(to: .image) {
                return .photo
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
            if type.conforms(to: .audio) {
                return .audio
            }
        }

        if mimeType.hasPrefix("image/") {
            return .photo
        }
        if mimeType.hasPrefix("video/") {
            return .video
        }
        if mimeType.hasPrefix("audio/") {
            return .audio
        }
        return .document
    }

    static func clearAcknowledgment() {
        guard let acknowledgmentURL = acknowledgmentURL() else { return }
        try? FileManager.default.removeItem(at: acknowledgmentURL)
    }

    static func writeAcknowledgment(payloadID: UUID) {
        guard let acknowledgmentURL = acknowledgmentURL() else { return }
        try? payloadID.uuidString.data(using: .utf8)?.write(to: acknowledgmentURL, options: .atomic)
    }

    static func hasAcknowledgment(for payloadID: UUID) -> Bool {
        guard
            let acknowledgmentURL = acknowledgmentURL(),
            let data = try? Data(contentsOf: acknowledgmentURL),
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return value.caseInsensitiveCompare(payloadID.uuidString) == .orderedSame
    }
}
