import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class LocalPushNotificationService: NSObject, PushNotificationService {
    static let shared = LocalPushNotificationService()

    private enum StorageKeys {
        static let deviceToken = "push.device_token"
        static let voipDeviceToken = "push.voip_device_token"
        static let registeredTokenSignature = "push.registered_token_signature"
        static let registeredVoIPTokenSignature = "push.registered_voip_token_signature"
        static let deviceIdentifier = "push.device_identifier"
    }

    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "PushNotifications")
    private var monitoredUserID: UUID?
    private var foregroundObserver: NSObjectProtocol?
    private var tokenSyncTask: Task<Void, Never>?
    private var isTokenSyncInFlight = false
    private var lastDeviceTokenSyncAttemptAt: Date?
    private var registrationNeedsSync = true
    private var voipRegistrationNeedsSync = true
    private var registeredTokenSignature: String?
    private var registeredVoIPTokenSignature: String?
    private var activeChatID: UUID?
    private var activeChatMode: ChatMode?

    private func assertPushRoutingMainThread(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE service step=\(step) main=\(Thread.isMainThread)\(suffix)"
        logger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    init(notificationCenter: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.registeredTokenSignature = defaults.string(forKey: StorageKeys.registeredTokenSignature)
        self.registeredVoIPTokenSignature = defaults.string(forKey: StorageKeys.registeredVoIPTokenSignature)
        super.init()
        #if !os(tvOS)
        notificationCenter.delegate = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncStoredDeviceTokenIfPossible(force: true)
            }
        }
        #endif
    }

    func registerBackgroundTasksIfNeeded() {
        // APNs-only: local notification polling is intentionally removed.
        logger.debug("Push local polling disabled. APNs-only pipeline active.")
    }

    func registerForRemoteNotifications() async {
        #if os(tvOS)
        return
        #else
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                logger.info("Notification permission granted. Registering with APNs.")
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                logger.info("Notification permission denied or dismissed by user.")
            }
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    func syncDeviceToken(_ token: Data) async {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        defaults.set(tokenString, forKey: StorageKeys.deviceToken)
        registrationNeedsSync = true
        logger.info("Stored APNs token locally. Hex length: \(tokenString.count, privacy: .public)")
        await syncStoredDeviceTokenIfPossible(force: true)
    }

    func syncVoIPDeviceToken(_ token: Data) async {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        defaults.set(tokenString, forKey: StorageKeys.voipDeviceToken)
        voipRegistrationNeedsSync = true
        logger.info("Stored VoIP token locally. Hex length: \(tokenString.count, privacy: .public)")
        await syncStoredDeviceTokenIfPossible(force: true)
    }

    func authorizationStatus() async -> PushAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    func startMonitoring(currentUser: User, chatRepository: ChatRepository) async {
        _ = chatRepository
        if monitoredUserID != currentUser.id {
            registrationNeedsSync = true
        }

        monitoredUserID = currentUser.id
        lastDeviceTokenSyncAttemptAt = nil
        registrationNeedsSync = true
        voipRegistrationNeedsSync = true

        #if !os(tvOS)
        await clearLegacyLocalNotificationRequestsIfNeeded()
        #endif

        startTokenSyncLoop()
        await syncStoredDeviceTokenIfPossible(force: true)
    }

    func stopMonitoring() async {
        tokenSyncTask?.cancel()
        tokenSyncTask = nil
        monitoredUserID = nil
        lastDeviceTokenSyncAttemptAt = nil
        registrationNeedsSync = true
        voipRegistrationNeedsSync = true
        isTokenSyncInFlight = false
        activeChatID = nil
        activeChatMode = nil
    }

    func updateActiveChat(_ chat: Chat?) async {
        activeChatID = chat?.id
        activeChatMode = chat?.mode
    }

    func handleIncomingChatPushRoute(
        _ route: NotificationChatRoute,
        source: String,
        userInfo: [AnyHashable: Any]? = nil
    ) {
        assertPushRoutingMainThread()
        var postedUserInfo = userInfo ?? self.userInfo(for: route)
        let notificationType = resolvedNotificationType(from: postedUserInfo)
        if notificationType == "message" {
            Task {
                await clearTypingNotifications(for: route.chatID)
            }
        }
        if postedUserInfo["chat_id"] == nil {
            postedUserInfo["chat_id"] = route.chatID.uuidString
        }
        if postedUserInfo["mode"] == nil {
            postedUserInfo["mode"] = route.mode.rawValue
        }
        if postedUserInfo["message_id"] == nil, let messageID = route.messageID {
            postedUserInfo["message_id"] = messageID.uuidString
        }
        NotificationCenter.default.post(
            name: .primeMessagingIncomingChatPush,
            object: nil,
            userInfo: postedUserInfo
        )
        logger.info(
            "Received chat push route for chat \(route.chatID.uuidString, privacy: .public) source=\(source, privacy: .public)"
        )
    }

    func performBackgroundRefresh() async -> UIBackgroundFetchResult {
        await syncStoredDeviceTokenIfPossible(force: true)
        return .noData
    }

    func clearCallNotifications(for callID: UUID) async {
        #if os(tvOS)
        _ = callID
        #else
        let callIDString = callID.uuidString.lowercased()

        let pending = await notificationCenter.pendingNotificationRequests()
        let pendingIdentifiers = pending.compactMap { request -> String? in
            guard let rawCallID = request.content.userInfo["call_id"] as? String else { return nil }
            return rawCallID.lowercased() == callIDString ? request.identifier : nil
        }
        if pendingIdentifiers.isEmpty == false {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let delivered = await notificationCenter.deliveredNotifications()
        let deliveredIdentifiers = delivered.compactMap { notification -> String? in
            guard let rawCallID = notification.request.content.userInfo["call_id"] as? String else { return nil }
            return rawCallID.lowercased() == callIDString ? notification.request.identifier : nil
        }
        if deliveredIdentifiers.isEmpty == false {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
        #endif
    }

    private func startTokenSyncLoop() {
        tokenSyncTask?.cancel()
        tokenSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncStoredDeviceTokenIfPossible()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func clearTypingNotifications(for chatID: UUID) async {
        #if os(tvOS)
        _ = chatID
        #else
        let chatIDString = chatID.uuidString.lowercased()

        let pending = await notificationCenter.pendingNotificationRequests()
        let pendingIdentifiers = pending.compactMap { request -> String? in
            guard let notificationType = request.content.userInfo["notification_type"] as? String,
                  notificationType == "typing",
                  let rawChatID = request.content.userInfo["chat_id"] as? String,
                  rawChatID.lowercased() == chatIDString else {
                return nil
            }
            return request.identifier
        }
        if pendingIdentifiers.isEmpty == false {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let delivered = await notificationCenter.deliveredNotifications()
        let deliveredIdentifiers = delivered.compactMap { notification -> String? in
            guard let notificationType = notification.request.content.userInfo["notification_type"] as? String,
                  notificationType == "typing",
                  let rawChatID = notification.request.content.userInfo["chat_id"] as? String,
                  rawChatID.lowercased() == chatIDString else {
                return nil
            }
            return notification.request.identifier
        }
        if deliveredIdentifiers.isEmpty == false {
            notificationCenter.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
        #endif
    }

    private var stableDeviceIdentifier: String {
        if let existing = defaults.string(forKey: StorageKeys.deviceIdentifier), existing.isEmpty == false {
            return existing
        }

        let fallback = UUID().uuidString
        #if os(tvOS)
        let generated = fallback
        #else
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? fallback
        #endif
        defaults.set(generated, forKey: StorageKeys.deviceIdentifier)
        return generated
    }

    private func registrationSignature(userID: UUID, token: String) -> String {
        "\(userID.uuidString.lowercased()):\(stableDeviceIdentifier.lowercased()):\(token.lowercased())"
    }

    private var apnsTopic: String? {
        Bundle.main.bundleIdentifier
    }

    private var voipTopic: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return "\(bundleID).voip"
    }

    private func syncStoredDeviceTokenIfPossible(force: Bool = false) async {
        #if os(tvOS)
        return
        #else
        guard isTokenSyncInFlight == false else { return }

        let now = Date()
        if force == false,
           let lastDeviceTokenSyncAttemptAt,
           now.timeIntervalSince(lastDeviceTokenSyncAttemptAt) < 5 {
            return
        }

        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            let monitoredUserID
        else {
            return
        }

        isTokenSyncInFlight = true
        lastDeviceTokenSyncAttemptAt = now
        defer {
            isTokenSyncInFlight = false
        }

        if let token = defaults.string(forKey: StorageKeys.deviceToken), token.isEmpty == false {
            let signature = registrationSignature(userID: monitoredUserID, token: token)
            if force || registrationNeedsSync || signature != registeredTokenSignature {
                do {
                    let requestBody = DeviceTokenRegistrationRequest(
                        token: token,
                        platform: "ios",
                        deviceID: stableDeviceIdentifier,
                        tokenType: "apns_alert",
                        topic: apnsTopic
                    )
                    let body = try JSONEncoder().encode(requestBody)
                    _ = try await BackendRequestTransport.authorizedRequest(
                        baseURL: baseURL,
                        path: "/devices/register",
                        method: "POST",
                        body: body,
                        userID: monitoredUserID
                    )
                    registeredTokenSignature = signature
                    defaults.set(signature, forKey: StorageKeys.registeredTokenSignature)
                    registrationNeedsSync = false
                    logger.info("Registered APNs alert token with backend for user \(monitoredUserID.uuidString, privacy: .public)")
                } catch {
                    registrationNeedsSync = true
                    logger.error("APNs alert token registration failed, will retry: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if let voipToken = defaults.string(forKey: StorageKeys.voipDeviceToken), voipToken.isEmpty == false {
            let voipSignature = registrationSignature(userID: monitoredUserID, token: voipToken)
            if force || voipRegistrationNeedsSync || voipSignature != registeredVoIPTokenSignature {
                do {
                    let requestBody = DeviceTokenRegistrationRequest(
                        token: voipToken,
                        platform: "ios",
                        deviceID: stableDeviceIdentifier,
                        tokenType: "apns_voip",
                        topic: voipTopic
                    )
                    let body = try JSONEncoder().encode(requestBody)
                    _ = try await BackendRequestTransport.authorizedRequest(
                        baseURL: baseURL,
                        path: "/devices/register",
                        method: "POST",
                        body: body,
                        userID: monitoredUserID
                    )
                    registeredVoIPTokenSignature = voipSignature
                    defaults.set(voipSignature, forKey: StorageKeys.registeredVoIPTokenSignature)
                    voipRegistrationNeedsSync = false
                    logger.info("Registered APNs VoIP token with backend for user \(monitoredUserID.uuidString, privacy: .public)")
                } catch {
                    voipRegistrationNeedsSync = true
                    logger.error("APNs VoIP token registration failed, will retry: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        #endif
    }

    #if !os(tvOS)
    private func clearLegacyLocalNotificationRequestsIfNeeded() async {
        let pendingRequests = await notificationCenter.pendingNotificationRequests()
        guard pendingRequests.isEmpty == false else { return }
        let identifiers = pendingRequests.map(\.identifier)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        logger.info("Cleared legacy local notification requests: \(identifiers.count, privacy: .public)")
    }
    #endif
}

private struct DeviceTokenRegistrationRequest: Encodable {
    let token: String
    let platform: String
    let deviceID: String?
    let tokenType: String?
    let topic: String?

    enum CodingKeys: String, CodingKey {
        case token
        case platform
        case deviceID = "device_id"
        case tokenType = "token_type"
        case topic
    }
}

extension LocalPushNotificationService: UNUserNotificationCenterDelegate {
    nonisolated private func logPushTraceOffMain(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE service step=\(step) main=\(Thread.isMainThread)\(suffix)"
        NSLog("%@", message)
        print(message)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo

        if let route = NotificationCallRoute(userInfo: notification.request.content.userInfo) {
            await MainActor.run {
                self.logger.info("Received incoming call push while app is foreground. call=\(route.callID.uuidString, privacy: .public)")
                NotificationCallRouteStore.shared.queue(route)
                handleIncomingCallNotificationRoute(route, prewarmCallKit: true)
            }
            // For call payloads in foreground, avoid duplicate "Incoming call" banners.
            return []
        }

        if let route = NotificationChatRoute(userInfo: userInfo) {
            let notificationType = await MainActor.run { self.resolvedNotificationType(from: userInfo) }
            let shouldSuppressForActiveChat = await MainActor.run { () -> Bool in
                self.handleIncomingChatPushRoute(
                    route,
                    source: "will_present",
                    userInfo: userInfo
                )
                return self.activeChatID == route.chatID && self.activeChatMode == route.mode
            }

            await MainActor.run {
                if shouldSuppressForActiveChat {
                    self.logger.info(
                        "Suppressing foreground banner for active chat \(route.chatID.uuidString, privacy: .public) type=\(notificationType, privacy: .public)"
                    )
                } else if notificationType == "message" {
                    self.logger.info(
                        "Suppressing system foreground banner in favor of in-app banner chat=\(route.chatID.uuidString, privacy: .public)"
                    )
                } else {
                    self.logger.info(
                        "Presenting foreground system banner for chat \(route.chatID.uuidString, privacy: .public) type=\(notificationType, privacy: .public)"
                    )
                }
            }
            if shouldSuppressForActiveChat {
                return []
            }

            switch notificationType {
            case "typing":
                return [.banner, .list]
            case "reaction":
                return [.banner, .list, .sound]
            default:
                return []
            }
        }
        return []
    }

    #if !os(tvOS)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        logPushTraceOffMain("delegate.didReceiveResponse")

        if let chatRoute = NotificationChatRoute(userInfo: userInfo) {
            logPushTraceOffMain(
                "delegate.didReceiveResponse.persistChatRoute",
                details: "chat=\(chatRoute.chatID.uuidString)"
            )
            NotificationRouteStore.persistLaunchRoute(chatRoute)
            return
        }

        if let callRoute = NotificationCallRoute(userInfo: userInfo) {
            await MainActor.run {
                self.handleNotificationCallResponseTap(callRoute)
            }
            return
        }

        await MainActor.run {
            self.logPushTrace("handleNotificationResponseTap.invalidRoute")
        }
    }
    #endif

    @MainActor
    private func handleNotificationCallResponseTap(_ callRoute: NotificationCallRoute) {
        assertPushRoutingMainThread()
        logPushTrace("handleNotificationResponseTap.call.begin", details: "call=\(callRoute.callID.uuidString)")
        logger.info("Opened app from notification for call \(callRoute.callID.uuidString, privacy: .public)")
        NotificationCallRouteStore.shared.queue(callRoute)
        handleIncomingCallNotificationRoute(callRoute, prewarmCallKit: true)
    }

    private func userInfo(for route: NotificationChatRoute) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "chat_id": route.chatID.uuidString,
            "mode": route.mode.rawValue,
        ]
        if let messageID = route.messageID {
            userInfo["message_id"] = messageID.uuidString
        }
        return userInfo
    }

    @MainActor
    private func resolvedNotificationType(from userInfo: [AnyHashable: Any]) -> String {
        ((userInfo["notification_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased())
            ?? "message"
    }
}
