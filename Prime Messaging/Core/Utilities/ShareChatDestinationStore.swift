import Foundation

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
    var chats: [ShareChatDestination]
}

actor ShareChatDestinationStore {
    static let shared = ShareChatDestinationStore()

    static let appGroupIdentifier = IncomingSharedPayloadStore.appGroupIdentifier

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileName = "share-chat-destinations.json"

    private var rootURL: URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            return nil
        }
        let directory = containerURL.appendingPathComponent("IncomingShare", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var fileURL: URL? {
        rootURL?.appendingPathComponent(fileName, isDirectory: false)
    }

    func loadDestinations() -> [ShareChatDestination] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? decoder.decode([ShareChatDestination].self, from: data)) ?? []
    }

    func saveDestinations(from chats: [Chat], ownerUserID: UUID) {
        guard let fileURL else { return }
        let destinations = chats
            .filter { $0.participantIDs.isEmpty == false || $0.group != nil || $0.type == .selfChat }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            .prefix(40)
            .map(makeDestination(from:))

        encoder.outputFormatting = [.sortedKeys]
        let export = ShareChatDestinationExport(
            ownerUserID: ownerUserID,
            chats: Array(destinations)
        )
        guard let data = try? encoder.encode(export) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func purgeChats(_ chatIDs: Set<UUID>) {
        guard chatIDs.isEmpty == false else { return }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard var export = try? decoder.decode(ShareChatDestinationExport.self, from: data) else { return }
        export.chats.removeAll { chatIDs.contains($0.id) }
        guard let nextData = try? encoder.encode(export) else { return }
        try? nextData.write(to: fileURL, options: .atomic)
    }

    private func makeDestination(from chat: Chat) -> ShareChatDestination {
        ShareChatDestination(
            id: chat.id,
            title: chat.title,
            subtitle: chat.subtitle,
            previewText: chat.lastMessagePreview ?? "",
            kind: destinationKind(for: chat),
            mode: destinationMode(for: chat.mode),
            isPinned: chat.isPinned,
            unreadCount: chat.unreadCount,
            lastActivityAt: chat.lastActivityAt
        )
    }

    private func destinationMode(for mode: ChatMode) -> ShareChatDestination.Mode {
        switch mode {
        case .online:
            return .online
        case .offline:
            return .offline
        case .smart:
            return .smart
        }
    }

    private func destinationKind(for chat: Chat) -> ShareChatDestination.Kind {
        if chat.type == .selfChat {
            return .saved
        }
        if let communityKind = chat.communityDetails?.kind {
            switch communityKind {
            case .channel:
                return .channel
            case .community:
                return .community
            case .group, .supergroup:
                return .group
            }
        }
        switch chat.type {
        case .direct, .secret:
            return .direct
        case .group:
            return .group
        case .selfChat:
            return .saved
        }
    }
}
