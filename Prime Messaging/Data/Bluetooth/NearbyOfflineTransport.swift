import CryptoKit
import Foundation
import MultipeerConnectivity
import UIKit

@MainActor
final class NearbyOfflineTransport: NSObject, OfflineTransporting {
    private struct KnownPeer {
        let peerID: MCPeerID
        var offlinePeer: OfflinePeer
    }

    private struct WireMessage: Codable {
        let id: UUID
        let chatID: UUID
        let senderID: UUID
        let text: String
        let createdAt: TimeInterval
    }

    private static let serviceType = "prmsgchat"
    private static let currentUserKey = "app_state.current_user"
    private static let installationIDKey = "offline_transport.installation_id"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentUser: User?
    private var localPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isScanning = false
    private var knownPeers: [UUID: KnownPeer] = [:]
    private var peerIDsByDisplayName: [String: UUID] = [:]
    private var chatsByID: [UUID: Chat] = [:]
    private var messagesByChatID: [UUID: [Message]] = [:]
    private var pendingConnections: [UUID: CheckedContinuation<BluetoothSession, Error>] = [:]
    private var pendingConnectionTimeouts: [UUID: Task<Void, Never>] = [:]

    override init() {
        super.init()
    }

    func updateCurrentUser(_ user: User) async {
        let shouldRestart = currentUser?.id != user.id ||
            currentUser?.profile.username != user.profile.username ||
            currentUser?.profile.displayName != user.profile.displayName

        currentUser = user

        if shouldRestart && isScanning {
            rebuildTransport()
        }
    }

    func startScanning() async {
        isScanning = true
        ensureTransport()
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
    }

    func stopScanning() async {
        isScanning = false
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
    }

    func discoveredPeers() async -> [OfflinePeer] {
        knownPeers.values
            .map(\.offlinePeer)
            .sorted(by: { lhs, rhs in
                if lhs.signalStrength != rhs.signalStrength {
                    return lhs.signalStrength > rhs.signalStrength
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            })
    }

    func connect(to peer: OfflinePeer) async throws -> BluetoothSession {
        ensureTransport()

        guard let knownPeer = knownPeers[peer.id], let session, let browser else {
            throw OfflineTransportError.peerUnavailable
        }

        if session.connectedPeers.contains(knownPeer.peerID) {
            return bluetoothSession(for: peer.id, state: .connected)
        }

        browser.invitePeer(knownPeer.peerID, to: session, withContext: nil, timeout: 10)

        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[peer.id] = continuation
            scheduleConnectionTimeout(for: peer.id)
        }
    }

    func fetchChats(currentUserID: UUID) async -> [Chat] {
        let savedMessages = makeSavedMessagesChat(for: currentUserID)
        let directChats = chatsByID.values
            .filter { $0.type != .selfChat }
            .sorted(by: { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            })

        return [savedMessages] + directChats
    }

    func openChat(with peer: OfflinePeer, currentUser: User) async throws -> Chat {
        await updateCurrentUser(currentUser)
        _ = try await connect(to: peer)

        let chatID = Self.chatID(for: currentUser.id, and: peer.id)
        if let existing = chatsByID[chatID] {
            return existing
        }

        let chat = Chat(
            id: chatID,
            mode: .offline,
            type: .direct,
            title: peer.displayName,
            subtitle: peer.alias.isEmpty ? "Nearby" : "@\(peer.alias)",
            participantIDs: [currentUser.id, peer.id],
            group: nil,
            lastMessagePreview: nil,
            lastActivityAt: .now,
            unreadCount: 0,
            isPinned: false,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )

        chatsByID[chatID] = chat
        messagesByChatID[chatID] = messagesByChatID[chatID] ?? []
        return chat
    }

    func fetchMessages(chatID: UUID) async -> [Message] {
        messagesByChatID[chatID] ?? []
    }

    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw OfflineTransportError.emptyMessage
        }

        let message = Message(
            id: UUID(),
            chatID: chat.id,
            senderID: senderID,
            mode: .offline,
            kind: .text,
            text: trimmed,
            attachments: [],
            replyToMessageID: nil,
            status: .sent,
            createdAt: .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )

        append(message: message, to: chat)

        if chat.type == .selfChat {
            return message
        }

        guard let remoteUserID = chat.participantIDs.first(where: { $0 != senderID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        guard let knownPeer = knownPeers[remoteUserID], let session else {
            throw OfflineTransportError.peerUnavailable
        }

        if session.connectedPeers.contains(knownPeer.peerID) == false {
            _ = try await connect(to: knownPeer.offlinePeer)
        }

        let wireMessage = WireMessage(
            id: message.id,
            chatID: chat.id,
            senderID: senderID,
            text: trimmed,
            createdAt: message.createdAt.timeIntervalSince1970
        )

        do {
            let data = try encoder.encode(wireMessage)
            try session.send(data, toPeers: [knownPeer.peerID], with: .reliable)
            return message
        } catch {
            replaceMessageStatus(messageID: message.id, in: chat.id, status: .failed)
            throw OfflineTransportError.deliveryFailed
        }
    }

    private func ensureTransport() {
        if session != nil, advertiser != nil, browser != nil {
            return
        }

        let identity = resolvedIdentity()
        currentUser = identity.user ?? currentUser

        let displayName = Self.peerDisplayName(alias: identity.alias, userID: identity.userID)
        let peerID = MCPeerID(displayName: displayName)
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: [
            "uid": identity.userID.uuidString,
            "nm": identity.displayName,
            "un": identity.alias
        ], serviceType: Self.serviceType)
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self

        localPeerID = peerID
        self.session = session
        self.advertiser = advertiser
        self.browser = browser
    }

    private func rebuildTransport() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        localPeerID = nil
        session = nil
        advertiser = nil
        browser = nil
        knownPeers.removeAll()
        peerIDsByDisplayName.removeAll()

        if isScanning {
            ensureTransport()
            advertiser?.startAdvertisingPeer()
            browser?.startBrowsingForPeers()
        }
    }

    private func scheduleConnectionTimeout(for peerID: UUID) {
        pendingConnectionTimeouts[peerID]?.cancel()
        pendingConnectionTimeouts[peerID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, let continuation = self.pendingConnections.removeValue(forKey: peerID) else { return }
            continuation.resume(throwing: OfflineTransportError.connectionTimedOut)
            self.pendingConnectionTimeouts[peerID] = nil
        }
    }

    private func resolveConnection(for peerID: UUID, result: Result<BluetoothSession, Error>) {
        pendingConnectionTimeouts[peerID]?.cancel()
        pendingConnectionTimeouts[peerID] = nil

        guard let continuation = pendingConnections.removeValue(forKey: peerID) else {
            return
        }

        continuation.resume(with: result)
    }

    private func bluetoothSession(for peerID: UUID, state: BluetoothSessionState) -> BluetoothSession {
        BluetoothSession(id: UUID(), peerID: peerID, state: state, negotiatedMTU: 180, lastActivityAt: .now)
    }

    private func makeSavedMessagesChat(for userID: UUID) -> Chat {
        let latestMessage = messagesByChatID[userID]?.last
        return Chat(
            id: userID,
            mode: .offline,
            type: .selfChat,
            title: "Saved Messages",
            subtitle: "Notes, links, and drafts",
            participantIDs: [userID],
            group: nil,
            lastMessagePreview: latestMessage?.text,
            lastActivityAt: latestMessage?.createdAt ?? .now,
            unreadCount: 0,
            isPinned: true,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )
    }

    private func append(message: Message, to chat: Chat) {
        messagesByChatID[chat.id, default: []].append(message)

        guard chat.type != .selfChat else {
            return
        }

        var updatedChat = chatsByID[chat.id] ?? chat
        updatedChat.lastMessagePreview = message.text
        updatedChat.lastActivityAt = message.createdAt
        chatsByID[chat.id] = updatedChat
    }

    private func replaceMessageStatus(messageID: UUID, in chatID: UUID, status: MessageStatus) {
        guard var messages = messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        messages[index].status = status
        messagesByChatID[chatID] = messages
    }

    private func handleFoundPeer(_ peerID: MCPeerID, discoveryInfo: [String: String]?) {
        guard localPeerID != peerID else {
            return
        }

        let peerUserID = UUID(uuidString: discoveryInfo?["uid"] ?? "") ?? Self.fallbackPeerID(from: peerID.displayName)
        guard peerUserID != resolvedIdentity().userID else {
            return
        }

        let displayName = discoveryInfo?["nm"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = discoveryInfo?["un"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        let offlinePeer = OfflinePeer(
            id: peerUserID,
            displayName: displayName?.isEmpty == false ? displayName! : peerID.displayName,
            alias: alias?.isEmpty == false ? alias! : Self.normalizedAlias(from: peerID.displayName),
            signalStrength: -55,
            isReachable: true
        )

        knownPeers[peerUserID] = KnownPeer(peerID: peerID, offlinePeer: offlinePeer)
        peerIDsByDisplayName[peerID.displayName] = peerUserID
    }

    private func handleLostPeer(_ peerID: MCPeerID) {
        guard let knownPeerID = peerIDsByDisplayName[peerID.displayName], var knownPeer = knownPeers[knownPeerID] else {
            return
        }

        knownPeer.offlinePeer.isReachable = false
        knownPeers[knownPeerID] = nil
        peerIDsByDisplayName[peerID.displayName] = nil
    }

    private func handlePeerStateChange(_ peerID: MCPeerID, state: MCSessionState) {
        guard let knownPeerID = peerIDsByDisplayName[peerID.displayName] else {
            return
        }

        switch state {
        case .connected:
            resolveConnection(for: knownPeerID, result: .success(bluetoothSession(for: knownPeerID, state: .connected)))
        case .notConnected:
            resolveConnection(for: knownPeerID, result: .failure(OfflineTransportError.connectionFailed))
        case .connecting:
            break
        @unknown default:
            resolveConnection(for: knownPeerID, result: .failure(OfflineTransportError.connectionFailed))
        }
    }

    private func handleReceivedData(_ data: Data, from peerID: MCPeerID) {
        guard let wireMessage = try? decoder.decode(WireMessage.self, from: data) else {
            return
        }

        let localUserID = resolvedIdentity().userID
        let knownPeerID = peerIDsByDisplayName[peerID.displayName] ?? wireMessage.senderID
        let knownPeer = knownPeers[knownPeerID]?.offlinePeer ?? OfflinePeer(
            id: knownPeerID,
            displayName: peerID.displayName,
            alias: Self.normalizedAlias(from: peerID.displayName),
            signalStrength: -55,
            isReachable: true
        )

        let chatID = wireMessage.chatID
        if chatsByID[chatID] == nil {
            chatsByID[chatID] = Chat(
                id: chatID,
                mode: .offline,
                type: .direct,
                title: knownPeer.displayName,
                subtitle: knownPeer.alias.isEmpty ? "Nearby" : "@\(knownPeer.alias)",
                participantIDs: [localUserID, knownPeer.id],
                group: nil,
                lastMessagePreview: nil,
                lastActivityAt: Date(timeIntervalSince1970: wireMessage.createdAt),
                unreadCount: 1,
                isPinned: false,
                draft: nil,
                disappearingPolicy: nil,
                notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
            )
        }

        let message = Message(
            id: wireMessage.id,
            chatID: chatID,
            senderID: wireMessage.senderID,
            mode: .offline,
            kind: .text,
            text: wireMessage.text,
            attachments: [],
            replyToMessageID: nil,
            status: .delivered,
            createdAt: Date(timeIntervalSince1970: wireMessage.createdAt),
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )

        if messagesByChatID[chatID]?.contains(where: { $0.id == message.id }) == true {
            return
        }

        if let chat = chatsByID[chatID] {
            append(message: message, to: chat)
            var updatedChat = chatsByID[chatID]
            updatedChat?.unreadCount += 1
            chatsByID[chatID] = updatedChat
        }
    }

    private func resolvedIdentity() -> (userID: UUID, displayName: String, alias: String, user: User?) {
        if let currentUser {
            return (
                userID: currentUser.id,
                displayName: currentUser.profile.displayName,
                alias: currentUser.profile.username,
                user: currentUser
            )
        }

        if
            let data = UserDefaults.standard.data(forKey: Self.currentUserKey),
            let storedUser = try? JSONDecoder().decode(User.self, from: data)
        {
            return (
                userID: storedUser.id,
                displayName: storedUser.profile.displayName,
                alias: storedUser.profile.username,
                user: storedUser
            )
        }

        let defaults = UserDefaults.standard
        let installationID: UUID
        if let existing = defaults.string(forKey: Self.installationIDKey).flatMap(UUID.init(uuidString:)) {
            installationID = existing
        } else {
            installationID = UUID()
            defaults.set(installationID.uuidString, forKey: Self.installationIDKey)
        }

        return (
            userID: installationID,
            displayName: UIDevice.current.name,
            alias: Self.normalizedAlias(from: UIDevice.current.name),
            user: nil
        )
    }

    private static func peerDisplayName(alias: String, userID: UUID) -> String {
        let cleanAlias = alias.isEmpty ? "prime" : normalizedAlias(from: alias)
        let suffix = userID.uuidString.prefix(4)
        return String("\(cleanAlias)-\(suffix)".prefix(32))
    }

    private static func normalizedAlias(from value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return String(allowed.prefix(13))
    }

    private static func fallbackPeerID(from value: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static func chatID(for firstUserID: UUID, and secondUserID: UUID) -> UUID {
        let sorted = [firstUserID.uuidString, secondUserID.uuidString].sorted().joined(separator: ":")
        return fallbackPeerID(from: "chat:\(sorted)")
    }
}

extension NearbyOfflineTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.handlePeerStateChange(peerID, state: state)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleReceivedData(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
}

extension NearbyOfflineTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            self.handleFoundPeer(peerID, discoveryInfo: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleLostPeer(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { }
}

extension NearbyOfflineTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            self.handleFoundPeer(peerID, discoveryInfo: nil)
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { }
}

enum OfflineTransportError: LocalizedError {
    case peerUnavailable
    case connectionTimedOut
    case connectionFailed
    case deliveryFailed
    case chatUnavailable
    case nearbySelectionRequired
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .peerUnavailable:
            return "Nearby device unavailable."
        case .connectionTimedOut:
            return "Nearby connection timed out."
        case .connectionFailed:
            return "Could not connect to the nearby device."
        case .deliveryFailed:
            return "Could not deliver the message."
        case .chatUnavailable:
            return "Chat is unavailable."
        case .nearbySelectionRequired:
            return "Choose a nearby device to start an offline chat."
        case .emptyMessage:
            return "Message is empty."
        }
    }
}
