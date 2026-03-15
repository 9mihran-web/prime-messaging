import Foundation

actor InMemoryLocalStore: LocalStore {
    private var drafts: [Draft] = []
    private var chatsByMode: [ChatMode: [Chat]] = [:]

    func loadDrafts() async -> [Draft] {
        drafts
    }

    func saveDraft(_ draft: Draft) async {
        drafts.removeAll(where: { $0.id == draft.id })
        drafts.append(draft)
    }

    func loadChats(for mode: ChatMode) async -> [Chat] {
        chatsByMode[mode] ?? []
    }

    func saveChats(_ chats: [Chat], for mode: ChatMode) async {
        chatsByMode[mode] = chats
    }
}
