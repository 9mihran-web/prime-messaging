import CoreBluetooth
import CryptoKit
import Foundation
import UIKit

@MainActor
final class NearbyOfflineTransport: NSObject, OfflineTransporting {
    private struct KnownPeer {
        let peripheralID: UUID
        var peripheral: CBPeripheral
        var offlinePeer: OfflinePeer
        var writableCharacteristic: CBCharacteristic?
        var profileCharacteristic: CBCharacteristic?
    }

    private struct PeerProfile: Codable {
        let userID: UUID
        let displayName: String
        let alias: String
    }

    private struct WireMessage: Codable {
        let id: UUID
        let chatID: UUID
        let senderID: UUID
        let senderName: String
        let senderAlias: String
        let text: String
        let createdAt: TimeInterval
    }

    private static let serviceUUID = CBUUID(string: "6A0C1001-2D2E-4A9E-A0C2-9C6C2F1D1001")
    private static let profileCharacteristicUUID = CBUUID(string: "6A0C1002-2D2E-4A9E-A0C2-9C6C2F1D1002")
    private static let inboxCharacteristicUUID = CBUUID(string: "6A0C1003-2D2E-4A9E-A0C2-9C6C2F1D1003")
    private static let currentUserKey = "app_state.current_user"
    private static let installationIDKey = "offline_transport.installation_id"
    private static let centralRestoreID = "mirowin.prime-messaging.ble.central"
    private static let peripheralRestoreID = "mirowin.prime-messaging.ble.peripheral"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentUser: User?
    private var isScanning = false

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var profileCharacteristic: CBMutableCharacteristic?
    private var inboxCharacteristic: CBMutableCharacteristic?

    private var knownPeersByPeripheralID: [UUID: KnownPeer] = [:]
    private var peripheralIDsByPeerID: [UUID: UUID] = [:]
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

        if shouldRestart {
            restartTransport()
        }
    }

    func startScanning() async {
        isScanning = true
        ensureManagers()
        restartAdvertisingIfNeeded()
        restartScanningIfNeeded()
    }

    func stopScanning() async {
        isScanning = false
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
    }

    func discoveredPeers() async -> [OfflinePeer] {
        knownPeersByPeripheralID.values
            .map(\.offlinePeer)
            .filter(\.isReachable)
            .sorted(by: { lhs, rhs in
                if lhs.signalStrength != rhs.signalStrength {
                    return lhs.signalStrength > rhs.signalStrength
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            })
    }

    func connect(to peer: OfflinePeer) async throws -> BluetoothSession {
        ensureManagers()

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

        guard let remotePeerID = chat.participantIDs.first(where: { $0 != senderID }) else {
            throw OfflineTransportError.chatUnavailable
        }

        guard let peripheralID = peripheralIDsByPeerID[remotePeerID], var knownPeer = knownPeersByPeripheralID[peripheralID] else {
            throw OfflineTransportError.peerUnavailable
        }

        if knownPeer.peripheral.state != .connected || knownPeer.writableCharacteristic == nil {
            _ = try await connect(to: knownPeer.offlinePeer)
            guard let refreshedPeer = knownPeersByPeripheralID[peripheralID] else {
                throw OfflineTransportError.peerUnavailable
            }
            knownPeer = refreshedPeer
        }

        guard let characteristic = knownPeer.writableCharacteristic else {
            throw OfflineTransportError.peerUnavailable
        }

        let identity = resolvedIdentity()
        let wireMessage = WireMessage(
            id: message.id,
            chatID: chat.id,
            senderID: senderID,
            senderName: identity.displayName,
            senderAlias: identity.alias,
            text: trimmed,
            createdAt: message.createdAt.timeIntervalSince1970
        )

        do {
            let data = try encoder.encode(wireMessage)
            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            knownPeer.peripheral.writeValue(data, for: characteristic, type: writeType)
            return message
        } catch {
            replaceMessageStatus(messageID: message.id, in: chat.id, status: .failed)
            throw OfflineTransportError.deliveryFailed
        }
    }

    private func ensureManagers() {
        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [
                    CBCentralManagerOptionShowPowerAlertKey: true,
                    CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID,
                ]
            )
        }

        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: nil,
                options: [
                    CBPeripheralManagerOptionShowPowerAlertKey: true,
                    CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID,
                ]
            )
        }
    }

    private func restartTransport() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()

        for knownPeer in knownPeersByPeripheralID.values where knownPeer.peripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(knownPeer.peripheral)
        }

        knownPeersByPeripheralID.removeAll()
        peripheralIDsByPeerID.removeAll()
        pendingConnections.removeAll()
        pendingConnectionTimeouts.values.forEach { $0.cancel() }
        pendingConnectionTimeouts.removeAll()

        restartAdvertisingIfNeeded()
        restartScanningIfNeeded()
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

    private func ensurePeripheralService() {
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
    }

    private func resolvedPeer(afterConnectingTo peerID: UUID) -> OfflinePeer? {
        if let peripheralID = peripheralIDsByPeerID[peerID] {
            return knownPeersByPeripheralID[peripheralID]?.offlinePeer
        }

        return nil
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

    private func resolveConnection(for peripheralID: UUID, result: Result<BluetoothSession, Error>) {
        pendingConnectionTimeouts[peripheralID]?.cancel()
        pendingConnectionTimeouts[peripheralID] = nil

        guard let continuation = pendingConnections.removeValue(forKey: peripheralID) else {
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
            isReachable: true
        )

        if let previousPeer = existingKnownPeer?.offlinePeer {
            peripheralIDsByPeerID[previousPeer.id] = peripheral.identifier
        }

        knownPeersByPeripheralID[peripheral.identifier] = KnownPeer(
            peripheralID: peripheral.identifier,
            peripheral: peripheral,
            offlinePeer: offlinePeer,
            writableCharacteristic: existingKnownPeer?.writableCharacteristic,
            profileCharacteristic: existingKnownPeer?.profileCharacteristic
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
            isReachable: true
        )
        knownPeer.offlinePeer = updatedPeer
        knownPeersByPeripheralID[peripheral.identifier] = knownPeer

        peripheralIDsByPeerID[previousPeerID] = nil
        peripheralIDsByPeerID[profile.userID] = peripheral.identifier

        resolveConnection(
            for: peripheral.identifier,
            result: .success(bluetoothSession(for: profile.userID, state: .connected))
        )
    }

    private func handleIncomingWriteRequests(_ requests: [CBATTRequest]) {
        let localUserID = resolvedIdentity().userID

        for request in requests where request.characteristic.uuid == Self.inboxCharacteristicUUID {
            guard let data = request.value, let wireMessage = try? decoder.decode(WireMessage.self, from: data) else {
                peripheralManager?.respond(to: request, withResult: .unlikelyError)
                continue
            }

            upsertKnownPeerFromIncomingMessage(wireMessage, centralID: request.central.identifier)

            let chatID = wireMessage.chatID
            let senderPeerID = wireMessage.senderID
            let knownPeer = resolvedPeer(afterConnectingTo: senderPeerID) ?? OfflinePeer(
                id: senderPeerID,
                displayName: wireMessage.senderName,
                alias: wireMessage.senderAlias,
                signalStrength: -60,
                isReachable: true
            )

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
                senderID: senderPeerID,
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

            if messagesByChatID[chatID]?.contains(where: { $0.id == message.id }) != true, let chat = chatsByID[chatID] {
                append(message: message, to: chat)
                var updatedChat = chatsByID[chatID]
                updatedChat?.unreadCount += 1
                chatsByID[chatID] = updatedChat
            }

            peripheralManager?.respond(to: request, withResult: .success)
        }
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
            isReachable: true
        )

        knownPeersByPeripheralID[centralID] = KnownPeer(
            peripheralID: centralID,
            peripheral: current.peripheral,
            offlinePeer: offlinePeer,
            writableCharacteristic: current.writableCharacteristic,
            profileCharacteristic: current.profileCharacteristic
        )

        peripheralIDsByPeerID[previousPeerID] = nil
        peripheralIDsByPeerID[wireMessage.senderID] = centralID
    }

    private func encodedProfileData() -> Data? {
        let identity = resolvedIdentity()
        let profile = PeerProfile(userID: identity.userID, displayName: identity.displayName, alias: identity.alias)
        return try? encoder.encode(profile)
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
            return "Nearby Bluetooth device unavailable."
        case .connectionTimedOut:
            return "Nearby Bluetooth connection timed out."
        case .connectionFailed:
            return "Could not connect to the nearby Bluetooth device."
        case .deliveryFailed:
            return "Could not deliver the Bluetooth message."
        case .chatUnavailable:
            return "Chat is unavailable."
        case .nearbySelectionRequired:
            return "Choose a nearby Bluetooth device to start an offline chat."
        case .emptyMessage:
            return "Message is empty."
        }
    }
}
