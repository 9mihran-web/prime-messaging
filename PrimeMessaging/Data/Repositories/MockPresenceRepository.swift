import Foundation

struct MockPresenceRepository: PresenceRepository {
    func fetchPresence(for userID: UUID) async throws -> Presence {
        Presence(userID: userID, state: .recently, lastSeenAt: .now.addingTimeInterval(-1_800), isTyping: false)
    }
}
