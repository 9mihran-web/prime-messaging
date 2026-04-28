import Foundation
import Intents
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler

        guard let mutableContent = (request.content.mutableCopy() as? UNMutableNotificationContent) else {
            contentHandler(request.content)
            return
        }

        bestAttemptContent = mutableContent

        Task {
            let updatedContent = await Self.enrichedContent(from: mutableContent)
            bestAttemptContent = updatedContent
            contentHandler(updatedContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private static func enrichedContent(from content: UNMutableNotificationContent) async -> UNMutableNotificationContent {
        let userInfo = content.userInfo
        let notificationType = normalizedString(userInfo["notification_type"]) ?? "message"
        let conversationIdentifier = normalizedString(userInfo["chat_id"]) ?? UUID().uuidString

        if notificationType == "message" {
            await clearDeliveredTypingNotifications(for: conversationIdentifier)
        }

        guard
            let senderName = normalizedString(userInfo["sender_name"]) ?? normalizedString(userInfo["title"]) ?? normalizedString(userInfo["display_name"])
        else {
            return content
        }

        let senderIdentifier = normalizedString(userInfo["sender_id"]) ?? senderName
        let isGroupConversation = normalizedString(userInfo["chat_type"]) == "group"
        let groupTitle = normalizedString(userInfo["group_title"])
        let senderAvatarURL = normalizedURL(userInfo["sender_photo_url"])
        let groupAvatarURL = normalizedURL(userInfo["group_photo_url"])
        let primaryImageName = isGroupConversation ? (groupTitle ?? senderName) : senderName
        let primaryImageURL = isGroupConversation ? groupAvatarURL : senderAvatarURL
        let senderImage = await avatarImage(for: primaryImageName, avatarURL: primaryImageURL)
        let senderDisplayName: String
        if isGroupConversation, let groupTitle, groupTitle.isEmpty == false {
            senderDisplayName = "\(senderName) • \(groupTitle)"
        } else {
            senderDisplayName = senderName
        }

        let sender = INPerson(
            personHandle: INPersonHandle(value: senderIdentifier, type: .unknown),
            nameComponents: nil,
            displayName: senderDisplayName,
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: senderIdentifier,
            isMe: false,
            suggestionType: .none
        )

        let currentUser = INPerson(
            personHandle: INPersonHandle(value: "current-user", type: .unknown),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: "current-user",
            isMe: true,
            suggestionType: .none
        )

        let intent = INSendMessageIntent(
            recipients: [currentUser],
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: isGroupConversation ? INSpeakableString(spokenPhrase: groupTitle ?? content.title) : nil,
            conversationIdentifier: conversationIdentifier,
            serviceName: "Prime Messaging",
            sender: sender,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        if notificationType != "typing" {
            try? await interaction.donate()
        }

        do {
            let updatedContent = try content.updating(from: intent) as? UNMutableNotificationContent ?? content
            updatedContent.threadIdentifier = conversationIdentifier
            updatedContent.title = senderDisplayName
            updatedContent.subtitle = ""
            return updatedContent
        } catch {
            return content
        }
    }

    private static func avatarImage(for senderName: String, avatarURL: URL?) async -> INImage? {
        if let avatarURL, let remoteImageData = await downloadImageData(from: avatarURL) {
            return INImage(imageData: remoteImageData)
        }

        guard let placeholderData = placeholderAvatarData(for: senderName) else {
            return nil
        }
        return INImage(imageData: placeholderData)
    }

    private static func downloadImageData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .returnCacheDataElseLoad

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func placeholderAvatarData(for senderName: String) -> Data? {
        let initials = senderInitials(from: senderName)
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.20, green: 0.49, blue: 0.92, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: bounds)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle,
            ]

            let textRect = CGRect(x: 0, y: 34, width: size.width, height: 52)
            NSString(string: initials).draw(in: textRect, withAttributes: attributes)
        }

        return image.pngData()
    }

    private static func senderInitials(from senderName: String) -> String {
        let components = senderName
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(2)

        let initials = components.compactMap { component -> String? in
            guard let scalar = component.first else { return nil }
            return String(scalar).uppercased()
        }

        let joined = initials.joined()
        return joined.isEmpty ? "PM" : joined
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let rawValue = value as? String else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func normalizedURL(_ value: Any?) -> URL? {
        guard let stringValue = normalizedString(value) else { return nil }
        return URL(string: stringValue)
    }

    private static func clearDeliveredTypingNotifications(for chatID: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await deliveredNotifications(from: center)
        let identifiers = delivered.compactMap { notification -> String? in
            let userInfo = notification.request.content.userInfo
            guard normalizedString(userInfo["notification_type"]) == "typing" else { return nil }
            guard normalizedString(userInfo["chat_id"]) == chatID else { return nil }
            return notification.request.identifier
        }
        if identifiers.isEmpty == false {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private static func deliveredNotifications(from center: UNUserNotificationCenter) async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
    }
}
