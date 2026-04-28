import Foundation
import AVFoundation

#if os(iOS) && canImport(CallKit)
import CallKit
#endif

nonisolated private func callKitSanitizedTrimmedLabel(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }

    let lowered = trimmed.lowercased()
    let rejectedPrefixes = [
        "pmuser:",
        "pmgroup:",
        "pmcall:",
        "pmgroupcall:",
        "group:",
        "user:",
        "call:",
        "call id:",
        "call_id:"
    ]

    if rejectedPrefixes.contains(where: { lowered.hasPrefix($0) }) {
        return nil
    }

    if lowered == "pm user" || lowered == "pm group" {
        return nil
    }

    if UUID(uuidString: trimmed) != nil {
        return nil
    }

    return trimmed
}

nonisolated func callKitDisplayName(primary: String?, secondary: String? = nil, fallback: String) -> String {
    if let primary = callKitSanitizedTrimmedLabel(primary) {
        return primary
    }
    if let secondary = callKitSanitizedTrimmedLabel(secondary) {
        return secondary
    }
    return fallback
}

nonisolated func callKitReadableHandleValue(primary: String?, secondary: String? = nil, fallback: String) -> String {
    let resolved = callKitDisplayName(primary: primary, secondary: secondary, fallback: fallback)
    return String(resolved.prefix(128))
}

@MainActor
final class CallKitCoordinator: NSObject {
    var onStart: ((UUID) -> Void)?
    var onStartOutgoingToUserID: ((UUID) -> Void)?
    var onAnswer: ((UUID) async -> Bool)?
    var onEnd: ((UUID) -> Void)?
    var onSetMuted: ((UUID, Bool) -> Void)?
    var onAudioSessionActivated: ((AVAudioSession) -> Void)?
    var onAudioSessionDeactivated: ((AVAudioSession) -> Void)?

#if os(iOS) && canImport(CallKit)
    private let provider: CXProvider
    private let callController = CXCallController()
    private var callUUIDByCallID: [UUID: UUID] = [:]
    private var callIDByCallUUID: [UUID: UUID] = [:]
    private var trackedCallRegisteredAtByCallID: [UUID: Date] = [:]
    private var outgoingStartedCallIDs: Set<UUID> = []
    private var outgoingConnectedCallIDs: Set<UUID> = []
#endif

    override init() {
#if os(iOS) && canImport(CallKit)
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = true
        if Bundle.main.url(forResource: "call_ringtone", withExtension: "caf") != nil {
            configuration.ringtoneSound = "call_ringtone.caf"
            print("[CallKit] ringtone.custom name=call_ringtone.caf")
        }
        provider = CXProvider(configuration: configuration)
#endif
        super.init()
#if os(iOS) && canImport(CallKit)
        provider.setDelegate(self, queue: nil)
#endif
    }

    func reportIncoming(callID: UUID, handleValue: String, displayName: String) {
#if os(iOS) && canImport(CallKit)
        guard callUUIDByCallID[callID] == nil else {
            print("[CallKit] incoming.report.skipped call=\(callID.uuidString) reason=already_tracking")
            return
        }

        // Keep CallKit registry clean without touching fresh tracked calls.
        // Aggressive preflight cleanup can cause spurious end actions.
        endStaleTrackedCalls(maxAge: 120, excluding: callID, reason: .failed, source: "incoming_preflight_stale_only")
        reportIncomingInternal(
            callID: callID,
            handleValue: handleValue,
            displayName: displayName,
            attempt: 1
        )
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.outgoingStartedCallIDs.remove(callID)
                    print("[CallKit] outgoing.start.failed call=\(callID.uuidString) error=\(error)")
                    return
                }
                self.provider.reportOutgoingCall(with: callUUID, startedConnectingAt: .now)
                print("[CallKit] outgoing.start.reported call=\(callID.uuidString)")
            }
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

    func isTracking(callID: UUID) -> Bool {
#if os(iOS) && canImport(CallKit)
        return callUUIDByCallID[callID] != nil
#else
        _ = callID
        return false
#endif
    }

    func requestAnswer(callID: UUID) async -> Bool {
#if os(iOS) && canImport(CallKit)
        guard let callUUID = callUUIDByCallID[callID] else {
            print("[CallKit] answer.request.skipped call=\(callID.uuidString) reason=missing_uuid")
            return false
        }

        let action = CXAnswerCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        return await withCheckedContinuation { continuation in
            callController.request(transaction) { error in
                if let error {
                    print("[CallKit] answer.request.failed call=\(callID.uuidString) error=\(error)")
                    continuation.resume(returning: false)
                    return
                }
                print("[CallKit] answer.requested call=\(callID.uuidString)")
                continuation.resume(returning: true)
            }
        }
#else
        _ = callID
        return false
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
            if trackedCallRegisteredAtByCallID[callID] == nil {
                trackedCallRegisteredAtByCallID[callID] = .now
            }
            return existing
        }
        let callUUID = UUID()
        callUUIDByCallID[callID] = callUUID
        callIDByCallUUID[callUUID] = callID
        trackedCallRegisteredAtByCallID[callID] = .now
        return callUUID
#else
        return UUID()
#endif
    }

    private func cleanup(callID: UUID) {
#if os(iOS) && canImport(CallKit)
        guard let callUUID = callUUIDByCallID.removeValue(forKey: callID) else { return }
        callIDByCallUUID.removeValue(forKey: callUUID)
        trackedCallRegisteredAtByCallID.removeValue(forKey: callID)
        outgoingStartedCallIDs.remove(callID)
        outgoingConnectedCallIDs.remove(callID)
#else
        _ = callID
#endif
    }

#if os(iOS) && canImport(CallKit)
    private func reportIncomingInternal(
        callID: UUID,
        handleValue: String,
        displayName: String,
        attempt: Int
    ) {
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
            Task { @MainActor in
                if let error {
                    self.cleanup(callID: callID)
                    print(
                        "[CallKit] incoming.report.failed call=\(callID.uuidString) attempt=\(attempt) error=\(error)"
                    )
                    self.endStaleTrackedCalls(
                        maxAge: 120,
                        excluding: callID,
                        reason: .failed,
                        source: "incoming_retry_cleanup_stale_only"
                    )
                    if attempt < 3 {
                        let delayNs: UInt64 = attempt == 1 ? 120_000_000 : 260_000_000
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            try? await Task.sleep(nanoseconds: delayNs)
                            self.reportIncomingInternal(
                                callID: callID,
                                handleValue: handleValue,
                                displayName: displayName,
                                attempt: attempt + 1
                            )
                        }
                    }
                    return
                }
                print("[CallKit] incoming.reported call=\(callID.uuidString)")
            }
        }
    }

    private func endTrackedCalls(excluding excludedCallID: UUID?, reason: CXCallEndedReason, source: String) {
        let trackedCallIDs = Array(callUUIDByCallID.keys)
        for trackedCallID in trackedCallIDs where trackedCallID != excludedCallID {
            guard let callUUID = callUUIDByCallID[trackedCallID] else { continue }
            provider.reportCall(with: callUUID, endedAt: .now, reason: reason)
            cleanup(callID: trackedCallID)
            print("[CallKit] tracked.cleanup call=\(trackedCallID.uuidString) source=\(source)")
        }
    }

    private func endStaleTrackedCalls(
        maxAge: TimeInterval,
        excluding excludedCallID: UUID?,
        reason: CXCallEndedReason,
        source: String
    ) {
        let now = Date.now
        let staleCallIDs = callUUIDByCallID.keys.filter { trackedCallID in
            guard trackedCallID != excludedCallID else { return false }
            guard let registeredAt = trackedCallRegisteredAtByCallID[trackedCallID] else { return false }
            return now.timeIntervalSince(registeredAt) >= maxAge
        }

        for staleCallID in staleCallIDs {
            guard let callUUID = callUUIDByCallID[staleCallID] else { continue }
            provider.reportCall(with: callUUID, endedAt: .now, reason: reason)
            cleanup(callID: staleCallID)
            print("[CallKit] tracked.cleanup.stale call=\(staleCallID.uuidString) source=\(source)")
        }
    }
#endif
}

#if os(iOS) && canImport(CallKit)
extension CallKitCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        _ = provider
        Task { @MainActor in
            self.callUUIDByCallID.removeAll()
            self.callIDByCallUUID.removeAll()
            self.trackedCallRegisteredAtByCallID.removeAll()
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
        let handleAnswer = { @MainActor in
            guard let callID = self.callIDByCallUUID[action.callUUID] else {
                action.fail()
                return
            }
            guard let onAnswer = self.onAnswer else {
                print("[CallKit] answer.failed call=\(callID.uuidString) reason=missing_handler")
                action.fail()
                self.onEnd?(callID)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let didStart = await onAnswer(callID)
                if didStart {
                    action.fulfill()
                    print("[CallKit] answer.fulfilled call=\(callID.uuidString) mode=deferred")
                    return
                }
                print("[CallKit] answer.post_start.failed call=\(callID.uuidString) -> ending")
                action.fail()
                self.onEnd?(callID)
            }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handleAnswer()
            }
        } else {
            Task { @MainActor in
                handleAnswer()
            }
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
            self.cleanup(callID: callID)
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
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.onAudioSessionActivated?(audioSession)
                print("[CallKit] audio_session.activated")
            }
        } else {
            Task { @MainActor in
                self.onAudioSessionActivated?(audioSession)
                print("[CallKit] audio_session.activated")
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        _ = provider
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.onAudioSessionDeactivated?(audioSession)
                print("[CallKit] audio_session.deactivated")
            }
        } else {
            Task { @MainActor in
                self.onAudioSessionDeactivated?(audioSession)
                print("[CallKit] audio_session.deactivated")
            }
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
