import OSLog
import UIKit
#if os(iOS) && canImport(PushKit)
import PushKit
#endif

@MainActor
final class PrimeMessagingAppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "PushRegistration")
    private let startupCallRepository: any CallRepository = BackendCallRepository(fallback: MockCallRepository())
    private enum BootstrapStorageKeys {
        static let currentUser = "app_state.current_user"
    }
    #if os(iOS) && canImport(PushKit)
    private let voipPushCoordinator = VoIPPushCoordinator()
    #endif

    override init() {
        super.init()
        logPushTrace("init")
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE appDelegate step=\(step) main=\(Thread.isMainThread)\(suffix)"
        logger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        logPushTrace("didFinishLaunching.begin")
        logger.info("Deferring launch service setup until after first run loop")
        DispatchQueue.main.async { [weak self] in
            self?.performDeferredLaunchSetup(launchOptions: launchOptions)
        }
        logPushTrace("didFinishLaunching.end")
        return true
    }

    private func performDeferredLaunchSetup(launchOptions: [UIApplication.LaunchOptionsKey : Any]?) {
        logPushTrace("deferredLaunchSetup.begin")
        #if !os(tvOS)
        LocalPushNotificationService.shared.registerBackgroundTasksIfNeeded()
        #endif
        #if os(iOS) && canImport(PushKit)
        voipPushCoordinator.start()
        #endif

        if let remoteNotificationPayload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let callRoute = NotificationCallRoute(userInfo: remoteNotificationPayload) {
            logPushTrace("deferredLaunchSetup.callRoute", details: "call=\(callRoute.callID.uuidString)")
            NotificationCallRouteStore.shared.queue(callRoute)
            handleIncomingCallNotificationRoute(callRoute, prewarmCallKit: true)
            logger.info("Queued call route from launch options for call \(callRoute.callID.uuidString, privacy: .public)")
        } else if let remoteNotificationPayload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
                  let chatRoute = NotificationChatRoute(userInfo: remoteNotificationPayload) {
            logPushTrace("deferredLaunchSetup.chatRoute", details: "chat=\(chatRoute.chatID.uuidString)")
            NotificationRouteStore.shared.queue(chatRoute)
            logger.info("Queued notification route from launch options for chat \(chatRoute.chatID.uuidString, privacy: .public)")
        }
        logPushTrace("deferredLaunchSetup.end")
    }

    private func preconfigureCallManagerForLaunchIfPossible() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let userID = await self.resolveBootstrapUserIDForCallManager() else {
                self.logger.info("Skipped early call manager preconfigure: no recoverable user at launch")
                return
            }
            InternetCallManager.shared.configure(
                currentUserID: userID,
                repository: self.startupCallRepository
            )
            GroupInternetCallManager.shared.configure(
                currentUserID: userID,
                repository: self.startupCallRepository
            )
            self.logger.info("Preconfigured call manager at launch for user \(userID.uuidString, privacy: .public)")
        }
    }

    private func resolveBootstrapUserIDForCallManager() async -> UUID? {
        if let persistedUserID = persistedAppStateUserID() {
            return persistedUserID
        }
        let sessions = await AuthSessionStore.shared.allSessions()
        if sessions.count == 1, let recentSession = sessions.first {
            return recentSession.userID
        }
        return nil
    }

    private func persistedAppStateUserID() -> UUID? {
        guard let data = UserDefaults.standard.data(forKey: BootstrapStorageKeys.currentUser) else {
            return nil
        }
        return (try? JSONDecoder().decode(User.self, from: data))?.id
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if !os(tvOS)
        logger.info("APNs token registration succeeded. Token length: \(deviceToken.count, privacy: .public) bytes")
        Task { @MainActor in
            await LocalPushNotificationService.shared.syncDeviceToken(deviceToken)
        }
        NotificationCenter.default.post(name: .primeMessagingDidRegisterDeviceToken, object: deviceToken)
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if !os(tvOS)
        logger.error("APNs token registration failed: \(error.localizedDescription, privacy: .public)")
        NotificationCenter.default.post(name: .primeMessagingDidFailDeviceTokenRegistration, object: error)
        #endif
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if !os(tvOS)
        Task { @MainActor in
            let result = await LocalPushNotificationService.shared.performBackgroundRefresh()
            completionHandler(result)
        }
        #else
        completionHandler(.noData)
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if !os(tvOS)
        if let callRoute = NotificationCallRoute(userInfo: userInfo) {
            NotificationCallRouteStore.shared.queue(callRoute)
            handleIncomingCallNotificationRoute(callRoute, prewarmCallKit: true)
            logger.info("Queued call route from remote notification callback for call \(callRoute.callID.uuidString, privacy: .public)")
            completionHandler(.newData)
            return
        }

        if let chatRoute = NotificationChatRoute(userInfo: userInfo) {
            if application.applicationState == .active {
                logger.info(
                    "Received foreground chat push callback; willPresent path is responsible for in-app banner chat=\(chatRoute.chatID.uuidString, privacy: .public)"
                )
            } else {
                logger.info(
                    "Received background chat push callback; skipping immediate UI route chat=\(chatRoute.chatID.uuidString, privacy: .public)"
                )
            }
            completionHandler(.newData)
            return
        }
        completionHandler(.noData)
        #else
        completionHandler(.noData)
        #endif
    }
}

#if os(iOS) && canImport(PushKit)
@MainActor
private final class VoIPPushCoordinator: NSObject, PKPushRegistryDelegate {
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "VoIPPush")
    private var registry: PKPushRegistry?
    private var recentCallPushes: [String: Date] = [:]
    private let duplicateWindow: TimeInterval = 2.0
    private let staleWindow: TimeInterval = 10 * 60
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func start() {
        guard registry == nil else { return }
        let pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        registry = pushRegistry
        logger.info("PushKit VoIP registry started")
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let tokenData = pushCredentials.token
        Task { @MainActor in
            await LocalPushNotificationService.shared.syncVoIPDeviceToken(tokenData)
            NotificationCenter.default.post(name: .primeMessagingDidRegisterVoIPDeviceToken, object: tokenData)
            self.logger.info("Received VoIP token from PushKit. bytes=\(tokenData.count, privacy: .public)")
            print("[CallManager] voip.token.received bytes=\(tokenData.count)")
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            NotificationCenter.default.post(name: .primeMessagingDidInvalidateVoIPDeviceToken, object: nil)
            self.logger.info("VoIP token invalidated by PushKit")
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleIncomingVoIPPush(payload: payload, completion: completion)
            }
            return
        }
        Task { @MainActor in
            self.handleIncomingVoIPPush(payload: payload, completion: completion)
        }
    }

    @MainActor
    private func handleIncomingVoIPPush(payload: PKPushPayload, completion: @escaping () -> Void) {
        defer { completion() }

        let userInfo = payload.dictionaryPayload
        guard let callRoute = NotificationCallRoute(userInfo: userInfo) else {
            self.logger.error("Invalid VoIP payload: call_id is missing or malformed")
            print("[CallManager] voip.push.invalid_payload")
            return
        }

        let now = Date()
        if let rawIssuedAt = userInfo["issued_at"] as? String,
           let issuedAt = isoFormatter.date(from: rawIssuedAt),
           now.timeIntervalSince(issuedAt) > staleWindow {
            self.logger.info(
                "VoIP push is older than stale window but still accepted. call=\(callRoute.callID.uuidString, privacy: .public)"
            )
        }

        let dedupeKey = callRoute.callID.uuidString.lowercased()
        if let lastSeen = recentCallPushes[dedupeKey], now.timeIntervalSince(lastSeen) <= duplicateWindow {
            self.logger.info("VoIP duplicate received but still prewarming CallKit call=\(callRoute.callID.uuidString, privacy: .public)")
            print("[CallManager] voip.push.duplicate.prewarm call=\(callRoute.callID.uuidString)")
        }
        recentCallPushes[dedupeKey] = now
        recentCallPushes = recentCallPushes.filter { now.timeIntervalSince($0.value) <= 30 }

        NotificationCallRouteStore.shared.queue(callRoute)
        handleIncomingCallNotificationRoute(callRoute, prewarmCallKit: true)
        self.logger.info("Handled VoIP push for call=\(callRoute.callID.uuidString, privacy: .public)")
        print("[CallManager] voip.push.handled call=\(callRoute.callID.uuidString)")
    }
}
#endif
