import CryptoKit
import Foundation

struct WhatsAppImportedHistory {
    let messages: [Message]
    let attachmentCount: Int
    let distinctSenderCount: Int
}

enum WhatsAppChatImportError: LocalizedError {
    case invalidExport
    case noMessagesFound

    var errorDescription: String? {
        switch self {
        case .invalidExport:
            return "Prime Messaging could not recognize this WhatsApp export."
        case .noMessagesFound:
            return "Prime Messaging found the export file, but there were no messages to import."
        }
    }
}

enum WhatsAppChatImportParser {
    private struct ParsedLineItem {
        let createdAt: Date
        let senderName: String?
        let text: String
        let isSystem: Bool
    }

    private static let attachmentSuffixMarkers = [
        "(file attached)",
        "(attached file)",
        "<media omitted>",
        "<attached>",
    ]

    static func looksLikeWhatsAppExport(_ payload: IncomingSharedPayload) -> Bool {
        let normalizedText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.isEmpty == false {
            let lines = normalizedText.split(whereSeparator: \.isNewline).prefix(16)
            let matchingLineCount = lines.reduce(into: 0) { partialResult, line in
                if parseLineHeader(from: String(line)) != nil {
                    partialResult += 1
                }
            }
            if matchingLineCount >= 2 {
                return true
            }
        }

        return payload.files.contains { file in
            let lowercasedName = file.fileName.lowercased()
            return lowercasedName == "_chat.txt"
                || lowercasedName.hasSuffix(".txt")
                || lowercasedName.hasSuffix(".zip")
                || lowercasedName.contains("whatsapp")
        }
    }

    static func parse(
        payload: IncomingSharedPayload,
        into chat: Chat,
        currentUser: User,
        fileURLResolver: (IncomingSharedFilePayload) -> URL?
    ) throws -> WhatsAppImportedHistory {
        guard looksLikeWhatsAppExport(payload) else {
            throw WhatsAppChatImportError.invalidExport
        }

        let parsedItems = parseLineItems(from: payload.text)
        guard parsedItems.isEmpty == false else {
            throw WhatsAppChatImportError.noMessagesFound
        }

        var unmatchedFiles = payload.files
        var importedMessages: [Message] = []
        importedMessages.reserveCapacity(parsedItems.count)

        let senderResolver = SenderResolver(chat: chat, currentUser: currentUser, parsedItems: parsedItems)

        for (index, item) in parsedItems.enumerated() {
            let matchedFiles = matchedFilePayloads(for: item.text, availableFiles: &unmatchedFiles)
            let attachments = matchedFiles.map { filePayload in
                Attachment(
                    id: filePayload.id,
                    type: filePayload.attachmentType,
                    fileName: filePayload.fileName,
                    mimeType: filePayload.mimeType,
                    localURL: fileURLResolver(filePayload),
                    remoteURL: nil,
                    byteSize: filePayload.byteSize
                )
            }

            let cleanedText = cleanedMessageText(item.text, removing: matchedFiles.map(\.fileName))
            let senderID = senderResolver.senderID(for: item)
            let senderDisplayName = senderResolver.senderDisplayName(for: item)
            let kind = resolveMessageKind(isSystem: item.isSystem, attachments: attachments)

            importedMessages.append(
                Message(
                    id: deterministicUUID(seed: "\(chat.id.uuidString)-import-id-\(index)-\(item.createdAt.timeIntervalSince1970)"),
                    chatID: chat.id,
                    senderID: senderID,
                    clientMessageID: deterministicUUID(seed: "\(chat.id.uuidString)-import-client-\(index)-\(item.createdAt.timeIntervalSince1970)-\(cleanedText ?? "")"),
                    senderDisplayName: senderDisplayName,
                    mode: chat.mode,
                    deliveryState: .migrated,
                    kind: kind,
                    text: kind == .system ? (cleanedText ?? item.text) : cleanedText,
                    attachments: attachments,
                    replyToMessageID: nil,
                    replyPreview: nil,
                    communityContext: nil,
                    deliveryOptions: MessageDeliveryOptions(),
                    status: .sent,
                    createdAt: item.createdAt,
                    editedAt: nil,
                    deletedForEveryoneAt: nil,
                    reactions: [],
                    voiceMessage: nil,
                    liveLocation: nil
                )
            )
        }

        importedMessages.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.clientMessageID.uuidString < rhs.clientMessageID.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }

        return WhatsAppImportedHistory(
            messages: importedMessages,
            attachmentCount: importedMessages.reduce(into: 0) { $0 += $1.attachments.count },
            distinctSenderCount: Set(importedMessages.compactMap(\.senderDisplayName)).count
        )
    }

    private static func parseLineItems(from text: String) -> [ParsedLineItem] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")

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
                let appendedText = existingItem.text.isEmpty ? line : existingItem.text + "\n" + line
                currentItem = ParsedLineItem(
                    createdAt: existingItem.createdAt,
                    senderName: existingItem.senderName,
                    text: appendedText,
                    isSystem: existingItem.isSystem
                )
            }
        }

        flushCurrentItem()
        return parsedItems
    }

    private static func parseLineItemBody(_ body: String, createdAt: Date) -> ParsedLineItem {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBody.isEmpty == false else {
            return ParsedLineItem(createdAt: createdAt, senderName: nil, text: "", isSystem: true)
        }

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

        for formatter in dateFormatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static func matchedFilePayloads(
        for text: String,
        availableFiles: inout [IncomingSharedFilePayload]
    ) -> [IncomingSharedFilePayload] {
        guard availableFiles.isEmpty == false else { return [] }
        let normalizedText = text.lowercased()
        var matched: [IncomingSharedFilePayload] = []

        availableFiles.removeAll { filePayload in
            let normalizedFileName = filePayload.fileName.lowercased()
            let isMatch = normalizedText.contains(normalizedFileName)
            if isMatch {
                matched.append(filePayload)
            }
            return isMatch
        }

        return matched
    }

    private static func cleanedMessageText(_ text: String, removing matchedFileNames: [String]) -> String? {
        var cleaned = text

        for fileName in matchedFileNames where fileName.isEmpty == false {
            cleaned = cleaned.replacingOccurrences(of: fileName, with: "", options: [.caseInsensitive])
        }

        for marker in attachmentSuffixMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t:-()[]"))

        return cleaned.isEmpty ? nil : cleaned
    }

    private static func resolveMessageKind(isSystem: Bool, attachments: [Attachment]) -> MessageKind {
        if isSystem {
            return .system
        }

        if let attachment = attachments.first {
            switch attachment.type {
            case .photo:
                return .photo
            case .video:
                return .video
            case .document:
                return .document
            case .audio:
                return .audio
            case .contact:
                return .contact
            case .location:
                return .location
            }
        }

        return .text
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static let dateFormatters: [DateFormatter] = {
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

    private struct SenderResolver {
        let chat: Chat
        let currentUser: User
        let currentUserAliases: Set<String>
        let directPeerID: UUID?

        init(chat: Chat, currentUser: User, parsedItems: [ParsedLineItem]) {
            self.chat = chat
            self.currentUser = currentUser

            var aliases = Set<String>()
            aliases.insert(Self.normalizedKey(currentUser.profile.displayName))
            aliases.insert(Self.normalizedKey(currentUser.profile.username))
            aliases.insert(Self.normalizedKey("@\(currentUser.profile.username)"))
            if let phoneNumber = currentUser.profile.phoneNumber {
                aliases.insert(Self.normalizedKey(phoneNumber))
            }
            for identityMethod in currentUser.identityMethods {
                aliases.insert(Self.normalizedKey(identityMethod.value))
            }
            currentUserAliases = aliases.filter { $0.isEmpty == false }
            directPeerID = chat.participantIDs.first(where: { $0 != currentUser.id })
        }

        func senderID(for item: ParsedLineItem) -> UUID {
            guard let senderName = item.senderName, item.isSystem == false else {
                return currentUser.id
            }

            if isCurrentUserName(senderName) {
                return currentUser.id
            }

            if chat.type == .direct, let directPeerID {
                return directPeerID
            }

            return WhatsAppChatImportParser.deterministicUUID(seed: "\(chat.id.uuidString)-sender-\(Self.normalizedKey(senderName))")
        }

        func senderDisplayName(for item: ParsedLineItem) -> String? {
            guard let senderName = item.senderName, item.isSystem == false else { return nil }
            if isCurrentUserName(senderName) {
                return currentUser.profile.displayName
            }
            return senderName
        }

        private func isCurrentUserName(_ senderName: String) -> Bool {
            currentUserAliases.contains(Self.normalizedKey(senderName))
        }

        private static func normalizedKey(_ value: String) -> String {
            value
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "@", with: "")
        }
    }
}
