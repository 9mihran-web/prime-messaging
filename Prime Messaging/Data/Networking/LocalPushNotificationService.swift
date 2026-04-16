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

    func handleIncomingChatPushRoute(_ route: NotificationChatRoute, source: String) {
        NotificationCenter.default.post(
            name: .primeMessagingIncomingChatPush,
            object: nil,
            userInfo: userInfo(for: route)
        )
        logger.info(
            "Received chat push route for chat \(route.chatID.uuidString, privacy: .public) source=\(source, privacy: .public)"
        )
    }

    func performBackgroundRefresh() async -> UIBackgroundFetchResult {
        await syncStoredDeviceTokenIfPossible(force: true)
        return .noData
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
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let route = NotificationCallRoute(userInfo: notification.request.content.userInfo) {
            await MainActor.run {
                self.logger.info("Received incoming call push while app is foreground. call=\(route.callID.uuidString, privacy: .public)")
                NotificationCallRouteStore.shared.queue(route)
                InternetCallManager.shared.queueIncomingCallFromPush(callID: route.callID, callerName: route.callerName)
            }
        }

        if let route = NotificationChatRoute(userInfo: notification.request.content.userInfo) {
            let shouldSuppressInAppBanner = await MainActor.run { () -> Bool in
                self.handleIncomingChatPushRoute(route, source: "will_present")
                return self.activeChatID == route.chatID && self.activeChatMode == route.mode
            }

            if shouldSuppressInAppBanner {
                await MainActor.run {
                    self.logger.info(
                        "Suppressing foreground banner for active chat \(route.chatID.uuidString, privacy: .public)"
                    )
                }
                return []
            }
        }

        var options: UNNotificationPresentationOptions = [.banner, .list]
        #if !os(tvOS)
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        #endif
        if notification.request.content.badge != nil {
            options.insert(.badge)
        }
        return options
    }

    #if !os(tvOS)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let callRoute = NotificationCallRoute(userInfo: userInfo) {
            await MainActor.run {
                self.logger.info("Opened app from notification for call \(callRoute.callID.uuidString, privacy: .public)")
                NotificationCallRouteStore.shared.queue(callRoute)
                InternetCallManager.shared.queueIncomingCallFromPush(callID: callRoute.callID, callerName: callRoute.callerName)
            }
            return
        }

        guard let chatRoute = NotificationChatRoute(userInfo: userInfo) else {
            await MainActor.run {
                self.logger.error("Failed to build notification route from push tap payload.")
            }
            return
        }

        await MainActor.run {
            self.handleIncomingChatPushRoute(chatRoute, source: "did_receive")
            self.logger.info("Opened app from notification for chat \(chatRoute.chatID.uuidString, privacy: .public)")
            NotificationRouteStore.shared.queue(chatRoute)
        }
    }
    #endif

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
}
