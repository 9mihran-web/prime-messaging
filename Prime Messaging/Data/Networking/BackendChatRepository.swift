import Foundation

struct BackendChatRepository: ChatRepository {
    let fallback: ChatRepository
    private let decoder = BackendChatRepository.makeDecoder()

    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            var components = URLComponents(url: baseURL.appending(path: "/chats"), resolvingAgainstBaseURL: false)
        else {
            return try await fallback.fetchChats(mode: mode, for: userID)
        }

        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID.uuidString),
            URLQueryItem(name: "mode", value: mode.rawValue)
        ]

        guard let url = components.url else {
            return try await fallback.fetchChats(mode: mode, for: userID)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response)
            let chats = try decoder.decode([Chat].self, from: data)
            let preparedChats = injectingSavedMessages(into: chats, mode: mode, userID: userID)
            return try await hydratingDirectChatTitles(in: preparedChats, currentUserID: userID, baseURL: baseURL)
        } catch {
            throw error
        }
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            var components = URLComponents(url: baseURL.appending(path: "/messages"), resolvingAgainstBaseURL: false)
        else {
            return try await fallback.fetchMessages(chatID: chatID, mode: mode)
        }

        components.queryItems = [URLQueryItem(name: "chat_id", value: chatID.uuidString)]

        guard let url = components.url else {
            return try await fallback.fetchMessages(chatID: chatID, mode: mode)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response)
            return try decoder.decode([Message].self, from: data)
        } catch {
            throw error
        }
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        try await sendMessage(
            OutgoingMessageDraft(text: text),
            in: chatID,
            mode: mode,
            senderID: senderID
        )
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        let body = try makeSendMessageRequest(from: draft, chatID: chatID, senderID: senderID, mode: mode)
        return try await request(
            path: "/messages/send",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.sendMessage(draft, in: chatID, mode: mode, senderID: senderID)
            }
        )
    }

    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat {
        let body = DirectChatRequest(currentUserID: currentUserID.uuidString, otherUserID: otherUserID.uuidString, mode: mode.rawValue)
        return try await request(
            path: "/chats/direct",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.createDirectChat(with: otherUserID, currentUserID: currentUserID, mode: mode)
            }
        )
    }

    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        throw OfflineTransportError.nearbySelectionRequired
    }

    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat {
        let body = GroupChatRequest(
            title: title,
            ownerID: ownerID.uuidString,
            memberIDs: memberIDs.map(\.uuidString),
            mode: mode.rawValue
        )
        return try await request(
            path: "/chats/group",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.createGroupChat(title: title, memberIDs: memberIDs, ownerID: ownerID, mode: mode)
            }
        )
    }

    func saveDraft(_ draft: Draft) async throws {
        try await fallback.saveDraft(draft)
    }

    private func injectingSavedMessages(into chats: [Chat], mode: ChatMode, userID: UUID) -> [Chat] {
        guard chats.contains(where: { $0.type == .selfChat }) == false else {
            return chats
        }

        let savedMessages = Chat(
            id: userID,
            mode: mode,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [userID],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: true,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(
                muteState: .active,
                previewEnabled: true,
                customSoundName: nil,
                badgeEnabled: true
            )
        )

        return [savedMessages] + chats
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        fallback: (() async throws -> Response)?
    ) async throws -> Response {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            if let fallback {
                return try await fallback()
            }
            throw UsernameRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
            throw UsernameRepositoryError.backendUnavailable
        }
    }

    private func makeSendMessageRequest(
        from draft: OutgoingMessageDraft,
        chatID: UUID,
        senderID: UUID,
        mode: ChatMode
    ) throws -> SendMessageRequest {
        let attachments = try draft.attachments.map { attachment in
            SendAttachmentRequest(
                type: attachment.type.rawValue,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                byteSize: attachment.byteSize,
                dataBase64: try loadBase64(from: attachment.localURL)
            )
        }

        let voiceMessage = try draft.voiceMessage.map { voiceMessage in
            SendVoiceMessageRequest(
                durationSeconds: voiceMessage.durationSeconds,
                waveformSamples: voiceMessage.waveformSamples,
                fileName: voiceMessage.localFileURL?.lastPathComponent ?? "voice.m4a",
                dataBase64: try loadBase64(from: voiceMessage.localFileURL)
            )
        }

        return SendMessageRequest(
            chatID: chatID.uuidString,
            senderID: senderID.uuidString,
            text: draft.normalizedText,
            mode: mode.rawValue,
            kind: resolvedKind(for: draft).rawValue,
            attachments: attachments,
            voiceMessage: voiceMessage
        )
    }

    private func loadBase64(from url: URL?) throws -> String? {
        guard let url else { return nil }
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
    }

    private func resolvedKind(for draft: OutgoingMessageDraft) -> MessageKind {
        if draft.voiceMessage != nil {
            return .voice
        }

        if let firstAttachment = draft.attachments.first {
            switch firstAttachment.type {
            case .photo:
                return .photo
            case .audio:
                return .audio
            case .video:
                return .video
            case .document:
                return .document
            case .contact:
                return .contact
            case .location:
                return .location
            }
        }

        return .text
    }

    private func hydratingDirectChatTitles(in chats: [Chat], currentUserID: UUID, baseURL: URL) async throws -> [Chat] {
        var hydratedChats = chats

        for index in hydratedChats.indices {
            guard hydratedChats[index].type == .direct else { continue }
            guard let otherUserID = await resolvedOtherUserID(for: hydratedChats[index], currentUserID: currentUserID) else {
                continue
            }

            do {
                let user = try await fetchUser(id: otherUserID, baseURL: baseURL)
                let trimmedDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = trimmedDisplayName.isEmpty ? user.profile.username : trimmedDisplayName
                hydratedChats[index].title = displayTitle
                hydratedChats[index].subtitle = "@\(user.profile.username)"
            } catch { }
        }

        return hydratedChats
    }

    private func resolvedOtherUserID(for chat: Chat, currentUserID: UUID) async -> UUID? {
        if let participantID = chat.participantIDs.first(where: { $0 != currentUserID }) {
            return participantID
        }

        do {
            let messages = try await fetchMessages(chatID: chat.id, mode: chat.mode)
            return messages
                .reversed()
                .map(\.senderID)
                .first(where: { $0 != currentUserID })
        } catch {
            return nil
        }
    }

    private func fetchUser(id: UUID, baseURL: URL) async throws -> User {
        let url = baseURL.appending(path: "/users/\(id.uuidString)")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        return try decoder.decode(User.self, from: data)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct SendMessageRequest: Encodable {
    let chatID: String
    let senderID: String
    let text: String?
    let mode: String
    let kind: String
    let attachments: [SendAttachmentRequest]
    let voiceMessage: SendVoiceMessageRequest?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case senderID = "sender_id"
        case text
        case mode
        case kind
        case attachments
        case voiceMessage = "voice_message"
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

private struct SendVoiceMessageRequest: Encodable {
    let durationSeconds: Int
    let waveformSamples: [Float]
    let fileName: String
    let dataBase64: String?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case waveformSamples = "waveform_samples"
        case fileName = "file_name"
        case dataBase64 = "data_base64"
    }
}

private struct DirectChatRequest: Encodable {
    let currentUserID: String
    let otherUserID: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case currentUserID = "current_user_id"
        case otherUserID = "other_user_id"
        case mode
    }
}

private struct GroupChatRequest: Encodable {
    let title: String
    let ownerID: String
    let memberIDs: [String]
    let mode: String

    enum CodingKeys: String, CodingKey {
        case title
        case ownerID = "owner_id"
        case memberIDs = "member_ids"
        case mode
    }
}
