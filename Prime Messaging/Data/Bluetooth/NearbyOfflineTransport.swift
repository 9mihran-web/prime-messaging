import CoreBluetooth
import CryptoKit
import Foundation
import MultipeerConnectivity
import UIKit

@MainActor
final class NearbyOfflineTransport: NSObject, OfflineTransporting {
    private enum WireMessageAction: String, Codable {
        case send
        case edit
        case delete
        case reaction
        case deliveryReceipt
    }

    private struct KnownPeer {
        let peripheralID: UUID
        var peripheral: CBPeripheral
        var offlinePeer: OfflinePeer
        var writableCharacteristic: CBCharacteristic?
        var profileCharacteristic: CBCharacteristic?
        var lastSeenAt: Date
    }

    private struct PeerProfile: Codable {
        let userID: UUID
        let displayName: String
        let alias: String
    }

    private struct WireMessage: Codable {
        let action: WireMessageAction
        let id: UUID
        let chatID: UUID
        let clientMessageID: UUID?
        let targetMessageID: UUID?
        let replyToMessageID: UUID?
        let replyPreview: ReplyPreviewSnapshot?
        let communityContext: CommunityMessageContext?
        let deliveryOptions: MessageDeliveryOptions?
        let senderID: UUID
        let senderName: String
        let senderAlias: String
        var recipientID: UUID?
        var text: String?
        var reactionEmoji: String?
        let createdAt: TimeInterval
        var preferredPath: OfflineTransportPath?
        var hopCount: Int?
        var maxHopCount: Int?
        var traversedPeerIDs: [UUID]?
    }

    private struct MeshKnownPeer {
        let peerID: MCPeerID
        var offlinePeer: OfflinePeer
        var state: MCSessionState
        var lastSeenAt: Date
    }

    private struct RelayPacketRecord: Codable {
        var wireMessage: WireMessage
        var queuedAt: Date
        var lastAttemptAt: Date?
        var attemptCount: Int
        var expiresAt: Date
    }

    private struct SeenWireMessageRecord: Codable {
        var id: UUID
        var seenAt: Date
    }

    private struct RelayPersistenceSnapshot: Codable {
        var packets: [RelayPacketRecord]
        var seenWireMessages: [SeenWireMessageRecord]
    }

    private static let serviceUUID = CBUUID(string: "6A0C1001-2D2E-4A9E-A0C2-9C6C2F1D1001")
    private static let profileCharacteristicUUID = CBUUID(string: "6A0C1002-2D2E-4A9E-A0C2-9C6C2F1D1002")
    private static let inboxCharacteristicUUID = CBUUID(string: "6A0C1003-2D2E-4A9E-A0C2-9C6C2F1D1003")
    private static let multipeerServiceType = "prmsgchat"
    private static let currentUserKey = "app_state.current_user"
    private static let installationIDKey = "offline_transport.installation_id"
    private static let reachablePeerFreshnessWindow: TimeInterval = 8
    private static let meshPeerFreshnessWindow: TimeInterval = 20
    private static let meshMaxHopCount = 3
    private static let relayRetryFloor: TimeInterval = 6
    private static let relayRetryCeiling: TimeInterval = 45
    private static let relayExpiryForOriginMessages: TimeInterval = 24 * 60 * 60
    private static let relayExpiryForForwardedMessages: TimeInterval = 2 * 60 * 60
    private static let seenWireMessageRetention: TimeInterval = 6 * 60 * 60
    private static let relayPersistenceKeyPrefix = "offline_transport.relay_state"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentUser: User?
    private var isScanning = false

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var profileCharacteristic: CBMutableCharacteristic?
    private var inboxCharacteristic: CBMutableCharacteristic?
    private var meshPeerID: MCPeerID?
    private var meshSession: MCSession?
    private var meshAdvertiser: MCNearbyServiceAdvertiser?
    private var meshBrowser: MCNearbyServiceBrowser?

    private var knownPeersByPeripheralID: [UUID: KnownPeer] = [:]
    private var peripheralIDsByPeerID: [UUID: UUID] = [:]
    private var meshKnownPeersByUserID: [UUID: MeshKnownPeer] = [:]
    private var meshUserIDsByPeerDisplayName: [String: UUID] = [:]
    private var pendingMeshConnections: [String: CheckedContinuation<BluetoothSession, Error>] = [:]
    private var pendingMeshConnectionTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingMeshInvitations: Set<String> = []
    private var relayWireMessages: [UUID: RelayPacketRecord] = [:]
    private var seenWireMessageIDs: [UUID: Date] = [:]
    private var relayRetryTask: Task<Void, Never>?
    private var chatsByID: [UUID: Chat] = [:]
    private var messagesByChatID: [UUID: [Message]] = [:]
    private var pendingConnections: [UUID: CheckedContinuation<BluetoothSession, Error>] = [:]
    private var pendingConnectionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var hasLoadedArchive = false
    private var archiveOwnerUserID: UUID?

    override init() {
        super.init()
    }

    func updateCurrentUser(_ user: User) async {
        let shouldRestart = currentUser?.id != user.id ||
            currentUser?.profile.username != user.profile.username ||
            currentUser?.profile.displayName != user.profile.displayName

        currentUser = user
        if let encoded = try? encoder.encode(user) {
            UserDefaults.standard.set(encoded, forKey: Self.currentUserKey)
        }
        await ensureArchiveLoaded(forceReload: shouldRestart)

        if shouldRestart {
            restartTransport()
        }
    }

    func startScanning() async {
        isScanning = true
        ensureManagers()
        ensureMeshServices()
        restartAdvertisingIfNeeded()
        restartScanningIfNeeded()
        restartMeshAdvertisingIfNeeded()
        restartMeshBrowsingIfNeeded()
        scheduleRelayRetryIfNeeded()
    }

    func stopScanning() async {
        isScanning = false
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        meshBrowser?.stopBrowsingForPeers()
        meshAdvertiser?.stopAdvertisingPeer()
        relayRetryTask?.cancel()
        relayRetryTask = nil
    }

    func discoveredPeers() async -> [OfflinePeer] {
        mergedDiscoveredPeers()
    }

    func reachablePeer(userID: UUID) async -> OfflinePeer? {
        mergedDiscoveredPeers().first(where: { $0.id == userID && $0.isReachable })
    }

    func connect(to peer: OfflinePeer) async throws -> BluetoothSession {
        ensureManagers()
        ensureMeshServices()

        if let meshSession = try await connectViaMeshIfAvailable(to: peer) {
            return meshSession
        }

        guard let peripheralID = peripheralIDsByPeerID[peer.id] else {
            throw OfflineTransportError.peerUnavailable
        }

        guard let knownPeer = knownPeersByPeripheralID[peripheralID], let centralManager else {
            throw OfflineTransportError.peerUnavailable
        }

        if knownPeer.peripheral.state == .connected, knownPeer.writableCharacteristic != nil {
            return bluetoothSession(for: knownPeer.offlinePeer.id, state: .connected)
        }

        knownPeer.peripheral.delegate = self
        knownPeersByPeripheralID[peripheralID] = knownPeer
        centralManager.connect(knownPeer.peripheral, options: nil)

        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[peripheralID] = continuation
            scheduleConnectionTimeout(for: peripheralID)
        }
    }

    func fetchChats(currentUserID: UUID) async -> [Chat] {
        await ensureArchiveLoaded()
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
        await ensureArchiveLoaded()
        _ = try await connect(to: peer)

        let resolvedPeer = resolvedPeer(afterConnectingTo: peer.id) ?? peer
        let chatID = Self.chatID(for: currentUser.id, and: resolvedPeer.id)

        if let existing = chatsByID[chatID] {
            return existing
        }

        let chat = Chat(
            id: chatID,
            mode: .offline,
            type: .direct,
            title: resolvedPeer.displayName,
            subtitle: resolvedPeer.alias.isEmpty ? "Nearby" : "@\(resolvedPeer.alias)",
            participantIDs: [currentUser.id, resolvedPeer.id],
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
        persistArchiveSnapshot()
        return chat
    }

    func fetchMessages(chatID: UUID) async -> [Message] {
        await ensureArchiveLoaded()
        return messagesByChatID[chatID] ?? []
    }

    func importHistory(_ messages: [Message], into chat: Chat, currentUser: User) async throws -> Chat {
        await updateCurrentUser(currentUser)
        await ensureArchiveLoaded()

        let targetChatID: UUID
        switch chat.type {
        case .selfChat:
            targetChatID = currentUser.id
        case .direct:
            guard let otherUserID = chat.participantIDs.first(where: { $0 != currentUser.id }) else {
                throw OfflineTransportError.chatUnavailable
            }
            targetChatID = Self.chatID(for: currentUser.id, and: otherUserID)
        case .group:
            throw ChatRepositoryError.unsupportedOfflineAction
        case .secret:
            throw ChatRepositoryError.unsupportedOfflineAction
        }

        let existingChat = chatsByID[targetChatID]
        let offlineChat = Chat(
            id: targetChatID,
            mode: .offline,
            type: chat.type,
            title: existingChat?.title ?? chat.title,
            subtitle: existingChat?.subtitle ?? chat.subtitle,
            participantIDs: chat.type == .selfChat ? [currentUser.id] : chat.participantIDs,
            participants: chat.participants,
            group: nil,
            lastMessagePreview: existingChat?.lastMessagePreview ?? chat.lastMessagePreview,
            lastActivityAt: existingChat?.lastActivityAt ?? chat.lastActivityAt,
            unreadCount: existingChat?.unreadCount ?? 0,
            isPinned: existingChat?.isPinned ?? chat.isPinned,
            draft: existingChat?.draft ?? chat.draft,
            disappearingPolicy: existingChat?.disappearingPolicy ?? chat.disappearingPolicy,
            notificationPreferences: existingChat?.notificationPreferences ?? chat.notificationPreferences,
            guestRequest: nil
        )

        chatsByID[targetChatID] = offlineChat

        var mergedByClientMessageID: [UUID: Message] = [:]
        for message in (messagesByChatID[targetChatID] ?? []) {
            mergedByClientMessageID[message.clientMessageID] = message
        }
        for message in messages {
            let normalized = Message(
                id: message.id,
                chatID: targetChatID,
                senderID: message.senderID,
                clientMessageID: message.clientMessageID,
                senderDisplayName: message.senderDisplayName,
                mode: .offline,
                deliveryState: message.deliveryState,
                kind: message.kind,
                text: message.text,
                attachments: message.attachments,
                replyToMessageID: message.replyToMessageID,
                replyPreview: message.replyPreview,
                status: message.status,
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                deletedForEveryoneAt: message.deletedForEveryoneAt,
                reactions: message.reactions,
                voiceMessage: message.voiceMessage,
                liveLocation: message.liveLocation
            )
            mergedByClientMessageID[normalized.clientMessageID] = normalized
        }

        messagesByChatID[targetChatID] = mergedByClientMessageID.values.sorted(by: { $0.createdAt < $1.createdAt })
        refreshChatMetadata(for: targetChatID, fallbackChat: offlineChat)
        persistArchiveSnapshot()
        return chatsByID[targetChatID] ?? offlineChat
    }

    func sendMessage(_ text: String, in chat: Chat, senderID: UUID) async throws -> Message {
        try await sendMessage(OutgoingMessageDraft(text: text), in: chat, senderID: senderID)
    }

    func sendMessage(_ draft: OutgoingMessageDraft, in chat: Chat, senderID: UUID) async throws -> Message {
        await ensureArchiveLoaded()
        guard draft.hasContent else {
            throw OfflineTransportError.emptyMessage
        }

        if chat.type != .selfChat && (draft.attachments.isEmpty == false || draft.voiceMessage != nil) {
            throw OfflineTransportError.mediaUnavailable
        }

        let identity = resolvedIdentity()
        let message = Message(
            id: UUID(),
            chatID: chat.id,
            senderID: senderID,
            clientMessageID: draft.clientMessageID,
            senderDisplayName: identity.displayName,
            mode: .offline,
            deliveryState: draft.deliveryStateOverride ?? .offline,
            deliveryRoute: nil,
            kind: resolvedKind(for: draft),
            text: draft.normalizedText,
            attachments: draft.attachments,
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            status: .sent,
            createdAt: draft.createdAt ?? .now,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: draft.voiceMessage,
            liveLocation: nil
        )

        append(message: message, to: chat)

        if chat.type == .selfChat {
            return message
        }

        guard let remotePeerID = chat.participantIDs.first(where: { $0 != senderID }) else {
            return markMessagePending(messageID: message.id, in: chat.id)
        }

        let wireMessage = WireMessage(
            action: .send,
            id: message.id,
            chatID: chat.id,
            clientMessageID: message.clientMessageID,
            targetMessageID: nil,
            replyToMessageID: message.replyToMessageID,
            replyPreview: message.replyPreview,
            communityContext: message.communityContext,
            deliveryOptions: message.deliveryOptions,
            senderID: senderID,
            senderName: identity.displayName,
            senderAlias: identity.alias,
            recipientID: remotePeerID,
            text: draft.normalizedText,
            reactionEmoji: nil,
            createdAt: message.createdAt.timeIntervalSince1970,
            preferredPath: await preferredPath(for: remotePeerID),
            hopCount: 0,
            maxHopCount: Self.meshMaxHopCount,
            traversedPeerIDs: [identity.userID]
        )

        do {
            let route = try await routeWireMessage(wireMessage, intendedRecipientID: remotePeerID)
            if let updated = updatedMessage(messageID: message.id, in: chat.id, senderID: senderID, mutate: { updatedMessage in
                updatedMessage.deliveryRoute = deliveryRoute(for: route)
                return true
            }) {
                if route == .meshRelay {
                    return markMessagePending(messageID: updated.id, in: chat.id)
                }
                return updated
            }
            if route == .meshRelay {
                return markMessagePending(messageID: message.id, in: chat.id)
            }
            return message
        } catch {
            return markMessagePending(messageID: message.id, in: chat.id)
        }
    }

    func toggleReaction(_ emoji: String, on messageID: UUID, in chatID: UUID, userID: UUID) async throws -> Message {
        await ensureArchiveLoaded()
        let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmoji.isEmpty == false else {
            throw OfflineTransportError.emptyMessage
        }

        guard let message = toggledReactionMessage(
            messageID: messageID,
            in: chatID,
            emoji: normalizedEmoji,
            userID: userID
        ) else {
            throw OfflineTransportError.chatUnavailable
        }

        try await sendWireUpdate(
            action: .reaction,
            chatID: chatID,
            targetMessageID: messageID,
            text: nil,
            reactionEmoji: normalizedEmoji,
            senderID: userID
        )
        return message
    }

    func editMessage(_ messageID: UUID, text: String, in chatID: UUID, editorID: UUID) async throws -> Message {
        await ensureArchiveLoaded()
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            throw OfflineTransportError.emptyMessage
        }

        guard var message = updatedMessage(
            messageID: messageID,
            in: chatID,
            senderID: editorID,
            mutate: { item in
                guard item.deletedForEveryoneAt == nil, item.attachments.isEmpty, item.voiceMessage == nil else { return false }
                item.text = normalizedText
                item.editedAt = .now
                return true
            }
        ) else {
            throw OfflineTransportError.chatUnavailable
        }

        refreshChatMetadata(for: chatID)
        try await sendWireUpdate(
            action: .edit,
            chatID: chatID,
            targetMessageID: messageID,
            text: normalizedText,
            senderID: editorID
        )
        message.editedAt = .now
        return message
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID, requesterID: UUID) async throws -> Message {
        await ensureArchiveLoaded()
        guard let message = updatedMessage(
            messageID: messageID,
            in: chatID,
            senderID: requesterID,
            mutate: { item in
                item.text = nil
                item.attachments = []
                item.voiceMessage = nil
                item.deletedForEveryoneAt = .now
                return true
            }
        ) else {
            throw OfflineTransportError.chatUnavailable
        }

        refreshChatMetadata(for: chatID)
        try await sendWireUpdate(
            action: .delete,
            chatID: chatID,
            targetMessageID: messageID,
            text: nil,
            senderID: requesterID
        )
        return message
    }

    func synchronizeArchivedChats(with onlineRepository: ChatRepository, currentUserID: UUID) async {
        await ensureArchiveLoaded()
        _ = onlineRepository
        _ = currentUserID
        // Offline chats stay authoritative inside the offline section.
        // We keep the full local archive so the same nearby conversation
        // is still visible on later offline sessions instead of disappearing
        // after an online refresh cycle.
    }

    private func mergedDiscoveredPeers() -> [OfflinePeer] {
        let currentUserID = resolvedIdentity().userID
        let bluetoothPeers = knownPeersByPeripheralID.values
            .filter { knownPeer in
                knownPeer.offlinePeer.isReachable &&
                isKnownPeerFresh(knownPeer) &&
                knownPeer.offlinePeer.id != currentUserID
            }
            .map { knownPeer in
                var peer = knownPeer.offlinePeer
                peer.availablePaths = mergePaths(peer.availablePaths + [.bluetooth])
                return peer
            }

        let meshPeers = meshKnownPeersByUserID.values
            .filter { meshPeer in
                meshPeer.offlinePeer.isReachable &&
                isMeshPeerFresh(meshPeer) &&
                meshPeer.offlinePeer.id != currentUserID
            }
            .map { meshPeer in
                var peer = meshPeer.offlinePeer
                peer.availablePaths = mergePaths(peer.availablePaths + [.localNetwork])
                peer.relayCapable = true
                return peer
            }

        var mergedByUserID: [UUID: OfflinePeer] = [:]
        for peer in bluetoothPeers + meshPeers {
            if var existing = mergedByUserID[peer.id] {
                existing.displayName = existing.displayName.count >= peer.displayName.count ? existing.displayName : peer.displayName
                existing.alias = existing.alias.isEmpty ? peer.alias : existing.alias
                existing.signalStrength = max(existing.signalStrength, peer.signalStrength)
                existing.isReachable = existing.isReachable || peer.isReachable
                existing.availablePaths = mergePaths(existing.availablePaths + peer.availablePaths)
                existing.relayCapable = existing.relayCapable || peer.relayCapable
                mergedByUserID[peer.id] = existing
            } else {
                mergedByUserID[peer.id] = peer
            }
        }

        return mergedByUserID.values
            .filter { $0.id != currentUserID }
            .sorted(by: { lhs, rhs in
            let lhsPriority = lhs.availablePaths.map(\.priority).min() ?? Int.max
            let rhsPriority = rhs.availablePaths.map(\.priority).min() ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.signalStrength != rhs.signalStrength {
                return lhs.signalStrength > rhs.signalStrength
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        })
    }

    private func ensureManagers() {
        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        }

        #if !os(tvOS)
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
            )
        }
        #endif
    }

    private func ensureMeshServices() {
        let identity = resolvedIdentity()
        let peerDisplayName = "prime-\(identity.userID.uuidString.prefix(12))"

        if meshPeerID?.displayName != peerDisplayName {
            meshAdvertiser?.stopAdvertisingPeer()
            meshBrowser?.stopBrowsingForPeers()
            meshSession?.disconnect()
            meshKnownPeersByUserID.removeAll()
            meshUserIDsByPeerDisplayName.removeAll()
            pendingMeshConnections.removeAll()
            pendingMeshConnectionTimeouts.values.forEach { $0.cancel() }
            pendingMeshConnectionTimeouts.removeAll()
            pendingMeshInvitations.removeAll()

            let peerID = MCPeerID(displayName: peerDisplayName)
            let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            meshPeerID = peerID
            meshSession = session
            meshAdvertiser = nil
            meshBrowser = nil
        }

        #if !os(tvOS)
        if meshAdvertiser == nil, let meshPeerID {
            let advertiser = MCNearbyServiceAdvertiser(
                peer: meshPeerID,
                discoveryInfo: meshDiscoveryInfo(),
                serviceType: Self.multipeerServiceType
            )
            advertiser.delegate = self
            meshAdvertiser = advertiser
        }
        #endif

        if meshBrowser == nil, let meshPeerID {
            let browser = MCNearbyServiceBrowser(peer: meshPeerID, serviceType: Self.multipeerServiceType)
            browser.delegate = self
            meshBrowser = browser
        }
    }

    private func restartTransport() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        meshBrowser?.stopBrowsingForPeers()
        meshAdvertiser?.stopAdvertisingPeer()
        meshSession?.disconnect()
        relayRetryTask?.cancel()
        relayRetryTask = nil

        for knownPeer in knownPeersByPeripheralID.values where knownPeer.peripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(knownPeer.peripheral)
        }

        knownPeersByPeripheralID.removeAll()
        peripheralIDsByPeerID.removeAll()
        pendingConnections.removeAll()
        pendingConnectionTimeouts.values.forEach { $0.cancel() }
        pendingConnectionTimeouts.removeAll()
        meshKnownPeersByUserID.removeAll()
        meshUserIDsByPeerDisplayName.removeAll()
        pendingMeshConnections.removeAll()
        pendingMeshConnectionTimeouts.values.forEach { $0.cancel() }
        pendingMeshConnectionTimeouts.removeAll()
        pendingMeshInvitations.removeAll()

        restartAdvertisingIfNeeded()
        restartScanningIfNeeded()
        ensureMeshServices()
        restartMeshAdvertisingIfNeeded()
        restartMeshBrowsingIfNeeded()
        scheduleRelayRetryIfNeeded()
    }

    private func ensureArchiveLoaded(forceReload: Bool = false) async {
        let ownerUserID = resolvedIdentity().userID
        guard forceReload || hasLoadedArchive == false || archiveOwnerUserID != ownerUserID else {
            return
        }

        let snapshot = await OfflineChatArchiveStore.shared.load(ownerUserID: ownerUserID)
        chatsByID = snapshot.chatsByID
        messagesByChatID = snapshot.messagesByChatID
        loadPersistedRelayState(ownerUserID: ownerUserID)
        archiveOwnerUserID = ownerUserID
        hasLoadedArchive = true
    }

    private func persistArchiveSnapshot() {
        let ownerUserID = resolvedIdentity().userID
        let chatsSnapshot = chatsByID
        let messagesSnapshot = messagesByChatID
        archiveOwnerUserID = ownerUserID
        hasLoadedArchive = true

        Task {
            await OfflineChatArchiveStore.shared.save(
                chatsByID: chatsSnapshot,
                messagesByChatID: messagesSnapshot,
                ownerUserID: ownerUserID
            )
        }
    }

    private func relayPersistenceKey(for ownerUserID: UUID) -> String {
        "\(Self.relayPersistenceKeyPrefix).\(ownerUserID.uuidString)"
    }

    private func loadPersistedRelayState(ownerUserID: UUID) {
        let defaults = UserDefaults.standard
        let key = relayPersistenceKey(for: ownerUserID)
        guard let data = defaults.data(forKey: key),
              let snapshot = try? decoder.decode(RelayPersistenceSnapshot.self, from: data) else {
            relayWireMessages = [:]
            seenWireMessageIDs = [:]
            scheduleRelayRetryIfNeeded()
            return
        }

        let now = Date()
        let packets = snapshot.packets.filter { isRelayPacketValid($0, now: now) }
        relayWireMessages = Dictionary(uniqueKeysWithValues: packets.map { ($0.wireMessage.id, $0) })
        seenWireMessageIDs = Dictionary(
            uniqueKeysWithValues: snapshot.seenWireMessages
                .filter { now.timeIntervalSince($0.seenAt) <= Self.seenWireMessageRetention }
                .map { ($0.id, $0.seenAt) }
        )
        persistRelayStateIfNeeded(ownerUserID: ownerUserID)
        scheduleRelayRetryIfNeeded()
    }

    private func persistRelayStateIfNeeded(ownerUserID: UUID? = nil) {
        let resolvedOwnerUserID = ownerUserID ?? resolvedIdentity().userID
        let defaults = UserDefaults.standard
        let key = relayPersistenceKey(for: resolvedOwnerUserID)
        pruneRelayState(now: Date())

        if relayWireMessages.isEmpty && seenWireMessageIDs.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }

        let snapshot = RelayPersistenceSnapshot(
            packets: relayWireMessages.values.sorted { $0.queuedAt < $1.queuedAt },
            seenWireMessages: seenWireMessageIDs
                .map { SeenWireMessageRecord(id: $0.key, seenAt: $0.value) }
                .sorted { $0.seenAt > $1.seenAt }
        )

        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    private func pruneRelayState(now: Date) {
        relayWireMessages = relayWireMessages.filter { _, record in
            isRelayPacketValid(record, now: now)
        }
        seenWireMessageIDs = seenWireMessageIDs.filter { _, seenAt in
            now.timeIntervalSince(seenAt) <= Self.seenWireMessageRetention
        }
    }

    private func isRelayPacketValid(_ record: RelayPacketRecord, now: Date) -> Bool {
        now <= record.expiresAt
    }

    private func restartScanningIfNeeded() {
        guard isScanning, let centralManager, centralManager.state == .poweredOn else {
            return
        }

        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func restartAdvertisingIfNeeded() {
        guard isScanning, let peripheralManager, peripheralManager.state == .poweredOn else {
            return
        }

        ensurePeripheralService()

        let identity = resolvedIdentity()
        let advertisedName = String((identity.alias.isEmpty ? identity.displayName : identity.alias).prefix(20))

        peripheralManager.stopAdvertising()
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: advertisedName,
        ])
    }

    private func restartMeshAdvertisingIfNeeded() {
        guard isScanning, let meshAdvertiser else { return }
        meshAdvertiser.stopAdvertisingPeer()
        meshAdvertiser.startAdvertisingPeer()
    }

    private func restartMeshBrowsingIfNeeded() {
        guard isScanning, let meshBrowser else { return }
        meshBrowser.stopBrowsingForPeers()
        meshBrowser.startBrowsingForPeers()
    }

    private func ensurePeripheralService() {
        #if os(tvOS)
        return
        #else
        guard profileCharacteristic == nil, let peripheralManager, peripheralManager.state == .poweredOn else {
            return
        }

        let profileCharacteristic = CBMutableCharacteristic(
            type: Self.profileCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        let inboxCharacteristic = CBMutableCharacteristic(
            type: Self.inboxCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [profileCharacteristic, inboxCharacteristic]

        self.profileCharacteristic = profileCharacteristic
        self.inboxCharacteristic = inboxCharacteristic
        peripheralManager.removeAllServices()
        peripheralManager.add(service)
        #endif
    }

    private func resolvedPeer(afterConnectingTo peerID: UUID) -> OfflinePeer? {
        if let peripheralID = peripheralIDsByPeerID[peerID] {
            return knownPeersByPeripheralID[peripheralID]?.offlinePeer
        }

        if let meshPeer = meshKnownPeersByUserID[peerID] {
            return meshPeer.offlinePeer
        }

        return nil
    }

    private func mergePaths(_ paths: [OfflineTransportPath]) -> [OfflineTransportPath] {
        Array(Set(paths)).sorted(by: { $0.priority < $1.priority })
    }

    private func meshDiscoveryInfo() -> [String: String] {
        let identity = resolvedIdentity()
        return [
            "uid": identity.userID.uuidString,
            "name": String(identity.displayName.prefix(18)),
            "alias": String(identity.alias.prefix(18)),
            "relay": "1",
        ]
    }

    private func connectedMeshPeerIDs() -> [UUID] {
        meshKnownPeersByUserID.values
            .filter { $0.state == .connected && isMeshPeerFresh($0) }
            .map { $0.offlinePeer.id }
    }

    private func isMeshPeerFresh(_ meshPeer: MeshKnownPeer, now: Date = .now) -> Bool {
        now.timeIntervalSince(meshPeer.lastSeenAt) <= Self.meshPeerFreshnessWindow
    }

    private func hasSeenWireMessage(_ id: UUID, now: Date = .now) -> Bool {
        if let seenAt = seenWireMessageIDs[id], now.timeIntervalSince(seenAt) <= Self.seenWireMessageRetention {
            return true
        }
        seenWireMessageIDs[id] = nil
        return false
    }

    private func markWireMessageSeen(_ id: UUID, at date: Date = .now) {
        seenWireMessageIDs[id] = date
        persistRelayStateIfNeeded()
    }

    private func queueRelayPacket(
        _ wireMessage: WireMessage,
        markAttempted: Bool,
        date: Date = .now
    ) {
        var record = relayWireMessages[wireMessage.id] ?? RelayPacketRecord(
            wireMessage: wireMessage,
            queuedAt: date,
            lastAttemptAt: nil,
            attemptCount: 0,
            expiresAt: date.addingTimeInterval(relayExpiryInterval(for: wireMessage))
        )
        record.wireMessage = wireMessage
        if markAttempted {
            record.lastAttemptAt = date
            record.attemptCount += 1
        }
        relayWireMessages[wireMessage.id] = record
        seenWireMessageIDs[wireMessage.id] = date
        persistRelayStateIfNeeded()
        scheduleRelayRetryIfNeeded()
    }

    private func removeRelayPacket(_ packetID: UUID) {
        relayWireMessages.removeValue(forKey: packetID)
        persistRelayStateIfNeeded()
        scheduleRelayRetryIfNeeded()
    }

    private func relayExpiryInterval(for wireMessage: WireMessage) -> TimeInterval {
        let localUserID = resolvedIdentity().userID
        return wireMessage.senderID == localUserID
            ? Self.relayExpiryForOriginMessages
            : Self.relayExpiryForForwardedMessages
    }

    private func nextRelayAttemptDate(for record: RelayPacketRecord) -> Date {
        guard let lastAttemptAt = record.lastAttemptAt else {
            return record.queuedAt
        }

        let exponent = min(max(record.attemptCount - 1, 0), 3)
        let delay = min(Self.relayRetryFloor * pow(2, Double(exponent)), Self.relayRetryCeiling)
        return lastAttemptAt.addingTimeInterval(delay)
    }

    private func scheduleRelayRetryIfNeeded() {
        relayRetryTask?.cancel()
        relayRetryTask = nil

        guard isScanning, relayWireMessages.isEmpty == false else { return }

        let now = Date()
        pruneRelayState(now: now)
        guard relayWireMessages.isEmpty == false else {
            persistRelayStateIfNeeded()
            return
        }

        let nextDate: Date
        if connectedMeshPeerIDs().isEmpty {
            nextDate = now.addingTimeInterval(Self.relayRetryFloor)
        } else {
            nextDate = relayWireMessages.values
                .map(nextRelayAttemptDate(for:))
                .min() ?? now.addingTimeInterval(Self.relayRetryFloor)
        }

        let delay = max(nextDate.timeIntervalSince(now), 1)
        let sleepDuration = Duration.milliseconds(Int64((delay * 1000).rounded()))
        relayRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: sleepDuration)
            guard let self, Task.isCancelled == false else { return }
            self.tryRelayStoredMessages()
        }
    }

    private func reachableBluetoothPeer(userID: UUID) async -> KnownPeer? {
        guard let peripheralID = peripheralIDsByPeerID[userID],
              let knownPeer = knownPeersByPeripheralID[peripheralID],
              knownPeer.offlinePeer.isReachable,
              isKnownPeerFresh(knownPeer) else {
            return nil
        }
        return knownPeer
    }

    private func ensureWritableCharacteristic(for knownPeer: KnownPeer) async throws -> CBCharacteristic {
        if knownPeer.peripheral.state != .connected || knownPeer.writableCharacteristic == nil {
            _ = try await connect(to: knownPeer.offlinePeer)
        }

        guard let peripheralID = peripheralIDsByPeerID[knownPeer.offlinePeer.id],
              let refreshedPeer = knownPeersByPeripheralID[peripheralID],
              let characteristic = refreshedPeer.writableCharacteristic else {
            throw OfflineTransportError.peerUnavailable
        }

        return characteristic
    }

    private func connectViaMeshIfAvailable(to peer: OfflinePeer) async throws -> BluetoothSession? {
        guard let meshPeer = meshKnownPeersByUserID[peer.id], isMeshPeerFresh(meshPeer) else {
            return nil
        }

        if meshPeer.state == .connected {
            return bluetoothSession(for: peer.id, state: .connected)
        }

        guard let meshBrowser, let meshSession else {
            return nil
        }

        meshBrowser.invitePeer(meshPeer.peerID, to: meshSession, withContext: nil, timeout: 12)
        return try await withCheckedThrowingContinuation { continuation in
            pendingMeshConnections[meshPeer.peerID.displayName] = continuation
            scheduleMeshConnectionTimeout(for: meshPeer.peerID.displayName)
        }
    }

    private func scheduleConnectionTimeout(for peripheralID: UUID) {
        pendingConnectionTimeouts[peripheralID]?.cancel()
        pendingConnectionTimeouts[peripheralID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, let continuation = self.pendingConnections.removeValue(forKey: peripheralID) else { return }
            continuation.resume(throwing: OfflineTransportError.connectionTimedOut)
            self.pendingConnectionTimeouts[peripheralID] = nil
        }
    }

    private func scheduleMeshConnectionTimeout(for peerDisplayName: String) {
        pendingMeshConnectionTimeouts[peerDisplayName]?.cancel()
        pendingMeshConnectionTimeouts[peerDisplayName] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, let continuation = self.pendingMeshConnections.removeValue(forKey: peerDisplayName) else { return }
            continuation.resume(throwing: OfflineTransportError.connectionTimedOut)
            self.pendingMeshConnectionTimeouts[peerDisplayName] = nil
        }
    }

    private func resolveConnection(for peripheralID: UUID, result: Result<BluetoothSession, Error>) {
        pendingConnectionTimeouts[peripheralID]?.cancel()
        pendingConnectionTimeouts[peripheralID] = nil

        guard let continuation = pendingConnections.removeValue(forKey: peripheralID) else {
            return
        }

        continuation.resume(with: result)
    }

    private func resolveMeshConnection(for peerDisplayName: String, result: Result<BluetoothSession, Error>) {
        pendingMeshConnectionTimeouts[peerDisplayName]?.cancel()
        pendingMeshConnectionTimeouts[peerDisplayName] = nil

        guard let continuation = pendingMeshConnections.removeValue(forKey: peerDisplayName) else {
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
            lastActivityAt: latestMessage?.createdAt ?? .distantPast,
            unreadCount: 0,
            isPinned: false,
            draft: nil,
            disappearingPolicy: nil,
            notificationPreferences: NotificationPreferences(muteState: .active, previewEnabled: true, customSoundName: nil, badgeEnabled: true)
        )
    }

    private func append(message: Message, to chat: Chat) {
        messagesByChatID[chat.id, default: []].append(message)
        refreshChatMetadata(for: chat.id, fallbackChat: chat)
        persistArchiveSnapshot()
    }

    private func refreshChatMetadata(for chatID: UUID, fallbackChat: Chat? = nil) {
        let latestMessage = messagesByChatID[chatID]?.last

        if chatID == resolvedIdentity().userID {
            return
        }

        guard var updatedChat = chatsByID[chatID] ?? fallbackChat else {
            return
        }

        updatedChat.lastMessagePreview = latestMessage.map { $0.text ?? mediaSummary(for: $0) }
        updatedChat.lastActivityAt = latestMessage?.createdAt ?? updatedChat.lastActivityAt
        chatsByID[chatID] = updatedChat
        persistArchiveSnapshot()
    }

    private func resolvedKind(for draft: OutgoingMessageDraft) -> MessageKind {
        if draft.voiceMessage != nil {
            return .voice
        }

        switch draft.attachments.first?.type {
        case .photo:
            return .photo
        case .audio:
            return .audio
        case .video:
            return .video
        case .document:
            return .document
        case .contact:
            return .contact
        case .location:
            return .location
        case nil:
            return .text
        }
    }

    private func mediaSummary(for message: Message) -> String {
        if message.deletedForEveryoneAt != nil {
            return "Message deleted"
        }

        if message.voiceMessage != nil {
            return "Voice message"
        }

        switch message.attachments.first?.type {
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
            return "Message"
        }
    }

    private func replaceMessageStatus(messageID: UUID, in chatID: UUID, status: MessageStatus) {
        guard var messages = messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        messages[index].status = status
        messagesByChatID[chatID] = messages
        persistArchiveSnapshot()
    }

    private func markMessagePending(messageID: UUID, in chatID: UUID) -> Message {
        guard var messages = messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return Message(
                id: messageID,
                chatID: chatID,
                senderID: resolvedIdentity().userID,
                senderDisplayName: resolvedIdentity().displayName,
                mode: .offline,
                deliveryRoute: nil,
                kind: .text,
                text: nil,
                attachments: [],
                replyToMessageID: nil,
                status: .localPending,
                createdAt: .now,
                editedAt: nil,
                deletedForEveryoneAt: nil,
                reactions: [],
                voiceMessage: nil,
                liveLocation: nil
            )
        }

        messages[index].status = .localPending
        let message = messages[index]
        messagesByChatID[chatID] = messages
        persistArchiveSnapshot()
        return message
    }

    private func deliveryRoute(for path: OfflineTransportPath) -> MessageDeliveryRoute {
        switch path {
        case .bluetooth:
            return .bluetooth
        case .localNetwork:
            return .localNetwork
        case .meshRelay:
            return .meshRelay
        }
    }

    private func updatedMessage(
        messageID: UUID,
        in chatID: UUID,
        senderID: UUID,
        mutate: (inout Message) -> Bool
    ) -> Message? {
        guard var messages = messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID && $0.senderID == senderID }) else {
            return nil
        }

        var message = messages[index]
        guard mutate(&message) else {
            return nil
        }

        messages[index] = message
        messagesByChatID[chatID] = messages
        persistArchiveSnapshot()
        return message
    }

    private func toggledReactionMessage(
        messageID: UUID,
        in chatID: UUID,
        emoji: String,
        userID: UUID
    ) -> Message? {
        guard var messages = messagesByChatID[chatID], let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        var message = messages[index]
        if let reactionIndex = message.reactions.firstIndex(where: { $0.emoji == emoji }) {
            if message.reactions[reactionIndex].userIDs.contains(userID) {
                message.reactions[reactionIndex].userIDs.removeAll { $0 == userID }
                if message.reactions[reactionIndex].userIDs.isEmpty {
                    message.reactions.remove(at: reactionIndex)
                }
            } else {
                message.reactions[reactionIndex].userIDs.append(userID)
            }
        } else {
            message.reactions.append(
                MessageReaction(id: UUID(), emoji: emoji, userIDs: [userID])
            )
        }

        messages[index] = message
        messagesByChatID[chatID] = messages
        persistArchiveSnapshot()
        return message
    }

    private func sendWireUpdate(
        action: WireMessageAction,
        chatID: UUID,
        targetMessageID: UUID,
        text: String?,
        reactionEmoji: String? = nil,
        senderID: UUID
    ) async throws {
        guard let chat = chatsByID[chatID] else {
            throw OfflineTransportError.chatUnavailable
        }

        guard let remotePeerID = chat.participantIDs.first(where: { $0 != senderID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        let identity = resolvedIdentity()
        let wireMessage = WireMessage(
            action: action,
            id: UUID(),
            chatID: chatID,
            clientMessageID: nil,
            targetMessageID: targetMessageID,
            replyToMessageID: nil,
            replyPreview: nil,
            communityContext: nil,
            deliveryOptions: nil,
            senderID: senderID,
            senderName: identity.displayName,
            senderAlias: identity.alias,
            recipientID: remotePeerID,
            text: text,
            reactionEmoji: reactionEmoji,
            createdAt: Date.now.timeIntervalSince1970,
            preferredPath: await preferredPath(for: remotePeerID),
            hopCount: 0,
            maxHopCount: Self.meshMaxHopCount,
            traversedPeerIDs: [identity.userID]
        )

        do {
            _ = try await routeWireMessage(wireMessage, intendedRecipientID: remotePeerID)
        } catch {
            throw OfflineTransportError.deliveryFailed
        }
    }

    private func preferredPath(for recipientID: UUID) async -> OfflineTransportPath {
        let availablePaths = availablePaths(for: recipientID)
        if let preferred = await SmartDeliveryPolicyStore.shared.preferredOfflinePath(
            for: recipientID,
            availablePaths: availablePaths
        ) {
            return preferred
        }

        return availablePaths.min(by: { $0.priority < $1.priority }) ?? .bluetooth
    }

    private func availablePaths(for recipientID: UUID) -> [OfflineTransportPath] {
        var paths: Set<OfflineTransportPath> = []

        if let meshPeer = meshKnownPeersByUserID[recipientID],
           meshPeer.state == .connected,
           isMeshPeerFresh(meshPeer) {
            paths.insert(.localNetwork)
        }

        if let peripheralID = peripheralIDsByPeerID[recipientID],
           let knownPeer = knownPeersByPeripheralID[peripheralID],
           knownPeer.offlinePeer.isReachable,
           isKnownPeerFresh(knownPeer) {
            paths.insert(.bluetooth)
        }

        if connectedMeshPeerIDs().isEmpty == false {
            paths.insert(.meshRelay)
        }

        return paths.sorted { lhs, rhs in
            lhs.priority < rhs.priority
        }
    }

    private func orderedCandidatePaths(
        for recipientID: UUID,
        preferredPath: OfflineTransportPath?
    ) -> [OfflineTransportPath] {
        var candidates = availablePaths(for: recipientID)
        if let preferredPath,
           let preferredIndex = candidates.firstIndex(of: preferredPath) {
            let preferred = candidates.remove(at: preferredIndex)
            candidates.insert(preferred, at: 0)
        }
        return candidates
    }

    @discardableResult
    private func routeWireMessage(
        _ wireMessage: WireMessage,
        intendedRecipientID: UUID
    ) async throws -> OfflineTransportPath {
        for candidate in orderedCandidatePaths(for: intendedRecipientID, preferredPath: wireMessage.preferredPath) {
            do {
                switch candidate {
                case .localNetwork:
                    guard let meshPeer = meshKnownPeersByUserID[intendedRecipientID],
                          meshPeer.state == .connected,
                          isMeshPeerFresh(meshPeer) else {
                        continue
                    }
                    try sendWireMessage(wireMessage, to: meshPeer.peerID)
                    return .localNetwork
                case .bluetooth:
                    guard let reachablePeer = await reachableBluetoothPeer(userID: intendedRecipientID) else {
                        continue
                    }
                    let characteristic = try await ensureWritableCharacteristic(for: reachablePeer)
                    try sendWireMessage(wireMessage, through: reachablePeer.peripheral, characteristic: characteristic)
                    return .bluetooth
                case .meshRelay:
                    if try relayWireMessageIfPossible(
                        wireMessage,
                        excludingUserIDs: Set(wireMessage.traversedPeerIDs ?? [])
                    ) {
                        queueRelayPacket(wireMessage, markAttempted: true)
                        return .meshRelay
                    }
                }
            } catch {
                continue
            }
        }

        throw OfflineTransportError.peerUnavailable
    }

    private func sendWireMessage(_ wireMessage: WireMessage, through peripheral: CBPeripheral, characteristic: CBCharacteristic) throws {
        let data = try encoder.encode(wireMessage)
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    private func sendWireMessage(_ wireMessage: WireMessage, to meshPeer: MCPeerID) throws {
        guard let meshSession, meshSession.connectedPeers.contains(meshPeer) else {
            throw OfflineTransportError.peerUnavailable
        }

        let data = try encoder.encode(wireMessage)
        try meshSession.send(data, toPeers: [meshPeer], with: .reliable)
    }

    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let provisionalPeerID = Self.fallbackPeerID(from: peripheral.identifier.uuidString)
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = advertisedName?.isEmpty == false ? advertisedName! : (peripheral.name ?? "Nearby iPhone")
        let alias = Self.normalizedAlias(from: advertisedName ?? peripheral.name ?? "")
        let existingKnownPeer = knownPeersByPeripheralID[peripheral.identifier]

        let offlinePeer = OfflinePeer(
            id: existingKnownPeer?.offlinePeer.id ?? provisionalPeerID,
            displayName: existingKnownPeer?.offlinePeer.displayName ?? displayName,
            alias: existingKnownPeer?.offlinePeer.alias.isEmpty == false
                ? existingKnownPeer!.offlinePeer.alias
                : alias,
            signalStrength: rssi.intValue,
            isReachable: true,
            availablePaths: mergePaths((existingKnownPeer?.offlinePeer.availablePaths ?? []) + [.bluetooth]),
            relayCapable: existingKnownPeer?.offlinePeer.relayCapable ?? false
        )

        if let previousPeer = existingKnownPeer?.offlinePeer {
            peripheralIDsByPeerID[previousPeer.id] = peripheral.identifier
        }

        knownPeersByPeripheralID[peripheral.identifier] = KnownPeer(
            peripheralID: peripheral.identifier,
            peripheral: peripheral,
            offlinePeer: offlinePeer,
            writableCharacteristic: existingKnownPeer?.writableCharacteristic,
            profileCharacteristic: existingKnownPeer?.profileCharacteristic,
            lastSeenAt: .now
        )
        peripheralIDsByPeerID[offlinePeer.id] = peripheral.identifier
    }

    private func handleConnectedPeripheral(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    private func handleDisconnectedPeripheral(_ peripheral: CBPeripheral, error: Error?) {
        guard var knownPeer = knownPeersByPeripheralID[peripheral.identifier] else {
            return
        }

        knownPeer.offlinePeer.isReachable = false
        knownPeer.writableCharacteristic = nil
        knownPeer.profileCharacteristic = nil
        knownPeersByPeripheralID[peripheral.identifier] = knownPeer

        if pendingConnections[peripheral.identifier] != nil {
            resolveConnection(for: peripheral.identifier, result: .failure(OfflineTransportError.connectionFailed))
        }
    }

    private func handleDiscoveredServices(for peripheral: CBPeripheral, error: Error?) {
        guard error == nil else {
            resolveConnection(for: peripheral.identifier, result: .failure(OfflineTransportError.connectionFailed))
            return
        }

        guard let services = peripheral.services else {
            resolveConnection(for: peripheral.identifier, result: .failure(OfflineTransportError.connectionFailed))
            return
        }

        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.profileCharacteristicUUID, Self.inboxCharacteristicUUID], for: service)
        }
    }

    private func handleDiscoveredCharacteristics(for peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard error == nil, var knownPeer = knownPeersByPeripheralID[peripheral.identifier] else {
            resolveConnection(for: peripheral.identifier, result: .failure(OfflineTransportError.connectionFailed))
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.inboxCharacteristicUUID {
                knownPeer.writableCharacteristic = characteristic
            } else if characteristic.uuid == Self.profileCharacteristicUUID {
                knownPeer.profileCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            }
        }

        knownPeersByPeripheralID[peripheral.identifier] = knownPeer

        if knownPeer.profileCharacteristic == nil {
            resolveConnection(
                for: peripheral.identifier,
                result: .success(bluetoothSession(for: knownPeer.offlinePeer.id, state: .connected))
            )
        }
    }

    private func handleUpdatedValue(for peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.profileCharacteristicUUID, let data = characteristic.value else {
            if let knownPeer = knownPeersByPeripheralID[peripheral.identifier] {
                resolveConnection(
                    for: peripheral.identifier,
                    result: .success(bluetoothSession(for: knownPeer.offlinePeer.id, state: .connected))
                )
            }
            return
        }

        guard
            let profile = try? decoder.decode(PeerProfile.self, from: data),
            var knownPeer = knownPeersByPeripheralID[peripheral.identifier]
        else {
            if let knownPeer = knownPeersByPeripheralID[peripheral.identifier] {
                resolveConnection(
                    for: peripheral.identifier,
                    result: .success(bluetoothSession(for: knownPeer.offlinePeer.id, state: .connected))
                )
            }
            return
        }

        let previousPeerID = knownPeer.offlinePeer.id
        let updatedPeer = OfflinePeer(
            id: profile.userID,
            displayName: profile.displayName,
            alias: profile.alias,
            signalStrength: knownPeer.offlinePeer.signalStrength,
            isReachable: true,
            availablePaths: mergePaths(knownPeer.offlinePeer.availablePaths + [.bluetooth]),
            relayCapable: knownPeer.offlinePeer.relayCapable
        )
        knownPeer.offlinePeer = updatedPeer
        knownPeer.lastSeenAt = .now
        knownPeersByPeripheralID[peripheral.identifier] = knownPeer

        peripheralIDsByPeerID[previousPeerID] = peripheral.identifier
        peripheralIDsByPeerID[profile.userID] = peripheral.identifier
        migrateExistingChatIfNeeded(from: previousPeerID, to: updatedPeer)

        resolveConnection(
            for: peripheral.identifier,
            result: .success(bluetoothSession(for: profile.userID, state: .connected))
        )
    }

    private func handleIncomingWriteRequests(_ requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.inboxCharacteristicUUID {
            guard let data = request.value, let wireMessage = try? decoder.decode(WireMessage.self, from: data) else {
                peripheralManager?.respond(to: request, withResult: .unlikelyError)
                continue
            }

            upsertKnownPeerFromIncomingMessage(wireMessage, centralID: request.central.identifier)
            handleIncomingWireMessage(
                wireMessage,
                preferredSignalStrength: -55,
                sourcePath: .bluetooth
            )
            peripheralManager?.respond(to: request, withResult: .success)
        }
    }

    private func handleIncomingWireMessage(
        _ wireMessage: WireMessage,
        preferredSignalStrength: Int,
        sourcePath: OfflineTransportPath
    ) {
        let localUserID = resolvedIdentity().userID

        if hasSeenWireMessage(wireMessage.id) {
            return
        }
        markWireMessageSeen(wireMessage.id)

        let knownPeer = resolvedPeer(afterConnectingTo: wireMessage.senderID) ?? OfflinePeer(
            id: wireMessage.senderID,
            displayName: wireMessage.senderName,
            alias: wireMessage.senderAlias,
            signalStrength: preferredSignalStrength,
            isReachable: true,
            availablePaths: mergePaths([sourcePath]),
            relayCapable: sourcePath != .bluetooth
        )

        if let recipientID = wireMessage.recipientID, recipientID != localUserID {
            queueRelayPacket(wireMessage, markAttempted: false)
            tryRelayStoredMessages()
            return
        }

        applyIncomingWireMessage(wireMessage, from: knownPeer, sourcePath: sourcePath)
    }

    private func applyIncomingWireMessage(
        _ wireMessage: WireMessage,
        from peer: OfflinePeer,
        sourcePath: OfflineTransportPath
    ) {
        let localUserID = resolvedIdentity().userID
        let chatID = wireMessage.chatID
        let senderPeerID = wireMessage.senderID

        if wireMessage.action == .deliveryReceipt {
            if let packetID = wireMessage.targetMessageID {
                applyDeliveryReceipt(for: packetID, sourcePath: sourcePath)
            }
            return
        }

        if chatsByID[chatID] == nil {
            chatsByID[chatID] = Chat(
                id: chatID,
                mode: .offline,
                type: .direct,
                title: peer.displayName,
                subtitle: peer.alias.isEmpty ? "Nearby" : "@\(peer.alias)",
                participantIDs: [localUserID, peer.id],
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

        if wireMessage.action == .send {
            let message = Message(
                id: wireMessage.id,
                chatID: chatID,
                senderID: senderPeerID,
                clientMessageID: wireMessage.clientMessageID ?? wireMessage.id,
                senderDisplayName: wireMessage.senderName,
                mode: .offline,
                deliveryState: .offline,
                kind: .text,
                text: wireMessage.text,
                attachments: [],
                replyToMessageID: wireMessage.replyToMessageID,
                replyPreview: wireMessage.replyPreview,
                communityContext: wireMessage.communityContext,
                deliveryOptions: wireMessage.deliveryOptions ?? MessageDeliveryOptions(),
                status: .delivered,
                createdAt: Date(timeIntervalSince1970: wireMessage.createdAt),
                editedAt: nil,
                deletedForEveryoneAt: nil,
                reactions: [],
                voiceMessage: nil,
                liveLocation: nil
            )

            if messagesByChatID[chatID]?.contains(where: { $0.id == message.id }) != true, let chat = chatsByID[chatID] {
                append(message: message, to: chat)
                var updatedChat = chatsByID[chatID]
                updatedChat?.unreadCount += 1
                chatsByID[chatID] = updatedChat
                persistArchiveSnapshot()
            }
        } else if wireMessage.action == .edit, let targetMessageID = wireMessage.targetMessageID {
            _ = updatedMessage(
                messageID: targetMessageID,
                in: chatID,
                senderID: senderPeerID,
                mutate: { item in
                    item.text = wireMessage.text
                    item.editedAt = Date(timeIntervalSince1970: wireMessage.createdAt)
                    return true
                }
            )
            refreshChatMetadata(for: chatID)
        } else if wireMessage.action == .reaction, let targetMessageID = wireMessage.targetMessageID, let reactionEmoji = wireMessage.reactionEmoji {
            _ = toggledReactionMessage(
                messageID: targetMessageID,
                in: chatID,
                emoji: reactionEmoji,
                userID: senderPeerID
            )
        } else if wireMessage.action == .delete, let targetMessageID = wireMessage.targetMessageID {
            _ = updatedMessage(
                messageID: targetMessageID,
                in: chatID,
                senderID: senderPeerID,
                mutate: { item in
                    item.text = nil
                    item.attachments = []
                    item.voiceMessage = nil
                    item.deletedForEveryoneAt = Date(timeIntervalSince1970: wireMessage.createdAt)
                    return true
                }
            )
            refreshChatMetadata(for: chatID)
        }

        Task { @MainActor [wireMessage] in
            await acknowledgeDelivery(of: wireMessage)
        }
    }

    private func acknowledgeDelivery(of wireMessage: WireMessage) async {
        guard wireMessage.action != .deliveryReceipt else { return }

        let localUserID = resolvedIdentity().userID
        let receipt = WireMessage(
            action: .deliveryReceipt,
            id: UUID(),
            chatID: wireMessage.chatID,
            clientMessageID: nil,
            targetMessageID: wireMessage.id,
            replyToMessageID: nil,
            replyPreview: nil,
            communityContext: nil,
            deliveryOptions: nil,
            senderID: localUserID,
            senderName: resolvedIdentity().displayName,
            senderAlias: resolvedIdentity().alias,
            recipientID: wireMessage.senderID,
            text: nil,
            reactionEmoji: nil,
            createdAt: Date.now.timeIntervalSince1970,
            preferredPath: await preferredPath(for: wireMessage.senderID),
            hopCount: 0,
            maxHopCount: Self.meshMaxHopCount,
            traversedPeerIDs: [localUserID]
        )

        _ = try? await routeWireMessage(receipt, intendedRecipientID: wireMessage.senderID)
    }

    private func applyDeliveryReceipt(for packetID: UUID, sourcePath: OfflineTransportPath) {
        removeRelayPacket(packetID)

        guard let match = messagesByChatID.first(where: { _, messages in
            messages.contains(where: { $0.id == packetID })
        }) else {
            return
        }

        let chatID = match.key
        var updatedMessages = match.value
        guard let index = updatedMessages.firstIndex(where: { $0.id == packetID }) else { return }

        updatedMessages[index].status = .delivered
        if updatedMessages[index].deliveryRoute == nil {
            updatedMessages[index].deliveryRoute = deliveryRoute(for: sourcePath)
        }
        messagesByChatID[chatID] = updatedMessages
        refreshChatMetadata(for: chatID)
        persistArchiveSnapshot()
    }

    private func upsertKnownPeerFromIncomingMessage(_ wireMessage: WireMessage, centralID: UUID) {
        let current = knownPeersByPeripheralID[centralID]
        guard let current else {
            peripheralIDsByPeerID[wireMessage.senderID] = centralID
            return
        }

        let previousPeerID = current.offlinePeer.id

        let offlinePeer = OfflinePeer(
            id: wireMessage.senderID,
            displayName: wireMessage.senderName,
            alias: wireMessage.senderAlias,
            signalStrength: current.offlinePeer.signalStrength,
            isReachable: true,
            availablePaths: mergePaths(current.offlinePeer.availablePaths + [.bluetooth]),
            relayCapable: current.offlinePeer.relayCapable
        )

        knownPeersByPeripheralID[centralID] = KnownPeer(
            peripheralID: centralID,
            peripheral: current.peripheral,
            offlinePeer: offlinePeer,
            writableCharacteristic: current.writableCharacteristic,
            profileCharacteristic: current.profileCharacteristic,
            lastSeenAt: .now
        )

        peripheralIDsByPeerID[previousPeerID] = nil
        peripheralIDsByPeerID[wireMessage.senderID] = centralID
    }

    private func relayWireMessageIfPossible(
        _ wireMessage: WireMessage,
        excludingUserIDs: Set<UUID>
    ) throws -> Bool {
        guard let meshSession else { return false }

        let localUserID = resolvedIdentity().userID
        let nextHopCount = min((wireMessage.hopCount ?? 0) + 1, Self.meshMaxHopCount)
        guard nextHopCount <= (wireMessage.maxHopCount ?? Self.meshMaxHopCount) else {
            return false
        }

        var relayedWireMessage = wireMessage
        relayedWireMessage.preferredPath = .meshRelay
        relayedWireMessage.hopCount = nextHopCount
        relayedWireMessage.maxHopCount = wireMessage.maxHopCount ?? Self.meshMaxHopCount
        relayedWireMessage.traversedPeerIDs = Array(Set((wireMessage.traversedPeerIDs ?? []) + [localUserID]))

        let candidatePeers = meshKnownPeersByUserID.values.filter { meshPeer in
            meshPeer.state == .connected &&
            isMeshPeerFresh(meshPeer) &&
            excludingUserIDs.contains(meshPeer.offlinePeer.id) == false &&
            relayedWireMessage.traversedPeerIDs?.contains(meshPeer.offlinePeer.id) == false
        }

        guard candidatePeers.isEmpty == false else {
            return false
        }

        let data = try encoder.encode(relayedWireMessage)
        try meshSession.send(data, toPeers: candidatePeers.map(\.peerID), with: .reliable)
        return true
    }

    private func tryRelayStoredMessages() {
        let now = Date()
        pruneRelayState(now: now)

        guard relayWireMessages.isEmpty == false else {
            persistRelayStateIfNeeded()
            scheduleRelayRetryIfNeeded()
            return
        }

        guard connectedMeshPeerIDs().isEmpty == false else {
            scheduleRelayRetryIfNeeded()
            return
        }

        let duePackets = relayWireMessages.values
            .filter { nextRelayAttemptDate(for: $0) <= now }
            .sorted { $0.queuedAt < $1.queuedAt }

        for record in duePackets {
            let packet = record.wireMessage
            let excluded = Set(packet.traversedPeerIDs ?? [])
            if (try? relayWireMessageIfPossible(packet, excludingUserIDs: excluded)) == true {
                var updatedRecord = relayWireMessages[packet.id] ?? record
                updatedRecord.lastAttemptAt = now
                updatedRecord.attemptCount = max(updatedRecord.attemptCount + 1, 1)
                relayWireMessages[packet.id] = updatedRecord
            }
        }

        persistRelayStateIfNeeded()
        scheduleRelayRetryIfNeeded()
    }

    private func handleFoundMeshPeer(_ peerID: MCPeerID, discoveryInfo: [String: String]?) {
        let userID = discoveryInfo?["uid"].flatMap(UUID.init(uuidString:)) ?? Self.fallbackPeerID(from: peerID.displayName)
        let discoveredName = discoveryInfo?["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = discoveredName.isEmpty ? peerID.displayName : discoveredName
        let alias = discoveryInfo?["alias"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let relayCapable = discoveryInfo?["relay"] == "1"

        let existingPeer = meshKnownPeersByUserID[userID]
        let offlinePeer = OfflinePeer(
            id: userID,
            displayName: existingPeer?.offlinePeer.displayName ?? displayName,
            alias: existingPeer?.offlinePeer.alias.isEmpty == false ? existingPeer!.offlinePeer.alias : alias,
            signalStrength: 0,
            isReachable: true,
            availablePaths: mergePaths((existingPeer?.offlinePeer.availablePaths ?? []) + [.localNetwork]),
            relayCapable: relayCapable || (existingPeer?.offlinePeer.relayCapable ?? false)
        )

        meshKnownPeersByUserID[userID] = MeshKnownPeer(
            peerID: peerID,
            offlinePeer: offlinePeer,
            state: existingPeer?.state ?? .notConnected,
            lastSeenAt: .now
        )
        meshUserIDsByPeerDisplayName[peerID.displayName] = userID

        guard let meshBrowser, let meshSession, peerID != meshSession.myPeerID else { return }
        guard pendingMeshInvitations.contains(peerID.displayName) == false else { return }
        guard meshSession.connectedPeers.contains(peerID) == false else { return }

        pendingMeshInvitations.insert(peerID.displayName)
        meshBrowser.invitePeer(peerID, to: meshSession, withContext: nil, timeout: 12)
        scheduleRelayRetryIfNeeded()
    }

    private func handleLostMeshPeer(_ peerID: MCPeerID) {
        guard let userID = meshUserIDsByPeerDisplayName[peerID.displayName],
              var knownPeer = meshKnownPeersByUserID[userID] else {
            return
        }

        knownPeer.offlinePeer.isReachable = false
        knownPeer.state = .notConnected
        meshKnownPeersByUserID[userID] = knownPeer
        pendingMeshInvitations.remove(peerID.displayName)
        scheduleRelayRetryIfNeeded()
    }

    private func handleMeshSessionStateChange(for peerID: MCPeerID, state: MCSessionState) {
        guard let userID = meshUserIDsByPeerDisplayName[peerID.displayName],
              var knownPeer = meshKnownPeersByUserID[userID] else {
            return
        }

        knownPeer.state = state
        knownPeer.lastSeenAt = .now
        knownPeer.offlinePeer.isReachable = state == .connected || state == .connecting
        knownPeer.offlinePeer.availablePaths = mergePaths(knownPeer.offlinePeer.availablePaths + [.localNetwork])
        knownPeer.offlinePeer.relayCapable = true
        meshKnownPeersByUserID[userID] = knownPeer
        pendingMeshInvitations.remove(peerID.displayName)

        if state == .connected {
            resolveMeshConnection(
                for: peerID.displayName,
                result: .success(bluetoothSession(for: userID, state: .connected))
            )
            tryRelayStoredMessages()
        } else if state == .notConnected {
            resolveMeshConnection(for: peerID.displayName, result: .failure(OfflineTransportError.connectionFailed))
        }

        scheduleRelayRetryIfNeeded()
    }

    private func handleReceivedMeshData(_ data: Data, from peerID: MCPeerID) {
        guard let wireMessage = try? decoder.decode(WireMessage.self, from: data) else {
            return
        }

        if meshUserIDsByPeerDisplayName[peerID.displayName] == nil {
            handleFoundMeshPeer(
                peerID,
                discoveryInfo: [
                    "uid": wireMessage.senderID.uuidString,
                    "name": wireMessage.senderName,
                    "alias": wireMessage.senderAlias,
                    "relay": "1",
                ]
            )
        }

        handleIncomingWireMessage(
            wireMessage,
            preferredSignalStrength: 0,
            sourcePath: wireMessage.recipientID == resolvedIdentity().userID ? .localNetwork : .meshRelay
        )
    }

    private func encodedProfileData() -> Data? {
        let identity = resolvedIdentity()
        let profile = PeerProfile(userID: identity.userID, displayName: identity.displayName, alias: identity.alias)
        return try? encoder.encode(profile)
    }

    private func isKnownPeerFresh(_ knownPeer: KnownPeer, now: Date = .now) -> Bool {
        now.timeIntervalSince(knownPeer.lastSeenAt) <= Self.reachablePeerFreshnessWindow
    }

    private func migrateExistingChatIfNeeded(from previousPeerID: UUID, to updatedPeer: OfflinePeer) {
        guard previousPeerID != updatedPeer.id else {
            return
        }

        let localUserID = resolvedIdentity().userID
        let oldChatID = Self.chatID(for: localUserID, and: previousPeerID)
        let newChatID = Self.chatID(for: localUserID, and: updatedPeer.id)

        guard oldChatID != newChatID else {
            return
        }

        if let oldChat = chatsByID.removeValue(forKey: oldChatID) {
            let migratedChat = Chat(
                id: newChatID,
                mode: oldChat.mode,
                type: oldChat.type,
                title: updatedPeer.displayName,
                subtitle: updatedPeer.alias.isEmpty ? "Nearby" : "@\(updatedPeer.alias)",
                participantIDs: [localUserID, updatedPeer.id],
                group: oldChat.group,
                lastMessagePreview: oldChat.lastMessagePreview,
                lastActivityAt: oldChat.lastActivityAt,
                unreadCount: oldChat.unreadCount,
                isPinned: oldChat.isPinned,
                draft: oldChat.draft,
                disappearingPolicy: oldChat.disappearingPolicy,
                notificationPreferences: oldChat.notificationPreferences
            )
            chatsByID[newChatID] = migratedChat
        }

        if let messages = messagesByChatID.removeValue(forKey: oldChatID) {
            let migratedMessages = messages.map { message in
                Message(
                    id: message.id,
                    chatID: newChatID,
                    senderID: message.senderID,
                    senderDisplayName: message.senderDisplayName,
                    mode: message.mode,
                    kind: message.kind,
                    text: message.text,
                    attachments: message.attachments,
                    replyToMessageID: message.replyToMessageID,
                    status: message.status,
                    createdAt: message.createdAt,
                    editedAt: message.editedAt,
                    deletedForEveryoneAt: message.deletedForEveryoneAt,
                    reactions: message.reactions,
                    voiceMessage: message.voiceMessage,
                    liveLocation: message.liveLocation
                )
            }
            messagesByChatID[newChatID] = migratedMessages
        }

        persistArchiveSnapshot()
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

extension NearbyOfflineTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                self.restartScanningIfNeeded()
            } else if central.state == .poweredOff {
                self.knownPeersByPeripheralID.removeAll()
                self.peripheralIDsByPeerID.removeAll()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        Task { @MainActor in
            let restoredPeripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
            for peripheral in restoredPeripherals {
                self.handleDiscoveredPeripheral(peripheral, advertisementData: [:], rssi: -60)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            self.handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.handleConnectedPeripheral(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.resolveConnection(for: peripheral.identifier, result: .failure(OfflineTransportError.connectionFailed))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.handleDisconnectedPeripheral(peripheral, error: error)
        }
    }
}

extension NearbyOfflineTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            self.handleDiscoveredServices(for: peripheral, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            self.handleDiscoveredCharacteristics(for: peripheral, service: service, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            self.handleUpdatedValue(for: peripheral, characteristic: characteristic, error: error)
        }
    }
}

extension NearbyOfflineTransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            if peripheral.state == .poweredOn {
                self.ensurePeripheralService()
                self.restartAdvertisingIfNeeded()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        Task { @MainActor in
            self.ensurePeripheralService()
            self.restartAdvertisingIfNeeded()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        Task { @MainActor in
            guard request.characteristic.uuid == Self.profileCharacteristicUUID, let data = self.encodedProfileData() else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                return
            }

            guard request.offset <= data.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }

            request.value = data.subdata(in: request.offset ..< data.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor in
            self.handleIncomingWriteRequests(requests)
        }
    }
}

extension NearbyOfflineTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            self.handleFoundMeshPeer(peerID, discoveryInfo: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleLostMeshPeer(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) { }
}

extension NearbyOfflineTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            self.handleFoundMeshPeer(peerID, discoveryInfo: nil)
            invitationHandler(true, self.meshSession)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) { }
}

extension NearbyOfflineTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.handleMeshSessionStateChange(for: peerID, state: state)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleReceivedMeshData(data, from: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) { }

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) { }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) { }

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}

enum OfflineTransportError: LocalizedError {
    case peerUnavailable
    case connectionTimedOut
    case connectionFailed
    case deliveryFailed
    case mediaUnavailable
    case chatUnavailable
    case nearbySelectionRequired
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .peerUnavailable:
            return "Nearby Bluetooth device unavailable."
        case .connectionTimedOut:
            return "Nearby Bluetooth connection timed out."
        case .connectionFailed:
            return "Could not connect to the nearby Bluetooth device."
        case .deliveryFailed:
            return "Could not deliver the Bluetooth message."
        case .mediaUnavailable:
            return "Bluetooth media sending is not available in this build yet."
        case .chatUnavailable:
            return "Chat is unavailable."
        case .nearbySelectionRequired:
            return "Choose a nearby Bluetooth device to start an offline chat."
        case .emptyMessage:
            return "Message is empty."
        }
    }
}
