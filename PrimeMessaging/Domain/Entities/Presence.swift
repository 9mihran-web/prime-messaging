import Foundation

struct Presence: Codable, Hashable {
    var userID: UUID
    var state: PresenceState
    var lastSeenAt: Date?
    var isTyping: Bool
}
