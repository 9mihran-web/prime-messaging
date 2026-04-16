import Foundation
import AVFoundation

#if os(iOS) && canImport(CallKit)
import CallKit
#endif

@MainActor
final class CallKitCoordinator: NSObject {
    var onStart: ((UUID) -> Void)?
    var onStartOutgoingToUserID: ((UUID) -> Void)?
    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onSetMuted: ((UUID, Bool) -> Void)?
    var onAudioSessionActivated: ((AVAudioSession) -> Void)?
    var onAudioSessionDeactivated: ((AVAudioSession) -> Void)?

#if os(iOS) && canImport(CallKit)
    private let provider: CXProvider
    private let callController = CXCallController()
    private var callUUIDByCallID: [UUID: UUID] = [:]
    private var callIDByCallUUID: [UUID: UUID] = [:]
    private var outgoingStartedCallIDs: Set<UUID> = []
    private var outgoingConnectedCallIDs: Set<UUID> = []
#endif

    override init() {
#if os(iOS) && canImport(CallKit)
        let configuration = CXProviderConfiguration(localizedName: "Prime Messaging")
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
#endif
        super.init()
#if os(iOS) && canImport(CallKit)
        provider.setDelegate(self, queue: nil)
#endif
    }

    func reportIncoming(callID: UUID, handleValue: String, displayName: String) {
#if os(iOS) && canImport(CallKit)
        guard callUUIDByCallID[callID] == nil else { return }
        let callUUID = register(callID: callID)

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handleValue)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            guard let self else { return }
            if let error {
                self.cleanup(callID: callID)
                print("[CallKit] incoming.report.failed call=\(callID.uuidString) error=\(error)")
                return
            }
            print("[CallKit] incoming.reported call=\(callID.uuidString)")
        }
#else
        _ = callID
        _ = handleValue
        _ = displayName
#endif
    }

    func reportOutgoingStarted(callID: UUID, handleValue: String, displayName: String) {
#if os(iOS) && canImport(CallKit)
        guard outgoingStartedCallIDs.contains(callID) == false else { return }
        outgoingStartedCallIDs.insert(callID)
        let callUUID = register(callID: callID)

        let action = CXStartCallAction(call: callUUID, handle: CXHandle(type: .generic, value: handleValue))
        action.isVideo = false
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            guard let self else { return }
            if let error {
                self.outgoingStartedCallIDs.remove(callID)
                print("[CallKit] outgoing.start.failed call=\(callID.uuidString) error=\(error)")
                return
            }
            self.provider.reportOutgoingCall(with: callUUID, startedConnectingAt: .now)
            print("[CallKit] outgoing.start.reported call=\(callID.uuidString)")
        }
#else
        _ = callID
        _ = handleValue
        _ = displayName
#endif
    }

    func reportOutgoingConnected(callID: UUID) {
#if os(iOS) && canImport(CallKit)
        guard outgoingConnectedCallIDs.contains(callID) == false else { return }
        guard let callUUID = callUUIDByCallID[callID] else { return }
        outgoingConnectedCallIDs.insert(callID)
        provider.reportOutgoingCall(with: callUUID, connectedAt: .now)
        print("[CallKit] outgoing.connected call=\(callID.uuidString)")
#else
        _ = callID
#endif
    }

    func reportEnded(callID: UUID) {
#if os(iOS) && canImport(CallKit)
        guard let callUUID = callUUIDByCallID[callID] else { return }
        provider.reportCall(with: callUUID, endedAt: .now, reason: .remoteEnded)
        cleanup(callID: callID)
        print("[CallKit] ended.reported call=\(callID.uuidString)")
#else
        _ = callID
#endif
    }

    func updateMuted(callID: UUID, isMuted: Bool) {
#if os(iOS) && canImport(CallKit)
        guard let callUUID = callUUIDByCallID[callID] else { return }
        let action = CXSetMutedCallAction(call: callUUID, muted: isMuted)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error {
                print("[CallKit] mute.update.failed call=\(callID.uuidString) error=\(error)")
            }
        }
#else
        _ = callID
        _ = isMuted
#endif
    }

    private func register(callID: UUID) -> UUID {
#if os(iOS) && canImport(CallKit)
        if let existing = callUUIDByCallID[callID] {
            return existing
        }
        let callUUID = UUID()
        callUUIDByCallID[callID] = callUUID
        callIDByCallUUID[callUUID] = callID
        return callUUID
#else
        return UUID()
#endif
    }

    private func cleanup(callID: UUID) {
#if os(iOS) && canImport(CallKit)
        guard let callUUID = callUUIDByCallID.removeValue(forKey: callID) else { return }
        callIDByCallUUID.removeValue(forKey: callUUID)
        outgoingStartedCallIDs.remove(callID)
        outgoingConnectedCallIDs.remove(callID)
#else
        _ = callID
#endif
    }
}

#if os(iOS) && canImport(CallKit)
extension CallKitCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        _ = provider
        Task { @MainActor in
            self.callUUIDByCallID.removeAll()
            self.callIDByCallUUID.removeAll()
            self.outgoingStartedCallIDs.removeAll()
            self.outgoingConnectedCallIDs.removeAll()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        _ = provider
        Task { @MainActor in
            if let callID = self.callIDByCallUUID[action.callUUID] {
                self.onStart?(callID)
                action.fulfill()
                print("[CallKit] start.fulfilled call=\(callID.uuidString)")
                return
            }

            if let userID = self.resolveUserID(from: action.handle.value) {
                self.onStartOutgoingToUserID?(userID)
                action.fulfill()
                print("[CallKit] start.fulfilled.recent user=\(userID.uuidString)")
                return
            }

            action.fail()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        _ = provider
        Task { @MainActor in
            guard let callID = self.callIDByCallUUID[action.callUUID] else {
                action.fail()
                return
            }
            self.onAnswer?(callID)
            action.fulfill()
            print("[CallKit] answer.fulfilled call=\(callID.uuidString)")
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        _ = provider
        Task { @MainActor in
            guard let callID = self.callIDByCallUUID[action.callUUID] else {
                action.fail()
                return
            }
            self.onEnd?(callID)
            action.fulfill()
            print("[CallKit] end.fulfilled call=\(callID.uuidString)")
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        _ = provider
        Task { @MainActor in
            guard let callID = self.callIDByCallUUID[action.callUUID] else {
                action.fail()
                return
            }
            self.onSetMuted?(callID, action.isMuted)
            action.fulfill()
            print("[CallKit] mute.fulfilled call=\(callID.uuidString) muted=\(action.isMuted)")
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        _ = provider
        Task { @MainActor in
            self.onAudioSessionActivated?(audioSession)
            print("[CallKit] audio_session.activated")
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        _ = provider
        Task { @MainActor in
            self.onAudioSessionDeactivated?(audioSession)
            print("[CallKit] audio_session.deactivated")
        }
    }
}

#if os(iOS) && canImport(CallKit)
private extension CallKitCoordinator {
    func resolveUserID(from handleValue: String) -> UUID? {
        let value = handleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = UUID(uuidString: value) {
            return parsed
        }
        let prefix = "pmuser:"
        if value.lowercased().hasPrefix(prefix),
           let parsed = UUID(uuidString: String(value.dropFirst(prefix.count))) {
            return parsed
        }
        return nil
    }
}
#endif
#endif
