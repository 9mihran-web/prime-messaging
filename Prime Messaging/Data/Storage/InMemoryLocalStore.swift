import Foundation

actor InMemoryLocalStore: LocalStore {
    private var drafts: [Draft] = []
    private var chatsByMode: [ChatMode: [Chat]] = [:]

    func loadDrafts() async -> [Draft] {
        drafts
    }

    func loadDraft(chatID: UUID, mode: ChatMode) async -> Draft? {
        drafts
            .filter { $0.chatID == chatID && $0.mode == mode }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    func saveDraft(_ draft: Draft) async {
        drafts.removeAll(where: { $0.chatID == draft.chatID && $0.mode == draft.mode })
        drafts.append(draft)
    }

    func removeDraft(chatID: UUID, mode: ChatMode) async {
        drafts.removeAll(where: { $0.chatID == chatID && $0.mode == mode })
    }

    func loadChats(for mode: ChatMode) async -> [Chat] {
        chatsByMode[mode] ?? []
    }

    func saveChats(_ chats: [Chat], for mode: ChatMode) async {
        chatsByMode[mode] = chats
    }
}
