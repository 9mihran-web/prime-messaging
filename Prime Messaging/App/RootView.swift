import SwiftUI
import Combine
import CryptoKit
import OSLog
#if os(iOS) && canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if os(iOS) && canImport(LocalAuthentication)
import LocalAuthentication
#endif

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notificationRouteStore = NotificationRouteStore.shared
    @ObservedObject private var notificationCallRouteStore = NotificationCallRouteStore.shared
    @ObservedObject private var internetCallManager = InternetCallManager.shared
    @State private var isShowingOnlineRecoveryAlert = false
    @State private var hasPromptedForCurrentNetworkLoss = false
    @State private var isApplyingOnlineRecoveryMode = false
    @State private var previousUsableChatNetwork: Bool?
    @ObservedObject private var appLockStore = AppLockStore.shared
    private let startupLogger = Logger(subsystem: "mirowin.Prime-Messaging", category: "Startup")

    var body: some View {
        ZStack {
            SwiftUI.Group {
                if appState.hasCompletedOnboarding {
                    MainTabView()
                        .id(appState.currentUser.id)
                } else {
                    NavigationStack {
                        OnboardingView()
                    }
                }
            }
            if appState.isBootstrappingSession {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading account…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .zIndex(10)
            }
            if appLockStore.isLocked {
                AppLockOverlayView(
                    isBiometricEnabled: appLockStore.usesBiometrics,
                    isUnlocking: appLockStore.isUnlocking,
                    statusText: appLockStore.statusText,
                    onUnlock: { passcode in
                        Task {
                            await appLockStore.unlockIfNeeded(passcode: passcode)
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(20)
            }
        }
        .tint(PrimeTheme.Colors.accent)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: appLockStore.isLocked)
        .alert("network.recovery.title".localized, isPresented: $isShowingOnlineRecoveryAlert) {
            Button("network.recovery.offline".localized) {
                Task {
                    await applyOnlineRecoveryMode(.offline)
                }
            }
            Button("network.recovery.smart".localized) {
                Task {
                    await applyOnlineRecoveryMode(.smart)
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("network.recovery.message".localized)
        }
        .task {
            let startupFailOpenTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                if appState.isBootstrappingSession {
                    startupLogger.error("Session bootstrap exceeded 2.5s. Forcing UI fail-open.")
                    appState.finishSessionBootstrap()
                }
            }
            await bootstrapPersistedSessionIfNeeded()
            startupFailOpenTask.cancel()
            await consumePendingNotificationRouteIfNeeded()
            consumePendingCallNotificationRouteIfNeeded()
            evaluateConnectivityPrompt()
            appLockStore.handleSceneBecameActive()
        }
        .sheet(
            isPresented: Binding(
                get: { appState.hasCompletedOnboarding && appState.isShowingAccountAuth },
                set: { isPresented in
                    if !isPresented {
                        appState.cancelAddingAccount()
                    }
                }
            )
        ) {
            NavigationStack {
                OnboardingView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("common.cancel".localized) {
                                appState.cancelAddingAccount()
                            }
                        }
                    }
            }
        }
        .onChange(of: notificationRouteStore.pendingRoute) { newValue in
            guard let route = newValue else { return }
            _ = notificationRouteStore.consume()
            Task { @MainActor in
                await handleNotificationChatRoute(route)
            }
        }
        .onChange(of: notificationCallRouteStore.pendingRoute) { newValue in
            guard let newValue else { return }
            internetCallManager.queueIncomingCallFromPush(callID: newValue.callID, callerName: newValue.callerName)
            _ = notificationCallRouteStore.consume()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDidRegisterDeviceToken)) { notification in
            guard let token = notification.object as? Data else { return }
            Task {
                await environment.pushNotificationService.syncDeviceToken(token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDidRegisterVoIPDeviceToken)) { notification in
            guard let token = notification.object as? Data else { return }
            Task {
                await environment.pushNotificationService.syncVoIPDeviceToken(token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingReachabilityChanged)) { notification in
            if let snapshot = notification.userInfo?["snapshot"] as? NetworkConnectionSnapshot,
               snapshot.isSatisfied {
                Task {
                    await environment.chatRepository.retryPendingOutgoingMessages(currentUserID: appState.currentUser.id)
                    await refreshActiveChatContinuityIfNeeded()
                }
            }
            evaluateConnectivityPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appLockStore.handleSceneBecameActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appLockStore.handleSceneMovedToBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged)) { _ in
            Task {
                await synchronizeWatchExperience(reason: "chat-snapshots")
            }
        }
        .onChange(of: appState.selectedMode) { _ in
            evaluateConnectivityPrompt()
        }
        .onOpenURL { url in
            Task {
                await handleIncomingURL(url)
            }
        }
        .task(id: rootTaskID) {
            guard appState.isBootstrappingSession == false else { return }
            if appState.hasCompletedOnboarding {
                let isValidSession = await validateCurrentServerSessionIfNeeded()
                guard isValidSession, appState.hasCompletedOnboarding else { return }

                internetCallManager.configure(
                    currentUserID: appState.currentUser.id,
                    repository: environment.callRepository
                )
                await environment.pushNotificationService.registerForRemoteNotifications()
                await environment.pushNotificationService.startMonitoring(
                    currentUser: appState.currentUser,
                    chatRepository: environment.chatRepository
                )
                await synchronizeModeServices()
                await restoreRecentChatContinuityIfNeeded()
            } else {
                internetCallManager.stopMonitoring()
                await environment.pushNotificationService.stopMonitoring()
                await environment.offlineTransport.stopScanning()
            }
        }
        .task(id: modeServicesTaskID) {
            guard appState.isBootstrappingSession == false else { return }
            guard appState.hasCompletedOnboarding else { return }
            await synchronizeModeServices()
        }
        .task(id: prewarmTaskID) {
            guard appState.isBootstrappingSession == false else { return }
            guard appState.hasCompletedOnboarding else { return }
            await prewarmCachedChatContent()
        }
        .task(id: watchSyncTaskID) {
            await synchronizeWatchExperience(reason: "watch-task")
        }
        .task(id: appState.selectedChat?.id.uuidString ?? "no-active-chat") {
            await environment.pushNotificationService.updateActiveChat(appState.selectedChat)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { internetCallManager.isPresentingCallUI && internetCallManager.activeCall != nil },
                set: { isPresented in
                    if !isPresented {
                        internetCallManager.dismissCallUI()
                    }
                }
            )
        ) {
            if let call = internetCallManager.activeCall {
                InternetCallView(call: call)
            }
        }
    }

    private var rootTaskID: String {
        "\(appState.isBootstrappingSession)-\(appState.hasCompletedOnboarding)-\(appState.currentUser.id.uuidString)-\(appState.currentUser.profile.username)"
    }

    private var modeServicesTaskID: String {
        "\(appState.currentUser.id.uuidString)-\(appState.selectedMode.rawValue)-\(appState.isEmergencyModeEnabled)-\(NetworkUsagePolicy.hasReachableNetwork())"
    }

    private var prewarmTaskID: String {
        "\(appState.currentUser.id.uuidString)-\(appState.selectedMode.rawValue)-\(appState.isEmergencyModeEnabled)-\(appState.hasCompletedOnboarding)"
    }

    private var watchSyncTaskID: String {
        "\(appState.isBootstrappingSession)-\(appState.hasCompletedOnboarding)-\(appState.currentUser.id.uuidString)-\(appState.selectedMode.rawValue)"
    }

    private var activeTransitionChat: Chat? {
        appState.routedChat ?? appState.selectedChat
    }

    private func synchronizeModeServices() async {
        await environment.offlineTransport.updateCurrentUser(appState.currentUser)

        if appState.isEmergencyModeEnabled {
            await environment.offlineTransport.startScanning()
        } else {
            switch appState.selectedMode {
            case .smart, .offline:
                await environment.offlineTransport.startScanning()
            case .online:
                await environment.offlineTransport.stopScanning()
            }
        }

        guard appState.selectedMode != .offline || appState.isEmergencyModeEnabled else { return }
        guard NetworkUsagePolicy.hasReachableNetwork() else { return }

        await environment.chatRepository.retryPendingOutgoingMessages(currentUserID: appState.currentUser.id)
    }

    private func prewarmCachedChatContent() async {
        let currentUserID = appState.currentUser.id
        let modesToWarm = orderedPrewarmModes(for: appState.selectedMode)
        let maxChatsToWarm = appState.isEmergencyModeEnabled ? 4 : 12

        var warmedChats: [Chat] = []
        var seenConversationKeys = Set<String>()

        for mode in modesToWarm {
            let cachedChats = await environment.chatRepository.cachedChats(mode: mode, for: currentUserID)
            for chat in cachedChats {
                let key = conversationKey(for: chat, currentUserID: currentUserID)
                guard seenConversationKeys.insert(key).inserted else { continue }
                warmedChats.append(chat)
                if warmedChats.count >= maxChatsToWarm {
                    break
                }
            }
            if warmedChats.count >= maxChatsToWarm {
                break
            }
        }

        let avatarURLs = warmedChats.compactMap { avatarURL(for: $0, currentUserID: currentUserID) }
        await RemoteAssetCacheStore.shared.prewarm(urls: avatarURLs, limit: appState.isEmergencyModeEnabled ? 6 : 18)

        guard appState.isEmergencyModeEnabled == false else { return }

        var mediaRequests: [RemoteAssetWarmupRequest] = []
        for chat in warmedChats.prefix(5) {
            let cachedMessages = await environment.chatRepository.cachedMessages(chatID: chat.id, mode: chat.mode)
            for message in cachedMessages.suffix(8) {
                mediaRequests.append(contentsOf: remoteAssetRequests(for: message))
            }
        }
        await RemoteAssetCacheStore.shared.prewarm(requests: mediaRequests, limit: 32)
    }

    @MainActor
    private func consumePendingNotificationRouteIfNeeded() async {
        guard let route = notificationRouteStore.consume() else { return }
        await handleNotificationChatRoute(route)
    }

    @MainActor
    private func consumePendingCallNotificationRouteIfNeeded() {
        guard let route = notificationCallRouteStore.consume() else { return }
        internetCallManager.queueIncomingCallFromPush(callID: route.callID, callerName: route.callerName)
    }

    @MainActor
    private func handleNotificationChatRoute(_ route: NotificationChatRoute) async {
        appState.queueNotificationRoute(route)
        guard appState.isBootstrappingSession == false else { return }
        guard appState.hasCompletedOnboarding else { return }

        if appState.selectedMode != route.mode {
            appState.updateSelectedMode(route.mode)
        }

        do {
            let chats = try await environment.chatRepository.fetchChats(mode: route.mode, for: appState.currentUser.id)
            if let matchedChat = chats.first(where: { $0.id == route.chatID }) {
                appState.routeToChatAfterCurrentTransition(matchedChat)
            }
        } catch {
            // Keep pending route queued; ChatListView will resolve it once data refresh succeeds.
        }
    }

    @MainActor
    private func evaluateConnectivityPrompt() {
        let hasUsableNetwork = NetworkUsagePolicy.hasReachableNetwork()
        defer {
            previousUsableChatNetwork = hasUsableNetwork
        }

        guard appState.isBootstrappingSession == false, appState.hasCompletedOnboarding else {
            isShowingOnlineRecoveryAlert = false
            return
        }

        guard appState.selectedMode == .online else {
            hasPromptedForCurrentNetworkLoss = false
            isShowingOnlineRecoveryAlert = false
            return
        }

        guard hasUsableNetwork == false else {
            hasPromptedForCurrentNetworkLoss = false
            isShowingOnlineRecoveryAlert = false
            return
        }

        guard previousUsableChatNetwork == true else {
            isShowingOnlineRecoveryAlert = false
            return
        }

        guard hasPromptedForCurrentNetworkLoss == false else { return }
        hasPromptedForCurrentNetworkLoss = true
        isShowingOnlineRecoveryAlert = true
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) async {
        guard appState.hasCompletedOnboarding else { return }
        guard url.scheme?.lowercased() == "primemessaging" else { return }
        guard url.host?.lowercased() == "join" else { return }

        let inviteCode = url.pathComponents.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard inviteCode.isEmpty == false else { return }

        let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode

        do {
            let joinedChat = try await environment.chatRepository.joinChat(
                inviteCode: inviteCode,
                mode: preferredMode,
                requesterID: appState.currentUser.id
            )
            if appState.selectedMode != preferredMode {
                appState.updateSelectedMode(preferredMode)
            }
            appState.routeToChatAfterCurrentTransition(joinedChat)
        } catch {
            // Keep the app stable even if the invite is stale or invalid.
        }
    }

    @MainActor
    private func applyOnlineRecoveryMode(_ mode: ChatMode) async {
        guard isApplyingOnlineRecoveryMode == false else { return }
        guard mode != appState.selectedMode else { return }

        isApplyingOnlineRecoveryMode = true
        defer { isApplyingOnlineRecoveryMode = false }

        if mode == .offline {
            let request = ChatModeTransitionRequest(
                fromMode: appState.selectedMode,
                toMode: mode,
                currentUser: appState.currentUser,
                activeChat: activeTransitionChat
            )
            appState.updateSelectedMode(.offline)
            isShowingOnlineRecoveryAlert = false

            Task(priority: .utility) {
                _ = try? await environment.chatRepository.prepareModeTransition(request)
            }
            return
        }

        do {
            let transition = try await environment.chatRepository.prepareModeTransition(
                ChatModeTransitionRequest(
                    fromMode: appState.selectedMode,
                    toMode: mode,
                    currentUser: appState.currentUser,
                    activeChat: activeTransitionChat
                )
            )
            appState.updateSelectedMode(mode)
            isShowingOnlineRecoveryAlert = false

            if let routedChat = transition.routedChat {
                appState.routeToChatAfterCurrentTransition(routedChat)
            }
        } catch {
            isShowingOnlineRecoveryAlert = false
        }
    }

    @MainActor
    private func bootstrapPersistedSessionIfNeeded() async {
        startupLogger.info("Session bootstrap started.")
        appState.finishSessionBootstrap()

        let storedSessions = await AuthSessionStore.shared.allSessions()
        let shouldValidateOnServer = BackendConfiguration.currentBaseURL != nil

        if let launchUser = await preferredLaunchUser(storedSessions: storedSessions) {
            appState.applyAuthenticatedUser(
                launchUser,
                requiresServerSessionValidation: shouldValidateOnServer
            )
            startupLogger.info("Session bootstrap restored user \(launchUser.id.uuidString, privacy: .public)")
            return
        }

        if appState.hasCompletedOnboarding {
            appState.logOutCurrentAccount()
            startupLogger.info("Session bootstrap removed stale onboarded state (no recoverable session).")
        }
        startupLogger.info("Session bootstrap finished.")
    }

    @MainActor
    private func cachedLaunchUser(for userID: UUID) async -> User? {
        if appState.hasCompletedOnboarding, appState.currentUser.id == userID {
            return appState.currentUser
        }

        if let cachedAccount = appState.accounts.first(where: { $0.id == userID }) {
            return cachedAccount
        }

        if let locallyStoredUser = try? await LocalAccountStore.shared.refreshUser(userID: userID) {
            return locallyStoredUser
        }

        return nil
    }

    @MainActor
    private func validateCurrentServerSessionIfNeeded() async -> Bool {
        guard appState.hasCompletedOnboarding else { return false }
        guard appState.requiresServerSessionValidation else { return true }
        guard BackendConfiguration.currentBaseURL != nil else { return true }

        let storedSessions = await AuthSessionStore.shared.allSessions()
        guard storedSessions.contains(where: { $0.userID == appState.currentUser.id }) else {
            if let restoredUser = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id) {
                appState.markCurrentServerSessionValidated(with: restoredUser)
                return true
            }
            if await LocalAccountStore.shared.credentials(for: appState.currentUser.id) != nil {
                appState.deferCurrentServerSessionValidation()
                return true
            }
            if let fallbackUser = await fallbackLaunchUser(
                storedSessions: storedSessions,
                excluding: appState.currentUser.id
            ) {
                appState.applyAuthenticatedUser(
                    fallbackUser,
                    requiresServerSessionValidation: true
                )
                return false
            }
            appState.logOutCurrentAccount()
            return false
        }

        do {
            let refreshedUser = try await environment.authRepository.refreshUser(userID: appState.currentUser.id)
            appState.markCurrentServerSessionValidated(with: refreshedUser)
            return true
        } catch AuthRepositoryError.accountNotFound {
            await BackendRequestTransport.removeSession(for: appState.currentUser.id)
            if let fallbackUser = await fallbackLaunchUser(
                storedSessions: await AuthSessionStore.shared.allSessions(),
                excluding: appState.currentUser.id
            ) {
                appState.applyAuthenticatedUser(
                    fallbackUser,
                    requiresServerSessionValidation: true
                )
                return false
            }
            appState.logOutCurrentAccount()
            return false
        } catch AuthRepositoryError.invalidCredentials {
            await BackendRequestTransport.removeSession(for: appState.currentUser.id)
            if let fallbackUser = await fallbackLaunchUser(
                storedSessions: await AuthSessionStore.shared.allSessions(),
                excluding: appState.currentUser.id
            ) {
                appState.applyAuthenticatedUser(
                    fallbackUser,
                    requiresServerSessionValidation: true
                )
                return false
            }
            appState.logOutCurrentAccount()
            return false
        } catch {
            return true
        }
    }

    @MainActor
    private func restoreSessionSilentlyIfPossible(for userID: UUID) async -> User? {
        guard let credentials = await LocalAccountStore.shared.credentials(for: userID) else {
            return nil
        }

        do {
            return try await environment.authRepository.logIn(
                identifier: credentials.identifier,
                password: credentials.password
            )
        } catch {
            return nil
        }
    }

    @MainActor
    private func preferredLaunchUser(storedSessions: [AuthSession]) async -> User? {
        if appState.hasCompletedOnboarding,
           await isRecoverableAccount(appState.currentUser.id, storedSessions: storedSessions),
           let cachedUser = await cachedLaunchUser(for: appState.currentUser.id) {
            return cachedUser
        }

        if let fallbackUser = await fallbackLaunchUser(storedSessions: storedSessions, excluding: nil) {
            return fallbackUser
        }

        return nil
    }

    @MainActor
    private func fallbackLaunchUser(storedSessions: [AuthSession], excluding excludedUserID: UUID?) async -> User? {
        for session in storedSessions where session.userID != excludedUserID {
            if let cachedUser = await cachedLaunchUser(for: session.userID) {
                return cachedUser
            }
        }

        let candidateIDs = [appState.currentUser.id] + appState.accounts.map(\.id)
        var seenIDs = Set<UUID>()

        for candidateID in candidateIDs where candidateID != excludedUserID {
            guard seenIDs.insert(candidateID).inserted else { continue }
            guard await isRecoverableAccount(candidateID, storedSessions: storedSessions) else { continue }
            if let cachedUser = await cachedLaunchUser(for: candidateID) {
                return cachedUser
            }
        }

        return nil
    }

    private func isRecoverableAccount(_ userID: UUID, storedSessions: [AuthSession]) async -> Bool {
        if storedSessions.contains(where: { $0.userID == userID }) {
            return true
        }

        if await LocalAccountStore.shared.remoteRecoveryAccount(for: userID) != nil {
            return true
        }

        return await LocalAccountStore.shared.credentials(for: userID) != nil
    }

    @MainActor
    private func restoreRecentChatContinuityIfNeeded() async {
        guard appState.hasCompletedOnboarding else { return }
        guard appState.selectedChat == nil, appState.routedChat == nil else { return }
        guard let selection = appState.restorableSelectedChatSelection() else { return }

        guard let restoredChat = await resolveContinuityChat(for: selection) else { return }
        appState.routeToChat(restoredChat)
        _ = try? await environment.chatRepository.fetchMessages(chatID: restoredChat.id, mode: restoredChat.mode)
    }

    @MainActor
    private func refreshActiveChatContinuityIfNeeded() async {
        guard appState.hasCompletedOnboarding else { return }

        if let activeChat = appState.routedChat ?? appState.selectedChat {
            let selection = AppState.PersistedChatSelection(
                chatID: activeChat.id,
                mode: activeChat.mode,
                conversationKey: conversationKey(for: activeChat, currentUserID: appState.currentUser.id),
                savedAt: .now
            )

            guard let refreshedChat = await resolveContinuityChat(for: selection) else { return }
            if appState.selectedChat?.id == activeChat.id {
                appState.selectedChat = refreshedChat
            }
            if appState.routedChat?.id == activeChat.id {
                appState.routedChat = refreshedChat
            }
            _ = try? await environment.chatRepository.fetchMessages(chatID: refreshedChat.id, mode: refreshedChat.mode)
            return
        }

        await restoreRecentChatContinuityIfNeeded()
    }

    private func resolveContinuityChat(for selection: AppState.PersistedChatSelection) async -> Chat? {
        let currentUserID = appState.currentUser.id
        let candidateModes = orderedContinuityModes(primary: selection.mode, currentSelection: appState.selectedMode)

        var cachedCandidates: [Chat] = []
        for mode in candidateModes {
            cachedCandidates.append(contentsOf: await environment.chatRepository.cachedChats(mode: mode, for: currentUserID))
        }
        if let resolved = matchingContinuityChat(
            from: cachedCandidates,
            chatID: selection.chatID,
            conversationKeyValue: selection.conversationKey,
            currentUserID: currentUserID
        ) {
            return resolved
        }

        guard NetworkUsagePolicy.canUseChatSyncNetwork() else {
            return nil
        }

        for mode in candidateModes where mode != .offline {
            if let fetchedChats = try? await environment.chatRepository.fetchChats(mode: mode, for: currentUserID),
               let resolved = matchingContinuityChat(
                   from: fetchedChats,
                   chatID: selection.chatID,
                   conversationKeyValue: selection.conversationKey,
                   currentUserID: currentUserID
               ) {
                return resolved
            }
        }

        return nil
    }

    private func orderedContinuityModes(primary: ChatMode, currentSelection: ChatMode) -> [ChatMode] {
        let candidates = [primary, currentSelection] + orderedPrewarmModes(for: currentSelection)
        var ordered: [ChatMode] = []
        for mode in candidates where ordered.contains(mode) == false {
            ordered.append(mode)
        }
        return ordered
    }

    private func matchingContinuityChat(
        from chats: [Chat],
        chatID: UUID,
        conversationKeyValue: String,
        currentUserID: UUID
    ) -> Chat? {
        if let exact = chats.first(where: { $0.id == chatID }) {
            return exact
        }

        return chats.first {
            conversationKey(for: $0, currentUserID: currentUserID) == conversationKeyValue
        }
    }

    private func orderedPrewarmModes(for selectedMode: ChatMode) -> [ChatMode] {
        switch selectedMode {
        case .smart:
            return [.smart, .online, .offline]
        case .online:
            return [.online, .smart, .offline]
        case .offline:
            return [.offline, .smart, .online]
        }
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

    private func avatarURL(for chat: Chat, currentUserID: UUID) -> URL? {
        if let groupPhotoURL = chat.group?.photoURL {
            return groupPhotoURL
        }
        return chat.directParticipant(for: currentUserID)?.photoURL
    }

    private func remoteAssetRequests(for message: Message) -> [RemoteAssetWarmupRequest] {
        var requests = message.attachments.compactMap { attachment -> RemoteAssetWarmupRequest? in
            guard let remoteURL = attachment.remoteURL else { return nil }
            return RemoteAssetWarmupRequest(
                url: remoteURL,
                networkAccessKind: .autoDownload(autoDownloadKind(for: attachment.type))
            )
        }
        if let remoteVoiceURL = message.voiceMessage?.remoteFileURL {
            requests.append(
                RemoteAssetWarmupRequest(
                    url: remoteVoiceURL,
                    networkAccessKind: .autoDownload(.voiceMessages)
                )
            )
        }
        return requests
    }

    private func autoDownloadKind(for attachmentType: AttachmentType) -> NetworkUsagePolicy.MediaAutoDownloadKind {
        switch attachmentType {
        case .photo:
            return .photos
        case .video:
            return .videos
        case .document, .audio, .contact, .location:
            return .files
        }
    }

    private func synchronizeWatchExperience(reason: String) async {
        #if os(iOS) && canImport(WatchConnectivity)
        await PrimeWatchSyncManager.shared.configure(
            appState: appState,
            chatRepository: environment.chatRepository
        )

        guard appState.isBootstrappingSession == false, appState.hasCompletedOnboarding else {
            await PrimeWatchSyncManager.shared.clearSnapshot(reason: reason)
            return
        }

        await PrimeWatchSyncManager.shared.pushLatestSnapshot(reason: reason)
        #else
        _ = reason
        #endif
    }
}

@MainActor
final class AppLockStore: ObservableObject {
    static let shared = AppLockStore()

    private enum Keys {
        static let appLockEnabled = "security.app_lock.enabled"
        static let appLockBiometricEnabled = "security.app_lock.biometric"
        static let appLockPasscodeHash = "security.app_lock.passcode_hash"
    }

    @Published private(set) var isLocked = false
    @Published private(set) var isUnlocking = false
    @Published private(set) var statusText = ""
    @Published var isEnabled: Bool {
        didSet {
            if isEnabled && isConfigured == false {
                isEnabled = false
            }
            defaults.set(isEnabled, forKey: Keys.appLockEnabled)
        }
    }
    @Published var usesBiometrics: Bool {
        didSet { defaults.set(usesBiometrics, forKey: Keys.appLockBiometricEnabled) }
    }
    @Published private(set) var isConfigured = false

    private let defaults: UserDefaults
    private var lastBackgroundAt: Date?
    private let lockDelay: TimeInterval = 2.0
    private var passcodeHash: String?
    private var requiresUnlockOnNextActive: Bool

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.appLockEnabled)
        self.usesBiometrics = defaults.object(forKey: Keys.appLockBiometricEnabled) as? Bool ?? true
        self.passcodeHash = defaults.string(forKey: Keys.appLockPasscodeHash)
        self.isConfigured = (passcodeHash?.isEmpty == false)
        self.requiresUnlockOnNextActive = false
        if isEnabled && isConfigured == false {
            isEnabled = false
            defaults.set(false, forKey: Keys.appLockEnabled)
        }
        self.requiresUnlockOnNextActive = (isEnabled && isConfigured)
        self.isLocked = requiresUnlockOnNextActive
    }

    func handleSceneMovedToBackground() {
        lastBackgroundAt = .now
        guard canLock else { return }
        requiresUnlockOnNextActive = true
        isLocked = true
        statusText = ""
    }

    func handleSceneBecameActive() {
        guard canLock else {
            isLocked = false
            requiresUnlockOnNextActive = false
            return
        }
        guard requiresUnlockOnNextActive else {
            return
        }
        guard let lastBackgroundAt else {
            isLocked = true
            return
        }
        if Date().timeIntervalSince(lastBackgroundAt) >= lockDelay {
            isLocked = true
        } else {
            requiresUnlockOnNextActive = false
        }
    }

    @MainActor
    func unlockIfNeeded(passcode: String? = nil) async {
        guard canLock else {
            isLocked = false
            return
        }
        guard isUnlocking == false else { return }
        isUnlocking = true
        defer { isUnlocking = false }

        let normalizedPasscode = passcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedPasscode.isEmpty == false {
            if validatePasscode(normalizedPasscode) {
                isLocked = false
                requiresUnlockOnNextActive = false
                statusText = ""
            } else {
                statusText = "Incorrect passcode."
            }
            return
        }

#if os(iOS) && canImport(LocalAuthentication)
        if usesBiometrics {
            let context = LAContext()
            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
                statusText = "Face ID unavailable. Enter app lock passcode."
                return
            }

            let biometricUnlocked = await evaluatePolicy(
                context: context,
                policy: .deviceOwnerAuthenticationWithBiometrics,
                reason: "Unlock Prime Messaging"
            )
            if biometricUnlocked {
                isLocked = false
                requiresUnlockOnNextActive = false
                statusText = ""
                return
            }
            statusText = "Face ID failed. Enter app lock passcode."
            return
        }
#endif
        statusText = "Enter app lock passcode."
    }

    func completeSetup(passcode: String, enableBiometrics: Bool) {
        let normalized = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4 else {
            statusText = "Passcode must be at least 4 digits."
            return
        }
        passcodeHash = hashPasscode(normalized)
        defaults.set(passcodeHash, forKey: Keys.appLockPasscodeHash)
        isConfigured = true
        isEnabled = true
        requiresUnlockOnNextActive = false
        usesBiometrics = enableBiometrics
        statusText = ""
    }

    func disableAppLock() {
        isEnabled = false
        isLocked = false
        requiresUnlockOnNextActive = false
        statusText = ""
    }

    func lockFromUserAction() {
        guard canLock else {
            statusText = "Set up App Lock first in Security settings."
            return
        }
        isLocked = true
        statusText = ""
    }

    var canLock: Bool {
        isEnabled && isConfigured
    }

    private func validatePasscode(_ passcode: String) -> Bool {
        guard let passcodeHash else { return false }
        return hashPasscode(passcode) == passcodeHash
    }

    private func hashPasscode(_ passcode: String) -> String {
        let digest = SHA256.hash(data: Data(passcode.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

#if os(iOS) && canImport(LocalAuthentication)
    private func evaluatePolicy(context: LAContext, policy: LAPolicy, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
#endif
}

private struct AppLockOverlayView: View {
    let isBiometricEnabled: Bool
    let isUnlocking: Bool
    let statusText: String
    let onUnlock: (String?) -> Void
    @State private var passcodeInput = ""

    var body: some View {
        ZStack {
            PrimeTheme.Colors.background
                .opacity(0.98)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
                Text("Prime Messaging Locked")
                    .font(.title3.weight(.semibold))
                Text(isBiometricEnabled ? "Authenticate with Face ID to continue." : "Tap unlock to continue.")
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                if statusText.isEmpty == false {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
                SecureField("Enter app lock passcode", text: $passcodeInput)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PrimeTheme.Colors.background.opacity(0.8))
                    )
                Button {
                    onUnlock(passcodeInput.isEmpty ? nil : passcodeInput)
                } label: {
                    if isUnlocking {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Unlock")
                            .font(.headline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimeTheme.Colors.accent)
                .disabled(isUnlocking)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
    }
}

#if os(iOS) && canImport(WatchConnectivity)
private struct PrimeWatchSyncPayload: Codable {
    var generatedAt: Date
    var accountDisplayName: String
    var chats: [PrimeWatchChatSnapshot]
}

private struct PrimeWatchChatSnapshot: Codable, Identifiable {
    var id: UUID
    var modeRawValue: String
    var title: String
    var subtitle: String
    var preview: String
    var unreadCount: Int
    var isMuted: Bool
    var symbolName: String
    var lastActivityAt: Date
    var messages: [PrimeWatchMessageSnapshot]
}

private struct PrimeWatchMessageSnapshot: Codable, Identifiable {
    var id: UUID
    var senderName: String
    var summary: String
    var isOutgoing: Bool
    var createdAt: Date
}

private struct PrimeWatchReplyRequest: Codable {
    var chatID: UUID
    var modeRawValue: String
    var text: String
}

private struct PrimeWatchOpenChatRequest: Codable {
    var chatID: UUID
    var modeRawValue: String
}

private struct PrimeWatchModeRequest: Codable {
    var modeRawValue: String
}

@MainActor
private final class PrimeWatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = PrimeWatchSyncManager()

    private enum Keys {
        static let payload = "prime_watch_payload"
        static let reply = "prime_watch_reply"
        static let openChat = "prime_watch_open_chat"
        static let mode = "prime_watch_mode"
    }

    private weak var appState: AppState?
    private var chatRepository: ChatRepository?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isConfigured = false
    private var watchRequestedMode: ChatMode = .online

    func configure(appState: AppState, chatRepository: ChatRepository) async {
        self.appState = appState
        self.chatRepository = chatRepository

        guard WCSession.isSupported() else { return }
        guard isConfigured == false else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        isConfigured = true
    }

    func clearSnapshot(reason: String) async {
        guard WCSession.isSupported() else { return }
        let payload = PrimeWatchSyncPayload(generatedAt: .now, accountDisplayName: "", chats: [])
        await send(payload: payload, reason: reason)
    }

    func pushLatestSnapshot(reason: String) async {
        guard WCSession.isSupported() else { return }
        guard let appState, let chatRepository else { return }

        let userID = appState.currentUser.id
        let targetMode = watchRequestedMode
        var chats = await ChatSnapshotStore.shared.loadSharedChats(userID: userID)
            .filter { $0.mode == targetMode }
        if chats.isEmpty {
            chats = await chatRepository.cachedChats(mode: targetMode, for: userID)
        }

        let snapshots = await buildChatSnapshots(
            from: chats,
            currentUserID: userID
        )

        let payload = PrimeWatchSyncPayload(
            generatedAt: .now,
            accountDisplayName: appState.currentUser.profile.displayName,
            chats: snapshots
        )
        await send(payload: payload, reason: reason)
    }

    private func send(payload: PrimeWatchSyncPayload, reason: String) async {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated || isConfigured else { return }

        do {
            let data = try encoder.encode(payload)
            try session.updateApplicationContext([Keys.payload: data])
        } catch {
            NSLog("PrimeWatchSyncManager: failed to send payload for reason=%@ error=%@", reason, error.localizedDescription)
        }
    }

    private func buildChatSnapshots(from chats: [Chat], currentUserID: UUID) async -> [PrimeWatchChatSnapshot] {
        let sortedChats = chats
            .filter { $0.type != .selfChat || $0.lastMessagePreview != nil || $0.unreadCount > 0 }
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                return $0.lastActivityAt > $1.lastActivityAt
            }
            .prefix(12)

        var snapshots: [PrimeWatchChatSnapshot] = []
        snapshots.reserveCapacity(sortedChats.count)

        for chat in sortedChats {
            let messages = await ChatSnapshotStore.shared.loadSharedMessages(chatID: chat.id, userID: currentUserID)
            let visibleMessages = messages
                .filter { $0.shouldHideDeletedPlaceholder == false }
                .suffix(18)

            let watchMessages = visibleMessages.map { message in
                PrimeWatchMessageSnapshot(
                    id: message.id,
                    senderName: watchSenderName(for: message, in: chat, currentUserID: currentUserID),
                    summary: watchMessageSummary(for: message),
                    isOutgoing: message.senderID == currentUserID,
                    createdAt: message.createdAt
                )
            }

            let preview: String? = {
                guard let raw = chat.lastMessagePreview else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
                ?? watchMessages.last?.summary
                ?? chat.subtitle

            snapshots.append(
                PrimeWatchChatSnapshot(
                    id: chat.id,
                    modeRawValue: chat.mode.rawValue,
                    title: chat.title,
                    subtitle: chat.subtitle,
                    preview: preview ?? "No messages yet",
                    unreadCount: chat.unreadCount,
                    isMuted: chat.notificationPreferences.muteState.suppressesNotifications,
                    symbolName: watchSymbolName(for: chat),
                    lastActivityAt: chat.lastActivityAt,
                    messages: watchMessages
                )
            )
        }

        return snapshots
    }

    private func watchSymbolName(for chat: Chat) -> String {
        if let kind = chat.communityDetails?.kind {
            return kind.symbolName
        }
        switch chat.type {
        case .selfChat:
            return "bookmark.fill"
        case .direct:
            return "person.fill"
        case .group:
            return "person.3.fill"
        case .secret:
            return "lock.fill"
        }
    }

    private func watchSenderName(for message: Message, in chat: Chat, currentUserID: UUID) -> String {
        if message.senderID == currentUserID {
            return "You"
        }
        if let senderDisplayName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           senderDisplayName.isEmpty == false {
            return senderDisplayName
        }
        if chat.type == .direct {
            return chat.title
        }
        return "Prime"
    }

    private func watchMessageSummary(for message: Message) -> String {
        if let trimmedText = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmedText.isEmpty == false {
            return trimmedText
        }
        if message.voiceMessage != nil {
            return "Voice message"
        }
        if let attachment = message.attachments.first {
            switch attachment.type {
            case .photo:
                return "Photo"
            case .video:
                return "Video"
            case .document:
                return attachment.fileName.isEmpty ? "Document" : attachment.fileName
            case .audio:
                return "Audio"
            case .contact:
                return "Contact"
            case .location:
                return "Location"
            }
        }
        switch message.kind {
        case .location:
            return "Location"
        case .liveLocation:
            return "Live location"
        case .system:
            return "System update"
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .document:
            return "Document"
        case .audio:
            return "Audio"
        case .voice:
            return "Voice message"
        case .contact:
            return "Contact"
        case .text:
            return "Message"
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        _ = session
        _ = activationState
        if let error {
            NSLog("PrimeWatchSyncManager: activation failed %@", error.localizedDescription)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        _ = session
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            await handleIncomingMessagePayload(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        Task { @MainActor in
            await handleIncomingMessagePayload(userInfo)
        }
    }

    private func handleIncomingMessagePayload(_ payload: [String: Any]) async {
        if let replyData = payload[Keys.reply] as? Data,
           let request = try? decoder.decode(PrimeWatchReplyRequest.self, from: replyData) {
            await handleReplyRequest(request)
        }
        if let openData = payload[Keys.openChat] as? Data,
           let request = try? decoder.decode(PrimeWatchOpenChatRequest.self, from: openData) {
            await handleOpenRequest(request)
        }
        if let modeData = payload[Keys.mode] as? Data,
           let request = try? decoder.decode(PrimeWatchModeRequest.self, from: modeData) {
            await handleModeRequest(request)
        }
    }

    private func handleModeRequest(_ request: PrimeWatchModeRequest) async {
        let requestedMode = ChatMode(rawValue: request.modeRawValue) ?? .online
        watchRequestedMode = requestedMode
        await pushLatestSnapshot(reason: "watch-mode-switch")
    }

    private func handleReplyRequest(_ request: PrimeWatchReplyRequest) async {
        guard let appState, let chatRepository else { return }
        let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return }

        let mode = ChatMode(rawValue: request.modeRawValue) ?? appState.selectedMode
        let sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: appState.currentUser.id)
        let cachedChats = await chatRepository.cachedChats(mode: mode, for: appState.currentUser.id)
        guard let chat = (sharedChats + cachedChats).first(where: { $0.id == request.chatID }) else { return }

        do {
            _ = try await chatRepository.sendMessage(trimmedText, in: chat.id, mode: chat.mode, senderID: appState.currentUser.id)
            await pushLatestSnapshot(reason: "watch-reply")
        } catch {
            NSLog("PrimeWatchSyncManager: failed to send watch reply %@", error.localizedDescription)
        }
    }

    private func handleOpenRequest(_ request: PrimeWatchOpenChatRequest) async {
        guard let appState, let chatRepository else { return }
        let mode = ChatMode(rawValue: request.modeRawValue) ?? appState.selectedMode
        let sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: appState.currentUser.id)
        let cachedChats = await chatRepository.cachedChats(mode: mode, for: appState.currentUser.id)
        guard let chat = (sharedChats + cachedChats).first(where: { $0.id == request.chatID }) else { return }

        appState.selectedMainTab = .chats
        appState.routeToChatAfterCurrentTransition(chat)
    }
}
#endif
