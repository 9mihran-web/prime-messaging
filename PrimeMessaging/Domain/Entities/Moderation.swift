import Foundation

struct BlockRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let blockerUserID: UUID
    let blockedUserID: UUID
    let createdAt: Date
}

struct ReportRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let reporterUserID: UUID
    let targetChatID: UUID?
    let targetMessageID: UUID?
    let targetUserID: UUID?
    let reason: String
    let createdAt: Date
}
