import Combine
import Foundation

struct NotificationChatRoute: Equatable, Sendable {
    let chatID: UUID
    let mode: ChatMode
    let messageID: UUID?

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

struct NotificationCallRoute: Equatable, Sendable {
    let callID: UUID
    let chatID: UUID?
    let mode: ChatMode
    let callerName: String?

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

        if let rawMode = userInfo["mode"] as? String,
           let parsedMode = ChatMode(rawValue: rawMode) {
            self.mode = parsedMode
        } else {
            self.mode = .online
        }
    }
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
final class NotificationRouteStore: ObservableObject {
    static let shared = NotificationRouteStore()

    @Published private(set) var pendingRoute: NotificationChatRoute?
    private var lastQueuedRoute: NotificationChatRoute?
    private var lastQueuedAt: Date = .distantPast
    private let duplicateWindow: TimeInterval = 1.2

    func queue(_ route: NotificationChatRoute) {
        let now = Date()
        if let pendingRoute, pendingRoute == route {
            return
        }
        if let lastQueuedRoute, lastQueuedRoute == route, now.timeIntervalSince(lastQueuedAt) <= duplicateWindow {
            return
        }
        pendingRoute = route
        lastQueuedRoute = route
        lastQueuedAt = now
    }

    func consume() -> NotificationChatRoute? {
        defer {
            pendingRoute = nil
        }
        return pendingRoute
    }
}

@MainActor
final class NotificationCallRouteStore: ObservableObject {
    static let shared = NotificationCallRouteStore()

    @Published private(set) var pendingRoute: NotificationCallRoute?

    func queue(_ route: NotificationCallRoute) {
        pendingRoute = route
    }

    func consume() -> NotificationCallRoute? {
        defer {
            pendingRoute = nil
        }
        return pendingRoute
    }
}
