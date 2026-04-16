import AVFoundation
import Combine
import Foundation
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

@MainActor
final class InternetCallManager: ObservableObject {
    static let shared = InternetCallManager()

    @Published private(set) var activeCall: InternetCall?
    @Published private(set) var isPresentingCallUI = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = false
    @Published private(set) var isVideoEnabled = false
    @Published private(set) var lastErrorMessage = ""

    private let audioSessionCoordinator = CallAudioSessionCoordinator()
    private let mediaEngine = WebRTCAudioCallEngine()
    private let callKitCoordinator = CallKitCoordinator()

    private var repository: (any CallRepository)?
    private var currentUserID: UUID?

    private var monitoringTask: Task<Void, Never>?
    private var callEventsTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private var callEventsCallID: UUID?
    private var lastEventSequence: Int = 0
    private var mediaCallID: UUID?
    private var sentOfferCallIDs: Set<UUID> = []
    private var sentAnswerCallIDs: Set<UUID> = []
    private var pendingRemoteOfferByCallID: [UUID: String] = [:]
    private var pendingRemoteAnswerByCallID: [UUID: String] = [:]
    private var pendingRemoteICEByCallID: [UUID: [WebRTCAudioCallEngine.ICECandidatePayload]] = [:]
    private var pendingPushCallIDs: Set<UUID> = []
    private var pendingCallKitAnswerCallIDs: Set<UUID> = []
    private var prewarmedIncomingCallIDs: Set<UUID> = []
    private var locallyOriginatedOutgoingCallIDs: Set<UUID> = []
    private var localOutgoingStartAtByCallID: [UUID: Date] = [:]
    private var incomingAnswerDispatchTasks: [UUID: Task<Void, Never>] = [:]
    private var isCallKitAudioSessionActive = false
    private var activeCallKitAudioSession: AVAudioSession?

    private init() {
        mediaEngine.onLocalICECandidate = { [weak self] payload in
            Task { @MainActor [weak self] in
                await self?.sendLocalICECandidate(payload)
            }
        }
        mediaEngine.onStateLog = { [weak self] state in
            self?.callDebugLog("webrtc.\(state)")
        }
        callKitCoordinator.onStart = { [weak self] callID in
            self?.callDebugLog("callkit.start call=\(callID.uuidString)")
        }
        callKitCoordinator.onStartOutgoingToUserID = { [weak self] userID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.startOutgoingCall(to: userID)
                } catch {
                    self.callDebugLog("callkit.start.recent.failed user=\(userID.uuidString) error=\(error)")
                }
            }
        }
        callKitCoordinator.onAnswer = { [weak self] callID in
            Task { @MainActor [weak self] in
                await self?.answerCall(callID: callID)
            }
        }
        callKitCoordinator.onEnd = { [weak self] callID in
            Task { @MainActor [weak self] in
                await self?.endCall(callID: callID)
            }
        }
        callKitCoordinator.onSetMuted = { [weak self] callID, isMuted in
            guard let self else { return }
            guard self.activeCall?.id == callID else { return }
            self.isMuted = isMuted
            self.mediaEngine.setMuted(isMuted)
        }
        callKitCoordinator.onAudioSessionActivated = { [weak self] audioSession in
            self?.isCallKitAudioSessionActive = true
            self?.activeCallKitAudioSession = audioSession
            self?.callDebugLog("callkit.audio.activated")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.audioSessionCoordinator.configureActivatedCallKitSession(
                        audioSession,
                        speakerEnabled: self.isSpeakerEnabled
                    )
                    #if !os(tvOS)
                    self.callDebugLog("audio.route.activated \(await self.audioSessionCoordinator.currentAudioRouteDescription())")
                    #endif
                } catch {
                    #if !os(tvOS)
                    self.callDebugLog(
                        "audio.callkit.configure.failed permission=\(await self.audioSessionCoordinator.microphonePermissionStatusDescription()) error=\(error)"
                    )
                    #else
                    self.callDebugLog("audio.callkit.configure.failed error=\(error)")
                    #endif
                }
            }
            self?.mediaEngine.notifyAudioSessionActivated(using: audioSession)
        }
        callKitCoordinator.onAudioSessionDeactivated = { [weak self] audioSession in
            self?.isCallKitAudioSessionActive = false
            self?.activeCallKitAudioSession = nil
            self?.callDebugLog("callkit.audio.deactivated")
            self?.mediaEngine.notifyAudioSessionDeactivated(using: audioSession)
        }
    }

    func configure(currentUserID: UUID, repository: any CallRepository) {
        let userDidChange = self.currentUserID != currentUserID
        self.currentUserID = currentUserID
        self.repository = repository

        if userDidChange || monitoringTask == nil {
            startMonitoring()
        }

        Task { [weak self] in
            await self?.processPendingPushCallsIfNeeded()
            await self?.processPendingCallKitAnswersIfNeeded()
        }
    }

    func stopMonitoring() {
        stopEventMonitoring()
        stopMediaSession()
        clearSignalBacklog(for: nil)
        stopIncomingAnswerDispatchLoop(for: nil)
        pendingPushCallIDs.removeAll()
        pendingCallKitAnswerCallIDs.removeAll()
        prewarmedIncomingCallIDs.removeAll()
        locallyOriginatedOutgoingCallIDs.removeAll()
        localOutgoingStartAtByCallID.removeAll()
        isCallKitAudioSessionActive = false
        activeCallKitAudioSession = nil

        monitoringTask?.cancel()
        monitoringTask = nil
        durationTask?.cancel()
        durationTask = nil
        dismissTask?.cancel()
        dismissTask = nil

        activeCall = nil
        isPresentingCallUI = false
        duration = 0
        isMuted = false
        isSpeakerEnabled = false
        isVideoEnabled = false
        lastErrorMessage = ""

        Task {
            await audioSessionCoordinator.deactivate()
        }
    }

    func startOutgoingCall(to user: User) async throws {
        guard let currentUserID, let repository else {
            throw CallRepositoryError.backendUnavailable
        }

        clearError()
        let call = try await repository.startAudioCall(with: user.id, from: currentUserID)
        locallyOriginatedOutgoingCallIDs.insert(call.id)
        localOutgoingStartAtByCallID[call.id] = Date.now
        callDebugLog("outgoing.local.start call=\(call.id.uuidString) callee=\(user.id.uuidString)")
        await install(call)
    }

    func startOutgoingCall(to calleeID: UUID) async throws {
        guard let currentUserID, let repository else {
            throw CallRepositoryError.backendUnavailable
        }

        clearError()
        let call = try await repository.startAudioCall(with: calleeID, from: currentUserID)
        locallyOriginatedOutgoingCallIDs.insert(call.id)
        localOutgoingStartAtByCallID[call.id] = Date.now
        callDebugLog("outgoing.callkit.start call=\(call.id.uuidString) callee=\(calleeID.uuidString)")
        await install(call)
    }

    func answerCall() async throws {
        guard let currentUserID, let repository, let activeCall else {
            throw CallRepositoryError.callNotFound
        }

        clearError()
        let updatedCall = try await repository.answerCall(activeCall.id, userID: currentUserID)
        await install(updatedCall)
        startIncomingAnswerDispatchLoopIfNeeded(for: updatedCall)
    }

    func rejectCall() async throws {
        guard let currentUserID, let repository, let activeCall else {
            throw CallRepositoryError.callNotFound
        }

        clearError()
        let updatedCall = try await repository.rejectCall(activeCall.id, userID: currentUserID)
        await install(updatedCall)
    }

    func endActiveCall() async throws {
        guard let currentUserID, let repository, let activeCall else {
            throw CallRepositoryError.callNotFound
        }

        clearError()
        let updatedCall = try await repository.endCall(activeCall.id, userID: currentUserID)
        await install(updatedCall)
    }

    func endCall() {
        Task {
            try? await endActiveCall()
        }
    }

    func presentCallUI() {
        guard activeCall != nil else { return }
        isPresentingCallUI = true
    }

    func dismissCallUI() {
        isPresentingCallUI = false
    }

    func toggleMute() {
        isMuted.toggle()
        mediaEngine.setMuted(isMuted)
        if let callID = activeCall?.id {
            callKitCoordinator.updateMuted(callID: callID, isMuted: isMuted)
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        Task {
            try? await audioSessionCoordinator.setSpeakerEnabled(isSpeakerEnabled)
        }
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
    }

    func queueIncomingCallFromPush(callID: UUID, callerName: String? = nil) {
        pendingPushCallIDs.insert(callID)
        let resolvedHandle = {
            let trimmed = callerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Prime Messaging" : trimmed
        }()
        let handleValue = callKitHandleValue(forRemoteUserID: nil, callID: callID)
        if prewarmedIncomingCallIDs.contains(callID) == false {
            prewarmedIncomingCallIDs.insert(callID)
            callKitCoordinator.reportIncoming(callID: callID, handleValue: handleValue, displayName: resolvedHandle)
            callDebugLog("push.call.prewarm callkit call=\(callID.uuidString) handle=\(resolvedHandle)")
        }
        Task { [weak self] in
            await self?.processPendingPushCallsIfNeeded()
        }
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshActiveCalls()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshActiveCalls() async {
        guard let currentUserID, let repository else { return }

        do {
            let calls = try await repository.fetchActiveCalls(for: currentUserID)
            let preferredCall = preferredCall(from: calls, currentUserID: currentUserID)

            if let preferredCall {
                await install(preferredCall)
            } else if let activeCall {
                do {
                    let latestCall = try await repository.fetchCall(activeCall.id, for: currentUserID)
                    await install(latestCall)
                } catch {
                    await clearCallState()
                }
            } else {
                // Keep idle monitoring side-effect free.
            }
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? "calls.unavailable.start".localized
        }
    }

    private func preferredCall(from calls: [InternetCall], currentUserID: UUID) -> InternetCall? {
        calls.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return statePriority(lhs.state, currentUserID: currentUserID, call: lhs) > statePriority(rhs.state, currentUserID: currentUserID, call: rhs)
            }
            return lhs.createdAt > rhs.createdAt
        }.first
    }

    private func statePriority(_ state: InternetCallState, currentUserID: UUID, call: InternetCall) -> Int {
        switch state {
        case .active:
            return 4
        case .ringing:
            return call.direction(for: currentUserID) == .incoming ? 3 : 2
        case .ended, .cancelled, .rejected, .missed:
            return 1
        }
    }

    private func install(_ call: InternetCall) async {
        dismissTask?.cancel()
        activeCall = call
        isPresentingCallUI = true
        duration = resolvedDuration(for: call)
        if let currentUserID {
            callDebugLog(
                "call.install id=\(call.id.uuidString) state=\(call.state.rawValue) direction=\(call.direction(for: currentUserID).rawValue)"
            )
        } else {
            callDebugLog("call.install id=\(call.id.uuidString) state=\(call.state.rawValue) direction=unknown")
        }
        syncCallKitState(for: call)

        switch call.state {
        case .active:
            prewarmedIncomingCallIDs.remove(call.id)
            startEventMonitoring(for: call)
            do {
                try await ensureMediaSession(for: call)
                await activateAudioIfNeeded()
                await recoverIncomingOfferIfNeeded(for: call)
                if let currentUserID,
                   call.direction(for: currentUserID) == .outgoing,
                   sentOfferCallIDs.contains(call.id) == false,
                   let repository {
                    let offer = try await mediaEngine.createOffer()
                    _ = try await repository.sendOffer(offer, in: call.id, userID: currentUserID)
                    sentOfferCallIDs.insert(call.id)
                    callDebugLog("offer.sent.recovered.active call=\(call.id.uuidString)")
                }
                try await flushPendingSignals(for: call.id)
                startIncomingAnswerDispatchLoopIfNeeded(for: call)
            } catch {
                callDebugLog("media.start.failed: \(error)")
            }
            startDurationUpdates(startDate: call.answeredAt ?? call.createdAt)
        case .ringing:
            startEventMonitoring(for: call)
            durationTask?.cancel()
            durationTask = nil
            if let currentUserID, call.direction(for: currentUserID) == .outgoing {
                do {
                    try await ensureMediaSession(for: call)
                    if sentOfferCallIDs.contains(call.id) == false {
                        let offer = try await mediaEngine.createOffer()
                        if let repository {
                            _ = try await repository.sendOffer(offer, in: call.id, userID: currentUserID)
                            sentOfferCallIDs.insert(call.id)
                            callDebugLog("offer.sent call=\(call.id.uuidString)")
                        }
                    }
                    try await flushPendingSignals(for: call.id)
                } catch {
                    callDebugLog("outgoing.offer.failed: \(error)")
                }
            }
        case .ended, .cancelled, .rejected, .missed:
            prewarmedIncomingCallIDs.remove(call.id)
            locallyOriginatedOutgoingCallIDs.remove(call.id)
            localOutgoingStartAtByCallID.removeValue(forKey: call.id)
            durationTask?.cancel()
            durationTask = nil
            stopEventMonitoring()
            stopMediaSession()
            clearSignalBacklog(for: call.id)
            stopIncomingAnswerDispatchLoop(for: call.id)
            isCallKitAudioSessionActive = false
            activeCallKitAudioSession = nil
            await audioSessionCoordinator.deactivate()
            scheduleDismissIfNeeded(for: call.id)
        }
    }

    private func clearCallState() async {
        let previousCallID = activeCall?.id
        if let previousCallID {
            prewarmedIncomingCallIDs.remove(previousCallID)
            callKitCoordinator.reportEnded(callID: previousCallID)
        }
        durationTask?.cancel()
        durationTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        stopEventMonitoring()
        stopMediaSession()
        clearSignalBacklog(for: previousCallID)
        stopIncomingAnswerDispatchLoop(for: previousCallID)
        locallyOriginatedOutgoingCallIDs.removeAll()
        localOutgoingStartAtByCallID.removeAll()
        isCallKitAudioSessionActive = false
        activeCallKitAudioSession = nil
        activeCall = nil
        isPresentingCallUI = false
        duration = 0
        isMuted = false
        isSpeakerEnabled = false
        isVideoEnabled = false
        await audioSessionCoordinator.deactivate()
    }

    private func activateAudioIfNeeded() async {
        if isCallKitAudioSessionActive {
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            do {
                try await audioSessionCoordinator.configureActivatedCallKitSession(
                    session,
                    speakerEnabled: isSpeakerEnabled
                )
                #if !os(tvOS)
                callDebugLog("audio.route.callkit-path \(await audioSessionCoordinator.currentAudioRouteDescription())")
                #endif
            } catch {
                #if !os(tvOS)
                callDebugLog(
                    "audio.callkit-path.configure.failed permission=\(await audioSessionCoordinator.microphonePermissionStatusDescription()) error=\(error)"
                )
                #else
                callDebugLog("audio.callkit-path.configure.failed error=\(error)")
                #endif
            }
            mediaEngine.notifyAudioSessionActivated(using: session)
            return
        }
        do {
            try await audioSessionCoordinator.activate(speakerEnabled: isSpeakerEnabled)
            mediaEngine.notifyAudioSessionActivated(using: AVAudioSession.sharedInstance())
            #if !os(tvOS)
            callDebugLog("audio.route.activated.local \(await audioSessionCoordinator.currentAudioRouteDescription())")
            #endif
        } catch {
            lastErrorMessage = "calls.unavailable.start".localized
            callDebugLog("audio.activate.failed: \(error)")
        }
    }

    private func startDurationUpdates(startDate: Date) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.duration = max(Date.now.timeIntervalSince(startDate), 0)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func resolvedDuration(for call: InternetCall) -> TimeInterval {
        let startDate = call.answeredAt ?? call.createdAt
        let endDate = call.endedAt ?? Date.now
        guard call.state != .ringing else { return 0 }
        return max(endDate.timeIntervalSince(startDate), 0)
    }

    private func scheduleDismissIfNeeded(for callID: UUID) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.activeCall?.id == callID else { return }
            await self.clearCallState()
        }
    }

    private func clearError() {
        lastErrorMessage = ""
    }

    private func syncCallKitState(for call: InternetCall) {
        guard let currentUserID else { return }
        let displayName = call.displayName(for: currentUserID)
        let direction = call.direction(for: currentUserID)
        let remoteUserID = remoteParticipantID(for: call, currentUserID: currentUserID)
        let handleValue = callKitHandleValue(forRemoteUserID: remoteUserID, callID: call.id)

        switch call.state {
        case .ringing:
            if direction == .incoming {
                callKitCoordinator.reportIncoming(callID: call.id, handleValue: handleValue, displayName: displayName)
            } else {
                guard locallyOriginatedOutgoingCallIDs.contains(call.id) else {
                    callDebugLog("callkit.outgoing.skip_non_local call=\(call.id.uuidString)")
                    return
                }
                callKitCoordinator.reportOutgoingStarted(callID: call.id, handleValue: handleValue, displayName: displayName)
            }
        case .active:
            if direction == .outgoing, locallyOriginatedOutgoingCallIDs.contains(call.id) {
                callKitCoordinator.reportOutgoingConnected(callID: call.id)
            }
        case .ended, .cancelled, .rejected, .missed:
            callKitCoordinator.reportEnded(callID: call.id)
        }
    }

    private func startEventMonitoring(for call: InternetCall) {
        if callEventsCallID == call.id, callEventsTask != nil {
            return
        }

        stopEventMonitoring()
        callEventsCallID = call.id
        // Always replay full signaling timeline for this call id to avoid missing
        // offers sent before this client started polling.
        lastEventSequence = 0
        callDebugLog("events.monitor.start call=\(call.id.uuidString) fromSequence=0 latest=\(call.lastEventSequence)")

        callEventsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let callID = self.callEventsCallID,
                      let currentUserID = self.currentUserID,
                      let repository = self.repository else {
                    try? await Task.sleep(for: .milliseconds(350))
                    continue
                }

                do {
                    let events = try await repository.fetchEvents(
                        callID: callID,
                        userID: currentUserID,
                        sinceSequence: self.lastEventSequence
                    ).sorted { $0.sequence < $1.sequence }

                    for event in events where event.sequence > self.lastEventSequence {
                        self.lastEventSequence = event.sequence
                        await self.handleCallEvent(event, callID: callID)
                    }
                } catch {
                    self.callDebugLog("events.fetch.failed call=\(callID.uuidString) error=\(error)")
                }

                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func stopEventMonitoring() {
        callEventsTask?.cancel()
        callEventsTask = nil
        callEventsCallID = nil
        lastEventSequence = 0
    }

    private func ensureMediaSession(for call: InternetCall) async throws {
        if mediaCallID == call.id {
            return
        }

        stopMediaSession()
        let iceServers = await resolveIceServers()
        try mediaEngine.start(iceServers: iceServers)
        mediaEngine.setMuted(isMuted)
        if isCallKitAudioSessionActive {
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            mediaEngine.notifyAudioSessionActivated(using: session)
        }
        mediaCallID = call.id
        callDebugLog("media.started call=\(call.id.uuidString)")
    }

    private func stopMediaSession() {
        let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
        mediaEngine.notifyAudioSessionDeactivated(using: session)
        mediaCallID = nil
        mediaEngine.stop()
    }

    private func clearSignalBacklog(for callID: UUID?) {
        if let callID {
            pendingRemoteOfferByCallID.removeValue(forKey: callID)
            pendingRemoteAnswerByCallID.removeValue(forKey: callID)
            pendingRemoteICEByCallID.removeValue(forKey: callID)
            sentOfferCallIDs.remove(callID)
            sentAnswerCallIDs.remove(callID)
            return
        }
        pendingRemoteOfferByCallID.removeAll()
        pendingRemoteAnswerByCallID.removeAll()
        pendingRemoteICEByCallID.removeAll()
        sentOfferCallIDs.removeAll()
        sentAnswerCallIDs.removeAll()
    }

    private func handleCallEvent(_ event: InternetCallEvent, callID: UUID) async {
        let isLocalSender = event.senderID == currentUserID
        if isLocalSender && (event.type == .offer || event.type == .answer || event.type == .ice) {
            return
        }

        callDebugLog(
            "event.received call=\(callID.uuidString) type=\(event.type.rawValue) seq=\(event.sequence) sender=\(event.senderID?.uuidString ?? "nil") localSender=\(isLocalSender)"
        )

        switch event.type {
        case .offer:
            guard let sdp = event.sdp, sdp.isEmpty == false else { return }
            do {
                if let call = activeCall, call.id == callID, call.state == .active {
                    if sentAnswerCallIDs.contains(callID) {
                        callDebugLog("offer.ignored.already_answered call=\(callID.uuidString) seq=\(event.sequence)")
                        return
                    }
                    try await ensureMediaSession(for: call)
                    let answer = try await mediaEngine.applyRemoteOfferAndCreateAnswer(sdp)
                    if let repository, let currentUserID {
                        _ = try await repository.sendAnswer(answer, in: callID, userID: currentUserID)
                        sentAnswerCallIDs.insert(callID)
                        callDebugLog("answer.sent call=\(callID.uuidString)")
                    }
                } else {
                    pendingRemoteOfferByCallID[callID] = sdp
                }
            } catch {
                pendingRemoteOfferByCallID[callID] = sdp
                callDebugLog("offer.handle.failed call=\(callID.uuidString) error=\(error)")
            }

        case .answer:
            guard let sdp = event.sdp, sdp.isEmpty == false else { return }
            do {
                try await mediaEngine.applyRemoteAnswer(sdp)
            } catch {
                pendingRemoteAnswerByCallID[callID] = sdp
                callDebugLog("answer.handle.failed call=\(callID.uuidString) error=\(error)")
            }

        case .ice:
            guard let candidate = event.candidate, candidate.isEmpty == false else { return }
            let payload = WebRTCAudioCallEngine.ICECandidatePayload(
                candidate: candidate,
                sdpMid: event.sdpMid,
                sdpMLineIndex: event.sdpMLineIndex
            )
            if mediaCallID == callID {
                mediaEngine.addRemoteICECandidate(
                    candidate: payload.candidate,
                    sdpMid: payload.sdpMid,
                    sdpMLineIndex: payload.sdpMLineIndex
                )
            } else {
                pendingRemoteICEByCallID[callID, default: []].append(payload)
            }

        case .accepted, .rejected, .ended:
            await refreshCallSnapshot(callID: callID)

        case .created:
            break
        }
    }

    private func refreshCallSnapshot(callID: UUID) async {
        guard let repository, let currentUserID else { return }
        do {
            let latest = try await repository.fetchCall(callID, for: currentUserID)
            await install(latest)
        } catch {
            callDebugLog("call.refresh.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func flushPendingSignals(for callID: UUID) async throws {
        if let offer = pendingRemoteOfferByCallID.removeValue(forKey: callID),
           let repository, let currentUserID {
            if sentAnswerCallIDs.contains(callID) {
                callDebugLog("answer.skip.already_sent.pending call=\(callID.uuidString)")
            } else {
                let answer = try await mediaEngine.applyRemoteOfferAndCreateAnswer(offer)
                _ = try await repository.sendAnswer(answer, in: callID, userID: currentUserID)
                sentAnswerCallIDs.insert(callID)
                callDebugLog("answer.sent.pending call=\(callID.uuidString)")
            }
        }

        if let answer = pendingRemoteAnswerByCallID.removeValue(forKey: callID) {
            try await mediaEngine.applyRemoteAnswer(answer)
        }

        if let candidates = pendingRemoteICEByCallID.removeValue(forKey: callID) {
            for candidate in candidates {
                mediaEngine.addRemoteICECandidate(
                    candidate: candidate.candidate,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: candidate.sdpMLineIndex
                )
            }
        }
    }

    private func sendLocalICECandidate(_ payload: WebRTCAudioCallEngine.ICECandidatePayload) async {
        guard let callID = mediaCallID, let repository, let currentUserID else { return }
        do {
            _ = try await repository.sendICECandidate(
                payload.candidate,
                sdpMid: payload.sdpMid,
                sdpMLineIndex: payload.sdpMLineIndex,
                in: callID,
                userID: currentUserID
            )
        } catch {
            callDebugLog("ice.send.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func recoverIncomingOfferIfNeeded(for call: InternetCall) async {
        guard let currentUserID, let repository else { return }
        guard call.direction(for: currentUserID) == .incoming else { return }
        guard sentAnswerCallIDs.contains(call.id) == false else { return }

        if pendingRemoteOfferByCallID[call.id] != nil {
            return
        }

        do {
            let events = try await repository.fetchEvents(
                callID: call.id,
                userID: currentUserID,
                sinceSequence: 0
            )
            let latestRemoteOffer = events
                .filter { event in
                    event.type == .offer && event.senderID != currentUserID
                }
                .max { lhs, rhs in
                    lhs.sequence < rhs.sequence
                }

            guard let latestRemoteOffer,
                  let sdp = latestRemoteOffer.sdp,
                  sdp.isEmpty == false else {
                return
            }

            pendingRemoteOfferByCallID[call.id] = sdp
            callDebugLog("offer.recovered call=\(call.id.uuidString) seq=\(latestRemoteOffer.sequence)")
        } catch {
            callDebugLog("offer.recover.failed call=\(call.id.uuidString) error=\(error)")
        }
    }

    private func processPendingPushCallsIfNeeded() async {
        guard let repository, let currentUserID else { return }
        guard pendingPushCallIDs.isEmpty == false else { return }

        let callIDs = Array(pendingPushCallIDs)
        for callID in callIDs {
            do {
                let call = try await repository.fetchCall(callID, for: currentUserID)
                pendingPushCallIDs.remove(callID)
                callDebugLog("push.call.resolve.success call=\(callID.uuidString) state=\(call.state.rawValue)")
                await install(call)
            } catch {
                callDebugLog("push.call.resolve.failed call=\(callID.uuidString) error=\(error)")
            }
        }
    }

    private func processPendingCallKitAnswersIfNeeded() async {
        guard pendingCallKitAnswerCallIDs.isEmpty == false else { return }
        guard currentUserID != nil, repository != nil else { return }

        let callIDs = Array(pendingCallKitAnswerCallIDs)
        for callID in callIDs {
            let didStart = await answerCall(callID: callID)
            if didStart {
                pendingCallKitAnswerCallIDs.remove(callID)
                callDebugLog("callkit.answer.pending.resolved call=\(callID.uuidString)")
            }
        }
    }

    @discardableResult
    private func answerCall(callID: UUID) async -> Bool {
        #if os(iOS) && canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "pm.call.answer.request.\(callID.uuidString)") { }
        #endif
        defer {
            #if os(iOS) && canImport(UIKit)
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            #endif
        }

        guard let currentUserID, let repository else {
            pendingCallKitAnswerCallIDs.insert(callID)
            callDebugLog("callkit.answer.deferred.missing_context call=\(callID.uuidString)")
            return false
        }

        do {
            let updatedCall = try await repository.answerCall(callID, userID: currentUserID)
            await install(updatedCall)
            startIncomingAnswerDispatchLoopIfNeeded(for: updatedCall)
            pendingCallKitAnswerCallIDs.remove(callID)
            callDebugLog("callkit.answer.accepted call=\(callID.uuidString)")
            return true
        } catch {
            callDebugLog("callkit.answer.failed call=\(callID.uuidString) error=\(error.localizedDescription)")
            return false
        }
    }

    private func endCall(callID: UUID) async {
        guard let currentUserID, let repository else { return }
        guard let activeCall, activeCall.id == callID else {
            callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=no_active_match")
            return
        }

        let direction = activeCall.direction(for: currentUserID)
        if activeCall.state == .ringing, direction == .outgoing {
            guard locallyOriginatedOutgoingCallIDs.contains(callID) else {
                callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=non_local_outgoing")
                return
            }

            let startedAt = localOutgoingStartAtByCallID[callID] ?? activeCall.createdAt
            let elapsed = Date.now.timeIntervalSince(startedAt)
            if elapsed < 0.9 {
                callDebugLog(
                    "callkit.end.ignored call=\(callID.uuidString) reason=spurious_early_end elapsed=\(String(format: "%.3f", elapsed))"
                )
                return
            }
        }

        do {
            let updatedCall = try await repository.endCall(callID, userID: currentUserID)
            await install(updatedCall)
        } catch {
            callDebugLog("callkit.end.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func resolveIceServers() async -> [WebRTCAudioCallEngine.ICEServer] {
        func normalizedServersWithFallback(_ raw: [WebRTCAudioCallEngine.ICEServer]) -> [WebRTCAudioCallEngine.ICEServer] {
            var servers = raw.isEmpty ? WebRTCAudioCallEngine.ICEServer.fallbackSet : raw
            if WebRTCAudioCallEngine.ICEServer.hasTURN(servers) == false {
                servers.append(.publicFallbackTURN)
                callDebugLog("ice-config.turn.missing -> appended_public_fallback_turn")
            }
            return servers
        }

        guard let baseURL = BackendConfiguration.currentBaseURL,
              let currentUserID else {
            return normalizedServersWithFallback([])
        }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/calls/ice-config",
                method: "GET",
                userID: currentUserID
            )

            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode else {
                return normalizedServersWithFallback([])
            }

            let payload = try BackendJSONDecoder.make().decode(CallICEConfigResponse.self, from: data)
            let servers = payload.iceServers.compactMap { server -> WebRTCAudioCallEngine.ICEServer? in
                let resolvedURLs: [String]
                if let urls = server.urls, urls.isEmpty == false {
                    resolvedURLs = urls
                } else if let url = server.url, url.isEmpty == false {
                    resolvedURLs = [url]
                } else {
                    return nil
                }
                return .init(urls: resolvedURLs, username: server.username, credential: server.credential)
            }

            return normalizedServersWithFallback(servers)
        } catch {
            callDebugLog("ice-config.fetch.failed error=\(error)")
            return normalizedServersWithFallback([])
        }
    }

    private func callDebugLog(_ message: String) {
        print("[CallManager] \(message)")
    }

    private func remoteParticipantID(for call: InternetCall, currentUserID: UUID) -> UUID? {
        if call.callerID == currentUserID {
            return call.calleeID
        }
        if call.calleeID == currentUserID {
            return call.callerID
        }
        return nil
    }

    private func callKitHandleValue(forRemoteUserID remoteUserID: UUID?, callID: UUID) -> String {
        if let remoteUserID {
            return "pmuser:\(remoteUserID.uuidString.lowercased())"
        }
        return "pmcall:\(callID.uuidString.lowercased())"
    }

    private func ensureIncomingAnswerDispatched(callID: UUID) async {
        guard let currentUserID, let repository else { return }
        guard sentAnswerCallIDs.contains(callID) == false else { return }

        #if os(iOS) && canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "pm.call.answer.\(callID.uuidString)") { }
        #endif
        defer {
            #if os(iOS) && canImport(UIKit)
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            #endif
        }

        for attempt in 1 ... 120 {
            if sentAnswerCallIDs.contains(callID) {
                return
            }

            do {
                let latestCall = try await repository.fetchCall(callID, for: currentUserID)
                if latestCall.state == .ended || latestCall.state == .cancelled || latestCall.state == .rejected || latestCall.state == .missed {
                    callDebugLog("answer.accept_flow.stop_terminal_state call=\(callID.uuidString) state=\(latestCall.state.rawValue)")
                    return
                }
                guard latestCall.state == .active else {
                    callDebugLog("answer.accept_flow.wait_state call=\(callID.uuidString) state=\(latestCall.state.rawValue) attempt=\(attempt)")
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard latestCall.direction(for: currentUserID) == .incoming else {
                    callDebugLog("answer.accept_flow.skip_non_incoming call=\(callID.uuidString)")
                    return
                }

                let events = try await repository.fetchEvents(
                    callID: callID,
                    userID: currentUserID,
                    sinceSequence: 0
                )
                callDebugLog("answer.accept_flow.events call=\(callID.uuidString) attempt=\(attempt) count=\(events.count)")
                guard let latestRemoteOffer = events
                    .filter({ $0.type == .offer && $0.senderID != currentUserID })
                    .max(by: { $0.sequence < $1.sequence }),
                      let offerSDP = latestRemoteOffer.sdp,
                      offerSDP.isEmpty == false else {
                    callDebugLog("answer.accept_flow.wait_offer call=\(callID.uuidString) attempt=\(attempt)")
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                #if !os(tvOS)
                let canPromptMicrophone = {
                    #if os(iOS) && canImport(UIKit)
                    UIApplication.shared.applicationState == .active
                    #else
                    true
                    #endif
                }()
                let hasMicPermission = try await audioSessionCoordinator.ensureMicrophonePermissionGranted(
                    canPrompt: canPromptMicrophone
                )
                if hasMicPermission == false {
                    callDebugLog(
                        "answer.accept_flow.wait_microphone_permission call=\(callID.uuidString) attempt=\(attempt) canPrompt=\(canPromptMicrophone) status=\(await audioSessionCoordinator.microphonePermissionStatusDescription())"
                    )
                    try? await Task.sleep(for: .milliseconds(350))
                    continue
                }
                #endif

                try await ensureMediaSession(for: latestCall)
                await activateAudioIfNeeded()

                let answerSDP: String
                do {
                    answerSDP = try await mediaEngine.applyRemoteOfferAndCreateAnswer(offerSDP)
                } catch {
                    callDebugLog("answer.accept_flow.apply_failed call=\(callID.uuidString) attempt=\(attempt) error=\(error)")
                    stopMediaSession()
                    try await ensureMediaSession(for: latestCall)
                    await activateAudioIfNeeded()
                    answerSDP = try await mediaEngine.applyRemoteOfferAndCreateAnswer(offerSDP)
                }

                _ = try await repository.sendAnswer(answerSDP, in: callID, userID: currentUserID)
                sentAnswerCallIDs.insert(callID)
                callDebugLog("answer.sent.accept_flow call=\(callID.uuidString) seq=\(latestRemoteOffer.sequence) attempt=\(attempt)")
                return
            } catch {
                callDebugLog("answer.accept_flow.retry call=\(callID.uuidString) attempt=\(attempt) error=\(error)")
            }

            try? await Task.sleep(for: .milliseconds(350))
        }

        callDebugLog("answer.accept_flow.give_up call=\(callID.uuidString)")
    }

    private func startIncomingAnswerDispatchLoopIfNeeded(for call: InternetCall) {
        guard let currentUserID else { return }
        guard call.state == .active else { return }
        guard call.direction(for: currentUserID) == .incoming else { return }
        guard sentAnswerCallIDs.contains(call.id) == false else { return }
        guard incomingAnswerDispatchTasks[call.id] == nil else { return }

        callDebugLog("answer.dispatch.loop.start call=\(call.id.uuidString)")
        incomingAnswerDispatchTasks[call.id] = Task { [weak self] in
            guard let self else { return }
            await self.ensureIncomingAnswerDispatched(callID: call.id)
            await MainActor.run {
                self.incomingAnswerDispatchTasks.removeValue(forKey: call.id)
            }
        }
    }

    private func stopIncomingAnswerDispatchLoop(for callID: UUID?) {
        if let callID {
            incomingAnswerDispatchTasks[callID]?.cancel()
            incomingAnswerDispatchTasks.removeValue(forKey: callID)
            return
        }

        for task in incomingAnswerDispatchTasks.values {
            task.cancel()
        }
        incomingAnswerDispatchTasks.removeAll()
    }
}

private struct CallICEConfigResponse: Decodable {
    let iceServers: [CallICEConfigServer]
}

private struct CallICEConfigServer: Decodable {
    let urls: [String]?
    let url: String?
    let username: String?
    let credential: String?
}
