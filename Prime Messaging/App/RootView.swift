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

@MainActor
struct RootView: View {
    private static let supportedUniversalLinkHosts: Set<String> = [
        "primemsg.site",
        "www.primemsg.site",
        "primemessaging.site",
        "www.primemessaging.site",
    ]

    private enum NotificationRouteResolutionError: Error {
        case fetchTimeout
    }

    private struct PublicCommunityLinkResolution: Decodable {
        let entityType: String
        let username: String?
        let title: String
        let subtitle: String
        let inviteCode: String?
        let communityKind: String?
        let chatID: UUID?
    }

    private struct PublicUserLinkResolution: Decodable {
        let entityType: String
        let userID: UUID?
        let username: String?
    }

    private enum SilentRestoreOutcome {
        case restored(User)
        case backendUnavailable
        case failed
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notificationCallRouteStore = NotificationCallRouteStore.shared
    @ObservedObject private var internetCallManager = InternetCallManager.shared
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared
    @State private var isShowingOnlineRecoveryAlert = false
    @State private var hasPromptedForCurrentNetworkLoss = false
    @State private var isApplyingOnlineRecoveryMode = false
    @State private var previousUsableChatNetwork: Bool?
    @State private var notificationRouteResolveTask: Task<Void, Never>?
    @State private var activeNotificationRouteRequestID = UUID()
    @State private var activeNotificationRoute: NotificationChatRoute?
    @State private var inAppChatBanner: IncomingChatPushBannerPayload?
    @State private var inAppChatBannerDismissTask: Task<Void, Never>?
    @State private var pendingIncomingSharePayload: IncomingSharedPayload?
    @State private var pendingIncomingShareChats: [Chat] = []
    @State private var isImportingSharedChatHistory = false
    @State private var sharedChatImportStatusText = ""
    @State private var sharedChatImportErrorMessage: String?
    @State private var appUpdatePresentation: AppUpdatePresentation?
    @State private var lastAppUpdateCheckAt: Date?
    @ObservedObject private var appLockStore = AppLockStore.shared
    private let startupLogger = Logger(subsystem: "mirowin.Prime-Messaging", category: "Startup")

    private func assertPushRoutingMainThread(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE root step=\(step) main=\(Thread.isMainThread)\(suffix)"
        startupLogger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    var body: some View {
        ZStack {
            SwiftUI.Group {
                if appState.hasCompletedOnboarding {
                    MainTabView()
                        .id(appState.currentUser.id)
                } else {
                    NavigationStack {
                        OnboardingView(restoresPersistedDraft: false)
                    }
                }
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
            if let activeCall = internetCallManager.activeCall,
               activeCall.state == .active,
               internetCallManager.isPresentingCallUI == false,
               appLockStore.isLocked == false {
                ActiveCallMiniOverlay(call: activeCall)
                    .environmentObject(appState)
                    .zIndex(18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let activeCall = groupCallManager.activeCall,
                      activeCall.state == .active,
                      groupCallManager.isPresentingCallUI == false,
                      appLockStore.isLocked == false {
                ActiveGroupCallMiniOverlay()
                    .zIndex(18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let inAppChatBanner,
               appState.isBootstrappingSession == false,
               appLockStore.isLocked == false {
                InAppChatBannerView(
                    payload: inAppChatBanner,
                    onTap: {
                        openChatFromInAppBanner(inAppChatBanner)
                    },
                    onClose: {
                        dismissInAppChatBanner()
                    }
                )
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(19)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isImportingSharedChatHistory {
                SharedHistoryImportOverlay(statusText: sharedChatImportStatusText)
                    .zIndex(21)
                    .transition(.opacity)
            }
            if let appUpdatePresentation {
                if appUpdatePresentation.requiresUpdate {
                    RequiredAppUpdateOverlay(
                        presentation: appUpdatePresentation,
                        onUpdate: {
                            openAppStoreForUpdate()
                        }
                    )
                    .zIndex(30)
                    .transition(.opacity)
                } else if appLockStore.isLocked == false {
                    OptionalAppUpdateBanner(
                        presentation: appUpdatePresentation,
                        onUpdate: {
                            openAppStoreForUpdate()
                        },
                        onDismiss: {
                            dismissOptionalAppUpdate(appUpdatePresentation)
                        }
                    )
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(22)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
        .alert(
            "Import failed",
            isPresented: sharedHistoryImportErrorBinding
        ) {
            Button("OK", role: .cancel) {
                sharedChatImportErrorMessage = nil
            }
        } message: {
            Text(sharedChatImportErrorMessage ?? "Prime Messaging could not import this shared chat export.")
        }
        .task {
            await performRootStartupTask()
            await refreshAppUpdatePolicyIfNeeded(force: true)
        }
        .sheet(isPresented: accountAuthSheetBinding) {
            NavigationStack {
                OnboardingView(restoresPersistedDraft: false)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("common.cancel".localized) {
                                appState.cancelAddingAccount()
                            }
                        }
                }
            }
        }
        .sheet(
            item: incomingSharePayloadSheetBinding
        ) { payload in
            NavigationStack {
                IncomingShareDestinationSheet(
                    payload: payload,
                    chats: pendingIncomingShareChats,
                    onSelect: { chat in
                        Task { @MainActor in
                            if await handleSelectedIncomingSharePayload(payload, for: chat) == false {
                                let draft = await IncomingSharedPayloadStore.shared.makeDraft(from: payload)
                                appState.stageIncomingShareDraft(draft, for: chat.id)
                                await IncomingSharedPayloadStore.shared.clearPendingPayloadMetadata()
                                pendingIncomingSharePayload = nil
                                pendingIncomingShareChats = []
                                appState.routeToChatAfterCurrentTransition(chat)
                            }
                        }
                    },
                    onCancel: {
                        Task {
                            await IncomingSharedPayloadStore.shared.clearPendingPayloadMetadata()
                        }
                        pendingIncomingSharePayload = nil
                        pendingIncomingShareChats = []
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingOpenChat).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                await handleOpenChatNotificationTrigger()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingIncomingChatPush).receive(on: RunLoop.main)) { notification in
            guard let payload = IncomingChatPushBannerPayload(userInfo: notification.userInfo ?? [:]) else { return }
            guard appState.isSceneActive else { return }
            guard appState.hasCompletedOnboarding else { return }
            guard appState.isBootstrappingSession == false else { return }
            presentInAppChatBanner(payload)
        }
        .onChange(of: appState.isBootstrappingSession) { isBootstrapping in
            guard isBootstrapping == false else { return }
            Task { @MainActor in
                guard appState.isSceneActive else {
                    logPushTrace("onChange.isBootstrappingSession.deferUntilActive")
                    return
                }
                await consumePendingNotificationRouteIfNeeded()
                resolvePendingNotificationRouteIfNeeded()
                processQueuedNotificationNavigationIfPossible()
            }
        }
        .onChange(of: appState.hasCompletedOnboarding) { hasCompletedOnboarding in
            guard hasCompletedOnboarding else { return }
            Task { @MainActor in
                guard appState.isSceneActive else {
                    logPushTrace("onChange.hasCompletedOnboarding.deferUntilActive")
                    return
                }
                await consumePendingNotificationRouteIfNeeded()
                if appState.isBootstrappingSession == false {
                    resolvePendingNotificationRouteIfNeeded()
                }
                processQueuedNotificationNavigationIfPossible()
            }
        }
        .onChange(of: appState.isSceneActive) { isSceneActive in
            Task { @MainActor in
                assertPushRoutingMainThread()
                logPushTrace(
                    "onChange.isSceneActive",
                    details: "active=\(isSceneActive)"
                )
                guard isSceneActive else { return }
                await consumePendingNotificationRouteIfNeeded()
                resolvePendingNotificationRouteIfNeeded()
                processQueuedNotificationNavigationIfPossible()
                consumePendingCallNotificationRouteIfNeeded()
                evaluateConnectivityPrompt()
                await refreshAppUpdatePolicyIfNeeded()
            }
        }
        .onChange(of: appState.notificationRouteQueueRevision) { _ in
            Task { @MainActor in
                processQueuedNotificationNavigationIfPossible()
            }
        }
        .onChange(of: appState.selectedMainTab) { _ in
            Task { @MainActor in
                processQueuedNotificationNavigationIfPossible()
            }
        }
        .onChange(of: notificationCallRouteStore.pendingRoute) { newValue in
            guard newValue != nil else { return }
            Task { @MainActor in
                guard let route = notificationCallRouteStore.consume() else { return }
                handleIncomingCallNotificationRoute(route, prewarmCallKit: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDidRegisterDeviceToken).receive(on: RunLoop.main)) { notification in
            guard let token = notification.object as? Data else { return }
            Task {
                await environment.pushNotificationService.syncDeviceToken(token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDidRegisterVoIPDeviceToken).receive(on: RunLoop.main)) { notification in
            guard let token = notification.object as? Data else { return }
            Task {
                await environment.pushNotificationService.syncVoIPDeviceToken(token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingReachabilityChanged).receive(on: RunLoop.main)) { notification in
            assertPushRoutingMainThread()
            Task { @MainActor in
                if let snapshot = notification.userInfo?["snapshot"] as? NetworkConnectionSnapshot,
                   snapshot.isSatisfied {
                    await environment.chatRepository.retryPendingOutgoingMessages(currentUserID: appState.currentUser.id)
                    await refreshActiveChatContinuityIfNeeded()
                }
                evaluateConnectivityPrompt()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                await synchronizeWatchExperience(reason: "chat-snapshots")
                await refreshShareDestinationsExport()
            }
        }
        .onChange(of: appState.selectedMode) { _ in
            evaluateConnectivityPrompt()
        }
        .onOpenURL(perform: handleOpenURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: handleBrowsingWebUserActivity)
        .onDisappear {
            notificationRouteResolveTask?.cancel()
            notificationRouteResolveTask = nil
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
                groupCallManager.configure(
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
                groupCallManager.stopMonitoring()
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
        .fullScreenCover(
            isPresented: Binding(
                get: { groupCallManager.isPresentingCallUI && groupCallManager.activeCall != nil },
                set: { isPresented in
                    if !isPresented {
                        groupCallManager.dismissCallUI()
                    }
                }
            )
        ) {
            if groupCallManager.activeCall != nil {
                GroupInternetCallView()
            }
        }
    }

    private var rootTaskID: String {
        "\(appState.isBootstrappingSession)-\(appState.hasCompletedOnboarding)-\(appState.currentUser.id.uuidString)-\(appState.currentUser.profile.username)"
    }

    private var accountAuthSheetBinding: Binding<Bool> {
        Binding(
            get: { appState.hasCompletedOnboarding && appState.isShowingAccountAuth },
            set: { isPresented in
                if isPresented == false {
                    appState.cancelAddingAccount()
                }
            }
        )
    }

    private var incomingSharePayloadSheetBinding: Binding<IncomingSharedPayload?> {
        Binding(
            get: { pendingIncomingSharePayload },
            set: { newValue in
                pendingIncomingSharePayload = newValue
                if newValue == nil {
                    pendingIncomingShareChats = []
                }
            }
        )
    }

    private var sharedHistoryImportErrorBinding: Binding<Bool> {
        Binding(
            get: { sharedChatImportErrorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    sharedChatImportErrorMessage = nil
                }
            }
        )
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

    @MainActor
    private func resolvePendingNotificationRouteIfNeeded() {
        let pendingRoute = appState.pendingNotificationRoute
        let pendingResolvedChat = appState.pendingResolvedNotificationChat
        guard pendingResolvedChat == nil else { return }
        guard let routeToResolve = pendingRoute else { return }
        scheduleNotificationRouteResolution(routeToResolve)
    }

    @MainActor
    private func performRootStartupTask() async {
        logPushTrace("root.task.begin")
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
        resolvePendingNotificationRouteIfNeeded()

        if appState.isSceneActive {
            processQueuedNotificationNavigationIfPossible()
        } else {
            logPushTrace("root.task.deferNotificationRouteUntilActive")
        }

        consumePendingCallNotificationRouteIfNeeded()
        evaluateConnectivityPrompt()
        await refreshShareDestinationsExport()
        logPushTrace("root.task.end")
    }

    @MainActor
    private func refreshShareDestinationsExport() async {
        guard appState.hasCompletedOnboarding else { return }
        let userID = appState.currentUser.id
        let sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: userID)
        await ShareChatDestinationStore.shared.saveDestinations(from: sharedChats, ownerUserID: userID)
    }

    private func handleOpenURL(_ url: URL) {
        Task { @MainActor in
            assertPushRoutingMainThread()
            await handleIncomingURL(url)
        }
    }

    private func handleBrowsingWebUserActivity(_ userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        Task { @MainActor in
            assertPushRoutingMainThread()
            await handleIncomingURL(url)
        }
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
        assertPushRoutingMainThread()
        logPushTrace("consumePendingNotificationRouteIfNeeded.begin")
        NotificationRouteStore.shared.rehydratePersistedRouteIfNeeded()
        guard let route = NotificationRouteStore.shared.consume() else { return }
        logPushTrace("consumePendingNotificationRouteIfNeeded.consumed", details: "chat=\(route.chatID.uuidString)")
        scheduleNotificationRouteResolution(route)
    }

    @MainActor
    private func scheduleNotificationRouteResolution(_ route: NotificationChatRoute) {
        assertPushRoutingMainThread()
        if activeNotificationRoute == route,
           notificationRouteResolveTask != nil {
            logPushTrace("scheduleNotificationRouteResolution.skipDuplicate", details: "chat=\(route.chatID.uuidString)")
            return
        }
        logPushTrace("scheduleNotificationRouteResolution", details: "chat=\(route.chatID.uuidString)")
        notificationRouteResolveTask?.cancel()
        let requestID = UUID()
        activeNotificationRouteRequestID = requestID
        activeNotificationRoute = route
        notificationRouteResolveTask = Task { @MainActor in
            await handleNotificationChatRoute(route, requestID: requestID)
        }
    }

    @MainActor
    private func consumePendingCallNotificationRouteIfNeeded() {
        assertPushRoutingMainThread()
        guard let route = notificationCallRouteStore.consume() else { return }
        handleIncomingCallNotificationRoute(route, prewarmCallKit: true)
    }

    @MainActor
    private func handleNotificationChatRoute(_ route: NotificationChatRoute, requestID: UUID) async {
        assertPushRoutingMainThread()
        defer {
            if activeNotificationRouteRequestID == requestID {
                activeNotificationRoute = nil
                notificationRouteResolveTask = nil
            }
        }
        logPushTrace("handleNotificationChatRoute.begin", details: "chat=\(route.chatID.uuidString)")
        guard Task.isCancelled == false else { return }
        guard requestID == activeNotificationRouteRequestID else { return }
        appState.queueNotificationRoute(route)

        let isReadyForRouting = await waitForNotificationRoutingReadiness(timeout: .seconds(7.5))
        await MainActor.run {
            self.assertPushRoutingMainThread()
            self.logPushTrace("handleNotificationChatRoute.afterReadiness", details: "chat=\(route.chatID.uuidString) ready=\(isReadyForRouting)")
        }
        guard isReadyForRouting else {
            startupLogger.error(
                "Notification route deferred because app readiness timeout elapsed chat=\(route.chatID.uuidString, privacy: .public) mode=\(route.mode.rawValue, privacy: .public)"
            )
            return
        }
        guard requestID == activeNotificationRouteRequestID else { return }
        guard Task.isCancelled == false else { return }
        if let pendingRoute = appState.pendingNotificationRoute, pendingRoute != route {
            return
        }

        let currentUserID = appState.currentUser.id
        let cachedChats = await environment.chatRepository.cachedChats(mode: route.mode, for: currentUserID)
        await MainActor.run {
            self.assertPushRoutingMainThread()
            self.logPushTrace("handleNotificationChatRoute.afterCachedChats", details: "chat=\(route.chatID.uuidString) cached=\(cachedChats.count)")
        }
        if let matchedCachedChat = cachedChats.first(where: { $0.id == route.chatID }) {
            await MainActor.run {
                self.assertPushRoutingMainThread()
                self.logPushTrace("handleNotificationChatRoute.cachedMatch", details: "chat=\(route.chatID.uuidString)")
                self.appState.queueResolvedNotificationChat(matchedCachedChat, expectedRoute: route)
                self.processQueuedNotificationNavigationIfPossible()
            }
            return
        }

        var lastError: Error?
        let canFetchFromNetwork = route.mode != .offline && NetworkUsagePolicy.canUseChatSyncNetwork()
        let maxAttempts = canFetchFromNetwork ? 2 : 0
        for attempt in 0..<maxAttempts {
            guard requestID == activeNotificationRouteRequestID else { return }
            guard Task.isCancelled == false else { return }
            if let pendingRoute = appState.pendingNotificationRoute, pendingRoute != route {
                return
            }
            do {
                let fetchedChats = try await fetchChatsForNotificationRoute(
                    mode: route.mode,
                    currentUserID: currentUserID,
                    timeout: .seconds(1.85)
                )
                await MainActor.run {
                    self.assertPushRoutingMainThread()
                    self.logPushTrace("handleNotificationChatRoute.afterFetch", details: "chat=\(route.chatID.uuidString) fetched=\(fetchedChats.count)")
                }
                if let matchedChat = fetchedChats.first(where: { $0.id == route.chatID }) {
                    await MainActor.run {
                        self.assertPushRoutingMainThread()
                        self.logPushTrace("handleNotificationChatRoute.fetchedMatch", details: "chat=\(route.chatID.uuidString)")
                        self.appState.queueResolvedNotificationChat(matchedChat, expectedRoute: route)
                        self.processQueuedNotificationNavigationIfPossible()
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    self.assertPushRoutingMainThread()
                }
                lastError = error
            }

            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: .milliseconds(260))
                await MainActor.run {
                    self.assertPushRoutingMainThread()
                }
            }
        }

        assertPushRoutingMainThread()
        appState.fallbackToChatListAfterNotificationFailure(expectedRoute: route)
        if let lastError {
            startupLogger.error(
                "Notification route resolve failed chat=\(route.chatID.uuidString, privacy: .public) mode=\(route.mode.rawValue, privacy: .public) error=\(lastError.localizedDescription, privacy: .public)"
            )
        } else {
            startupLogger.error(
                "Notification route resolve failed chat=\(route.chatID.uuidString, privacy: .public) mode=\(route.mode.rawValue, privacy: .public) reason=chat_not_found_after_retries"
            )
        }
    }

    @MainActor
    private func processQueuedNotificationNavigationIfPossible() {
        assertPushRoutingMainThread()
        logPushTrace("processQueuedNotificationNavigationIfPossible.begin")
        _ = appState.commitQueuedNotificationNavigationIfPossible()
        logPushTrace("processQueuedNotificationNavigationIfPossible.end")
    }

    @MainActor
    private func presentInAppChatBanner(_ payload: IncomingChatPushBannerPayload) {
        inAppChatBannerDismissTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            inAppChatBanner = payload
        }
        inAppChatBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard Task.isCancelled == false else { return }
            dismissInAppChatBanner()
        }
    }

    @MainActor
    private func dismissInAppChatBanner() {
        inAppChatBannerDismissTask?.cancel()
        inAppChatBannerDismissTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            inAppChatBanner = nil
        }
    }

    @MainActor
    private func openChatFromInAppBanner(_ payload: IncomingChatPushBannerPayload) {
        dismissInAppChatBanner()
        NotificationRouteStore.persistLaunchRoute(payload.route)
        NotificationCenter.default.post(name: .primeMessagingOpenChat, object: nil)
    }

    @MainActor
    private func waitForNotificationRoutingReadiness(timeout: Duration) async -> Bool {
        assertPushRoutingMainThread()
        let clock = ContinuousClock()
        let start = clock.now

        while appState.isBootstrappingSession
            || appState.hasCompletedOnboarding == false
            || appState.requiresServerSessionValidation {
            guard Task.isCancelled == false else { return false }
            guard clock.now - start < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                self.assertPushRoutingMainThread()
            }
        }

        while appState.isSceneActive == false {
            guard Task.isCancelled == false else { return false }
            guard clock.now - start < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(80))
            await MainActor.run {
                self.assertPushRoutingMainThread()
            }
        }

        if let settleDelay = appState.pendingNotificationActivationSettleDelay() {
            let settleDelayMilliseconds = Int(settleDelay.components.seconds * 1_000)
                + Int(settleDelay.components.attoseconds / 1_000_000_000_000_000)
            logPushTrace(
                "waitForNotificationRoutingReadiness.activationSettle",
                details: "delay_ms=\(max(settleDelayMilliseconds, 0))"
            )
            try? await Task.sleep(for: settleDelay)
            await MainActor.run {
                self.assertPushRoutingMainThread()
            }
        }

        return true
    }

    private func fetchChatsForNotificationRoute(
        mode: ChatMode,
        currentUserID: UUID,
        timeout: Duration
    ) async throws -> [Chat] {
        try await withThrowingTaskGroup(of: [Chat].self) { group in
            group.addTask {
                try await environment.chatRepository.fetchChats(mode: mode, for: currentUserID)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NotificationRouteResolutionError.fetchTimeout
            }

            guard let resolvedChats = try await group.next() else {
                throw NotificationRouteResolutionError.fetchTimeout
            }
            group.cancelAll()
            return resolvedChats
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
        assertPushRoutingMainThread()
        guard appState.hasCompletedOnboarding else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""

        if scheme == "primemessaging" || scheme == "prime" {
            switch host {
            case "join":
                let inviteCode = url.pathComponents.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await joinChatFromInviteCode(inviteCode)
            case "share":
                await prepareIncomingShareFlow()
            case "user":
                let rawUsername = url.pathComponents
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await openDirectChatFromPublicUserLink(rawUsername)
            default:
                break
            }
            return
        }

        if scheme == "https" || scheme == "http" {
            let normalizedHost = host.replacingOccurrences(of: "www.", with: "")
            guard Self.supportedUniversalLinkHosts.contains(normalizedHost) || Self.supportedUniversalLinkHosts.contains(host) else { return }

            let pathParts = url.pathComponents.filter { $0 != "/" }
            if let firstPathPart = pathParts.first, pathParts.count == 1, firstPathPart.hasPrefix("@") {
                await openDirectChatFromPublicUserLink(String(firstPathPart.dropFirst()))
                return
            }
            if pathParts.count >= 2 {
                let route = pathParts[0].lowercased()
                let payload = pathParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if route == "u" || route == "user" {
                    await openDirectChatFromPublicUserLink(payload)
                    return
                }
                if route == "c" || route == "channel" {
                    await openCommunityFromPublicLink(payload, kindHint: "channel")
                    return
                }
                if route == "g" || route == "group" || route == "community" {
                    await openCommunityFromPublicLink(payload, kindHint: "group")
                    return
                }
                if route == "join" || route == "invite" {
                    await joinChatFromInviteCode(payload)
                    return
                }
                if route == "share" {
                    await prepareIncomingShareFlow()
                    return
                }
            }

            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                if let username = queryItems.first(where: { $0.name == "u" || $0.name == "user" })?.value {
                    await openDirectChatFromPublicUserLink(username)
                    return
                }
                if let inviteCode = queryItems.first(where: { $0.name == "join" || $0.name == "invite" })?.value {
                    await joinChatFromInviteCode(inviteCode)
                    return
                }
                if let community = queryItems.first(where: { $0.name == "community" || $0.name == "channel" || $0.name == "group" })?.value {
                    await openCommunityFromPublicLink(community, kindHint: nil)
                    return
                }
            }
        }
    }

    @MainActor
    private func openCommunityFromPublicLink(_ rawHandle: String, kindHint: String?) async {
        assertPushRoutingMainThread()
        let normalizedHandle = appState
            .normalizedUsername(rawHandle.replacingOccurrences(of: "@", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedHandle.isEmpty == false else { return }
        guard let resolution = await resolvePublicCommunityLink(handle: normalizedHandle, kindHint: kindHint) else { return }
        guard let inviteCode = resolution.inviteCode, inviteCode.isEmpty == false else { return }
        await joinChatFromInviteCode(inviteCode)
    }

    private func resolvePublicCommunityLink(handle: String, kindHint: String?) async -> PublicCommunityLinkResolution? {
        guard let baseURL = BackendConfiguration.currentBaseURL else { return nil }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("public/resolve"), resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems = [URLQueryItem(name: "community", value: handle)]
        if let kindHint, kindHint.isEmpty == false {
            queryItems.append(URLQueryItem(name: "kind", value: kindHint))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoder = JSONDecoder()
            return try decoder.decode(PublicCommunityLinkResolution.self, from: data)
        } catch {
            return nil
        }
    }

    @MainActor
    private func joinChatFromInviteCode(_ inviteCodeRaw: String) async {
        assertPushRoutingMainThread()
        let inviteCode = inviteCodeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inviteCode.isEmpty == false else { return }

        let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode

        do {
            let joinedChat = try await environment.chatRepository.joinChat(
                inviteCode: inviteCode,
                mode: preferredMode,
                requesterID: appState.currentUser.id
            )
            await MainActor.run {
                self.assertPushRoutingMainThread()
            }
            if appState.selectedMode != preferredMode {
                appState.updateSelectedMode(preferredMode)
            }
            appState.routeToChatAfterCurrentTransition(joinedChat)
        } catch {
            // Keep the app stable even if the invite is stale or invalid.
        }
    }

    @MainActor
    private func resolvePublicUserLink(identifier: String) async -> PublicUserLinkResolution? {
        guard let baseURL = BackendConfiguration.currentBaseURL else { return nil }
        guard var components = URLComponents(url: baseURL.appendingPathComponent("public/resolve"), resolvingAgainstBaseURL: false) else {
            return nil
        }

        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmedIdentifier) != nil {
            components.queryItems = [URLQueryItem(name: "user_id", value: trimmedIdentifier)]
        } else {
            components.queryItems = [URLQueryItem(name: "username", value: trimmedIdentifier)]
        }

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoder = JSONDecoder()
            return try decoder.decode(PublicUserLinkResolution.self, from: data)
        } catch {
            return nil
        }
    }

    @MainActor
    private func prepareIncomingShareFlow() async {
        assertPushRoutingMainThread()
        guard appState.hasCompletedOnboarding, appState.isBootstrappingSession == false else { return }
        guard let payload = await IncomingSharedPayloadStore.shared.loadPendingPayload() else { return }
        await IncomingSharedPayloadStore.shared.acknowledgePayload(payload.id)

        var sharedChats = await ChatSnapshotStore.shared.loadSharedChats(userID: appState.currentUser.id)
        if sharedChats.isEmpty {
            let preferredModes: [ChatMode] = appState.currentUser.isOfflineOnly ? [.offline] : [.online, .offline]
            for mode in preferredModes {
                let cached = await environment.chatRepository.cachedChats(mode: mode, for: appState.currentUser.id)
                sharedChats.append(contentsOf: cached)
            }
        }

        let chats = Array(Dictionary(uniqueKeysWithValues: sharedChats.map { ($0.id, $0) }).values)
            .filter { $0.participantIDs.isEmpty == false || $0.group != nil || $0.type == .selfChat }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }

        if let preferredChatID = payload.preferredDestinationChatID,
           let preferredChat = chats.first(where: { $0.id == preferredChatID }) {
            if await handleSelectedIncomingSharePayload(payload, for: preferredChat) == false {
                let draft = await IncomingSharedPayloadStore.shared.makeDraft(from: payload)
                appState.stageIncomingShareDraft(draft, for: preferredChat.id)
                await IncomingSharedPayloadStore.shared.clearPendingPayloadMetadata()
                pendingIncomingShareChats = []
                pendingIncomingSharePayload = nil
                appState.selectedMainTab = .chats
                appState.routeToChatAfterCurrentTransition(preferredChat)
            }
            return
        }

        pendingIncomingShareChats = chats
        pendingIncomingSharePayload = payload
        appState.selectedMainTab = .chats
    }

    @MainActor
    private func handleOpenChatNotificationTrigger() async {
        assertPushRoutingMainThread()
        logPushTrace("onReceive.openChat")
        guard appState.isSceneActive else {
            logPushTrace("onReceive.openChat.deferUntilActive")
            return
        }
        await consumePendingNotificationRouteIfNeeded()
        resolvePendingNotificationRouteIfNeeded()
        processQueuedNotificationNavigationIfPossible()
    }

    @MainActor
    private func handleSelectedIncomingSharePayload(_ payload: IncomingSharedPayload, for chat: Chat) async -> Bool {
        assertPushRoutingMainThread()
        guard WhatsAppChatImportParser.looksLikeWhatsAppExport(payload) else { return false }

        isImportingSharedChatHistory = true
        sharedChatImportStatusText = "Preparing WhatsApp migration…"
        appState.selectedMainTab = .chats

        defer {
            isImportingSharedChatHistory = false
        }

        do {
            var sharedFileURLs: [UUID: URL] = [:]
            for filePayload in payload.files {
                if let fileURL = await IncomingSharedPayloadStore.shared.availableFileURL(for: filePayload) {
                    sharedFileURLs[filePayload.id] = fileURL
                }
            }

            let importedHistory = try WhatsAppChatImportParser.parse(
                payload: payload,
                into: chat,
                currentUser: appState.currentUser,
                fileURLResolver: { filePayload in
                    sharedFileURLs[filePayload.id]
                }
            )

            sharedChatImportStatusText = importedHistory.messages.count == 1
                ? "Migrating 1 message from WhatsApp…"
                : "Migrating \(importedHistory.messages.count) messages from WhatsApp…"

            let updatedChat = try await environment.chatRepository.importExternalHistory(
                importedHistory.messages,
                into: chat,
                currentUser: appState.currentUser
            )

            await IncomingSharedPayloadStore.shared.clearPendingPayloadMetadata()
            pendingIncomingSharePayload = nil
            pendingIncomingShareChats = []
            appState.routeToChatAfterCurrentTransition(updatedChat)
            return true
        } catch {
            await IncomingSharedPayloadStore.shared.clearPendingPayloadMetadata()
            pendingIncomingSharePayload = nil
            pendingIncomingShareChats = []
            sharedChatImportErrorMessage = error.localizedDescription.isEmpty
                ? "Prime Messaging could not import this WhatsApp export."
                : error.localizedDescription
            return true
        }
    }

    @MainActor
    private func openDirectChatFromPublicUserLink(_ identifier: String) async {
        assertPushRoutingMainThread()
        let trimmedIdentifier = identifier.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedIdentifier.isEmpty == false else { return }

        let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode

        do {
            let user: User
            if let resolution = await resolvePublicUserLink(identifier: trimmedIdentifier),
               let resolvedUserID = resolution.userID,
               resolvedUserID != appState.currentUser.id {
                user = User(
                    id: resolvedUserID,
                    profile: Profile(
                        displayName: resolution.username ?? trimmedIdentifier,
                        username: resolution.username ?? trimmedIdentifier,
                        bio: "",
                        status: "",
                        birthday: nil,
                        email: nil,
                        phoneNumber: nil,
                        profilePhotoURL: nil,
                        socialLink: nil
                    ),
                    identityMethods: [],
                    privacySettings: .defaultEmailOnly
                )
            } else {
                let normalizedUsername = appState
                    .normalizedUsername(trimmedIdentifier)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedUsername.isEmpty == false else { return }

                let users = try await environment.authRepository.searchUsers(
                    query: normalizedUsername,
                    excluding: appState.currentUser.id
                )
                await MainActor.run {
                    self.assertPushRoutingMainThread()
                }
                guard let resolvedUser = users.first(where: {
                    $0.profile.username.caseInsensitiveCompare(normalizedUsername) == .orderedSame
                }) else { return }
                user = resolvedUser
            }

            var chat = try await environment.chatRepository.createDirectChat(
                with: user.id,
                currentUserID: appState.currentUser.id,
                mode: preferredMode
            )
            await MainActor.run {
                self.assertPushRoutingMainThread()
            }
            let otherDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.title = otherDisplayName.isEmpty ? user.profile.username : otherDisplayName
            chat.subtitle = "@\(user.profile.username)"

            if appState.selectedMode != preferredMode {
                appState.updateSelectedMode(preferredMode)
            }
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            // Ignore malformed/unresolvable usernames from deep links.
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
            appState.deferCurrentServerSessionValidation()
            startupLogger.error("Session bootstrap preserved cached onboarded account despite missing recoverable backend session.")
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
            let silentRestoreOutcome = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id)
            switch silentRestoreOutcome {
            case .restored(let restoredUser):
                appState.markCurrentServerSessionValidated(with: restoredUser)
                return true
            case .backendUnavailable:
                appState.deferCurrentServerSessionValidation()
                return true
            case .failed:
                startupLogger.error("Server session validation failed to restore missing session. Preserving local account user=\(appState.currentUser.id.uuidString, privacy: .public)")
            }
            appState.deferCurrentServerSessionValidation()
            return true
        }

        do {
            let refreshedUser = try await environment.authRepository.refreshUser(userID: appState.currentUser.id)
            appState.markCurrentServerSessionValidated(with: refreshedUser)
            return true
        } catch AuthRepositoryError.accountNotFound {
            let silentRestoreOutcome = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id)
            switch silentRestoreOutcome {
            case .restored(let restoredUser):
                appState.markCurrentServerSessionValidated(with: restoredUser)
            case .backendUnavailable, .failed:
                startupLogger.error("Server validation returned account-not-found for user=\(appState.currentUser.id.uuidString, privacy: .public). Preserving local account and deferring validation.")
                appState.deferCurrentServerSessionValidation()
            }
            return true
        } catch AuthRepositoryError.invalidCredentials {
            let silentRestoreOutcome = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id)
            switch silentRestoreOutcome {
            case .restored(let restoredUser):
                appState.markCurrentServerSessionValidated(with: restoredUser)
            case .backendUnavailable, .failed:
                startupLogger.error("Server validation returned invalid-credentials for user=\(appState.currentUser.id.uuidString, privacy: .public). Preserving local account and deferring validation.")
                appState.deferCurrentServerSessionValidation()
            }
            return true
        } catch {
            startupLogger.error("Server validation temporarily unavailable for user=\(appState.currentUser.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    @MainActor
    private func restoreSessionSilentlyIfPossible(for userID: UUID) async -> SilentRestoreOutcome {
        guard let credentials = await LocalAccountStore.shared.credentials(for: userID) else {
            return .failed
        }

        do {
            let restoredUser = try await environment.authRepository.logIn(
                identifier: credentials.identifier,
                password: credentials.password
            )
            guard restoredUser.id == userID else {
                startupLogger.error(
                    "Silent restore identity mismatch expected=\(userID.uuidString, privacy: .public) actual=\(restoredUser.id.uuidString, privacy: .public)"
                )
                return .failed
            }
            return .restored(restoredUser)
        } catch AuthRepositoryError.backendUnavailable {
            return .backendUnavailable
        } catch {
            return .failed
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
        guard appState.pendingNotificationRoute == nil else { return }
        guard appState.pendingResolvedNotificationChat == nil else { return }
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

    private func refreshAppUpdatePolicyIfNeeded(force: Bool = false) async {
        let now = Date()
        if force == false,
           let lastAppUpdateCheckAt,
           now.timeIntervalSince(lastAppUpdateCheckAt) < 60 * 15 {
            return
        }

        lastAppUpdateCheckAt = now

        do {
            let policy = try await AppUpdateService.fetchVersionPolicy()
            appUpdatePresentation = AppUpdateService.makePresentation(from: policy)
        } catch {
            if appUpdatePresentation?.requiresUpdate == true {
                return
            }
        }
    }

    private func dismissOptionalAppUpdate(_ presentation: AppUpdatePresentation) {
        guard presentation.requiresUpdate == false else { return }
        AppUpdateService.dismissOptionalVersion(presentation.latestVersion)
        appUpdatePresentation = nil
    }

    private func openAppStoreForUpdate() {
        guard let targetURL = appUpdatePresentation?.appStoreURL else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(targetURL)
        #endif
    }
}

@MainActor
final class AppLockStore: ObservableObject {
    static let shared = AppLockStore()
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "AppLockState")

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

    private func assertMainThreadForUIState(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logStateMutation(_ field: StaticString) {
        let message = "AppLockState state mutation field=\(String(describing: field)) main=\(Thread.isMainThread)"
        logger.notice("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

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
        assertMainThreadForUIState()
        lastBackgroundAt = .now
        guard canLock else { return }
        requiresUnlockOnNextActive = true
        statusText = ""
        logStateMutation("statusText")
    }

    func handleSceneBecameActive() {
        assertMainThreadForUIState()
        guard canLock else {
            isLocked = false
            logStateMutation("isLocked")
            requiresUnlockOnNextActive = false
            return
        }
        guard requiresUnlockOnNextActive else {
            return
        }
        guard let lastBackgroundAt else {
            isLocked = true
            logStateMutation("isLocked")
            return
        }
        if Date().timeIntervalSince(lastBackgroundAt) >= lockDelay {
            isLocked = true
            logStateMutation("isLocked")
        } else {
            isLocked = false
            logStateMutation("isLocked")
            requiresUnlockOnNextActive = false
        }
    }

    @MainActor
    func unlockIfNeeded(passcode: String? = nil) async {
        assertMainThreadForUIState()
        guard canLock else {
            isLocked = false
            logStateMutation("isLocked")
            return
        }
        guard isUnlocking == false else { return }
        isUnlocking = true
        logStateMutation("isUnlocking")
        defer { isUnlocking = false }

        let normalizedPasscode = passcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedPasscode.isEmpty == false {
            if validatePasscode(normalizedPasscode) {
                isLocked = false
                logStateMutation("isLocked")
                requiresUnlockOnNextActive = false
                statusText = ""
                logStateMutation("statusText")
            } else {
                statusText = "Incorrect passcode."
                logStateMutation("statusText")
            }
            return
        }

#if os(iOS) && canImport(LocalAuthentication)
        if usesBiometrics {
            let context = LAContext()
            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
                statusText = "Face ID unavailable. Enter app lock passcode."
                logStateMutation("statusText")
                return
            }

            let biometricUnlocked = await evaluatePolicy(
                context: context,
                policy: .deviceOwnerAuthenticationWithBiometrics,
                reason: "Unlock Prime Messaging"
            )
            if biometricUnlocked {
                isLocked = false
                logStateMutation("isLocked")
                requiresUnlockOnNextActive = false
                statusText = ""
                logStateMutation("statusText")
                return
            }
            statusText = "Face ID failed. Enter app lock passcode."
            logStateMutation("statusText")
            return
        }
#endif
        statusText = "Enter app lock passcode."
        logStateMutation("statusText")
    }

    func completeSetup(passcode: String, enableBiometrics: Bool) {
        assertMainThreadForUIState()
        let normalized = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4 else {
            statusText = "Passcode must be at least 4 digits."
            logStateMutation("statusText")
            return
        }
        passcodeHash = hashPasscode(normalized)
        defaults.set(passcodeHash, forKey: Keys.appLockPasscodeHash)
        isConfigured = true
        isEnabled = true
        requiresUnlockOnNextActive = false
        usesBiometrics = enableBiometrics
        statusText = ""
        logStateMutation("isConfigured")
        logStateMutation("isEnabled")
        logStateMutation("usesBiometrics")
        logStateMutation("statusText")
    }

    func disableAppLock() {
        assertMainThreadForUIState()
        isEnabled = false
        isLocked = false
        requiresUnlockOnNextActive = false
        statusText = ""
        logStateMutation("isEnabled")
        logStateMutation("isLocked")
        logStateMutation("statusText")
    }

    func lockFromUserAction() {
        assertMainThreadForUIState()
        guard canLock else {
            statusText = "Set up App Lock first in Security settings."
            logStateMutation("statusText")
            return
        }
        isLocked = true
        logStateMutation("isLocked")
        statusText = ""
        logStateMutation("statusText")
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

private struct ActiveCallMiniOverlay: View {
    @ObservedObject private var callManager = InternetCallManager.shared
    @EnvironmentObject private var appState: AppState
    let call: InternetCall
    @State private var cardOffset: CGSize = .zero
    @GestureState private var cardDragOffset: CGSize = .zero

    private let cardWidth: CGFloat = 170
    private let cardHeight: CGFloat = 108

    var body: some View {
        GeometryReader { proxy in
            let combinedDragOffset = CGSize(
                width: cardOffset.width + cardDragOffset.width,
                height: cardOffset.height + cardDragOffset.height
            )
            let resolvedOffset = clampedCardOffset(combinedDragOffset, in: proxy)
            VStack {
                HStack {
                    Spacer()
                    ZStack(alignment: .topLeading) {
                        miniCard
                            .overlay {
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        callManager.presentCallUI()
                                    }
                            }
                            .offset(resolvedOffset)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($cardDragOffset) { value, state, _ in
                                        state = value.translation
                                    }
                                    .onEnded { value in
                                        cardOffset = clampedCardOffset(
                                            CGSize(
                                                width: cardOffset.width + value.translation.width,
                                                height: cardOffset.height + value.translation.height
                                            ),
                                            in: proxy
                                        )
                                    }
                            )

                        Button {
                            callManager.endCall(source: "active_call_mini_overlay_hangup")
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(PrimeTheme.Colors.warning)
                                )
                        }
                        .buttonStyle(.plain)
                        .offset(x: -10 + resolvedOffset.width, y: -10 + resolvedOffset.height)
                    }
                }
                Spacer()
            }
            .padding(.top, max(proxy.safeAreaInsets.top + 8, 56))
            .padding(.trailing, 14)
        }
        .ignoresSafeArea(edges: .top)
        .animation(.easeInOut(duration: 0.2), value: callManager.isRemoteVideoAvailable)
    }

    @ViewBuilder
    private var miniCard: some View {
        if callManager.isVideoEnabled {
            ZStack(alignment: .bottomLeading) {
                if callManager.isRemoteVideoAvailable {
                    WebRTCVideoRendererView(stream: .remote)
                        .allowsHitTesting(false)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    PrimeTheme.Colors.elevated,
                                    PrimeTheme.Colors.background
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay(
                            Text(initials)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        )
                }

                LinearGradient(
                    colors: [
                        .clear,
                        Color.black.opacity(0.58),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(durationLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                WebRTCVideoRendererView(stream: .local)
                    .allowsHitTesting(false)
                    .frame(width: 46, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(durationLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
        }
    }

    private var displayName: String {
        (callManager.activeCall ?? call).displayName(for: appState.currentUser.id)
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        if letters.isEmpty {
            return String(displayName.prefix(2)).uppercased()
        }
        return String(letters.prefix(2)).uppercased()
    }

    private var durationLabel: String {
        let totalSeconds = max(Int(callManager.duration), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func clampedCardOffset(_ candidate: CGSize, in proxy: GeometryProxy) -> CGSize {
        let safeInsets = proxy.safeAreaInsets
        let maxShiftLeft = max(0, proxy.size.width - cardWidth - 26)
        let maxShiftDown = max(0, proxy.size.height - cardHeight - safeInsets.top - safeInsets.bottom - 28)

        return CGSize(
            width: min(max(candidate.width, -maxShiftLeft), 0),
            height: min(max(candidate.height, 0), maxShiftDown)
        )
    }
}

private struct InAppChatBannerView: View {
    let payload: IncomingChatPushBannerPayload
    let onTap: () -> Void
    let onClose: () -> Void

    private var eyebrowText: String {
        if payload.communityKind == "channel" {
            if let groupTitle = payload.groupTitle, groupTitle.isEmpty == false {
                return groupTitle
            }
            return "New message"
        }
        if let senderName = payload.senderName,
           let groupTitle = payload.groupTitle,
           groupTitle.isEmpty == false {
            return "\(senderName) in \(groupTitle)"
        }
        if let senderName = payload.senderName, senderName.isEmpty == false {
            return senderName
        }
        if let groupTitle = payload.groupTitle, groupTitle.isEmpty == false {
            return groupTitle
        }
        return "New message"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "message.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.accent)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrowText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Text(payload.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(payload.body)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.background.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }
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

private struct SharedHistoryImportOverlay: View {
    let statusText: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.05)
                Text(statusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
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
        guard session.isPaired, session.isWatchAppInstalled else { return }

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
