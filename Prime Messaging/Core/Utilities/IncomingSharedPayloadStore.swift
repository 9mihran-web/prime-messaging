import Foundation

struct IncomingSharedFilePayload: Codable, Hashable, Identifiable {
    let id: UUID
    let typeRawValue: String
    let fileName: String
    let mimeType: String
    let relativePath: String
    let byteSize: Int64

    var attachmentType: AttachmentType {
        AttachmentType(rawValue: typeRawValue) ?? .document
    }
}

struct IncomingSharedPayload: Codable, Hashable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    let files: [IncomingSharedFilePayload]
    let sourceApplicationBundleID: String?
    let preferredDestinationChatID: UUID?
}

actor IncomingSharedPayloadStore {
    static let shared = IncomingSharedPayloadStore()

    static let appGroupIdentifier = "group.prime1.prime-Messaging.shared"

    private let decoder = JSONDecoder()
    private let metadataFileName = "incoming-share-payload.json"
    private let acknowledgmentFileName = "incoming-share-ack.txt"
    private let rootDirectoryName = "IncomingShare"

    private var rootURL: URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            return nil
        }
        let directory = containerURL.appendingPathComponent(rootDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var metadataURL: URL? {
        rootURL?.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    private var acknowledgmentURL: URL? {
        rootURL?.appendingPathComponent(acknowledgmentFileName, isDirectory: false)
    }

    func loadPendingPayload() -> IncomingSharedPayload? {
        guard let metadataURL, let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? decoder.decode(IncomingSharedPayload.self, from: data)
    }

    func clearPendingPayloadMetadata() {
        guard let metadataURL else { return }
        try? FileManager.default.removeItem(at: metadataURL)
    }

    func acknowledgePayload(_ payloadID: UUID) {
        guard let acknowledgmentURL else { return }
        try? payloadID.uuidString.data(using: .utf8)?.write(to: acknowledgmentURL, options: .atomic)
    }

    func makeDraft(from payload: IncomingSharedPayload) -> OutgoingMessageDraft {
        let attachments = payload.files.map { filePayload in
            Attachment(
                id: filePayload.id,
                type: filePayload.attachmentType,
                fileName: filePayload.fileName,
                mimeType: filePayload.mimeType,
                localURL: availableFileURL(for: filePayload),
                remoteURL: nil,
                byteSize: filePayload.byteSize
            )
        }

        return OutgoingMessageDraft(
            text: payload.text,
            attachments: attachments,
            voiceMessage: nil
        )
    }

    func availableFileURL(for filePayload: IncomingSharedFilePayload) -> URL? {
        rootURL?.appendingPathComponent(filePayload.relativePath, isDirectory: false)
    }
}
