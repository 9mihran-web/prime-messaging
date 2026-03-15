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
        let body = SendMessageRequest(chatID: chatID.uuidString, senderID: senderID.uuidString, text: text, mode: mode.rawValue)
        return try await request(
            path: "/messages/send",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.sendMessage(text, in: chatID, mode: mode, senderID: senderID)
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

    private func hydratingDirectChatTitles(in chats: [Chat], currentUserID: UUID, baseURL: URL) async throws -> [Chat] {
        var hydratedChats = chats

        for index in hydratedChats.indices {
            guard needsHydration(hydratedChats[index]) else { continue }
            guard let otherUserID = hydratedChats[index].participantIDs.first(where: { $0 != currentUserID }) else { continue }

            do {
                let user = try await fetchUser(id: otherUserID, baseURL: baseURL)
                hydratedChats[index].title = user.profile.displayName
                hydratedChats[index].subtitle = "@\(user.profile.username)"
            } catch { }
        }

        return hydratedChats
    }

    private func needsHydration(_ chat: Chat) -> Bool {
        guard chat.type == .direct else {
            return false
        }

        let trimmedTitle = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty || trimmedTitle.caseInsensitiveCompare("Direct Chat") == .orderedSame
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
    let text: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case senderID = "sender_id"
        case text
        case mode
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
