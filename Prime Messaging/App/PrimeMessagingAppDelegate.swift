import OSLog
import UIKit
#if os(iOS) && canImport(PushKit)
import PushKit
#endif

@MainActor
final class PrimeMessagingAppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "PushRegistration")
    #if os(iOS) && canImport(PushKit)
    private let voipPushCoordinator = VoIPPushCoordinator()
    #endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        #if !os(tvOS)
        LocalPushNotificationService.shared.registerBackgroundTasksIfNeeded()
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        #endif
        #if os(iOS) && canImport(PushKit)
        voipPushCoordinator.start()
        #endif

        if let remoteNotificationPayload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let callRoute = NotificationCallRoute(userInfo: remoteNotificationPayload) {
            NotificationCallRouteStore.shared.queue(callRoute)
            InternetCallManager.shared.queueIncomingCallFromPush(callID: callRoute.callID, callerName: callRoute.callerName)
            logger.info("Queued call route from launch options for call \(callRoute.callID.uuidString, privacy: .public)")
        } else if let remoteNotificationPayload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
                  let chatRoute = NotificationChatRoute(userInfo: remoteNotificationPayload) {
            NotificationRouteStore.shared.queue(chatRoute)
            logger.info("Queued notification route from launch options for chat \(chatRoute.chatID.uuidString, privacy: .public)")
        }
        return true
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
            InternetCallManager.shared.queueIncomingCallFromPush(callID: callRoute.callID, callerName: callRoute.callerName)
            logger.info("Queued call route from remote notification callback for call \(callRoute.callID.uuidString, privacy: .public)")
            completionHandler(.newData)
            return
        }

        if let chatRoute = NotificationChatRoute(userInfo: userInfo) {
            LocalPushNotificationService.shared.handleIncomingChatPushRoute(
                chatRoute,
                source: "remote_notification"
            )
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
    private let staleWindow: TimeInterval = 45.0
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

        Task { @MainActor in
            defer { completion() }

            let userInfo = payload.dictionaryPayload
            guard let callRoute = NotificationCallRoute(userInfo: userInfo) else {
                self.logger.error("Invalid VoIP payload: call_id is missing or malformed")
                return
            }
            let now = Date()
            if let rawIssuedAt = userInfo["issued_at"] as? String,
               let issuedAt = isoFormatter.date(from: rawIssuedAt),
               now.timeIntervalSince(issuedAt) > staleWindow {
                self.logger.info("Dropped stale VoIP push call=\(callRoute.callID.uuidString, privacy: .public)")
                return
            }

            let dedupeKey = callRoute.callID.uuidString.lowercased()
            if let lastSeen = recentCallPushes[dedupeKey], now.timeIntervalSince(lastSeen) <= duplicateWindow {
                self.logger.info("Dropped duplicate VoIP push call=\(callRoute.callID.uuidString, privacy: .public)")
                return
            }
            recentCallPushes[dedupeKey] = now
            recentCallPushes = recentCallPushes.filter { now.timeIntervalSince($0.value) <= 30 }

            NotificationCallRouteStore.shared.queue(callRoute)
            InternetCallManager.shared.queueIncomingCallFromPush(callID: callRoute.callID, callerName: callRoute.callerName)
            self.logger.info("Handled VoIP push for call=\(callRoute.callID.uuidString, privacy: .public)")
        }
    }
}
#endif
