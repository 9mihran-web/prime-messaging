import Foundation
import UIKit
import UserNotifications

@MainActor
final class LocalPushNotificationService: NSObject, PushNotificationService {
    private let notificationCenter: UNUserNotificationCenter
    private var monitorTask: Task<Void, Never>?
    private var seenMessageIDs: Set<UUID> = []
    private var activeChatID: UUID?
    private var monitoredUserID: UUID?

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
    }

    func registerForRemoteNotifications() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch { }
    }

    func syncDeviceToken(_ token: Data) async { }

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
        if monitoredUserID != currentUser.id {
            seenMessageIDs = []
            activeChatID = nil
        }

        monitoredUserID = currentUser.id
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runMonitorLoop(currentUser: currentUser, chatRepository: chatRepository)
        }
    }

    func stopMonitoring() async {
        monitorTask?.cancel()
        monitorTask = nil
        seenMessageIDs.removeAll()
        activeChatID = nil
        monitoredUserID = nil
    }

    func updateActiveChat(_ chat: Chat?) async {
        activeChatID = chat?.id
    }

    private func runMonitorLoop(currentUser: User, chatRepository: ChatRepository) async {
        var didSeedSnapshot = false

        while !Task.isCancelled {
            do {
                let snapshot = try await collectSnapshot(currentUser: currentUser, chatRepository: chatRepository)
                if didSeedSnapshot {
                    for item in snapshot.newIncomingMessages where item.chat.id != activeChatID {
                        await scheduleNotification(for: item)
                    }
                } else {
                    didSeedSnapshot = true
                }
                seenMessageIDs.formUnion(snapshot.allMessageIDs)
            } catch { }

            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func collectSnapshot(currentUser: User, chatRepository: ChatRepository) async throws -> MessageSnapshot {
        var allMessageIDs: Set<UUID> = []
        var newIncomingMessages: [NotifiableMessage] = []

        for mode in ChatMode.allCases {
            let chats = try await chatRepository.fetchChats(mode: mode, for: currentUser.id)
            for chat in chats {
                let messages = try await chatRepository.fetchMessages(chatID: chat.id, mode: chat.mode)
                for message in messages {
                    allMessageIDs.insert(message.id)

                    guard
                        message.senderID != currentUser.id,
                        !seenMessageIDs.contains(message.id)
                    else { continue }

                    newIncomingMessages.append(NotifiableMessage(chat: chat, message: message))
                }
            }
        }

        return MessageSnapshot(allMessageIDs: allMessageIDs, newIncomingMessages: newIncomingMessages)
    }

    private func scheduleNotification(for item: NotifiableMessage) async {
        let content = UNMutableNotificationContent()
        content.title = item.chat.resolvedDisplayTitle
        content.body = item.message.text ?? "New message"
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "chat_id": item.chat.id.uuidString,
            "mode": item.chat.mode.rawValue,
        ]

        let request = UNNotificationRequest(
            identifier: item.message.id.uuidString,
            content: content,
            trigger: nil
        )

        try? await notificationCenter.add(request)
    }
}

extension LocalPushNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}

private struct MessageSnapshot {
    let allMessageIDs: Set<UUID>
    let newIncomingMessages: [NotifiableMessage]
}

private struct NotifiableMessage {
    let chat: Chat
    let message: Message
}
