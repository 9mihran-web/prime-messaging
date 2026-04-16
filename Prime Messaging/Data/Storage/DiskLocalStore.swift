import Foundation

actor DiskLocalStore: LocalStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let directoryURL: URL

    init(directoryName: String = "PrimeMessagingLocalStore") {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func loadDrafts() async -> [Draft] {
        load([Draft].self, from: draftsURL) ?? []
    }

    func loadDraft(chatID: UUID, mode: ChatMode) async -> Draft? {
        loadDraftsSync()
            .filter { $0.chatID == chatID && $0.mode == mode }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    func saveDraft(_ draft: Draft) async {
        var drafts = loadDraftsSync()
        drafts.removeAll(where: { $0.chatID == draft.chatID && $0.mode == draft.mode })
        drafts.append(draft)
        save(drafts, to: draftsURL)
    }

    func removeDraft(chatID: UUID, mode: ChatMode) async {
        var drafts = loadDraftsSync()
        drafts.removeAll(where: { $0.chatID == chatID && $0.mode == mode })
        save(drafts, to: draftsURL)
    }

    func loadChats(for mode: ChatMode) async -> [Chat] {
        load([Chat].self, from: chatsURL(for: mode)) ?? []
    }

    func saveChats(_ chats: [Chat], for mode: ChatMode) async {
        save(chats, to: chatsURL(for: mode))
    }

    private var draftsURL: URL {
        directoryURL.appendingPathComponent("drafts.json")
    }

    private func chatsURL(for mode: ChatMode) -> URL {
        directoryURL.appendingPathComponent("chats-\(mode.rawValue).json")
    }

    private func loadDraftsSync() -> [Draft] {
        load([Draft].self, from: draftsURL) ?? []
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
