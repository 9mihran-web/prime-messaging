import Combine
import Foundation
import OSLog

enum MainTab: Hashable {
    case contacts
    case chats
    case calls
    case settings
}

@MainActor
final class AppState: ObservableObject {
    private let navigationLogger = Logger(subsystem: "mirowin.Prime-Messaging", category: "NavigationState")
    private let navigationDiagnosticsEnabled = ProcessInfo.processInfo.environment["PRIME_NAVIGATION_DIAGNOSTICS"] == "1"
    private enum FeatureAvailability {
        static let smartModeEnabled = false
        static let emergencyModeEnabled = false
    }

    private enum StorageKeys {
        static let selectedMode = "app_state.selected_mode"
        static let lastAppActivityAt = "app_state.last_app_activity_at"
        static let lastSelectedChatID = "app_state.last_selected_chat_id"
        static let lastSelectedChatMode = "app_state.last_selected_chat_mode"
        static let lastSelectedChatConversationKey = "app_state.last_selected_chat_conversation_key"
        static let lastSelectedChatAt = "app_state.last_selected_chat_at"
        static let currentUser = "app_state.current_user"
        static let accounts = "app_state.accounts"
        static let hasCompletedOnboarding = "app_state.has_completed_onboarding"
        static let selectedLanguage = "selected_app_language"
        static let isEmergencyModeEnabled = "app_state.emergency_mode_enabled"
        static let emergencyModeStatus = "app_state.emergency_mode_status"
        static let preEmergencyProfileStatus = "app_state.pre_emergency_profile_status"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let onlineModeRestoreWindow: TimeInterval = 60 * 60 * 24
    private let recentChatRestoreWindow: TimeInterval = 60 * 60 * 6
    private let notificationRouteDuplicateWindow: TimeInterval = 1.2
    private let shareAppGroupIdentifier = "group.prime1.prime-Messaging.shared"
    private let shareRootDirectoryName = "IncomingShare"
    private let mirroredCurrentUserFileName = "current-user.json"
    private var lastQueuedNotificationRoute: NotificationChatRoute?
    private var lastQueuedNotificationRouteAt: Date = .distantPast
    private var pendingNotificationLaunchRoute: NotificationChatRoute?
    private var lastSceneBecameActiveAt: Date?

    @Published var selectedMode: ChatMode = .online {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("selectedMode")
        }
    }
    @Published var selectedMainTab: MainTab = .chats {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("selectedMainTab")
        }
    }
    @Published var selectedChat: Chat? {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("selectedChat")
            persistSelectedChatSelection()
        }
    }
    @Published var routedChat: Chat? {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("routedChat")
        }
    }
    @Published var currentUser: User = .mockCurrentUser
    @Published private(set) var accounts: [User] = []
    @Published var hasCompletedOnboarding = false {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published var selectedLanguage: AppLanguage = .english
    @Published var isShowingAccountAuth = false {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published private(set) var requiresServerSessionValidation = false {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published var isBootstrappingSession = true {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published private(set) var isSceneActive = false {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published private(set) var isChatsRootReady = false {
        didSet {
            assertMainThreadForUIState()
        }
    }
    @Published private(set) var pendingNotificationRoute: NotificationChatRoute? {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("pendingNotificationRoute")
        }
    }
    @Published private(set) var pendingResolvedNotificationChat: Chat? {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("pendingResolvedNotificationChat")
        }
    }
    @Published private(set) var pendingFocusedMessageID: UUID? {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("pendingFocusedMessageID")
        }
    }
    @Published private(set) var notificationRouteQueueRevision: Int = 0 {
        didSet {
            assertMainThreadForUIState()
            logNavigationStateMutation("notificationRouteQueueRevision")
        }
    }
    @Published private(set) var incomingShareDraftRevision: Int = 0
    @Published var isEmergencyModeEnabled = false
    @Published var emergencyModeStatus: EmergencyModeStatus = .safe
    private var pendingIncomingShareDraftsByChatID: [UUID: OutgoingMessageDraft] = [:]

    private func assertMainThreadForUIState(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logNavigationStateMutation(_ field: StaticString) {
        guard navigationDiagnosticsEnabled else { return }
        let message = "NavigationState state mutation field=\(String(describing: field)) main=\(Thread.isMainThread)"
        navigationLogger.notice("\(message, privacy: .public)")
    }

    var isSmartModeAvailable: Bool {
        FeatureAvailability.smartModeEnabled && currentUser.isOfflineOnly == false
    }

    var isEmergencyModeAvailable: Bool {
        FeatureAvailability.emergencyModeEnabled
    }

    var availableModes: [ChatMode] {
        if currentUser.isOfflineOnly {
            return [.offline]
        }
        if isSmartModeAvailable {
            return [.smart, .online, .offline]
        }
        return [.online, .offline]
    }

    struct PersistedChatSelection: Hashable {
        let chatID: UUID
        let mode: ChatMode
        let conversationKey: String
        let savedAt: Date
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawLanguage = defaults.string(forKey: StorageKeys.selectedLanguage), let language = AppLanguage(rawValue: rawLanguage) {
            selectedLanguage = language
        } else {
            defaults.set(AppLanguage.english.rawValue, forKey: StorageKeys.selectedLanguage)
        }

        var restoredCurrentUser: User?
        if let data = defaults.data(forKey: StorageKeys.currentUser), let user = try? decoder.decode(User.self, from: data) {
            currentUser = user
            restoredCurrentUser = user
        }

        if let data = defaults.data(forKey: StorageKeys.accounts), let storedAccounts = try? decoder.decode([User].self, from: data) {
            accounts = storedAccounts
        } else if defaults.data(forKey: StorageKeys.currentUser) != nil {
            accounts = [currentUser]
        }

        if restoredCurrentUser == nil, let recoveredAccount = accounts.first {
            currentUser = recoveredAccount
        }

        selectedMode = restoredSelectedMode(for: currentUser, fallback: preferredDefaultMode(for: currentUser))
        hasCompletedOnboarding = defaults.bool(forKey: StorageKeys.hasCompletedOnboarding)
        requiresServerSessionValidation = false
        isEmergencyModeEnabled = isEmergencyModeAvailable ? defaults.bool(forKey: StorageKeys.isEmergencyModeEnabled) : false
        if let rawEmergencyStatus = defaults.string(forKey: StorageKeys.emergencyModeStatus),
           let storedEmergencyStatus = EmergencyModeStatus(rawValue: rawEmergencyStatus) {
            emergencyModeStatus = storedEmergencyStatus
        }
        applyEmergencyStateIfNeeded()
        mirrorCurrentUserForShareExtension()
    }

    func completeOnboarding(name: String, username: String, contactValue: String, methodType: IdentityMethodType) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = normalizedUsername(username)
        let trimmedContact = contactValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmedName.isEmpty,
            !trimmedContact.isEmpty,
            isValidUsername(trimmedUsername)
        else { return }

        currentUser.profile.displayName = trimmedName
        currentUser.profile.username = trimmedUsername
        currentUser.profile.status = "Ready to connect"
        currentUser.profile.email = methodType == .email ? trimmedContact : nil
        currentUser.profile.phoneNumber = methodType == .phone ? trimmedContact : nil
        currentUser.identityMethods = [
            IdentityMethod(type: methodType, value: trimmedContact, isVerified: true, isPubliclyDiscoverable: true),
            IdentityMethod(type: .username, value: "@\(trimmedUsername)", isVerified: true, isPubliclyDiscoverable: true)
        ]
        hasCompletedOnboarding = true
        persistState()
    }

    func applyAuthenticatedUser(_ user: User, requiresServerSessionValidation: Bool = false) {
        let previousUserWasOfflineOnly = currentUser.isOfflineOnly
        currentUser = user
        applyEmergencyStateIfNeeded()
        hasCompletedOnboarding = true
        isShowingAccountAuth = false
        self.requiresServerSessionValidation = requiresServerSessionValidation
        if user.isOfflineOnly {
            selectedMode = .offline
        } else if previousUserWasOfflineOnly && selectedMode == .offline {
            selectedMode = preferredDefaultMode(for: user)
        }
        selectedChat = nil
        routedChat = nil
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        pendingNotificationLaunchRoute = nil
        selectedMainTab = .chats
        clearPersistedSelectedChatSelection()
        upsertAccount(user)
        persistState()
    }

    func refreshCurrentUserPreservingNavigation(_ user: User) {
        let previousUserWasOfflineOnly = currentUser.isOfflineOnly
        currentUser = user
        applyEmergencyStateIfNeeded()
        hasCompletedOnboarding = true
        isShowingAccountAuth = false
        requiresServerSessionValidation = false
        if user.isOfflineOnly {
            selectedMode = .offline
        } else if previousUserWasOfflineOnly && selectedMode == .offline {
            selectedMode = preferredDefaultMode(for: user)
        }
        upsertAccount(user)
        persistState()
    }

    func updateCurrentUsername(_ username: String) {
        let normalized = normalizedUsername(username)
        guard isValidUsername(normalized) else { return }

        currentUser.profile.username = normalized

        if let usernameIndex = currentUser.identityMethods.firstIndex(where: { $0.type == .username }) {
            currentUser.identityMethods[usernameIndex] = IdentityMethod(
                id: currentUser.identityMethods[usernameIndex].id,
                type: .username,
                value: "@\(normalized)",
                isVerified: currentUser.identityMethods[usernameIndex].isVerified,
                isPubliclyDiscoverable: currentUser.identityMethods[usernameIndex].isPubliclyDiscoverable
            )
        } else {
            currentUser.identityMethods.append(
                IdentityMethod(type: .username, value: "@\(normalized)", isVerified: true, isPubliclyDiscoverable: true)
            )
        }

        upsertAccount(currentUser)
        persistState()
    }

    func updateSelectedMode(_ mode: ChatMode) {
        assertMainThreadForUIState()
        selectedMode = sanitizedMode(mode, for: currentUser)
        defaults.set(selectedMode.rawValue, forKey: StorageKeys.selectedMode)
        recordAppActivity()
    }

    func markSceneBecameActive() {
        assertMainThreadForUIState()
        isSceneActive = true
        lastSceneBecameActiveAt = Date()
        let resolvedMode = restoredSelectedMode(for: currentUser, fallback: selectedMode)
        if resolvedMode != selectedMode {
            selectedMode = resolvedMode
            defaults.set(resolvedMode.rawValue, forKey: StorageKeys.selectedMode)
        }
        recordAppActivity()
    }

    func markSceneMovedToBackground() {
        assertMainThreadForUIState()
        isSceneActive = false
        defaults.set(selectedMode.rawValue, forKey: StorageKeys.selectedMode)
        recordAppActivity()
    }

    func setChatsRootReady(_ isReady: Bool) {
        assertMainThreadForUIState()
        isChatsRootReady = isReady
    }

    func setEmergencyModeEnabled(_ isEnabled: Bool) {
        guard isEmergencyModeAvailable else {
            if isEmergencyModeEnabled {
                isEmergencyModeEnabled = false
                persistState()
            }
            return
        }

        if isEmergencyModeEnabled == isEnabled { return }

        if isEnabled {
            let currentStatus = currentUser.profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentStatus.isEmpty == false,
               currentStatus != emergencyModeStatus.profileStatusText {
                defaults.set(currentStatus, forKey: StorageKeys.preEmergencyProfileStatus)
            }
            currentUser.profile.status = emergencyModeStatus.profileStatusText
        } else {
            let previousStatus = defaults.string(forKey: StorageKeys.preEmergencyProfileStatus)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            currentUser.profile.status = previousStatus.isEmpty ? "Available" : previousStatus
        }

        isEmergencyModeEnabled = isEnabled
        upsertAccount(currentUser)
        persistState()
    }

    func updateEmergencyModeStatus(_ status: EmergencyModeStatus) {
        emergencyModeStatus = status
        if isEmergencyModeEnabled {
            currentUser.profile.status = status.profileStatusText
            upsertAccount(currentUser)
        }
        persistState()
    }

    func updateLanguage(_ language: AppLanguage) {
        selectedLanguage = language
        defaults.set(language.rawValue, forKey: StorageKeys.selectedLanguage)
        objectWillChange.send()
    }

    func beginAddingAccount() {
        isShowingAccountAuth = true
    }

    func cancelAddingAccount() {
        isShowingAccountAuth = false
    }

    func switchToAccount(_ accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let previousUserWasOfflineOnly = currentUser.isOfflineOnly
        currentUser = account
        applyEmergencyStateIfNeeded()
        hasCompletedOnboarding = true
        requiresServerSessionValidation = false
        if account.isOfflineOnly {
            selectedMode = .offline
        } else if previousUserWasOfflineOnly && selectedMode == .offline {
            selectedMode = preferredDefaultMode(for: account)
        }
        selectedChat = nil
        routedChat = nil
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        pendingNotificationLaunchRoute = nil
        selectedMainTab = .chats
        clearPersistedSelectedChatSelection()
        persistState()
    }

    func logOutCurrentAccount() {
        let currentAccountID = currentUser.id
        Task {
            await BackendRequestTransport.removeSession(for: currentAccountID)
        }
        accounts.removeAll(where: { $0.id == currentAccountID })

        if let nextAccount = accounts.first {
            currentUser = nextAccount
            applyEmergencyStateIfNeeded()
            hasCompletedOnboarding = true
            requiresServerSessionValidation = false
            selectedMode = nextAccount.isOfflineOnly ? .offline : preferredDefaultMode(for: nextAccount)
        } else {
            currentUser = .mockCurrentUser
            applyEmergencyStateIfNeeded()
            hasCompletedOnboarding = false
            selectedMode = preferredDefaultMode(for: currentUser)
            requiresServerSessionValidation = false
        }

        isShowingAccountAuth = false
        selectedChat = nil
        routedChat = nil
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        pendingNotificationLaunchRoute = nil
        selectedMainTab = .chats
        clearPersistedSelectedChatSelection()
        persistState()
    }

    func removeAccount(_ accountID: UUID) {
        if accountID == currentUser.id {
            logOutCurrentAccount()
            return
        }

        Task {
            await BackendRequestTransport.removeSession(for: accountID)
        }
        accounts.removeAll(where: { $0.id == accountID })
        persistState()
    }

    func markCurrentServerSessionValidated(with user: User) {
        let previousUserWasOfflineOnly = currentUser.isOfflineOnly
        currentUser = user
        applyEmergencyStateIfNeeded()
        hasCompletedOnboarding = true
        isShowingAccountAuth = false
        requiresServerSessionValidation = false
        if user.isOfflineOnly {
            selectedMode = .offline
        } else if previousUserWasOfflineOnly && selectedMode == .offline {
            selectedMode = preferredDefaultMode(for: user)
        }
        selectedChat = nil
        routedChat = nil
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        pendingNotificationLaunchRoute = nil
        selectedMainTab = .chats
        clearPersistedSelectedChatSelection()
        upsertAccount(user)
        persistState()
    }

    func deferCurrentServerSessionValidation() {
        hasCompletedOnboarding = true
        isShowingAccountAuth = false
        requiresServerSessionValidation = false
        upsertAccount(currentUser)
        persistState()
    }

    func finishSessionBootstrap() {
        isBootstrappingSession = false
    }

    func queueNotificationRoute(_ route: NotificationChatRoute) {
        assertMainThreadForUIState()
        _ = enqueueNotificationRoute(route)
    }

    @discardableResult
    func enqueueNotificationRoute(_ route: NotificationChatRoute) -> Bool {
        assertMainThreadForUIState()
        let now = Date()
        if let pendingNotificationRoute, pendingNotificationRoute == route {
            return false
        }
        if let lastQueuedNotificationRoute,
           lastQueuedNotificationRoute == route,
           now.timeIntervalSince(lastQueuedNotificationRouteAt) <= notificationRouteDuplicateWindow {
            return false
        }

        pendingNotificationRoute = route
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = route.messageID
        pendingNotificationLaunchRoute = route
        notificationRouteQueueRevision &+= 1
        lastQueuedNotificationRoute = route
        lastQueuedNotificationRouteAt = now
        return true
    }

    func clearPendingNotificationRoute(clearLaunchContext: Bool = false) {
        assertMainThreadForUIState()
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        if clearLaunchContext {
            pendingNotificationLaunchRoute = nil
        }
        notificationRouteQueueRevision &+= 1
    }

    func fallbackToChatListAfterNotificationFailure(expectedRoute: NotificationChatRoute? = nil) {
        assertMainThreadForUIState()
        if let expectedRoute, let pendingNotificationRoute, pendingNotificationRoute != expectedRoute {
            return
        }
        selectedMainTab = .chats
        selectedChat = nil
        routedChat = nil
        clearPendingNotificationRoute(clearLaunchContext: true)
    }

    func resolvePendingNotificationRoute(with chats: [Chat]) -> Chat? {
        assertMainThreadForUIState()
        guard let route = pendingNotificationRoute else { return nil }
        guard let chat = chats.first(where: { $0.id == route.chatID }) else { return nil }

        pendingNotificationRoute = nil
        routeToChat(chat)
        return chat
    }

    func queueResolvedNotificationChat(_ chat: Chat, expectedRoute: NotificationChatRoute) {
        assertMainThreadForUIState()
        guard let pendingNotificationRoute, pendingNotificationRoute == expectedRoute else { return }
        pendingResolvedNotificationChat = chat
        notificationRouteQueueRevision &+= 1
    }

    @discardableResult
    func commitQueuedNotificationNavigationIfPossible() -> Bool {
        assertMainThreadForUIState()
        guard let pendingNotificationRoute, let chat = pendingResolvedNotificationChat else { return false }
        guard isSceneActive, hasCompletedOnboarding, isBootstrappingSession == false else { return false }

        if selectedMainTab != .chats {
            selectedMainTab = .chats
            notificationRouteQueueRevision &+= 1
            return false
        }

        guard isChatsRootReady else { return false }

        updateSelectedMode(pendingNotificationRoute.mode)
        selectedChat = chat
        routedChat = chat
        self.pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        if let pendingNotificationLaunchRoute,
           pendingNotificationLaunchRoute.chatID != chat.id {
            self.pendingNotificationLaunchRoute = nil
        }
        notificationRouteQueueRevision &+= 1
        return true
    }

    func routeToChat(_ chat: Chat) {
        assertMainThreadForUIState()
        updateSelectedMode(chat.mode)
        pendingNotificationRoute = nil
        pendingResolvedNotificationChat = nil
        pendingFocusedMessageID = nil
        if let pendingNotificationLaunchRoute,
           pendingNotificationLaunchRoute.chatID != chat.id {
            self.pendingNotificationLaunchRoute = nil
        }
        selectedMainTab = .chats

        if selectedChat?.id == chat.id, routedChat?.id == chat.id {
            selectedChat = chat
            routedChat = chat
            return
        }

        selectedChat = chat
        routedChat = chat
    }

    func routeToChatAfterCurrentTransition(_ chat: Chat) {
        assertMainThreadForUIState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard Task.isCancelled == false else { return }
            self.routeToChat(chat)
        }
    }

    func stageIncomingShareDraft(_ draft: OutgoingMessageDraft, for chatID: UUID) {
        assertMainThreadForUIState()
        pendingIncomingShareDraftsByChatID[chatID] = draft
        incomingShareDraftRevision &+= 1
    }

    func consumeIncomingShareDraft(for chatID: UUID) -> OutgoingMessageDraft? {
        assertMainThreadForUIState()
        let draft = pendingIncomingShareDraftsByChatID.removeValue(forKey: chatID)
        if draft != nil {
            incomingShareDraftRevision &+= 1
        }
        return draft
    }

    func consumeFocusedMessageID(for chatID: UUID) -> UUID? {
        guard selectedChat?.id == chatID || routedChat?.id == chatID || pendingNotificationRoute?.chatID == chatID else {
            return nil
        }

        let messageID = pendingFocusedMessageID
        pendingFocusedMessageID = nil
        return messageID
    }

    func consumeNotificationLaunchRoute(for chatID: UUID) -> NotificationChatRoute? {
        guard let route = pendingNotificationLaunchRoute else { return nil }
        guard route.chatID == chatID else { return nil }
        pendingNotificationLaunchRoute = nil
        return route
    }

    func hasPendingNotificationLaunchRoute(for chatID: UUID) -> Bool {
        pendingNotificationLaunchRoute?.chatID == chatID
    }

    func pendingNotificationActivationSettleDelay(minimumActiveDuration: TimeInterval = 1.35) -> Duration? {
        assertMainThreadForUIState()
        guard let lastSceneBecameActiveAt else { return nil }
        guard pendingNotificationRoute != nil || pendingResolvedNotificationChat != nil else { return nil }

        let activeDuration = Date().timeIntervalSince(lastSceneBecameActiveAt)
        guard activeDuration < minimumActiveDuration else { return nil }

        let remainingDelay = minimumActiveDuration - activeDuration
        guard remainingDelay > 0 else { return nil }
        return .milliseconds(Int64(remainingDelay * 1000))
    }

    func clearRoutedChat() {
        assertMainThreadForUIState()
        routedChat = nil
    }

    func forgetChatRoutes(chatIDs: Set<UUID>) {
        assertMainThreadForUIState()
        guard chatIDs.isEmpty == false else { return }

        if let selectedChat, chatIDs.contains(selectedChat.id) {
            self.selectedChat = nil
        }
        if let routedChat, chatIDs.contains(routedChat.id) {
            self.routedChat = nil
        }
        if let pendingNotificationRoute, chatIDs.contains(pendingNotificationRoute.chatID) {
            self.pendingNotificationRoute = nil
        }
        if let pendingResolvedNotificationChat, chatIDs.contains(pendingResolvedNotificationChat.id) {
            self.pendingResolvedNotificationChat = nil
        }
        if let pendingNotificationLaunchRoute, chatIDs.contains(pendingNotificationLaunchRoute.chatID) {
            self.pendingNotificationLaunchRoute = nil
        }
        if pendingFocusedMessageID != nil,
           selectedChat == nil,
           routedChat == nil,
           pendingNotificationRoute == nil {
            pendingFocusedMessageID = nil
        }
    }

    func restorableSelectedChatSelection(now: Date = .now) -> PersistedChatSelection? {
        guard
            let rawID = defaults.string(forKey: StorageKeys.lastSelectedChatID),
            let chatID = UUID(uuidString: rawID),
            let rawMode = defaults.string(forKey: StorageKeys.lastSelectedChatMode),
            let mode = ChatMode(rawValue: rawMode),
            let conversationKey = defaults.string(forKey: StorageKeys.lastSelectedChatConversationKey)
        else {
            return nil
        }

        let savedTimestamp = defaults.double(forKey: StorageKeys.lastSelectedChatAt)
        guard savedTimestamp > 0 else { return nil }

        let savedAt = Date(timeIntervalSince1970: savedTimestamp)
        guard now.timeIntervalSince(savedAt) <= recentChatRestoreWindow else { return nil }

        return PersistedChatSelection(
            chatID: chatID,
            mode: mode,
            conversationKey: conversationKey,
            savedAt: savedAt
        )
    }

    func normalizedUsername(_ username: String) -> String {
        let lowered = username.lowercased()
        let allowed = lowered.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        return String(allowed.prefix(32))
    }

    func isValidUsername(_ username: String, minimumLength: Int = 5) -> Bool {
        guard username.count >= minimumLength, username.count <= 32 else { return false }
        return username.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
    }

    func isValidLegacyUsername(_ username: String) -> Bool {
        isValidUsername(username, minimumLength: 3)
    }

    func isValidInternationalPhoneNumber(_ phoneNumber: String) -> Bool {
        guard phoneNumber.hasPrefix("+") else { return false }
        let digits = phoneNumber.dropFirst()
        guard digits.count >= 7, digits.count <= 15 else { return false }
        return digits.allSatisfy(\.isNumber)
    }

    func normalizedInternationalPhoneNumber(countryCode: String, localNumber: String) -> String {
        let pastedInternationalNumber = localNumber.filter { $0 == "+" || $0.isNumber }
        if pastedInternationalNumber.hasPrefix("+") {
            return pastedInternationalNumber
        }

        let normalizedCountryCode = countryCode.filter { $0 == "+" || $0.isNumber }
        let normalizedLocalNumber = localNumber.filter(\.isNumber)
        let combined = normalizedCountryCode.hasPrefix("+") ? normalizedCountryCode + normalizedLocalNumber : "+\(normalizedCountryCode)\(normalizedLocalNumber)"
        return combined
    }

    func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false else { return false }
        return parts[1].contains(".")
    }

    func generatedGuestUsername(seed: UUID = UUID()) -> String {
        "guest-\(seed.uuidString.replacingOccurrences(of: "-", with: "").prefix(7).lowercased())"
    }

    private func persistState() {
        defaults.set(hasCompletedOnboarding, forKey: StorageKeys.hasCompletedOnboarding)
        defaults.set(selectedMode.rawValue, forKey: StorageKeys.selectedMode)
        defaults.set(selectedLanguage.rawValue, forKey: StorageKeys.selectedLanguage)
        defaults.set(isEmergencyModeEnabled, forKey: StorageKeys.isEmergencyModeEnabled)
        defaults.set(emergencyModeStatus.rawValue, forKey: StorageKeys.emergencyModeStatus)

        if let data = try? encoder.encode(currentUser) {
            defaults.set(data, forKey: StorageKeys.currentUser)
        }

        if let data = try? encoder.encode(accounts) {
            defaults.set(data, forKey: StorageKeys.accounts)
        }

        mirrorCurrentUserForShareExtension()
    }

    private func mirrorCurrentUserForShareExtension() {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: shareAppGroupIdentifier) else {
            return
        }
        let directory = containerURL.appendingPathComponent(shareRootDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let mirrorURL = directory.appendingPathComponent(mirroredCurrentUserFileName, isDirectory: false)
        if let data = try? encoder.encode(currentUser) {
            try? data.write(to: mirrorURL, options: .atomic)
        }
    }

    private func persistSelectedChatSelection(now: Date = .now) {
        guard let selectedChat else { return }

        defaults.set(selectedChat.id.uuidString, forKey: StorageKeys.lastSelectedChatID)
        defaults.set(selectedChat.mode.rawValue, forKey: StorageKeys.lastSelectedChatMode)
        defaults.set(
            conversationKey(for: selectedChat, currentUserID: currentUser.id),
            forKey: StorageKeys.lastSelectedChatConversationKey
        )
        defaults.set(now.timeIntervalSince1970, forKey: StorageKeys.lastSelectedChatAt)
    }

    private func clearPersistedSelectedChatSelection() {
        defaults.removeObject(forKey: StorageKeys.lastSelectedChatID)
        defaults.removeObject(forKey: StorageKeys.lastSelectedChatMode)
        defaults.removeObject(forKey: StorageKeys.lastSelectedChatConversationKey)
        defaults.removeObject(forKey: StorageKeys.lastSelectedChatAt)
    }

    private func upsertAccount(_ user: User) {
        if let existingIndex = accounts.firstIndex(where: { $0.id == user.id }) {
            accounts[existingIndex] = user
        } else {
            accounts.insert(user, at: 0)
        }
    }

    private func applyEmergencyStateIfNeeded() {
        guard isEmergencyModeAvailable else {
            isEmergencyModeEnabled = false
            return
        }
        guard isEmergencyModeEnabled else { return }
        currentUser.profile.status = emergencyModeStatus.profileStatusText
    }

    private func restoredSelectedMode(for user: User, fallback: ChatMode = .online, now: Date = .now) -> ChatMode {
        guard user.isOfflineOnly == false else { return .offline }

        guard
            let storedRawMode = defaults.string(forKey: StorageKeys.selectedMode),
            let storedMode = ChatMode(rawValue: storedRawMode)
        else {
            return fallback
        }

        if storedMode == .smart, FeatureAvailability.smartModeEnabled == false {
            return fallback
        }

        if storedMode == .online, shouldExpireStoredOnlineMode(now: now) {
            return FeatureAvailability.smartModeEnabled ? .smart : .online
        }

        return sanitizedMode(storedMode, for: user)
    }

    private func shouldExpireStoredOnlineMode(now: Date) -> Bool {
        guard let lastActivityAt = defaults.object(forKey: StorageKeys.lastAppActivityAt) as? Double else {
            return false
        }

        return now.timeIntervalSince1970 - lastActivityAt >= onlineModeRestoreWindow
    }

    private func recordAppActivity(_ date: Date = .now) {
        defaults.set(date.timeIntervalSince1970, forKey: StorageKeys.lastAppActivityAt)
    }

    private func preferredDefaultMode(for user: User) -> ChatMode {
        user.isOfflineOnly ? .offline : (FeatureAvailability.smartModeEnabled ? .smart : .online)
    }

    private func sanitizedMode(_ mode: ChatMode, for user: User) -> ChatMode {
        guard user.isOfflineOnly == false else { return .offline }
        guard FeatureAvailability.smartModeEnabled || mode != .smart else {
            return .online
        }
        return mode
    }

    private func conversationKey(for chat: Chat, currentUserID: UUID) -> String {
        switch chat.type {
        case .selfChat:
            return "self:\(currentUserID.uuidString)"
        case .direct:
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "direct:\(participantKey)"
        case .group:
            return "group:\(chat.group?.id.uuidString ?? chat.id.uuidString)"
        case .secret:
            return "secret:\(chat.id.uuidString)"
        }
    }
}
