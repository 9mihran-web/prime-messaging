import Foundation

struct AccountLookupResult: Codable, Hashable {
    var exists: Bool
    var accountKind: AccountKind?
    var displayName: String?
}

enum OTPPurpose: String, Codable, Hashable, Sendable {
    case signup
    case login
    case resetPassword = "reset_password"
}

struct OTPChallenge: Codable, Hashable, Sendable {
    var challengeID: String
    var expiresAt: Date
    var resendAvailableAt: Date
    var attemptLimit: Int
    var remainingAttempts: Int
    var channel: String
    var destinationMasked: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case expiresAt = "expires_at"
        case resendAvailableAt = "resend_available_at"
        case attemptLimit = "attempt_limit"
        case remainingAttempts = "remaining_attempts"
        case channel
        case destinationMasked = "destination_masked"
    }
}

struct AppleSignInResult: Codable, Equatable, Sendable {
    var user: User
    var isNewUser: Bool
}

struct DeviceContactCandidate: Codable, Hashable, Sendable {
    var localContactID: String
    var displayName: String
    var emails: [String]
    var phones: [String]

    enum CodingKeys: String, CodingKey {
        case localContactID = "local_contact_id"
        case displayName = "display_name"
        case emails
        case phones
    }
}

struct MatchedDeviceContact: Codable, Equatable, Sendable {
    var localContactID: String
    var user: User
    var matchedBy: String

    enum CodingKeys: String, CodingKey {
        case localContactID = "local_contact_id"
        case user
        case matchedBy = "matched_by"
    }
}

struct ChatModeTransitionRequest {
    var fromMode: ChatMode
    var toMode: ChatMode
    var currentUser: User
    var activeChat: Chat?
}

struct ChatModeTransitionResult {
    var routedChat: Chat?
}

protocol AuthRepository {
    func currentUser() async throws -> User
    func signInWithApple(
        identityToken: String,
        authorizationCode: String?,
        appleUserID: String,
        email: String?,
        givenName: String?,
        familyName: String?
    ) async throws -> AppleSignInResult
    func matchDeviceContacts(
        _ contacts: [DeviceContactCandidate],
        currentUserID: UUID
    ) async throws -> [MatchedDeviceContact]
    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType,
        accountKind: AccountKind,
        otpChallengeID: String?,
        signupEmail: String?
    ) async throws -> User
    func lookupAccount(identifier: String) async throws -> AccountLookupResult
    func requestOTP(identifier: String, purpose: OTPPurpose) async throws -> OTPChallenge
    func verifyOTPChallenge(challengeID: String, otpCode: String) async throws -> OTPChallenge
    func authenticate(identifier: String, otpCode: String, challengeID: String?) async throws -> User?
    func logIn(identifier: String, password: String) async throws -> User
    func resetPassword(identifier: String, newPassword: String, challengeID: String?) async throws
    func refreshUser(userID: UUID) async throws -> User
    func userProfile(userID: UUID) async throws -> User
    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User
    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User
    func removeAvatar(for userID: UUID) async throws -> User
    func updatePassword(_ password: String, for userID: UUID) async throws
    func updatePassword(currentPassword: String?, newPassword: String, for userID: UUID) async throws
    func deleteAccount(userID: UUID) async throws
    func searchUsers(query: String, excluding userID: UUID) async throws -> [User]
    func fetchBlockedUsers(for userID: UUID) async throws -> [User]
    func blockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws
    func unblockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws
}

protocol ChatRepository {
    func fetchChats(mode: ChatMode, for userID: UUID) async throws -> [Chat]
    func fetchMessages(chatID: UUID, mode: ChatMode) async throws -> [Message]
    func cachedChats(mode: ChatMode, for userID: UUID) async -> [Chat]
    func cachedMessages(chatID: UUID, mode: ChatMode) async -> [Message]
    func markChatRead(chatID: UUID, mode: ChatMode, readerID: UUID) async throws
    func sendMessage(_ text: String, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message
    func sendMessage(_ draft: OutgoingMessageDraft, in chatID: UUID, mode: ChatMode, senderID: UUID) async throws -> Message
    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, mode: ChatMode, userID: UUID) async throws -> Message
    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, mode: ChatMode, editorID: UUID) async throws -> Message
    func deleteMessage(_ messageID: UUID, in chatID: UUID, mode: ChatMode, requesterID: UUID) async throws -> Message
    func createDirectChat(with otherUserID: UUID, currentUserID: UUID, mode: ChatMode) async throws -> Chat
    func submitGuestRequest(introText: String, in chatID: UUID, senderID: UUID) async throws -> Chat
    func respondToGuestRequest(in chatID: UUID, approve: Bool, responderID: UUID) async throws -> Chat
    func createGroupChat(
        title: String,
        memberIDs: [UUID],
        ownerID: UUID,
        mode: ChatMode,
        communityDetails: CommunityChatDetails?
    ) async throws -> Chat
    func updateGroup(_ chat: Chat, title: String, requesterID: UUID) async throws -> Chat
    func deleteGroup(_ chat: Chat, requesterID: UUID) async throws
    func updateCommunityDetails(_ details: CommunityChatDetails, for chat: Chat, requesterID: UUID) async throws -> Chat
    func uploadGroupAvatar(imageData: Data, for chat: Chat, requesterID: UUID) async throws -> Chat
    func removeGroupAvatar(for chat: Chat, requesterID: UUID) async throws -> Chat
    func addMembers(_ memberIDs: [UUID], to chat: Chat, requesterID: UUID) async throws -> Chat
    func removeMember(_ memberID: UUID, from chat: Chat, requesterID: UUID) async throws -> Chat
    func updateMemberRole(_ role: GroupMemberRole, for memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat
    func transferGroupOwnership(to memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat
    func leaveGroup(_ chat: Chat, requesterID: UUID) async throws
    func searchDiscoverableChats(query: String, mode: ChatMode, currentUserID: UUID) async throws -> [Chat]
    func joinDiscoverableChat(_ chat: Chat, requesterID: UUID) async throws -> Chat
    func joinChat(inviteCode: String, mode: ChatMode, requesterID: UUID) async throws -> Chat
    func submitJoinRequest(for chat: Chat, requesterID: UUID, answers: [String]) async throws
    func fetchModerationDashboard(for chat: Chat, requesterID: UUID) async throws -> ModerationDashboard
    func resolveJoinRequest(
        for requesterUserID: UUID,
        approve: Bool,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard
    func reportChatContent(
        in chat: Chat,
        requesterID: UUID,
        targetMessageID: UUID?,
        targetUserID: UUID?,
        reason: ModerationReportReason,
        details: String?
    ) async throws
    func banMember(
        _ memberID: UUID,
        duration: TimeInterval,
        reason: String?,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard
    func removeBan(
        for memberID: UUID,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard
    func createNearbyChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat
    func importExternalHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat
    func saveDraft(_ draft: Draft) async throws
    func prepareModeTransition(_ request: ChatModeTransitionRequest) async throws -> ChatModeTransitionResult
    func retryPendingOutgoingMessages(currentUserID: UUID) async
    func cancelPendingOutgoingMessage(clientMessageID: UUID, in chat: Chat, ownerUserID: UUID) async
    func purgeLocalChatArtifacts(chatIDs: [UUID], currentUserID: UUID) async
}

protocol PresenceRepository {
    func fetchPresence(for userID: UUID) async throws -> Presence
}

protocol CallRepository {
    func fetchActiveCalls(for userID: UUID) async throws -> [InternetCall]
    func fetchCallHistory(for userID: UUID) async throws -> [InternetCall]
    func fetchCall(_ callID: UUID, for userID: UUID) async throws -> InternetCall
    func startAudioCall(with calleeID: UUID, from callerID: UUID) async throws -> InternetCall
    func fetchActiveGroupCall(in chatID: UUID, userID: UUID) async throws -> InternetCall?
    func fetchGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func startGroupAudioCall(in chatID: UUID, from callerID: UUID) async throws -> InternetCall
    func joinGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func leaveGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func answerCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func rejectCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func endCall(_ callID: UUID, userID: UUID) async throws -> InternetCall
    func fetchEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent]
    func fetchGroupEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent]
    func sendOffer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent
    func sendGroupOffer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
    func sendAnswer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent
    func sendGroupAnswer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
    func sendICECandidate(
        _ candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
    func sendGroupICECandidate(
        _ candidate: String,
        to targetUserID: UUID,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
    func sendMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
    func sendGroupMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent
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
    func syncVoIPDeviceToken(_ token: Data) async
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
    func reachablePeer(userID: UUID) async -> OfflinePeer?
    func connect(to peer: OfflinePeer) async throws -> BluetoothSession
    func fetchChats(currentUserID: UUID) async -> [Chat]
    func openChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat
    func fetchMessages(chatID: UUID) async -> [Message]
    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message
    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message
    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, userID: UUID) async throws -> Message
    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, editorID: UUID) async throws -> Message
    func deleteMessage(_ messageID: UUID, in chatID: UUID, requesterID: UUID) async throws -> Message
    func synchronizeArchivedChats(with onlineRepository: ChatRepository, currentUserID: UUID) async
    func importHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat
}

protocol LocalStore {
    func loadDrafts() async -> [Draft]
    func loadDraft(chatID: UUID, mode: ChatMode) async -> Draft?
    func saveDraft(_ draft: Draft) async
    func removeDraft(chatID: UUID, mode: ChatMode) async
    func loadChats(for mode: ChatMode) async -> [Chat]
    func saveChats(_ chats: [Chat], for mode: ChatMode) async
}

extension ChatRepository {
    func importExternalHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat {
        _ = messages
        _ = currentUser
        return chat
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        try await sendMessage(draft, in: chat.id, mode: chat.mode, senderID: senderID)
    }

    func cachedChats(mode: ChatMode, for userID: UUID) async -> [Chat] {
        _ = mode
        _ = userID
        return []
    }

    func cachedMessages(chatID: UUID, mode: ChatMode) async -> [Message] {
        _ = chatID
        _ = mode
        return []
    }

    func prepareModeTransition(_ request: ChatModeTransitionRequest) async throws -> ChatModeTransitionResult {
        _ = request
        return ChatModeTransitionResult(routedChat: nil)
    }

    func retryPendingOutgoingMessages(currentUserID: UUID) async {
        _ = currentUserID
    }

    func cancelPendingOutgoingMessage(clientMessageID: UUID, in chat: Chat, ownerUserID: UUID) async {
        _ = clientMessageID
        _ = chat
        _ = ownerUserID
    }

    func purgeLocalChatArtifacts(chatIDs: [UUID], currentUserID: UUID) async {
        _ = chatIDs
        _ = currentUserID
    }

    func transferGroupOwnership(to memberID: UUID, in chat: Chat, requesterID: UUID) async throws -> Chat {
        _ = memberID
        _ = requesterID
        return chat
    }

    func leaveGroup(_ chat: Chat, requesterID: UUID) async throws {
        _ = chat
        _ = requesterID
    }

    func updateCommunityDetails(_ details: CommunityChatDetails, for chat: Chat, requesterID: UUID) async throws -> Chat {
        _ = details
        _ = requesterID
        return chat
    }

    func searchDiscoverableChats(query: String, mode: ChatMode, currentUserID: UUID) async throws -> [Chat] {
        _ = query
        _ = mode
        _ = currentUserID
        return []
    }

    func joinDiscoverableChat(_ chat: Chat, requesterID: UUID) async throws -> Chat {
        _ = requesterID
        return chat
    }

    func joinChat(inviteCode: String, mode: ChatMode, requesterID: UUID) async throws -> Chat {
        _ = inviteCode
        _ = mode
        _ = requesterID
        throw ChatRepositoryError.chatNotFound
    }

    func submitJoinRequest(for chat: Chat, requesterID: UUID, answers: [String]) async throws {
        _ = chat
        _ = requesterID
        _ = answers
        throw ChatRepositoryError.unsupportedOfflineAction
    }

    func fetchModerationDashboard(for chat: Chat, requesterID: UUID) async throws -> ModerationDashboard {
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func resolveJoinRequest(
        for requesterUserID: UUID,
        approve: Bool,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = requesterUserID
        _ = approve
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func reportChatContent(
        in chat: Chat,
        requesterID: UUID,
        targetMessageID: UUID?,
        targetUserID: UUID?,
        reason: ModerationReportReason,
        details: String?
    ) async throws {
        _ = chat
        _ = requesterID
        _ = targetMessageID
        _ = targetUserID
        _ = reason
        _ = details
    }

    func banMember(
        _ memberID: UUID,
        duration: TimeInterval,
        reason: String?,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = memberID
        _ = duration
        _ = reason
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }

    func removeBan(
        for memberID: UUID,
        in chat: Chat,
        requesterID: UUID
    ) async throws -> ModerationDashboard {
        _ = memberID
        _ = chat
        _ = requesterID
        return ModerationDashboard()
    }
}

extension PushNotificationService {
    func syncVoIPDeviceToken(_ token: Data) async {
        _ = token
    }
}

extension OfflineTransporting {
    func reachablePeer(userID: UUID) async -> OfflinePeer? {
        let peers = await discoveredPeers()
        return peers.first(where: { $0.id == userID && $0.isReachable })
    }

    func importHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat {
        _ = messages
        _ = currentUser
        return chat
    }
}
