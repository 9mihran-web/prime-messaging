import Combine
import Foundation
import OSLog

private let notificationRoutingLogger = Logger(subsystem: "mirowin.Prime-Messaging", category: "PushRouting")

private enum PersistedNotificationRouteStorage {
    private enum Keys {
        nonisolated static let chatID = "push.pending_chat_route.chat_id"
        nonisolated static let mode = "push.pending_chat_route.mode"
        nonisolated static let messageID = "push.pending_chat_route.message_id"
        nonisolated static let savedAt = "push.pending_chat_route.saved_at"
    }

    private nonisolated(unsafe) static let defaults = UserDefaults.standard
    private nonisolated static let ttl: TimeInterval = 10 * 60

    nonisolated static func store(_ route: NotificationChatRoute) {
        defaults.set(route.chatID.uuidString, forKey: Keys.chatID)
        defaults.set(route.mode.rawValue, forKey: Keys.mode)
        defaults.set(route.messageID?.uuidString, forKey: Keys.messageID)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.savedAt)
        let message = "PUSHTRACE routeStore step=persisted.store main=\(Thread.isMainThread) chat=\(route.chatID.uuidString)"
        NSLog("%@", message)
        print(message)
    }

    nonisolated static func take() -> NotificationChatRoute? {
        defer { clear() }

        let timestamp = defaults.double(forKey: Keys.savedAt)
        guard timestamp > 0 else { return nil }
        guard Date().timeIntervalSince1970 - timestamp <= ttl else { return nil }
        guard
            let rawChatID = defaults.string(forKey: Keys.chatID),
            let chatID = UUID(uuidString: rawChatID)
        else {
            return nil
        }

        let rawMode = defaults.string(forKey: Keys.mode) ?? ChatMode.online.rawValue
        let mode = ChatMode(rawValue: rawMode) ?? .online
        let messageID: UUID?
        if let rawMessageID = defaults.string(forKey: Keys.messageID),
           rawMessageID.isEmpty == false {
            messageID = UUID(uuidString: rawMessageID)
        } else {
            messageID = nil
        }

        let route = NotificationChatRoute(chatID: chatID, mode: mode, messageID: messageID)
        let message = "PUSHTRACE routeStore step=persisted.take main=\(Thread.isMainThread) chat=\(route.chatID.uuidString)"
        NSLog("%@", message)
        print(message)
        return route
    }

    nonisolated static func clear() {
        defaults.removeObject(forKey: Keys.chatID)
        defaults.removeObject(forKey: Keys.mode)
        defaults.removeObject(forKey: Keys.messageID)
        defaults.removeObject(forKey: Keys.savedAt)
    }
}

struct NotificationChatRoute: Equatable, Sendable {
    let chatID: UUID
    let mode: ChatMode
    let messageID: UUID?

    nonisolated init(chatID: UUID, mode: ChatMode, messageID: UUID?) {
        self.chatID = chatID
        self.mode = mode
        self.messageID = messageID
    }

    nonisolated init?(userInfo: [AnyHashable: Any]) {
        guard
            let rawChatID = userInfo["chat_id"] as? String,
            let chatID = UUID(uuidString: rawChatID)
        else {
            return nil
        }

        self.chatID = chatID
        if let rawMode = userInfo["mode"] as? String,
           let parsedMode = ChatMode(rawValue: rawMode) {
            self.mode = parsedMode
        } else {
            self.mode = .online
        }

        if let rawMessageID = userInfo["message_id"] as? String {
            self.messageID = UUID(uuidString: rawMessageID)
        } else {
            self.messageID = nil
        }
    }
}

struct IncomingChatPushBannerPayload: Equatable, Sendable {
    let route: NotificationChatRoute
    let title: String
    let body: String
    let senderName: String?
    let groupTitle: String?
    let communityKind: String?

    nonisolated init?(userInfo: [AnyHashable: Any]) {
        guard let route = NotificationChatRoute(userInfo: userInfo) else { return nil }
        self.route = route

        let apsAlert = userInfo["aps"] as? [AnyHashable: Any]
        let alert = apsAlert?["alert"] as? [AnyHashable: Any]

        let rawTitle = (
            alert?["title"] as? String
            ?? userInfo["title"] as? String
            ?? userInfo["chat_title"] as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawBody = (
            alert?["body"] as? String
            ?? userInfo["body"] as? String
            ?? userInfo["message"] as? String
            ?? userInfo["text"] as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedTitle = rawTitle?.isEmpty == false ? rawTitle! : "Prime Messaging"
        let resolvedBody = rawBody?.isEmpty == false ? rawBody! : "New message"

        self.title = resolvedTitle
        self.body = resolvedBody
        self.senderName = (userInfo["sender_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.groupTitle = (userInfo["group_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.communityKind = (userInfo["community_kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NotificationCallRoute: Equatable, Sendable {
    enum Scope: String, Sendable {
        case direct
        case group
    }

    let callID: UUID
    let chatID: UUID?
    let mode: ChatMode
    let callerName: String?
    let displayName: String?
    let recipientUserID: UUID?
    let scope: Scope

    nonisolated init?(userInfo: [AnyHashable: Any]) {
        guard
            let rawCallID = userInfo["call_id"] as? String,
            let callID = UUID(uuidString: rawCallID)
        else {
            return nil
        }

        self.callID = callID
        if let rawChatID = userInfo["chat_id"] as? String {
            self.chatID = UUID(uuidString: rawChatID)
        } else {
            self.chatID = nil
        }

        self.callerName = (userInfo["caller_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (
            (userInfo["call_display_name"] as? String)
            ?? (userInfo["chat_title"] as? String)
            ?? (userInfo["display_name"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawRecipientID = (userInfo["recipient_user_id"] as? String) ?? (userInfo["callee_id"] as? String) {
            self.recipientUserID = UUID(uuidString: rawRecipientID)
        } else {
            self.recipientUserID = nil
        }

        if let rawMode = userInfo["mode"] as? String,
           let parsedMode = ChatMode(rawValue: rawMode) {
            self.mode = parsedMode
        } else {
            self.mode = .online
        }

        let rawScope = (
            (userInfo["scope"] as? String)
            ?? (userInfo["call_scope"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawScope == Scope.group.rawValue
            || (userInfo["notification_type"] as? String) == "incoming_group_call" {
            self.scope = .group
        } else {
            self.scope = .direct
        }
    }

    nonisolated var isGroupCall: Bool {
        scope == .group
    }

    nonisolated var preferredDisplayName: String? {
        let resolved = callKitDisplayName(
            primary: displayName,
            secondary: callerName,
            fallback: isGroupCall ? "Group Call" : "Prime Messaging"
        )
        return resolved == "Prime Messaging" || resolved == "Group Call" ? nil : resolved
    }
}

@MainActor
func handleIncomingCallNotificationRoute(
    _ route: NotificationCallRoute,
    prewarmCallKit: Bool = true
) {
    if route.isGroupCall {
        GroupInternetCallManager.shared.queueIncomingCallFromPush(
            callID: route.callID,
            chatID: route.chatID,
            displayName: route.preferredDisplayName,
            callerName: route.callerName,
            preferredUserID: route.recipientUserID,
            prewarmCallKit: prewarmCallKit
        )
        return
    }

    InternetCallManager.shared.queueIncomingCallFromPush(
        callID: route.callID,
        callerName: route.preferredDisplayName ?? route.callerName,
        preferredUserID: route.recipientUserID,
        prewarmCallKit: prewarmCallKit
    )
}

extension Notification.Name {
    static let primeMessagingOpenChat = Notification.Name("PrimeMessaging.openChatFromNotification")
    static let primeMessagingIncomingChatPush = Notification.Name("PrimeMessaging.incomingChatPush")
    static let primeMessagingDidRegisterDeviceToken = Notification.Name("PrimeMessaging.didRegisterDeviceToken")
    static let primeMessagingDidRegisterVoIPDeviceToken = Notification.Name("PrimeMessaging.didRegisterVoIPDeviceToken")
    static let primeMessagingDidInvalidateVoIPDeviceToken = Notification.Name("PrimeMessaging.didInvalidateVoIPDeviceToken")
    static let primeMessagingDidFailDeviceTokenRegistration = Notification.Name("PrimeMessaging.didFailDeviceTokenRegistration")
}

@MainActor
final class NotificationRouteStore {
    static let shared = NotificationRouteStore()

    private(set) var pendingRoute: NotificationChatRoute?
    private var lastQueuedRoute: NotificationChatRoute?
    private var lastQueuedAt: Date = .distantPast
    private let duplicateWindow: TimeInterval = 1.2

    private func assertPushRoutingMainThread(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE routeStore step=\(step) main=\(Thread.isMainThread)\(suffix)"
        notificationRoutingLogger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    func queue(_ route: NotificationChatRoute) {
        assertPushRoutingMainThread()
        logPushTrace("queue.begin", details: "chat=\(route.chatID.uuidString)")
        let now = Date()
        if let pendingRoute, pendingRoute == route {
            logPushTrace("queue.skipPendingMatch", details: "chat=\(route.chatID.uuidString)")
            return
        }
        if let lastQueuedRoute, lastQueuedRoute == route, now.timeIntervalSince(lastQueuedAt) <= duplicateWindow {
            logPushTrace("queue.skipDuplicateWindow", details: "chat=\(route.chatID.uuidString)")
            return
        }
        pendingRoute = route
        lastQueuedRoute = route
        lastQueuedAt = now
        logPushTrace("queue.end", details: "chat=\(route.chatID.uuidString)")
    }

    func rehydratePersistedRouteIfNeeded() {
        assertPushRoutingMainThread()
        guard pendingRoute == nil else { return }
        guard let persistedRoute = PersistedNotificationRouteStorage.take() else { return }
        logPushTrace("rehydratePersisted.begin", details: "chat=\(persistedRoute.chatID.uuidString)")
        queue(persistedRoute)
    }

    func consume() -> NotificationChatRoute? {
        assertPushRoutingMainThread()
        logPushTrace("consume.begin")
        defer {
            pendingRoute = nil
        }
        if let pendingRoute {
            logPushTrace("consume.end", details: "chat=\(pendingRoute.chatID.uuidString)")
        } else {
            logPushTrace("consume.end", details: "chat=nil")
        }
        return pendingRoute
    }

    nonisolated static func persistLaunchRoute(_ route: NotificationChatRoute) {
        PersistedNotificationRouteStorage.store(route)
    }
}

@MainActor
final class NotificationCallRouteStore: ObservableObject {
    static let shared = NotificationCallRouteStore()

    @Published private(set) var pendingRoute: NotificationCallRoute?
    private var lastQueuedRoute: NotificationCallRoute?
    private var lastQueuedAt: Date = .distantPast
    private let duplicateWindow: TimeInterval = 1.2

    private func assertPushRoutingMainThread(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(Thread.isMainThread, "\(function) must run on the main thread")
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE callRouteStore step=\(step) main=\(Thread.isMainThread)\(suffix)"
        notificationRoutingLogger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    func queue(_ route: NotificationCallRoute) {
        assertPushRoutingMainThread()
        logPushTrace("queue.begin", details: "call=\(route.callID.uuidString)")
        let now = Date()
        if let pendingRoute, pendingRoute == route {
            logPushTrace("queue.skipPendingMatch", details: "call=\(route.callID.uuidString)")
            return
        }
        if let lastQueuedRoute, lastQueuedRoute == route, now.timeIntervalSince(lastQueuedAt) <= duplicateWindow {
            logPushTrace("queue.skipDuplicateWindow", details: "call=\(route.callID.uuidString)")
            return
        }
        pendingRoute = route
        lastQueuedRoute = route
        lastQueuedAt = now
        logPushTrace("queue.end", details: "call=\(route.callID.uuidString)")
    }

    func consume() -> NotificationCallRoute? {
        assertPushRoutingMainThread()
        logPushTrace("consume.begin")
        defer {
            pendingRoute = nil
        }
        if let pendingRoute {
            logPushTrace("consume.end", details: "call=\(pendingRoute.callID.uuidString)")
        } else {
            logPushTrace("consume.end", details: "call=nil")
        }
        return pendingRoute
    }
}

struct RealtimeChatEvent: Decodable, Hashable, Sendable {
    let seq: Int?
    let type: String
    let chatID: UUID?
    let mode: ChatMode?
    let timestamp: Date?
    let actorUserID: UUID?
    let message: Message?
    let chat: Chat?
    let presence: Presence?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case seq
        case type
        case chatID
        case chatIDSnake = "chat_id"
        case mode
        case timestamp
        case actorUserID
        case actorUserIDSnake = "actor_user_id"
        case message
        case chat
        case presence
        case reason
    }

    init(
        seq: Int?,
        type: String,
        chatID: UUID?,
        mode: ChatMode?,
        timestamp: Date?,
        actorUserID: UUID?,
        message: Message?,
        chat: Chat?,
        presence: Presence?,
        reason: String?
    ) {
        self.seq = seq
        self.type = type
        self.chatID = chatID
        self.mode = mode
        self.timestamp = timestamp
        self.actorUserID = actorUserID
        self.message = message
        self.chat = chat
        self.presence = presence
        self.reason = reason
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        type = try container.decode(String.self, forKey: .type)
        chatID = try container.decodeIfPresent(UUID.self, forKey: .chatID)
            ?? container.decodeLossyUUIDIfPresent(forKey: .chatIDSnake)
        mode = try container.decodeIfPresent(ChatMode.self, forKey: .mode)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        actorUserID = try container.decodeIfPresent(UUID.self, forKey: .actorUserID)
            ?? container.decodeLossyUUIDIfPresent(forKey: .actorUserIDSnake)
        message = try container.decodeIfPresent(Message.self, forKey: .message)
        chat = try container.decodeIfPresent(Chat.self, forKey: .chat)
        presence = try container.decodeIfPresent(Presence.self, forKey: .presence)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

actor ChatRealtimeService {
    static let shared = ChatRealtimeService()

    private enum Constants {
        static let path = "/ws/realtime"
        static let pingInterval: Duration = .seconds(20)
        static let maxReconnectDelaySeconds: Double = 12
        static let sequenceStoragePrefix = "realtime.last_sequence"
    }

    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "Realtime")
    private let defaults = UserDefaults.standard
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) {
                    return date
                }
                if let fallbackDate = ISO8601DateFormatter().date(from: value) {
                    return fallbackDate
                }
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date payload for realtime event."
            )
        }
        return decoder
    }()

    private var activeUserID: UUID?
    private var activeMode: ChatMode = .online
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isConnected = false
    private var isFeedSubscribed = false
    private var subscribedChatIDs = Set<UUID>()
    private var streamContinuations: [UUID: AsyncStream<RealtimeChatEvent>.Continuation] = [:]

    func stream(for userID: UUID, mode: ChatMode = .online) async -> AsyncStream<RealtimeChatEvent> {
        await activate(userID: userID, mode: mode)

        let streamID = UUID()
        return AsyncStream<RealtimeChatEvent>(bufferingPolicy: .bufferingNewest(128)) { continuation in
            Task {
                self.registerStreamContinuation(continuation, streamID: streamID)
            }
        }
    }

    func activate(userID: UUID, mode: ChatMode) async {
        let shouldResetConnection = activeUserID != userID || activeMode != mode
        if shouldResetConnection {
            await disconnect(reason: "scope_changed")
            activeUserID = userID
            activeMode = mode
            reconnectAttempt = 0
        } else if activeUserID == nil {
            activeUserID = userID
            activeMode = mode
        }

        guard mode == .online else {
            await disconnect(reason: "mode_not_online")
            return
        }
        await connectIfNeeded()
    }

    func deactivateIfNeeded(for userID: UUID) async {
        guard activeUserID == userID else { return }
        await disconnect(reason: "deactivated")
    }

    func subscribe(chatID: UUID, userID: UUID, mode: ChatMode) async {
        await activate(userID: userID, mode: mode)
        guard mode == .online else { return }
        let inserted = subscribedChatIDs.insert(chatID).inserted
        guard inserted else { return }
        await sendCommand([
            "action": "subscribe",
            "chat_id": chatID.uuidString,
        ])
    }

    func unsubscribe(chatID: UUID, userID: UUID) async {
        guard activeUserID == userID else { return }
        let removed = subscribedChatIDs.remove(chatID) != nil
        guard removed else { return }
        await sendCommand([
            "action": "unsubscribe",
            "chat_id": chatID.uuidString,
        ])
    }

    func subscribeFeed(userID: UUID, mode: ChatMode) async {
        await activate(userID: userID, mode: mode)
        guard mode == .online else { return }
        guard isFeedSubscribed == false else { return }
        isFeedSubscribed = true
        await sendCommand(["action": "subscribe_feed"])
    }

    func unsubscribeFeed(userID: UUID) async {
        guard activeUserID == userID else { return }
        guard isFeedSubscribed else { return }
        isFeedSubscribed = false
        await sendCommand(["action": "unsubscribe_feed"])
    }

    func isLikelyConnected(userID: UUID) async -> Bool {
        activeUserID == userID && isConnected && socketTask != nil
    }

    func forceResync(userID: UUID) async {
        guard activeUserID == userID else { return }
        await sendCommand([
            "action": "resync",
            "since": lastSequence(for: userID),
        ])
    }

    func sendTyping(
        chatID: UUID,
        userID: UUID,
        mode: ChatMode,
        isTyping: Bool
    ) async {
        await activate(userID: userID, mode: mode)
        guard mode == .online else { return }
        guard activeUserID == userID else { return }

        await sendCommand([
            "action": "typing",
            "chat_id": chatID.uuidString,
            "is_typing": isTyping,
        ])
    }

    func sendPresenceHeartbeat(
        userID: UUID,
        mode: ChatMode,
        force: Bool = false
    ) async {
        await activate(userID: userID, mode: mode)
        guard mode == .online else { return }
        guard activeUserID == userID else { return }
        await sendPresenceCommand(force: force)
    }

    private func registerStreamContinuation(
        _ continuation: AsyncStream<RealtimeChatEvent>.Continuation,
        streamID: UUID
    ) {
        continuation.onTermination = { _ in
            Task { await self.unregisterStreamContinuation(streamID: streamID) }
        }
        streamContinuations[streamID] = continuation
    }

    private func unregisterStreamContinuation(streamID: UUID) {
        streamContinuations.removeValue(forKey: streamID)
    }

    private func connectIfNeeded() async {
        guard socketTask == nil else { return }
        guard let userID = activeUserID else { return }
        guard activeMode == .online else { return }
        guard let websocketURL = websocketURL(for: userID) else {
            logger.error("Realtime connection skipped: invalid backend URL")
            return
        }

        var request = URLRequest(url: websocketURL)
        request.timeoutInterval = 20

        if let accessToken = await resolvedAccessToken(for: userID) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        socketTask = socket
        isConnected = true
        reconnectAttempt = 0

        await sendHello(userID: userID)
        await sendPresenceCommand(force: true)
        startReceiveLoop()
        startPingLoop()
        logger.info("Realtime websocket connected for user \(userID.uuidString, privacy: .public)")
    }

    private func disconnect(reason: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        if let socketTask {
            socketTask.cancel(with: .goingAway, reason: nil)
        }
        socketTask = nil
        isConnected = false
        logger.info("Realtime websocket disconnected reason=\(reason, privacy: .public)")
    }

    private func scheduleReconnectIfNeeded(trigger: String) async {
        guard reconnectTask == nil else { return }
        guard activeMode == .online, activeUserID != nil else { return }

        reconnectAttempt += 1
        let delay = min(pow(1.7, Double(reconnectAttempt)), Constants.maxReconnectDelaySeconds)
        logger.info("Realtime reconnect scheduled in \(delay, privacy: .public)s trigger=\(trigger, privacy: .public)")

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            await self.performReconnect()
        }
    }

    private func performReconnect() async {
        reconnectTask = nil
        guard activeMode == .online, activeUserID != nil else { return }
        await disconnect(reason: "reconnect")
        await connectIfNeeded()
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while Task.isCancelled == false {
            guard let socketTask else { return }
            do {
                let message = try await socketTask.receive()
                await handleSocketMessage(message)
            } catch {
                isConnected = false
                logger.error("Realtime receive failed: \(error.localizedDescription, privacy: .public)")
                await scheduleReconnectIfNeeded(trigger: "receive_failed")
                return
            }
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    private func pingLoop() async {
        while Task.isCancelled == false {
            try? await Task.sleep(for: Constants.pingInterval)
            guard let socketTask else { return }
            do {
                try await sendPingAwaitingSingleCallback(socketTask)
            } catch {
                isConnected = false
                logger.error("Realtime ping failed: \(error.localizedDescription, privacy: .public)")
                await scheduleReconnectIfNeeded(trigger: "ping_failed")
                return
            }
            await sendPresenceCommand(force: false)
        }
    }

    private func sendPingAwaitingSingleCallback(_ socketTask: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var hasResumed = false

            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard hasResumed == false else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            socketTask.sendPing { error in
                if let error {
                    resumeOnce(.failure(error))
                } else {
                    resumeOnce(.success(()))
                }
            }
        }
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
        let rawPayload: Data?
        switch message {
        case let .string(text):
            rawPayload = text.data(using: .utf8)
        case let .data(data):
            rawPayload = data
        @unknown default:
            rawPayload = nil
        }

        guard let rawPayload else { return }

        do {
            let event = try decoder.decode(RealtimeChatEvent.self, from: rawPayload)
            if let userID = activeUserID, let sequence = event.seq {
                persistLastSequence(sequence, for: userID)
            }
            for continuation in streamContinuations.values {
                continuation.yield(event)
            }
        } catch {
            if let text = String(data: rawPayload, encoding: .utf8) {
                logger.debug("Realtime non-event payload: \(text, privacy: .public)")
            } else {
                logger.debug("Realtime payload decode skipped.")
            }
        }
    }

    private func sendHello(userID: UUID) async {
        let command: [String: Any] = [
            "action": "hello",
            "since": lastSequence(for: userID),
            "feed": isFeedSubscribed,
            "chat_ids": subscribedChatIDs.map(\.uuidString),
        ]
        await sendCommand(command)
    }

    private func sendPresenceCommand(force: Bool) async {
        guard let userID = activeUserID else { return }
        guard activeMode == .online else { return }
        await sendCommand([
            "action": "presence",
            "user_id": userID.uuidString,
            "force": force,
        ])
    }

    private func sendCommand(_ command: [String: Any]) async {
        guard let socketTask else { return }
        guard JSONSerialization.isValidJSONObject(command) else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await socketTask.send(.string(text))
        } catch {
            isConnected = false
            logger.error("Realtime send failed: \(error.localizedDescription, privacy: .public)")
            await scheduleReconnectIfNeeded(trigger: "send_failed")
        }
    }

    private func websocketURL(for userID: UUID) -> URL? {
        guard let baseURL = BackendConfiguration.currentBaseURL else { return nil }
        guard var components = URLComponents(url: baseURL.appending(path: Constants.path), resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID.uuidString),
            URLQueryItem(name: "since", value: String(lastSequence(for: userID))),
        ]
        return components.url
    }

    private func resolvedAccessToken(for userID: UUID) async -> String? {
        if let session = await AuthSessionStore.shared.session(for: userID),
           session.accessTokenExpiresAt > Date().addingTimeInterval(30) {
            return session.accessToken
        }
        if let session = await AuthSessionStore.shared.mostRecentSession(),
           session.userID == userID,
           session.accessTokenExpiresAt > Date().addingTimeInterval(30) {
            return session.accessToken
        }
        return nil
    }

    private func lastSequence(for userID: UUID) -> Int {
        defaults.integer(forKey: sequenceStorageKey(for: userID))
    }

    private func persistLastSequence(_ sequence: Int, for userID: UUID) {
        guard sequence > 0 else { return }
        let key = sequenceStorageKey(for: userID)
        let current = defaults.integer(forKey: key)
        if sequence > current {
            defaults.set(sequence, forKey: key)
        }
    }

    private func sequenceStorageKey(for userID: UUID) -> String {
        "\(Constants.sequenceStoragePrefix).\(userID.uuidString.lowercased())"
    }
}

private extension KeyedDecodingContainer where Key: CodingKey {
    nonisolated func decodeLossyUUIDIfPresent(forKey key: Key) -> UUID? {
        if let value = try? decodeIfPresent(UUID.self, forKey: key) {
            return value
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return UUID(uuidString: stringValue)
        }
        return nil
    }
}
