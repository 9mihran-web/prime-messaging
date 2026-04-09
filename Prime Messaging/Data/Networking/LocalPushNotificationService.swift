import BackgroundTasks
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class LocalPushNotificationService: NSObject, PushNotificationService {
    static let shared = LocalPushNotificationService()

    private enum StorageKeys {
        static let lastProcessedPrefix = "push.last_processed_at"
        static let deviceToken = "push.device_token"
    }

    private enum BackgroundTaskIdentifiers {
        static let refresh = "mirowin.PrimeMessaging.notifications.refresh"
    }

    private static var didRegisterBackgroundTasks = false

    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "PushNotifications")
    private var monitorTask: Task<Void, Never>?
    private var seenMessageKeys: Set<String> = []
    private var activeChatID: UUID?
    private var activeConversationKey: String?
    private var monitoredUserID: UUID?
    private var lastProcessedAt: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isPollingEnabled = UIApplication.shared.applicationState == .active
    private var monitoredUser: User?
    private var monitoredChatRepository: (any ChatRepository)?
    private var isRefreshInFlight = false
    private var lastDeviceTokenSyncAttemptAt: Date?

    init(notificationCenter: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        super.init()
        #if !os(tvOS)
        notificationCenter.delegate = self
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPollingEnabled = false
                self.scheduleBackgroundRefresh()
                self.beginBackgroundMonitoringWindowIfNeeded()
                _ = await self.performBackgroundRefresh()
                self.endBackgroundMonitoringWindowIfNeeded()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPollingEnabled = true
                await self.syncStoredDeviceTokenIfPossible(force: true)
            }
        }
        #endif
    }

    func registerBackgroundTasksIfNeeded() {
        #if os(tvOS)
        return
        #else
        guard Self.didRegisterBackgroundTasks == false else { return }
        Self.didRegisterBackgroundTasks = true

        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskIdentifiers.refresh,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                await Self.shared.handleBackgroundRefreshTask(refreshTask)
            }
        }

        if didRegister == false {
            logger.error("Failed to register BGAppRefreshTask for local notifications.")
        }
        #endif
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
        logger.info("Stored APNs token locally. Hex length: \(tokenString.count, privacy: .public)")
        await syncStoredDeviceTokenIfPossible()
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
        #if os(tvOS)
        monitoredUser = currentUser
        monitoredChatRepository = chatRepository
        monitoredUserID = currentUser.id
        seenMessageKeys = []
        activeChatID = nil
        activeConversationKey = nil
        lastProcessedAt = nil
        monitorTask?.cancel()
        monitorTask = nil
        return
        #else
        if monitoredUserID != currentUser.id {
            seenMessageKeys = []
            activeChatID = nil
            activeConversationKey = nil
            lastProcessedAt = loadLastProcessedDate(for: currentUser.id) ?? .now
        }

        monitoredUser = currentUser
        monitoredChatRepository = chatRepository
        monitoredUserID = currentUser.id
        lastDeviceTokenSyncAttemptAt = nil
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runMonitorLoop(currentUser: currentUser, chatRepository: chatRepository)
        }
        await syncStoredDeviceTokenIfPossible()
        isPollingEnabled = UIApplication.shared.applicationState == .active
        scheduleBackgroundRefresh()
        endBackgroundMonitoringWindowIfNeeded()
        #endif
    }

    func stopMonitoring() async {
        monitorTask?.cancel()
        monitorTask = nil
        seenMessageKeys.removeAll()
        activeChatID = nil
        activeConversationKey = nil
        monitoredUserID = nil
        monitoredUser = nil
        monitoredChatRepository = nil
        lastProcessedAt = nil
        lastDeviceTokenSyncAttemptAt = nil
        endBackgroundMonitoringWindowIfNeeded()
    }

    func updateActiveChat(_ chat: Chat?) async {
        activeChatID = chat?.id
        if let chat, let monitoredUserID {
            activeConversationKey = conversationKey(for: chat, currentUserID: monitoredUserID)
        } else {
            activeConversationKey = nil
        }
    }

    private func runMonitorLoop(currentUser: User, chatRepository: ChatRepository) async {
        while !Task.isCancelled {
            guard isPollingEnabled else {
                try? await Task.sleep(for: .seconds(4))
                continue
            }

            do {
                await syncStoredDeviceTokenIfPossible()
                let snapshot = try await collectSnapshot(currentUser: currentUser, chatRepository: chatRepository)
                for item in snapshot.newIncomingMessages where item.chat.id != activeChatID {
                    await scheduleNotification(for: item, currentUserID: currentUser.id)
                }
                seenMessageKeys.formUnion(snapshot.allMessageKeys)
                if let newestDate = snapshot.newestMessageDate {
                    let persistedDate = max(lastProcessedAt ?? .distantPast, newestDate)
                    lastProcessedAt = persistedDate
                    saveLastProcessedDate(persistedDate, for: currentUser.id)
                }
            } catch { }

            try? await Task.sleep(for: .seconds(4))
        }
    }

    func performBackgroundRefresh() async -> UIBackgroundFetchResult {
        #if os(tvOS)
        return .noData
        #else
        guard isRefreshInFlight == false else {
            return .noData
        }

        guard
            let currentUser = monitoredUser,
            let chatRepository = monitoredChatRepository
        else {
            return .noData
        }

        isRefreshInFlight = true
        defer {
            isRefreshInFlight = false
            scheduleBackgroundRefresh()
        }

        do {
            let snapshot = try await collectSnapshot(currentUser: currentUser, chatRepository: chatRepository)
            for item in snapshot.newIncomingMessages where item.chat.id != activeChatID {
                await scheduleNotification(for: item, currentUserID: currentUser.id)
            }
            seenMessageKeys.formUnion(snapshot.allMessageKeys)
            if let newestDate = snapshot.newestMessageDate {
                let persistedDate = max(lastProcessedAt ?? .distantPast, newestDate)
                lastProcessedAt = persistedDate
                saveLastProcessedDate(persistedDate, for: currentUser.id)
            }

            if NetworkUsagePolicy.hasReachableNetwork() {
                await chatRepository.retryPendingOutgoingMessages(currentUserID: currentUser.id)
            }

            return snapshot.newIncomingMessages.isEmpty ? .noData : .newData
        } catch {
            logger.error("Background notification refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        #endif
    }

    private func collectSnapshot(currentUser: User, chatRepository: ChatRepository) async throws -> MessageSnapshot {
        var allMessageKeys: Set<String> = []
        var newIncomingMessages: [NotifiableMessage] = []
        var newestMessageDate: Date?

        for mode in monitoredModes(for: currentUser) {
            let chats = (try? await chatRepository.fetchChats(mode: mode, for: currentUser.id)) ?? []
            for chat in chats {
                guard let decoratedChat = await ChatThreadStateStore.shared.apply(to: chat, ownerUserID: currentUser.id) else {
                    continue
                }

                let conversationKey = conversationKey(for: decoratedChat, currentUserID: currentUser.id)
                let messages = (try? await chatRepository.fetchMessages(chatID: decoratedChat.id, mode: decoratedChat.mode)) ?? []
                for message in messages {
                    let messageKey = stableNotificationKey(for: message, conversationKey: conversationKey)
                    allMessageKeys.insert(messageKey)
                    newestMessageDate = max(newestMessageDate ?? .distantPast, message.createdAt)

                    guard
                        message.senderID != currentUser.id,
                        !seenMessageKeys.contains(messageKey),
                        shouldNotify(for: decoratedChat, conversationKey: conversationKey),
                        message.createdAt > (lastProcessedAt ?? .distantPast)
                    else { continue }

                    newIncomingMessages.append(NotifiableMessage(chat: decoratedChat, message: message))
                }
            }
        }

        return MessageSnapshot(
            allMessageKeys: allMessageKeys,
            newIncomingMessages: newIncomingMessages,
            newestMessageDate: newestMessageDate
        )
    }

    private func monitoredModes(for currentUser: User) -> [ChatMode] {
        currentUser.isOfflineOnly ? [.offline] : [.smart, .online]
    }

    private func scheduleNotification(for item: NotifiableMessage, currentUserID: UUID) async {
        #if os(tvOS)
        return
        #else
        let content = UNMutableNotificationContent()
        content.title = item.chat.displayTitle(for: currentUserID)
        content.body = item.chat.notificationPreferences.previewEnabled
            ? item.message.notificationPreview
            : "New message"
        #if !os(tvOS)
        content.sound = item.message.isSilentDelivery ? nil : notificationSound(for: item.chat.notificationPreferences)
        #endif
        content.badge = item.chat.notificationPreferences.badgeEnabled ? 1 : nil
        content.userInfo = [
            "chat_id": item.chat.id.uuidString,
            "mode": item.chat.mode.rawValue,
            "message_id": item.message.id.uuidString,
            "chat_type": item.chat.type.rawValue,
        ]

        let request = UNNotificationRequest(
            identifier: item.message.id.uuidString,
            content: content,
            trigger: nil
        )

        try? await notificationCenter.add(request)
        #endif
    }

    private func beginBackgroundMonitoringWindowIfNeeded() {
        #if os(tvOS)
        return
        #else
        guard monitorTask != nil else { return }
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PrimeMessagingOnlineMonitor") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundMonitoringWindowIfNeeded()
            }
        }
        #endif
    }

    private func endBackgroundMonitoringWindowIfNeeded() {
        #if os(tvOS)
        backgroundTaskID = .invalid
        #else
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }

    private func scheduleBackgroundRefresh() {
        #if os(tvOS)
        return
        #else
        guard monitoredUserID != nil else { return }

        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskIdentifiers.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to submit BGAppRefreshTask: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func handleBackgroundRefreshTask(_ task: BGAppRefreshTask) async {
        #if os(tvOS)
        task.setTaskCompleted(success: false)
        #else
        scheduleBackgroundRefresh()

        let work = Task<UIBackgroundFetchResult, Never> { @MainActor [weak self] in
            guard let self else { return .noData }
            return await self.performBackgroundRefresh()
        }

        task.expirationHandler = {
            work.cancel()
        }

        let result = await work.value
        task.setTaskCompleted(success: result != .failed)
        #endif
    }

    private func storageKey(for userID: UUID) -> String {
        "\(StorageKeys.lastProcessedPrefix).\(userID.uuidString)"
    }

    private func syncStoredDeviceTokenIfPossible(force: Bool = false) async {
        #if os(tvOS)
        return
        #else
        let now = Date()
        if force == false,
           let lastDeviceTokenSyncAttemptAt,
           now.timeIntervalSince(lastDeviceTokenSyncAttemptAt) < 45 {
            return
        }

        lastDeviceTokenSyncAttemptAt = now

        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            let monitoredUserID,
            let token = defaults.string(forKey: StorageKeys.deviceToken),
            !token.isEmpty
        else {
            return
        }

        let requestBody = DeviceTokenRegistrationRequest(token: token, platform: "ios")

        do {
            let body = try JSONEncoder().encode(requestBody)
            _ = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/devices/register",
                method: "POST",
                body: body,
                userID: monitoredUserID
            )
            logger.info("Registered APNs token with backend for user \(monitoredUserID.uuidString, privacy: .public)")
        } catch {
            logger.error("Authorized APNs token registration failed: \(error.localizedDescription, privacy: .public)")
            do {
                try await registerDeviceTokenWithLegacyFallback(
                    baseURL: baseURL,
                    userID: monitoredUserID,
                    token: token
                )
                logger.info(
                    "Registered APNs token with backend via legacy fallback for user \(monitoredUserID.uuidString, privacy: .public)"
                )
            } catch {
                logger.error("Legacy APNs token registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    private func registerDeviceTokenWithLegacyFallback(baseURL: URL, userID: UUID, token: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/devices/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.allowsCellularAccess = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let legacyBody = DeviceTokenRegistrationRequest(
            token: token,
            platform: "ios",
            userID: userID.uuidString,
            currentUserID: userID.uuidString
        )
        request.httpBody = try JSONEncoder().encode(legacyBody)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
            throw AuthRepositoryError.backendUnavailable
        }
    }

    private func loadLastProcessedDate(for userID: UUID) -> Date? {
        guard let timestamp = defaults.object(forKey: storageKey(for: userID)) as? TimeInterval else {
            return nil
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    private func saveLastProcessedDate(_ date: Date, for userID: UUID) {
        defaults.set(date.timeIntervalSince1970, forKey: storageKey(for: userID))
    }

    private func shouldNotify(for chat: Chat, conversationKey: String) -> Bool {
        guard chat.notificationPreferences.muteState.suppressesNotifications == false else {
            return false
        }

        if let activeConversationKey, activeConversationKey == conversationKey {
            return false
        }

        return true
    }

    #if !os(tvOS)
    private func notificationSound(for preferences: NotificationPreferences) -> UNNotificationSound? {
        guard preferences.muteState.suppressesNotifications == false else {
            return nil
        }

        if let customSoundName = preferences.customSoundName?.trimmingCharacters(in: .whitespacesAndNewlines),
           customSoundName.isEmpty == false {
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        }

        return UNNotificationSound(named: UNNotificationSoundName(rawValue: "notification_banner.wav"))
    }
    #endif

    private func stableNotificationKey(for message: Message, conversationKey: String) -> String {
        let logicalID = message.clientMessageID.uuidString
        return "\(conversationKey):\(logicalID)"
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
            if let groupID = chat.group?.id {
                return "group:\(groupID.uuidString)"
            }
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "group-fallback:\(participantKey)"
        case .secret:
            return "secret:\(chat.id.uuidString)"
        }
    }
}

private struct DeviceTokenRegistrationRequest: Encodable {
    let token: String
    let platform: String
    let userID: String?
    let currentUserID: String?

    init(token: String, platform: String, userID: String? = nil, currentUserID: String? = nil) {
        self.token = token
        self.platform = platform
        self.userID = userID
        self.currentUserID = currentUserID
    }

    enum CodingKeys: String, CodingKey {
        case token
        case platform
        case userID = "user_id"
        case currentUserID = "userID"
    }
}

extension LocalPushNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
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
        guard let route = NotificationChatRoute(userInfo: response.notification.request.content.userInfo) else {
            return
        }

        await MainActor.run {
            self.logger.info("Opened app from notification for chat \(route.chatID.uuidString, privacy: .public)")
            NotificationRouteStore.shared.queue(route)
            NotificationCenter.default.post(
                name: .primeMessagingOpenChat,
                object: nil,
                userInfo: response.notification.request.content.userInfo
            )
        }
    }
    #endif
}

private struct MessageSnapshot {
    let allMessageKeys: Set<String>
    let newIncomingMessages: [NotifiableMessage]
    let newestMessageDate: Date?
}

private struct NotifiableMessage {
    let chat: Chat
    let message: Message
}

private extension Message {
    var notificationPreview: String {
        if let text, text.isEmpty == false {
            return text
        }

        if voiceMessage != nil {
            return "Voice message"
        }

        switch attachments.first?.type {
        case .photo:
            return "Photo"
        case .audio:
            return "Audio"
        case .video:
            return "Video"
        case .document:
            return "Document"
        case .contact:
            return "Contact"
        case .location:
            return "Location"
        case nil:
            return "New message"
        }
    }
}
