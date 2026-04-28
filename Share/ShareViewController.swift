//
//  ShareViewController.swift
//  Share
//
//  Created by Mihran Gevorgyan on 27.04.2026.
//

import Foundation
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import zlib

final class ShareViewController: UIViewController {
    private enum ShareError: LocalizedError {
        case sharedContainerUnavailable
        case noSupportedContent
        case noDestinationSelected

        var errorDescription: String? {
            switch self {
            case .sharedContainerUnavailable:
                return "Prime Messaging shared storage is unavailable."
            case .noSupportedContent:
                return "This item type is not supported yet."
            case .noDestinationSelected:
                return "Choose a chat before sending."
            }
        }
    }

    private var hostingController: UIHostingController<ShareDestinationPickerView>?
    private var currentPayload: ShareIncomingPayload?
    private var currentChats: [ShareChatDestination] = []
    private var currentSenderUserID: UUID?
    private var selectedChatID: UUID?
    private var currentErrorMessage: String?
    private var currentSubmissionProgress: ShareDestinationPickerView.SubmissionProgress?
    private var isLoading = true
    private var isSubmitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHost()
        Task { await prepareShareContent() }
    }

    private func configureHost() {
        let hostingController = UIHostingController(rootView: makeRootView())
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }

    @MainActor
    private func prepareShareContent() async {
        defer {
            isLoading = false
            refreshView()
        }

        do {
            let payload = try await buildPayload()
            let export = loadRecentChatExport()
            currentPayload = payload
            currentChats = export.chats
            currentSenderUserID = export.ownerUserID
        } catch {
            currentErrorMessage = error.localizedDescription.isEmpty ? "Prime Messaging could not prepare this share." : error.localizedDescription
        }
    }

    @MainActor
    private func sendSelectedShare() async {
        guard isSubmitting == false else { return }
        guard let payload = currentPayload else { return }
        guard let selectedChatID else {
            currentErrorMessage = ShareError.noDestinationSelected.localizedDescription
            refreshView()
            return
        }
        guard let selectedChat = currentChats.first(where: { $0.id == selectedChatID }) else {
            currentErrorMessage = ShareError.noDestinationSelected.localizedDescription
            refreshView()
            return
        }

        isSubmitting = true
        currentErrorMessage = nil
        currentSubmissionProgress = ShareDestinationPickerView.SubmissionProgress(
            title: isLikelyWhatsAppImport ? "Preparing import…" : "Preparing share…",
            detail: nil,
            fractionCompleted: nil
        )
        refreshView()

        do {
            let senderID = try resolvedSenderUserID()

            if isLikelyWhatsAppImport == false {
                updateSubmissionProgress(
                    title: "Sending message…",
                    detail: selectedChat.title,
                    fractionCompleted: nil
                )
                try await sendDirectMessage(payload: payload, to: selectedChat, senderID: senderID)
                try? await Task.sleep(for: .milliseconds(250))
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                return
            }

            updateSubmissionProgress(
                title: "Preparing chat migration…",
                detail: "Prime Messaging is preparing a quiet server-side import.",
                fractionCompleted: 0.05
            )

            try await ShareDirectMessageSender.importWhatsAppHistory(
                payload: payload,
                to: selectedChat,
                senderID: senderID,
                progress: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.currentSubmissionProgress = progress
                        self?.refreshView()
                    }
                }
            )

            updateSubmissionProgress(
                title: "Import complete",
                detail: "Chat history migrated successfully.",
                fractionCompleted: 1
            )
            try? await Task.sleep(for: .milliseconds(450))
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            currentErrorMessage = error.localizedDescription.isEmpty ? "Prime Messaging could not prepare this share." : error.localizedDescription
            isSubmitting = false
            currentSubmissionProgress = nil
            refreshView()
        }
    }

    private func refreshView() {
        hostingController?.rootView = makeRootView()
    }

    private func makeRootView() -> ShareDestinationPickerView {
        let preview = ShareDestinationPickerView.PreviewItem(
            text: currentPayload?.text ?? "",
            attachmentCount: currentPayload?.files.count ?? 0
        )

        return ShareDestinationPickerView(
            mode: isLikelyWhatsAppImport ? .importHistory : .share,
            preview: preview,
            chats: currentChats,
            selectedChatID: selectedChatID,
            isLoading: isLoading,
            isSubmitting: isSubmitting,
            submissionProgress: currentSubmissionProgress,
            errorMessage: currentErrorMessage,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            },
            onSelectChat: { [weak self] chatID in
                self?.selectedChatID = chatID
                self?.refreshView()
            },
            onSend: { [weak self] in
                Task { @MainActor in
                    await self?.sendSelectedShare()
                }
            }
        )
    }

    private var isLikelyWhatsAppImport: Bool {
        guard let currentPayload else { return false }
        let normalizedText = currentPayload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingLineCount = normalizedText
            .split(whereSeparator: \.isNewline)
            .prefix(12)
            .reduce(into: 0) { partialResult, line in
                if parseWhatsAppHeaderLine(String(line)) {
                    partialResult += 1
                }
            }

        if matchingLineCount >= 2 {
            return true
        }

        return currentPayload.files.contains { file in
            let lowercasedName = file.fileName.lowercased()
            return lowercasedName == "_chat.txt"
                || lowercasedName.hasSuffix(".zip")
                || lowercasedName.contains("whatsapp")
        }
    }

    private func buildPayload() async throws -> ShareIncomingPayload {
        let payloadID = UUID()
        let payloadDirectoryURL = try payloadDirectoryURL(for: payloadID)
        let sourceApplicationBundleID: String? = nil
        var textBlocks: [String] = []
        let typedText = ""
        if typedText.isEmpty == false {
            textBlocks.append(typedText)
        }

        var files: [ShareIncomingFilePayload] = []
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []

        for item in inputItems {
            if let itemAttributedContent = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               itemAttributedContent.isEmpty == false,
               textBlocks.contains(itemAttributedContent) == false {
                textBlocks.append(itemAttributedContent)
            }

            for provider in item.attachments ?? [] {
                if let filePayload = try await loadFilePayload(from: provider, payloadDirectoryURL: payloadDirectoryURL) {
                    files.append(filePayload)
                    continue
                }

                if let loadedText = try await loadText(from: provider) {
                    if textBlocks.contains(loadedText) == false {
                        textBlocks.append(loadedText)
                    }
                    continue
                }
            }
        }

        let mergedText = textBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n\n")

        guard mergedText.isEmpty == false || files.isEmpty == false else {
            throw ShareError.noSupportedContent
        }

        return ShareIncomingPayload(
            id: payloadID,
            createdAt: Date(),
            text: mergedText,
            files: files,
            sourceApplicationBundleID: sourceApplicationBundleID,
            preferredDestinationChatID: nil
        )
    }

    private func loadRecentChatExport() -> ShareChatDestinationExport {
        guard
            let destinationsURL = SharePayloadBridge.destinationsURL(),
            let data = try? Data(contentsOf: destinationsURL)
        else {
            return ShareChatDestinationExport(ownerUserID: nil, chats: [])
        }

        let decoder = JSONDecoder()
        if let export = try? decoder.decode(ShareChatDestinationExport.self, from: data) {
            return export
        }
        if let chats = try? decoder.decode([ShareChatDestination].self, from: data) {
            return ShareChatDestinationExport(ownerUserID: nil, chats: chats)
        }
        return ShareChatDestinationExport(ownerUserID: nil, chats: [])
    }

    private func payloadDirectoryURL(for payloadID: UUID) throws -> URL {
        guard let directoryURL = SharePayloadBridge.payloadDirectoryURL(for: payloadID) else {
            throw ShareError.sharedContainerUnavailable
        }
        return directoryURL
    }

    private func resolvedSenderUserID() throws -> UUID {
        if let currentSenderUserID {
            return currentSenderUserID
        }
        if let userID = ShareDirectMessageSender.mostRecentSessionUserID() {
            return userID
        }
        throw ShareDirectMessageSender.DirectSendError.missingSession
    }

    private func sendDirectMessage(
        payload: ShareIncomingPayload,
        to chat: ShareChatDestination,
        senderID: UUID
    ) async throws {
        try await ShareDirectMessageSender.send(
            payload: payload,
            to: chat,
            senderID: senderID
        )
    }

    @MainActor
    private func updateSubmissionProgress(
        title: String,
        detail: String?,
        fractionCompleted: Double?
    ) {
        currentSubmissionProgress = ShareDestinationPickerView.SubmissionProgress(
            title: title,
            detail: detail,
            fractionCompleted: fractionCompleted
        )
        refreshView()
    }

    private func loadText(from provider: NSItemProvider) async throws -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await loadURL(from: provider) {
                if url.isFileURL {
                    return nil
                }
                return url.absoluteString
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let string = item as? String {
                        continuation.resume(returning: self.normalizedSharedTextCandidate(string))
                        return
                    }
                    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: self.normalizedSharedTextCandidate(string))
                        return
                    }
                    continuation.resume(returning: nil)
                }
            }
        }

        return nil
    }

    private func normalizedSharedTextCandidate(_ rawValue: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false else { return nil }

        if let url = URL(string: trimmedValue), url.isFileURL {
            return nil
        }

        if trimmedValue.hasPrefix("file:///private/") || trimmedValue.hasPrefix("file:///var/") {
            return nil
        }

        return trimmedValue
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let data = item as? Data,
                   let absoluteString = String(data: data, encoding: .utf8),
                   let url = URL(string: absoluteString) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func loadFilePayload(from provider: NSItemProvider, payloadDirectoryURL: URL) async throws -> ShareIncomingFilePayload? {
        let preferredTypes: [UTType] = [.image, .movie, .audio, .item]

        for preferredType in preferredTypes where provider.hasItemConformingToTypeIdentifier(preferredType.identifier) {
            if let filePayload = try await copyFilePayload(from: provider, matching: preferredType, payloadDirectoryURL: payloadDirectoryURL) {
                return filePayload
            }
        }

        return nil
    }

    private func copyFilePayload(from provider: NSItemProvider, matching preferredType: UTType, payloadDirectoryURL: URL) async throws -> ShareIncomingFilePayload? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShareIncomingFilePayload?, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: preferredType.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sourceURL = url else {
                    continuation.resume(returning: nil)
                    return
                }

                let needsScopedAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if needsScopedAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let resolvedType = UTType(filenameExtension: sourceURL.pathExtension) ?? preferredType
                    let mimeType = resolvedType.preferredMIMEType ?? "application/octet-stream"
                    let fileNameBase = sourceURL.lastPathComponent.isEmpty ? UUID().uuidString : sourceURL.lastPathComponent
                    let targetFileName = UUID().uuidString + "-" + fileNameBase
                    let relativePath = payloadDirectoryURL.lastPathComponent + "/" + targetFileName
                    let targetURL = payloadDirectoryURL.appendingPathComponent(targetFileName, isDirectory: false)

                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: targetURL.path) {
                        try? fileManager.removeItem(at: targetURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: targetURL)

                    let resourceValues = try? targetURL.resourceValues(forKeys: [URLResourceKey.fileSizeKey])
                    let byteSize = Int64(resourceValues?.fileSize ?? 0)
                    let kind = SharePayloadBridge.inferAttachmentKind(for: resolvedType, mimeType: mimeType)

                    continuation.resume(returning: ShareIncomingFilePayload(
                        id: UUID(),
                        typeRawValue: kind.rawValue,
                        fileName: fileNameBase,
                        mimeType: mimeType,
                        relativePath: relativePath,
                        byteSize: byteSize
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func parseWhatsAppHeaderLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.isEmpty == false else { return false }

        if trimmedLine.hasPrefix("["),
           let closingBracketIndex = trimmedLine.firstIndex(of: "]") {
            let dateCandidate = String(trimmedLine[trimmedLine.index(after: trimmedLine.startIndex)..<closingBracketIndex])
            return parseWhatsAppDate(dateCandidate) != nil
        }

        if let separatorRange = trimmedLine.range(of: " - ") {
            let dateCandidate = String(trimmedLine[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return parseWhatsAppDate(dateCandidate) != nil
        }

        return false
    }

    private func parseWhatsAppDate(_ rawValue: String) -> Date? {
        let normalized = rawValue
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for formatter in Self.whatsAppDateFormatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static let whatsAppDateFormatters: [DateFormatter] = {
        let formatStrings = [
            "M/d/yy, h:mm:ss a",
            "M/d/yy, h:mm a",
            "M/d/yyyy, h:mm:ss a",
            "M/d/yyyy, h:mm a",
            "d/M/yy, HH:mm:ss",
            "d/M/yy, HH:mm",
            "d/M/yyyy, HH:mm:ss",
            "d/M/yyyy, HH:mm",
            "d.M.yy, HH:mm:ss",
            "d.M.yy, HH:mm",
            "dd.MM.yy, HH:mm:ss",
            "dd.MM.yy, HH:mm",
            "dd.MM.yyyy, HH:mm:ss",
            "dd.MM.yyyy, HH:mm",
        ]

        return formatStrings.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()
}

private enum ShareDirectMessageSender {
    private struct ShareAuthSession: Codable {
        let userID: UUID
        var accessToken: String
        var refreshToken: String
        var accessTokenExpiresAt: Date
        var refreshTokenExpiresAt: Date
        var updatedAt: Date
    }

    private struct ShareAuthSessionPayload: Codable {
        let accessToken: String
        let refreshToken: String
        let accessTokenExpiresAt: Date
        let refreshTokenExpiresAt: Date

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accessTokenExpiresAt = "access_token_expires_at"
            case refreshTokenExpiresAt = "refresh_token_expires_at"
        }
    }

    private struct ShareAuthenticatedSessionResponse: Decodable {
        let userID: UUID
        let session: ShareAuthSessionPayload?

        enum RootCodingKeys: String, CodingKey {
            case user
            case session
        }

        enum UserCodingKeys: String, CodingKey {
            case id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RootCodingKeys.self)
            let user = try container.nestedContainer(keyedBy: UserCodingKeys.self, forKey: .user)
            userID = try user.decode(UUID.self, forKey: .id)
            session = try container.decodeIfPresent(ShareAuthSessionPayload.self, forKey: .session)
        }
    }

    private struct RefreshSessionRequest: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct SendAttachmentRequest: Encodable {
        let type: String
        let fileName: String
        let mimeType: String
        let byteSize: Int64
        let dataBase64: String?

        enum CodingKeys: String, CodingKey {
            case type
            case fileName = "file_name"
            case mimeType = "mime_type"
            case byteSize = "byte_size"
            case dataBase64 = "data_base64"
        }
    }

    private struct SendMessageRequest: Encodable {
        let chatID: String
        let senderID: String
        let senderDisplayName: String?
        let clientMessageID: String?
        let text: String?
        let createdAt: String?
        let deliveryState: String
        let mode: String
        let kind: String
        let attachments: [SendAttachmentRequest]

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case senderID = "sender_id"
            case senderDisplayName = "sender_display_name"
            case clientMessageID = "client_message_id"
            case text
            case createdAt = "created_at"
            case deliveryState = "delivery_state"
            case mode
            case kind
            case attachments
        }
    }

    private struct ImportHistoryRequest: Encodable {
        let chatID: String
        let importerID: String
        let mode: String
        let messages: [ImportedHistoryMessageRequest]

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case importerID = "importer_id"
            case mode
            case messages
        }
    }

    private struct ImportedHistoryMessageRequest: Encodable {
        let clientMessageID: String
        let senderOrigin: String
        let senderDisplayName: String?
        let text: String?
        let createdAt: String
        let kind: String
        let attachments: [SendAttachmentRequest]

        enum CodingKeys: String, CodingKey {
            case clientMessageID = "client_message_id"
            case senderOrigin = "sender_origin"
            case senderDisplayName = "sender_display_name"
            case text
            case createdAt = "created_at"
            case kind
            case attachments
        }
    }

    struct MirroredCurrentUser: Decodable {
        struct Profile: Decodable {
            let displayName: String
            let username: String
            let phoneNumber: String?
        }

        struct IdentityMethod: Decodable {
            let value: String
        }

        let id: UUID
        let profile: Profile
        let identityMethods: [IdentityMethod]
    }

    enum DirectSendError: LocalizedError {
        case missingServerURL
        case missingSession
        case unreadableAttachment
        case backendFailed
        case historyImportNotSupported

        var errorDescription: String? {
            switch self {
            case .missingServerURL:
                return "Prime Messaging server URL is missing."
            case .missingSession:
                return "Prime Messaging login session is unavailable."
            case .unreadableAttachment:
                return "One of the shared files could not be prepared."
            case .backendFailed:
                return "Prime Messaging could not send this share right now."
            case .historyImportNotSupported:
                return "This import is supported only for online direct chats right now."
            }
        }
    }

    private static let sessionService = "miro.Prime-Messaging"
    private static let sessionAccount = "auth.sessions"
    private static let mirroredSessionsFileName = "auth-sessions.json"

    static func mostRecentSessionUserID() -> UUID? {
        mostRecentSession()?.userID
    }

    private static func mostRecentSession() -> ShareAuthSession? {
        guard let sessions = loadSessions() else { return nil }
        return sessions
            .values
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    static func send(
        payload: ShareIncomingPayload,
        to chat: ShareChatDestination,
        senderID: UUID
    ) async throws {
        guard let baseURL = currentBaseURL() else {
            throw DirectSendError.missingServerURL
        }
        guard var session = session(for: senderID) ?? mostRecentSession(), session.userID == senderID else {
            throw DirectSendError.missingSession
        }

        let requestPayload = try makeRequestPayload(
            from: payload,
            chat: chat,
            senderID: senderID
        )

        do {
            try await performSend(
                requestPayload,
                session: session,
                baseURL: baseURL
            )
        } catch {
            session = try await refreshSession(session, baseURL: baseURL)
            try await performSend(
                requestPayload,
                session: session,
                baseURL: baseURL
            )
        }
    }

    static func importWhatsAppHistory(
        payload: ShareIncomingPayload,
        to chat: ShareChatDestination,
        senderID: UUID,
        progress: @escaping @Sendable (ShareDestinationPickerView.SubmissionProgress) -> Void
    ) async throws {
        guard let baseURL = currentBaseURL() else {
            throw DirectSendError.missingServerURL
        }
        guard var session = session(for: senderID) ?? mostRecentSession(), session.userID == senderID else {
            throw DirectSendError.missingSession
        }
        guard chat.mode != .offline, chat.kind == .direct else {
            throw DirectSendError.historyImportNotSupported
        }

        progress(
            ShareDestinationPickerView.SubmissionProgress(
                title: "Reading export…",
                detail: "Preparing WhatsApp history for import",
                fractionCompleted: 0.15
            )
        )
        let importedMessages = try ShareWhatsAppImportParser.parse(
            payload: payload,
            currentUser: mirroredCurrentUser()
        ) { filePayload in
            guard let rootURL = SharePayloadBridge.rootURL() else { return nil }
            return rootURL.appendingPathComponent(filePayload.relativePath, isDirectory: false)
        }

        progress(
            ShareDestinationPickerView.SubmissionProgress(
                title: "Importing messages…",
                detail: importedMessages.count == 1 ? "1 message ready" : "\(importedMessages.count) messages ready",
                fractionCompleted: 0.45
            )
        )

        let requestPayload = try makeImportHistoryRequest(
            importedMessages,
            chat: chat,
            senderID: senderID
        )

        do {
            try await performImport(
                requestPayload,
                session: session,
                baseURL: baseURL,
                progress: progress
            )
        } catch {
            session = try await refreshSession(session, baseURL: baseURL)
            try await performImport(
                requestPayload,
                session: session,
                baseURL: baseURL,
                progress: progress
            )
        }
    }

    private static func makeRequestPayload(
        from payload: ShareIncomingPayload,
        chat: ShareChatDestination,
        senderID: UUID
    ) throws -> SendMessageRequest {
        let attachments = try payload.files.map { filePayload -> SendAttachmentRequest in
            guard
                let rootURL = SharePayloadBridge.rootURL(),
                let data = try? Data(contentsOf: rootURL.appendingPathComponent(filePayload.relativePath, isDirectory: false))
            else {
                throw DirectSendError.unreadableAttachment
            }

            return SendAttachmentRequest(
                type: normalizedAttachmentType(filePayload.typeRawValue),
                fileName: filePayload.fileName,
                mimeType: filePayload.mimeType,
                byteSize: filePayload.byteSize,
                dataBase64: data.base64EncodedString()
            )
        }

        let trimmedText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = resolvedKind(text: trimmedText, attachments: attachments)
        let mode = chat.mode.rawValue
        let deliveryState = mode == "offline" ? "offline" : "online"

        return SendMessageRequest(
            chatID: chat.id.uuidString,
            senderID: senderID.uuidString,
            senderDisplayName: nil,
            clientMessageID: payload.id.uuidString,
            text: trimmedText.isEmpty ? nil : trimmedText,
            createdAt: payload.createdAt.ISO8601Format(),
            deliveryState: deliveryState,
            mode: mode,
            kind: kind,
            attachments: attachments
        )
    }

    private static func makeImportHistoryRequest(
        _ importedMessages: [ShareWhatsAppImportParser.ImportedMessage],
        chat: ShareChatDestination,
        senderID: UUID
    ) throws -> ImportHistoryRequest {
        let messages = try importedMessages.map { importedMessage in
            let attachments = try importedMessage.attachments.map { attachment in
                guard let data = try? Data(contentsOf: attachment.fileURL) else {
                    throw DirectSendError.unreadableAttachment
                }

                return SendAttachmentRequest(
                    type: attachment.kind.rawValue,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType,
                    byteSize: Int64(data.count),
                    dataBase64: data.base64EncodedString()
                )
            }

            return ImportedHistoryMessageRequest(
                clientMessageID: importedMessage.clientMessageID.uuidString,
                senderOrigin: importedMessage.senderOrigin.rawValue,
                senderDisplayName: importedMessage.senderDisplayName,
                text: importedMessage.text,
                createdAt: importedMessage.createdAt.ISO8601Format(),
                kind: importedMessage.kind,
                attachments: attachments
            )
        }

        return ImportHistoryRequest(
            chatID: chat.id.uuidString,
            importerID: senderID.uuidString,
            mode: chat.mode.rawValue,
            messages: messages
        )
    }

    private static func performSend(
        _ payload: SendMessageRequest,
        session: ShareAuthSession,
        baseURL: URL
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("messages/send"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        applyDeviceHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DirectSendError.backendFailed
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw DirectSendError.backendFailed
        }
    }

    private static func performImport(
        _ payload: ImportHistoryRequest,
        session: ShareAuthSession,
        baseURL: URL,
        progress: @escaping @Sendable (ShareDestinationPickerView.SubmissionProgress) -> Void
    ) async throws {
        progress(
            ShareDestinationPickerView.SubmissionProgress(
                title: "Syncing chat history…",
                detail: payload.messages.count == 1 ? "Sending 1 imported message" : "Sending \(payload.messages.count) imported messages",
                fractionCompleted: 0.72
            )
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("chats/\(payload.chatID)/import-history"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        applyDeviceHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DirectSendError.backendFailed
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 409 {
                throw DirectSendError.historyImportNotSupported
            }
            throw DirectSendError.backendFailed
        }

        progress(
            ShareDestinationPickerView.SubmissionProgress(
                title: "Finishing import…",
                detail: "History synced successfully",
                fractionCompleted: 1
            )
        )
    }

    private static func refreshSession(_ session: ShareAuthSession, baseURL: URL) async throws -> ShareAuthSession {
        guard session.refreshTokenExpiresAt > Date().addingTimeInterval(60) else {
            throw DirectSendError.missingSession
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyDeviceHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(
            RefreshSessionRequest(refreshToken: session.refreshToken)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
            throw DirectSendError.missingSession
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(ShareAuthenticatedSessionResponse.self, from: data)
        guard let refreshed = payload.session, payload.userID == session.userID else {
            throw DirectSendError.missingSession
        }

        let shareSession = ShareAuthSession(
            userID: payload.userID,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            accessTokenExpiresAt: refreshed.accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshed.refreshTokenExpiresAt,
            updatedAt: .now
        )
        saveSession(shareSession)
        return shareSession
    }

    private static func currentBaseURL() -> URL? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PrimeMessagingServerURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return nil }
        return URL(string: value)
    }

    private static func resolvedKind(text: String, attachments: [SendAttachmentRequest]) -> String {
        if let firstAttachment = attachments.first {
            switch firstAttachment.type {
            case "photo":
                return "photo"
            case "video":
                return "video"
            case "audio":
                return "audio"
            default:
                return text.isEmpty ? "document" : "text"
            }
        }
        return "text"
    }

    private static func normalizedAttachmentType(_ value: String) -> String {
        switch value {
        case "photo", "video", "audio", "document":
            return value
        default:
            return "document"
        }
    }

    private static func applyDeviceHeaders(to request: inout URLRequest) {
        request.setValue("ios", forHTTPHeaderField: "X-Prime-Platform")
        request.setValue(stableDeviceIdentifier(), forHTTPHeaderField: "X-Prime-Device-ID")
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            request.setValue(appVersion, forHTTPHeaderField: "X-Prime-App-Version")
        }
        #if canImport(UIKit)
        request.setValue(UIDevice.current.name, forHTTPHeaderField: "X-Prime-Device-Name")
        request.setValue(UIDevice.current.model, forHTTPHeaderField: "X-Prime-Device-Model")
        request.setValue(UIDevice.current.systemName, forHTTPHeaderField: "X-Prime-OS-Name")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Prime-OS-Version")
        #endif
    }

    private static func stableDeviceIdentifier() -> String {
        let defaults = UserDefaults.standard
        let key = "push.device_identifier"
        if let existing = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
           existing.isEmpty == false {
            return existing
        }
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }

    private static func session(for userID: UUID) -> ShareAuthSession? {
        loadSessions()?[userID.uuidString]
    }

    private static func loadSessions() -> [String: ShareAuthSession]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: sessionAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try? JSONDecoder().decode([String: ShareAuthSession].self, from: data)
        }
        guard
            let rootURL = SharePayloadBridge.rootURL(),
            let data = try? Data(contentsOf: rootURL.appendingPathComponent(mirroredSessionsFileName, isDirectory: false))
        else {
            return nil
        }
        return try? JSONDecoder().decode([String: ShareAuthSession].self, from: data)
    }

    private static func saveSession(_ session: ShareAuthSession) {
        var sessions = loadSessions() ?? [:]
        sessions[session.userID.uuidString] = session
        guard let data = try? JSONEncoder().encode(sessions) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: sessionAccount
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insertQuery as CFDictionary, nil)
    }

    private static func mirroredCurrentUser() -> MirroredCurrentUser? {
        guard
            let mirrorURL = SharePayloadBridge.mirroredCurrentUserURL(),
            let data = try? Data(contentsOf: mirrorURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(MirroredCurrentUser.self, from: data)
    }
}

private enum ShareWhatsAppImportParser {
    enum SenderOrigin: String {
        case selfUser = "self"
        case counterparty
        case system
    }

    struct ImportedAttachment {
        let fileName: String
        let mimeType: String
        let kind: ShareAttachmentKind
        let fileURL: URL
    }

    struct ImportedMessage {
        let clientMessageID: UUID
        let createdAt: Date
        let senderOrigin: SenderOrigin
        let senderDisplayName: String?
        let text: String?
        let kind: String
        let attachments: [ImportedAttachment]
    }

    private struct ParsedLineItem {
        let createdAt: Date
        let senderName: String?
        let text: String
        let isSystem: Bool
    }

    private struct ExtractedAttachmentFile {
        let fileName: String
        let mimeType: String
        let kind: ShareAttachmentKind
        let fileURL: URL
    }

    private struct ZipEntry {
        let path: String
        let data: Data
    }

    private enum ImportError: LocalizedError {
        case invalidExport
        case noMessagesFound
        case unsupportedArchive

        var errorDescription: String? {
            switch self {
            case .invalidExport:
                return "Prime Messaging could not recognize this WhatsApp export."
            case .noMessagesFound:
                return "Prime Messaging found the export file, but there were no messages to import."
            case .unsupportedArchive:
                return "Prime Messaging could not unpack this WhatsApp export archive."
            }
        }
    }

    static func parse(
        payload: ShareIncomingPayload,
        currentUser: ShareDirectMessageSender.MirroredCurrentUser?,
        fileURLResolver: (ShareIncomingFilePayload) -> URL?
    ) throws -> [ImportedMessage] {
        let resolved = try resolveTranscriptAndAttachments(
            from: payload,
            fileURLResolver: fileURLResolver
        )
        let parsedItems = parseLineItems(from: resolved.transcript)
        guard parsedItems.isEmpty == false else {
            throw ImportError.noMessagesFound
        }

        var unmatchedAttachments = resolved.attachments
        let currentUserAliases = currentUser.map(makeAliasSet(for:)) ?? []
        return parsedItems.enumerated().map { index, item in
            let matchedAttachments = matchedAttachmentFiles(for: item.text, availableFiles: &unmatchedAttachments)
            let cleanedText = cleanedMessageText(item.text, removing: matchedAttachments.map(\.fileName))
            let kind = resolvedKind(text: cleanedText, attachments: matchedAttachments, isSystem: item.isSystem)
            return ImportedMessage(
                clientMessageID: UUID(),
                createdAt: item.createdAt,
                senderOrigin: resolvedSenderOrigin(for: item, currentUserAliases: currentUserAliases),
                senderDisplayName: item.senderName,
                text: cleanedText,
                kind: kind,
                attachments: matchedAttachments.map {
                    ImportedAttachment(
                        fileName: $0.fileName,
                        mimeType: $0.mimeType,
                        kind: $0.kind,
                        fileURL: $0.fileURL
                    )
                }
            )
        }
    }

    private static func resolveTranscriptAndAttachments(
        from payload: ShareIncomingPayload,
        fileURLResolver: (ShareIncomingFilePayload) -> URL?
    ) throws -> (transcript: String, attachments: [ExtractedAttachmentFile]) {
        let normalizedText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeTranscript(normalizedText) {
            let attachments = payload.files.compactMap { filePayload -> ExtractedAttachmentFile? in
                guard let fileURL = fileURLResolver(filePayload) else { return nil }
                return ExtractedAttachmentFile(
                    fileName: filePayload.fileName,
                    mimeType: filePayload.mimeType,
                    kind: ShareAttachmentKind(rawValue: filePayload.typeRawValue) ?? .document,
                    fileURL: fileURL
                )
            }
            return (normalizedText, attachments)
        }

        for filePayload in payload.files {
            guard let fileURL = fileURLResolver(filePayload) else { continue }
            let lowercasedName = filePayload.fileName.lowercased()
            if lowercasedName.hasSuffix(".txt"),
               let transcript = try? String(contentsOf: fileURL, encoding: .utf8),
               looksLikeTranscript(transcript) {
                return (transcript, [])
            }

            if lowercasedName.hasSuffix(".zip") {
                let entries = try extractZipEntries(from: fileURL)
                let transcriptEntry = entries.first {
                    $0.path.lowercased().hasSuffix("_chat.txt") || $0.path.lowercased().hasSuffix(".txt")
                }
                guard let transcriptEntry,
                      let transcript = String(data: transcriptEntry.data, encoding: .utf8),
                      looksLikeTranscript(transcript)
                else {
                    throw ImportError.invalidExport
                }

                let extractionDirectory = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("wa-import-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

                let attachments = try entries.compactMap { entry -> ExtractedAttachmentFile? in
                    let fileName = URL(fileURLWithPath: entry.path).lastPathComponent
                    guard fileName.isEmpty == false, fileName != transcriptEntry.path else { return nil }
                    let resolvedType = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension) ?? .item
                    let mimeType = resolvedType.preferredMIMEType ?? "application/octet-stream"
                    let kind = SharePayloadBridge.inferAttachmentKind(for: resolvedType, mimeType: mimeType)
                    let targetURL = extractionDirectory.appendingPathComponent(fileName, isDirectory: false)
                    try entry.data.write(to: targetURL, options: .atomic)
                    return ExtractedAttachmentFile(
                        fileName: fileName,
                        mimeType: mimeType,
                        kind: kind,
                        fileURL: targetURL
                    )
                }
                return (transcript, attachments)
            }
        }

        throw ImportError.invalidExport
    }

    private static func looksLikeTranscript(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return false }
        return normalized
            .split(whereSeparator: \.isNewline)
            .prefix(16)
            .reduce(into: 0) { count, line in
                if parseLineHeader(from: String(line)) != nil {
                    count += 1
                }
            } >= 2
    }

    private static func parseLineItems(from text: String) -> [ParsedLineItem] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var parsedItems: [ParsedLineItem] = []
        var currentItem: ParsedLineItem?

        func flushCurrentItem() {
            guard let currentItem else { return }
            let trimmedText = currentItem.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedText.isEmpty == false else { return }
            parsedItems.append(
                ParsedLineItem(
                    createdAt: currentItem.createdAt,
                    senderName: currentItem.senderName,
                    text: trimmedText,
                    isSystem: currentItem.isSystem
                )
            )
        }

        for line in lines {
            if let (date, remainder) = parseLineHeader(from: line) {
                flushCurrentItem()
                currentItem = parseLineItemBody(remainder, createdAt: date)
            } else if let existingItem = currentItem {
                currentItem = ParsedLineItem(
                    createdAt: existingItem.createdAt,
                    senderName: existingItem.senderName,
                    text: existingItem.text + "\n" + line,
                    isSystem: existingItem.isSystem
                )
            }
        }

        flushCurrentItem()
        return parsedItems
    }

    private static func parseLineItemBody(_ body: String, createdAt: Date) -> ParsedLineItem {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separatorRange = trimmedBody.range(of: ": ") {
            let sender = String(trimmedBody[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(trimmedBody[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sender.isEmpty == false {
                return ParsedLineItem(createdAt: createdAt, senderName: sender, text: text, isSystem: false)
            }
        }
        return ParsedLineItem(createdAt: createdAt, senderName: nil, text: trimmedBody, isSystem: true)
    }

    private static func parseLineHeader(from line: String) -> (Date, String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.isEmpty == false else { return nil }

        if trimmedLine.hasPrefix("["),
           let closingBracketIndex = trimmedLine.firstIndex(of: "]") {
            let dateCandidate = String(trimmedLine[trimmedLine.index(after: trimmedLine.startIndex)..<closingBracketIndex])
            if let date = parseWhatsAppDate(dateCandidate) {
                let remainder = String(trimmedLine[trimmedLine.index(after: closingBracketIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (date, remainder)
            }
        }

        if let separatorRange = trimmedLine.range(of: " - ") {
            let dateCandidate = String(trimmedLine[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = parseWhatsAppDate(dateCandidate) {
                let remainder = String(trimmedLine[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (date, remainder)
            }
        }

        return nil
    }

    private static func parseWhatsAppDate(_ rawValue: String) -> Date? {
        let normalized = rawValue
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return dateFormatters.lazy.compactMap { $0.date(from: normalized) }.first
    }

    private static func matchedAttachmentFiles(
        for text: String,
        availableFiles: inout [ExtractedAttachmentFile]
    ) -> [ExtractedAttachmentFile] {
        let normalizedText = text.lowercased()
        var matched: [ExtractedAttachmentFile] = []
        availableFiles.removeAll { file in
            let isMatch = normalizedText.contains(file.fileName.lowercased())
            if isMatch { matched.append(file) }
            return isMatch
        }
        return matched
    }

    private static func cleanedMessageText(_ text: String, removing fileNames: [String]) -> String? {
        var cleaned = text
        for fileName in fileNames where fileName.isEmpty == false {
            cleaned = cleaned.replacingOccurrences(of: fileName, with: "")
        }
        for marker in ["<attached>", "<media omitted>", "(file attached)", "(attached file)"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvedKind(text: String?, attachments: [ExtractedAttachmentFile], isSystem: Bool) -> String {
        if isSystem { return "system" }
        if let firstAttachment = attachments.first {
            switch firstAttachment.kind {
            case .photo: return "photo"
            case .video: return "video"
            case .audio: return "audio"
            case .document: return text == nil ? "document" : "text"
            }
        }
        return "text"
    }

    private static func resolvedSenderOrigin(
        for item: ParsedLineItem,
        currentUserAliases: Set<String>
    ) -> SenderOrigin {
        guard item.isSystem == false, let senderName = item.senderName else {
            return .system
        }

        return currentUserAliases.contains(normalizedAliasKey(senderName)) ? .selfUser : .counterparty
    }

    private static func makeAliasSet(for currentUser: ShareDirectMessageSender.MirroredCurrentUser) -> Set<String> {
        var aliases = Set<String>()
        aliases.insert(normalizedAliasKey(currentUser.profile.displayName))
        aliases.insert(normalizedAliasKey(currentUser.profile.username))
        aliases.insert(normalizedAliasKey("@\(currentUser.profile.username)"))
        if let phoneNumber = currentUser.profile.phoneNumber {
            aliases.insert(normalizedAliasKey(phoneNumber))
        }
        for identityMethod in currentUser.identityMethods {
            aliases.insert(normalizedAliasKey(identityMethod.value))
        }
        return aliases.filter { $0.isEmpty == false }
    }

    private static func normalizedAliasKey(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
    }

    private static func extractZipEntries(from fileURL: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: fileURL)
        guard let endRecordOffset = findEndOfCentralDirectory(in: data) else {
            throw ImportError.unsupportedArchive
        }

        let totalEntryCount = Int(readUInt16LE(data, at: endRecordOffset + 10))
        let centralDirectoryOffset = Int(readUInt32LE(data, at: endRecordOffset + 16))
        var currentOffset = centralDirectoryOffset
        var entries: [ZipEntry] = []
        entries.reserveCapacity(totalEntryCount)

        for _ in 0..<totalEntryCount {
            guard readUInt32LE(data, at: currentOffset) == 0x02014b50 else {
                throw ImportError.unsupportedArchive
            }

            let compressionMethod = readUInt16LE(data, at: currentOffset + 10)
            let compressedSize = Int(readUInt32LE(data, at: currentOffset + 20))
            let uncompressedSize = Int(readUInt32LE(data, at: currentOffset + 24))
            let fileNameLength = Int(readUInt16LE(data, at: currentOffset + 28))
            let extraFieldLength = Int(readUInt16LE(data, at: currentOffset + 30))
            let commentLength = Int(readUInt16LE(data, at: currentOffset + 32))
            let localHeaderOffset = Int(readUInt32LE(data, at: currentOffset + 42))

            let fileNameDataRange = (currentOffset + 46)..<(currentOffset + 46 + fileNameLength)
            let fileName = String(data: data.subdata(in: fileNameDataRange), encoding: .utf8) ?? ""

            currentOffset += 46 + fileNameLength + extraFieldLength + commentLength
            guard fileName.isEmpty == false, fileName.hasSuffix("/") == false else { continue }

            guard readUInt32LE(data, at: localHeaderOffset) == 0x04034b50 else {
                throw ImportError.unsupportedArchive
            }

            let localFileNameLength = Int(readUInt16LE(data, at: localHeaderOffset + 26))
            let localExtraFieldLength = Int(readUInt16LE(data, at: localHeaderOffset + 28))
            let compressedDataOffset = localHeaderOffset + 30 + localFileNameLength + localExtraFieldLength
            let compressedDataRange = compressedDataOffset..<(compressedDataOffset + compressedSize)
            let compressedData = data.subdata(in: compressedDataRange)

            let entryData: Data
            switch compressionMethod {
            case 0:
                entryData = compressedData
            case 8:
                entryData = try inflateRawDeflate(compressedData, expectedSize: uncompressedSize)
            default:
                throw ImportError.unsupportedArchive
            }

            entries.append(ZipEntry(path: fileName, data: entryData))
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let signature: UInt32 = 0x06054b50
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if readUInt32LE(data, at: offset) == signature {
                return offset
            }
        }
        return nil
    }

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        var status = data.withUnsafeBytes { rawBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(rawBuffer.count)
            return inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Z_OK else {
            throw ImportError.unsupportedArchive
        }
        defer { inflateEnd(&stream) }

        let chunkSize = max(16_384, expectedSize)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        repeat {
            status = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                stream.next_out = bufferPointer.baseAddress
                stream.avail_out = uInt(bufferPointer.count)
                let inflateStatus = inflate(&stream, Z_FINISH)
                let producedCount = bufferPointer.count - Int(stream.avail_out)
                if producedCount > 0 {
                    output.append(bufferPointer.baseAddress!, count: producedCount)
                }
                return inflateStatus
            }
        } while status == Z_OK

        guard status == Z_STREAM_END else {
            throw ImportError.unsupportedArchive
        }

        return output
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let range = offset..<(offset + 2)
        return data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let range = offset..<(offset + 4)
        return data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    private static let dateFormatters: [DateFormatter] = [
        "M/d/yy, h:mm:ss a",
        "M/d/yy, h:mm a",
        "M/d/yyyy, h:mm:ss a",
        "M/d/yyyy, h:mm a",
        "d/M/yy, HH:mm:ss",
        "d/M/yy, HH:mm",
        "d/M/yyyy, HH:mm:ss",
        "d/M/yyyy, HH:mm",
        "d.M.yy, HH:mm:ss",
        "d.M.yy, HH:mm",
        "dd.MM.yy, HH:mm:ss",
        "dd.MM.yy, HH:mm",
        "dd.MM.yyyy, HH:mm:ss",
        "dd.MM.yyyy, HH:mm",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
