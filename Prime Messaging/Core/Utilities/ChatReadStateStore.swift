import Foundation

actor ChatReadStateStore {
    static let shared = ChatReadStateStore()

    private enum StorageKeys {
        static let readMarkers = "chats.read_markers"
    }

    private struct ReadMarker: Codable, Hashable {
        let userID: UUID
        let chatID: UUID
        let mode: ChatMode
        var readThroughAt: Date
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bootstrapReadMarkerIfNeeded(chat: Chat, messages: [Message], currentUserID: UUID) {
        guard chat.type != .selfChat else { return }
        guard chat.unreadCount == 0 else { return }
        guard readMarker(for: chat.id, mode: chat.mode, userID: currentUserID) == nil else { return }
        guard let latestMessageDate = messages.map(\.createdAt).max() else { return }
        upsertReadMarker(chatID: chat.id, mode: chat.mode, userID: currentUserID, readThroughAt: latestMessageDate)
    }

    func markChatRead(chatID: UUID, mode: ChatMode, userID: UUID, messages: [Message]) {
        let readThroughAt = messages.map(\.createdAt).max() ?? .now
        upsertReadMarker(chatID: chatID, mode: mode, userID: userID, readThroughAt: readThroughAt)
    }

    func unreadCount(for chat: Chat, messages: [Message], currentUserID: UUID) -> Int {
        guard chat.type != .selfChat else { return 0 }

        let serverUnreadCount = max(chat.unreadCount, 0)
        if chat.mode == .online {
            return serverUnreadCount
        }

        let localUnreadByMarker: Int
        if let marker = readMarker(for: chat.id, mode: chat.mode, userID: currentUserID) {
            localUnreadByMarker = messages.reduce(into: 0) { count, message in
                guard message.senderID != currentUserID else { return }
                guard message.status != .read else { return }
                guard message.createdAt > marker.readThroughAt else { return }
                count += 1
            }
        } else {
            localUnreadByMarker = messages.reduce(into: 0) { count, message in
                guard message.senderID != currentUserID else { return }
                guard message.status != .read else { return }
                count += 1
            }
        }

        return max(serverUnreadCount, localUnreadByMarker)
    }

    func firstUnreadMessageID(for chat: Chat, messages: [Message], currentUserID: UUID) -> UUID? {
        guard chat.type != .selfChat else { return nil }

        let incomingMessages = messages
            .filter { $0.senderID != currentUserID && $0.status != .read }
            .sorted(by: { $0.createdAt < $1.createdAt })

        guard incomingMessages.isEmpty == false else { return nil }

        if let marker = readMarker(for: chat.id, mode: chat.mode, userID: currentUserID) {
            return incomingMessages.first(where: { $0.createdAt > marker.readThroughAt })?.id
        }

        let unresolvedUnreadCount = max(chat.unreadCount, 0)
        guard unresolvedUnreadCount > 0 else { return nil }

        return incomingMessages.suffix(unresolvedUnreadCount).first?.id
    }

    private func upsertReadMarker(chatID: UUID, mode: ChatMode, userID: UUID, readThroughAt: Date) {
        var markers = loadReadMarkers()
        if let index = markers.firstIndex(where: { $0.chatID == chatID && $0.mode == mode && $0.userID == userID }) {
            markers[index].readThroughAt = readThroughAt
        } else {
            markers.append(
                ReadMarker(
                    userID: userID,
                    chatID: chatID,
                    mode: mode,
                    readThroughAt: readThroughAt
                )
            )
        }
        persistReadMarkers(markers)
    }

    private func readMarker(for chatID: UUID, mode: ChatMode, userID: UUID) -> ReadMarker? {
        loadReadMarkers().first(where: { $0.chatID == chatID && $0.mode == mode && $0.userID == userID })
    }

    private func loadReadMarkers() -> [ReadMarker] {
        guard let data = defaults.data(forKey: StorageKeys.readMarkers) else { return [] }
        return (try? decoder.decode([ReadMarker].self, from: data)) ?? []
    }

    private func persistReadMarkers(_ markers: [ReadMarker]) {
        guard let data = try? encoder.encode(markers) else { return }
        defaults.set(data, forKey: StorageKeys.readMarkers)
    }
}
