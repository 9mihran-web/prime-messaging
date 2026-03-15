import Foundation

protocol AuthRepository {
    func currentUser() async throws -> User
    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType
    ) async throws -> User
    func logIn(identifier: String, password: String) async throws -> User
    func refreshUser(userID: UUID) async throws -> User
    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User
    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User
    func searchUsers(query: String, excluding userID: UUID) async throws -> [User]
}

protocol ChatRepository {
    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat]
    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message]
    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat
    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat
    func saveDraft(_ draft: Draft) async throws
}

protocol PresenceRepository {
    func fetchPresence(for userID: UUID) async throws -> Presence
}

protocol SettingsRepository {
    func fetchPrivacySettings() async throws -> PrivacySettings
    func updatePrivacySettings(_ settings: PrivacySettings) async throws
    func isUsernameAvailable(_ username: String, for userID: UUID?) async throws -> Bool
    func claimUsername(_ username: String, for userID: UUID) async throws
}

protocol PushNotificationService {
    func registerForRemoteNotifications() async
    func syncDeviceToken(_ token: Data) async
}

protocol OfflineTransporting {
    func updateCurrentUser(_ user: User) async
    func startScanning() async
    func stopScanning() async
    func discoveredPeers() async -> [OfflinePeer]
    func connect(to peer: OfflinePeer) async throws -> BluetoothSession
    func fetchChats(currentUserID: UUID) async -> [Chat]
    func openChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat
    func fetchMessages(chatID: UUID) async -> [Message]
    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message
}

protocol LocalStore {
    func loadDrafts() async -> [Draft]
    func saveDraft(_ draft: Draft) async
    func loadChats(for mode: ChatMode) async -> [Chat]
    func saveChats(_ chats: [Chat], for mode: ChatMode) async
}
