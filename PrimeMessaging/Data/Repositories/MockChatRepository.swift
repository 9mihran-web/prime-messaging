import Foundation

struct MockChatRepository: ChatRepository {
    let localStore: LocalStore

    func fetchChats(mode: ChatMode) async throws -> [Chat] {
        let cached = await localStore.loadChats(for: mode)
        if !cached.isEmpty {
            return cached
        }

        let generated = Chat.mock(mode: mode, currentUserID: User.mockCurrentUser.id)
        await localStore.saveChats(generated, for: mode)
        return generated
    }

    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message] {
        Message.mock(chatID: chatID, mode: mode, currentUserID: User.mockCurrentUser.id)
    }

    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message {
        Message(
            id: UUID(),
            chatID: chatID,
            senderID: senderID,
            mode: mode,
            kind: .text,
            text: text,
            attachments: [],
            replyToMessageID: nil,
            status: mode == .offline ? .sent : .sending,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )
    }

    func saveDraft(_ draft: Draft) async throws {
        await localStore.saveDraft(draft)
    }
}
