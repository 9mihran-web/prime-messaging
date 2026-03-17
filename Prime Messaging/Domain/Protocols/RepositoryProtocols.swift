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
    func userProfile(userID: UUID) async throws -> User
    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User
    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User
    func removeAvatar(for userID: UUID) async throws -> User
    func updatePassword(_ password: String, for userID: UUID) async throws
    func deleteAccount(userID: UUID) async throws
    func searchUsers(query: String, excluding userID: UUID) async throws -> [User]
}

protocol ChatRepository {
    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat]
    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message]
    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws
    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message
    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message
    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat
    func createGroupChat(title: String, memberIDs: [UUID], ownerID: UUID, mode: ChatMode) async throws -> Chat
    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat
    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat
    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat
    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat
    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat
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

enum PushAuthorizationStatus: String {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var localizationKey: String {
        switch self {
        case .notDetermined:
            return "settings.notifications.status.not_determined"
        case .denied:
            return "settings.notifications.status.denied"
        case .authorized:
            return "settings.notifications.status.authorized"
        case .provisional:
            return "settings.notifications.status.provisional"
        case .ephemeral:
            return "settings.notifications.status.ephemeral"
        }
    }
}

@MainActor
protocol PushNotificationService: AnyObject {
    func registerForRemoteNotifications() async
    func syncDeviceToken(_ token: Data) async
    func authorizationStatus() async -> PushAuthorizationStatus
    func startMonitoring(currentUser: User, chatRepository: ChatRepository) async
    func stopMonitoring() async
    func updateActiveChat(_ chat: Chat?) async
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
    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message
    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, editorID: UUID) async throws -> Message
    func deleteMessage(_ messageID: UUID, in chatID: UUID, requesterID: UUID) async throws -> Message
}

protocol LocalStore {
    func loadDrafts() async -> [Draft]
    func saveDraft(_ draft: Draft) async
    func loadChats(for mode: ChatMode) async -> [Chat]
    func saveChats(_ chats: [Chat], for mode: ChatMode) async
}
