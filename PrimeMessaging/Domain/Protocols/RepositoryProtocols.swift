import Foundation

protocol AuthRepository {
    func currentUser() async throws -> User
}

protocol ChatRepository {
    func fetchChats(mode: ChatMode) async throws -> [Chat]
    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message]
    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func saveDraft(_ draft: Draft) async throws
}

protocol PresenceRepository {
    func fetchPresence(for userID: UUID) async throws -> Presence
}

protocol SettingsRepository {
    func fetchPrivacySettings() async throws -> PrivacySettings
    func updatePrivacySettings(_ settings: PrivacySettings) async throws
}

protocol PushNotificationService {
    func registerForRemoteNotifications() async
    func syncDeviceToken(_ token: Data) async
}

protocol OfflineTransporting {
    func startScanning() async
    func stopScanning() async
    func discoveredPeers() async -> [OfflinePeer]
    func connect(to peer: OfflinePeer) async throws -> BluetoothSession
}

protocol LocalStore {
    func loadDrafts() async -> [Draft]
    func saveDraft(_ draft: Draft) async
    func loadChats(for mode: ChatMode) async -> [Chat]
    func saveChats(_ chats: [Chat], for mode: ChatMode) async
}
