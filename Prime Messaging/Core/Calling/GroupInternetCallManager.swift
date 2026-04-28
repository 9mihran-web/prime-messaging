import AVFoundation
import Combine
import Foundation

@MainActor
final class GroupInternetCallManager: ObservableObject {
    private struct PendingIncomingPush: Sendable {
        let callID: UUID
        let chatID: UUID?
        let displayName: String
        let callerName: String?
        let preferredUserID: UUID?
    }

    struct RemoteParticipantState: Identifiable, Hashable {
        let participant: InternetCallParticipant
        var isJoined: Bool
        var isMuted: Bool
        var connectionState: WebRTCAudioCallEngine.ICEConnectionState

        var id: UUID { participant.id }
    }

    static let shared = GroupInternetCallManager()

    @Published private(set) var activeCall: InternetCall?
    @Published private(set) var isPresentingCallUI = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerEnabled = true
    @Published private(set) var isConnecting = false
    @Published private(set) var roomTitle = "Group Call"
    @Published private(set) var remoteParticipantStates: [RemoteParticipantState] = []
    @Published private(set) var lastErrorMessage = ""

    private let audioSessionCoordinator = CallAudioSessionCoordinator()
    private let callKitCoordinator = CallKitCoordinator()
    private let defaultPollingIntervalNanoseconds: UInt64 = 350_000_000
    private let bootstrapEventHistoryWindow = 48
    private let incomingPushDuplicateSuppressWindow: TimeInterval = 3.5
    private let staleSoloCallReuseThreshold: TimeInterval = 20

    private var repository: (any CallRepository)?
    private var currentUserID: UUID?
    private var monitoringTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var enginesByPeerID: [UUID: WebRTCAudioCallEngine] = [:]
    private var participantsByID: [UUID: InternetCallParticipant] = [:]
    private var remoteMuteStateByPeerID: [UUID: Bool] = [:]
    private var iceStateByPeerID: [UUID: WebRTCAudioCallEngine.ICEConnectionState] = [:]
    private var pendingRemoteICEByPeerID: [UUID: [WebRTCAudioCallEngine.ICECandidatePayload]] = [:]
    private var offerSentPeerIDs: Set<UUID> = []
    private var answerSentPeerIDs: Set<UUID> = []
    private var remoteAnswerAppliedPeerIDs: Set<UUID> = []
    private var lastEventSequence = 0
    private var activeChatID: UUID?
    private var audioSessionIsActive = false
    private var callKitStartedCallIDs: Set<UUID> = []
    private var callKitConnectedCallIDs: Set<UUID> = []
    private var pendingIncomingPushByCallID: [UUID: PendingIncomingPush] = [:]
    private var recentIncomingPushQueuedAtByCallID: [UUID: Date] = [:]
    private var pendingCallKitAnswerCallIDs: Set<UUID> = []
    private var callKitAnswerInFlightCallIDs: Set<UUID> = []

    private init() {
        callKitCoordinator.onAnswer = { [weak self] callID in
            guard let self else { return false }
            if self.callKitAnswerInFlightCallIDs.contains(callID) {
                return true
            }
            self.callKitAnswerInFlightCallIDs.insert(callID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.callKitAnswerInFlightCallIDs.remove(callID)
                }
                _ = await self.answerIncomingCall(callID: callID, allowDeferredSuccess: true)
            }
            return true
        }
        callKitCoordinator.onEnd = { [weak self] callID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activeCall?.id == callID {
                    do {
                        try await self.leaveCurrentCall()
                    } catch {
                        self.lastErrorMessage = error.localizedDescription
                        self.resetLocalState(clearError: false)
                    }
                    return
                }
                self.pendingIncomingPushByCallID.removeValue(forKey: callID)
                self.pendingCallKitAnswerCallIDs.remove(callID)
            }
        }
        callKitCoordinator.onSetMuted = { [weak self] callID, isMuted in
            guard let self, self.activeCall?.id == callID else { return }
            self.isMuted = isMuted
            for engine in self.enginesByPeerID.values {
                engine.setMuted(isMuted)
            }
            Task { @MainActor [weak self] in
                await self?.sendLocalMediaState()
            }
        }
        callKitCoordinator.onAudioSessionActivated = { [weak self] audioSession in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioSessionIsActive = true
                do {
                    _ = try await self.audioSessionCoordinator.configureActivatedCallKitSession(
                        audioSession,
                        speakerEnabled: self.isSpeakerEnabled
                    )
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                }

                for engine in self.enginesByPeerID.values {
                    engine.notifyAudioSessionActivated(using: audioSession)
                }
            }
        }
        callKitCoordinator.onAudioSessionDeactivated = { [weak self] _ in
            self?.audioSessionIsActive = false
        }
    }

    func configure(currentUserID: UUID, repository: any CallRepository) {
        let userDidChange = self.currentUserID != currentUserID
        self.currentUserID = currentUserID
        self.repository = repository
        if userDidChange, let activeCall, activeCall.joinedParticipantIDSet.contains(currentUserID) == false {
            resetLocalState(clearError: false)
        }
        Task { @MainActor [weak self] in
            await self?.processPendingCallKitAnswersIfNeeded()
        }
    }

    func stopMonitoring() {
        resetLocalState(clearError: false)
    }

    func presentCallUI() {
        guard activeCall != nil else { return }
        isPresentingCallUI = true
    }

    func dismissCallUI() {
        isPresentingCallUI = false
    }

    func isManaging(callID: UUID) -> Bool {
        activeCall?.id == callID
    }

    func queueIncomingCallFromPush(
        callID: UUID,
        chatID: UUID?,
        displayName: String? = nil,
        callerName: String? = nil,
        preferredUserID: UUID? = nil,
        prewarmCallKit: Bool = true
    ) {
        let now = Date.now
        if let lastQueuedAt = recentIncomingPushQueuedAtByCallID[callID],
           now.timeIntervalSince(lastQueuedAt) < incomingPushDuplicateSuppressWindow {
            return
        }
        recentIncomingPushQueuedAtByCallID[callID] = now
        recentIncomingPushQueuedAtByCallID = recentIncomingPushQueuedAtByCallID.filter {
            now.timeIntervalSince($0.value) < 60
        }

        let resolvedDisplayName = callKitDisplayName(
            primary: displayName,
            secondary: callerName,
            fallback: "Group Call"
        )

        pendingIncomingPushByCallID[callID] = PendingIncomingPush(
            callID: callID,
            chatID: chatID,
            displayName: resolvedDisplayName,
            callerName: callerName,
            preferredUserID: preferredUserID
        )

        guard prewarmCallKit else { return }
        let handleValue = callKitReadableHandleValue(
            primary: resolvedDisplayName,
            fallback: chatID == nil ? "Group Call" : "Prime Messaging Group"
        )

        if callKitCoordinator.isTracking(callID: callID) == false {
            callKitCoordinator.reportIncoming(
                callID: callID,
                handleValue: handleValue,
                displayName: resolvedDisplayName
            )
        }
    }

    func startOrJoinCall(in chat: Chat) async throws {
        guard let repository, let currentUserID else { return }

        roomTitle = chat.displayTitle(for: currentUserID)
        seedParticipantsDirectory(from: chat)
        isConnecting = true
        lastErrorMessage = ""

        let resolvedCall: InternetCall
        if let existingCall = try await repository.fetchActiveGroupCall(in: chat.id, userID: currentUserID) {
            if shouldRecycleExistingSoloCall(existingCall, currentUserID: currentUserID) {
                _ = try? await repository.leaveGroupCall(existingCall.id, userID: currentUserID)
                if activeCall?.id == existingCall.id {
                    resetLocalState(clearError: false)
                }
                resolvedCall = try await repository.startGroupAudioCall(in: chat.id, from: currentUserID)
            } else if let activeCall, activeCall.id == existingCall.id, activeCall.joinedParticipantIDSet.contains(currentUserID) {
                install(call: existingCall, roomTitle: roomTitle, resetEventCursor: false)
                presentCallUI()
                startMonitoringLoop()
                await reconcilePeerSessions(forceOfferEvaluation: false)
                isConnecting = false
                return
            } else if existingCall.joinedParticipantIDSet.contains(currentUserID) {
                roomTitle = chat.displayTitle(for: currentUserID)
                resolvedCall = existingCall
            } else {
                resolvedCall = try await repository.joinGroupCall(existingCall.id, userID: currentUserID)
            }
        } else {
            if let activeCall, activeCall.chatID == chat.id {
                resetLocalState(clearError: false)
            } else if activeCall != nil {
                try? await leaveCurrentCall()
            }
            resolvedCall = try await repository.startGroupAudioCall(in: chat.id, from: currentUserID)
        }

        try await activateAudioSessionIfNeeded()
        install(call: resolvedCall, roomTitle: roomTitle, resetEventCursor: true)
        presentCallUI()
        startMonitoringLoop()
        await reconcilePeerSessions(forceOfferEvaluation: true)
    }

    private func shouldRecycleExistingSoloCall(_ call: InternetCall, currentUserID: UUID) -> Bool {
        let joinedIDs = call.joinedParticipantIDSet
        guard joinedIDs == Set([currentUserID]) else { return false }
        let anchor = call.answeredAt ?? call.createdAt
        return Date.now.timeIntervalSince(anchor) >= staleSoloCallReuseThreshold
    }

    func leaveCurrentCall() async throws {
        guard let repository, let currentUserID, let activeCall else {
            resetLocalState(clearError: false)
            return
        }

        do {
            _ = try await repository.leaveGroupCall(activeCall.id, userID: currentUserID)
        } catch {
            lastErrorMessage = error.localizedDescription
            resetLocalState(clearError: false)
            throw error
        }

        resetLocalState(clearError: false)
    }

    func toggleMute() {
        isMuted.toggle()
        for engine in enginesByPeerID.values {
            engine.setMuted(isMuted)
        }
        if let activeCall {
            callKitCoordinator.updateMuted(callID: activeCall.id, isMuted: isMuted)
        }

        Task { @MainActor [weak self] in
            await self?.sendLocalMediaState()
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioSessionCoordinator.setSpeakerEnabled(self.isSpeakerEnabled)
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func startMonitoringLoop() {
        monitoringTask?.cancel()
        guard let callID = activeCall?.id else { return }

        monitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                await self.refreshActiveCallSnapshot(callID: callID)
                await self.refreshEvents(callID: callID)
                await self.reconcilePeerSessions(forceOfferEvaluation: false)
                try? await Task.sleep(nanoseconds: self.defaultPollingIntervalNanoseconds)
            }
        }

        startDurationLoop()
    }

    private func refreshActiveCallSnapshot(callID: UUID) async {
        guard let repository, let currentUserID else { return }

        do {
            let latestCall = try await repository.fetchGroupCall(callID, userID: currentUserID)
            guard activeCall?.id == latestCall.id else { return }
            install(call: latestCall, roomTitle: roomTitle, resetEventCursor: false)

            if latestCall.state == .ended || latestCall.joinedParticipantIDSet.contains(currentUserID) == false {
                resetLocalState(clearError: false)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshEvents(callID: UUID) async {
        guard let repository, let currentUserID else { return }

        do {
            let events = try await repository.fetchGroupEvents(
                callID: callID,
                userID: currentUserID,
                sinceSequence: lastEventSequence
            )

            if events.isEmpty {
                return
            }

            for event in events.sorted(by: { $0.sequence < $1.sequence }) {
                lastEventSequence = max(lastEventSequence, event.sequence)
                await handle(event: event)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handle(event: InternetCallEvent) async {
        guard let currentUserID else { return }

        switch event.type {
        case .created, .accepted, .rejected, .ended:
            break

        case .offer:
            guard let senderID = event.senderID,
                  senderID != currentUserID,
                  let sdp = event.sdp,
                  event.targetUserID == nil || event.targetUserID == currentUserID
            else {
                return
            }

            if shouldLocalInitiatePeerNegotiation(with: senderID), offerSentPeerIDs.contains(senderID) {
                return
            }

            do {
                let engine = try await ensurePeerEngine(for: senderID)
                let answerSDP = try await engine.applyRemoteOfferAndCreateAnswer(sdp)
                guard let repository, let activeCall else { return }
                answerSentPeerIDs.insert(senderID)
                _ = try await repository.sendGroupAnswer(
                    answerSDP,
                    to: senderID,
                    in: activeCall.id,
                    userID: currentUserID
                )
            } catch {
                lastErrorMessage = error.localizedDescription
            }

        case .answer:
            guard let senderID = event.senderID,
                  senderID != currentUserID,
                  let sdp = event.sdp,
                  event.targetUserID == nil || event.targetUserID == currentUserID,
                  let engine = enginesByPeerID[senderID]
            else {
                return
            }

            guard remoteAnswerAppliedPeerIDs.contains(senderID) == false else { return }

            do {
                try await engine.applyRemoteAnswer(sdp)
                remoteAnswerAppliedPeerIDs.insert(senderID)
            } catch {
                lastErrorMessage = error.localizedDescription
            }

        case .ice:
            guard let senderID = event.senderID,
                  senderID != currentUserID,
                  event.targetUserID == nil || event.targetUserID == currentUserID
            else {
                return
            }

            guard let candidate = event.candidate else {
                return
            }

            if let engine = enginesByPeerID[senderID] {
                engine.addRemoteICECandidate(
                    candidate: candidate,
                    sdpMid: event.sdpMid,
                    sdpMLineIndex: event.sdpMLineIndex
                )
            } else {
                var bufferedCandidates = pendingRemoteICEByPeerID[senderID] ?? []
                bufferedCandidates.append(
                    .init(
                        candidate: candidate,
                        sdpMid: event.sdpMid,
                        sdpMLineIndex: event.sdpMLineIndex
                    )
                )
                pendingRemoteICEByPeerID[senderID] = Array(bufferedCandidates.suffix(64))
            }

        case .mediaState:
            guard let senderID = event.senderID, senderID != currentUserID else { return }
            if let isMuted = event.isMuted {
                remoteMuteStateByPeerID[senderID] = isMuted
                rebuildRemoteParticipantStates()
            }
        }
    }

    private func reconcilePeerSessions(forceOfferEvaluation: Bool) async {
        guard let activeCall, let currentUserID else { return }

        updateParticipantsDirectory(with: activeCall)

        let joinedRemoteIDs = activeCall.joinedParticipantIDSet.subtracting([currentUserID])
        let obsoletePeerIDs = Set(enginesByPeerID.keys).subtracting(joinedRemoteIDs)
        for peerID in obsoletePeerIDs {
            removePeer(peerID)
        }

        for peerID in joinedRemoteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                _ = try await ensurePeerEngine(for: peerID)
            } catch {
                lastErrorMessage = error.localizedDescription
                continue
            }

            guard shouldLocalInitiatePeerNegotiation(with: peerID) else { continue }
            guard forceOfferEvaluation || offerSentPeerIDs.contains(peerID) == false else { continue }

            do {
                try await sendOffer(to: peerID)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }

        rebuildRemoteParticipantStates()
        isConnecting = joinedRemoteIDs.isEmpty == false && joinedRemoteIDs.allSatisfy {
            let state = iceStateByPeerID[$0] ?? .new
            return state != .connected && state != .completed
        }
    }

    private func ensurePeerEngine(for peerID: UUID) async throws -> WebRTCAudioCallEngine {
        if let existingEngine = enginesByPeerID[peerID] {
            return existingEngine
        }

        let engine = WebRTCAudioCallEngine()
        engine.onLocalICECandidate = { [weak self] payload in
            Task { @MainActor [weak self] in
                await self?.sendLocalICECandidate(payload, to: peerID)
            }
        }
        engine.onICEConnectionStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.iceStateByPeerID[peerID] = state
                self?.rebuildRemoteParticipantStates()
            }
        }
        engine.onStateLog = { [weak self] state in
            guard state.contains("error") else { return }
            Task { @MainActor [weak self] in
                self?.lastErrorMessage = state
            }
        }

        if audioSessionIsActive {
            let audioSession = AVAudioSession.sharedInstance()
            engine.notifyAudioSessionActivated(using: audioSession)
        }
        try engine.start(iceServers: WebRTCAudioCallEngine.ICEServer.fallbackSet)
        engine.setMuted(isMuted)
        if let bufferedCandidates = pendingRemoteICEByPeerID.removeValue(forKey: peerID) {
            for payload in bufferedCandidates {
                engine.addRemoteICECandidate(
                    candidate: payload.candidate,
                    sdpMid: payload.sdpMid,
                    sdpMLineIndex: payload.sdpMLineIndex
                )
            }
        }

        enginesByPeerID[peerID] = engine
        return engine
    }

    private func sendOffer(to peerID: UUID) async throws {
        guard let activeCall,
              let currentUserID,
              let repository,
              let engine = enginesByPeerID[peerID]
        else {
            return
        }

        let offerSDP = try await engine.createOffer()
        _ = try await repository.sendGroupOffer(
            offerSDP,
            to: peerID,
            in: activeCall.id,
            userID: currentUserID
        )
        offerSentPeerIDs.insert(peerID)
    }

    private func sendLocalICECandidate(_ payload: WebRTCAudioCallEngine.ICECandidatePayload, to peerID: UUID) async {
        guard let activeCall,
              let currentUserID,
              let repository
        else {
            return
        }

        do {
            _ = try await repository.sendGroupICECandidate(
                payload.candidate,
                to: peerID,
                sdpMid: payload.sdpMid,
                sdpMLineIndex: payload.sdpMLineIndex,
                in: activeCall.id,
                userID: currentUserID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func sendLocalMediaState() async {
        guard let activeCall,
              let currentUserID,
              let repository
        else {
            return
        }

        do {
            _ = try await repository.sendGroupMediaState(
                isMuted: isMuted,
                isVideoEnabled: false,
                in: activeCall.id,
                userID: currentUserID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func activateAudioSessionIfNeeded() async throws {
        if audioSessionIsActive == false {
            try await audioSessionCoordinator.activate(speakerEnabled: isSpeakerEnabled)
            audioSessionIsActive = true
        }

        let audioSession = AVAudioSession.sharedInstance()
        for engine in enginesByPeerID.values {
            engine.notifyAudioSessionActivated(using: audioSession)
        }
    }

    private func processPendingCallKitAnswersIfNeeded() async {
        guard pendingCallKitAnswerCallIDs.isEmpty == false else { return }
        let callIDs = Array(pendingCallKitAnswerCallIDs)
        for callID in callIDs {
            let didStart = await answerIncomingCall(callID: callID, allowDeferredSuccess: false)
            if didStart {
                pendingCallKitAnswerCallIDs.remove(callID)
            }
        }
    }

    private func answerIncomingCall(callID: UUID, allowDeferredSuccess: Bool) async -> Bool {
        if let activeCall, activeCall.id == callID {
            presentCallUI()
            return true
        }

        guard let repository, let currentUserID else {
            if allowDeferredSuccess {
                pendingCallKitAnswerCallIDs.insert(callID)
                return true
            }
            return false
        }

        do {
            let latestCall = try await repository.fetchGroupCall(callID, userID: currentUserID)
            let joinedCall: InternetCall
            if latestCall.joinedParticipantIDSet.contains(currentUserID) {
                joinedCall = latestCall
            } else {
                joinedCall = try await repository.joinGroupCall(callID, userID: currentUserID)
            }

            let roomTitle = pendingIncomingPushByCallID[callID]?.displayName ?? "Group Call"
            let shouldWaitForCallKitAudioActivation =
                callKitCoordinator.isTracking(callID: callID) && audioSessionIsActive == false
            if shouldWaitForCallKitAudioActivation == false {
                try await activateAudioSessionIfNeeded()
            }
            install(call: joinedCall, roomTitle: roomTitle, resetEventCursor: true)
            presentCallUI()
            startMonitoringLoop()
            await reconcilePeerSessions(forceOfferEvaluation: true)
            pendingIncomingPushByCallID.removeValue(forKey: callID)
            pendingCallKitAnswerCallIDs.remove(callID)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            if allowDeferredSuccess {
                pendingCallKitAnswerCallIDs.insert(callID)
                return true
            }
            return false
        }
    }

    private func removePeer(_ peerID: UUID) {
        enginesByPeerID[peerID]?.stop()
        enginesByPeerID.removeValue(forKey: peerID)
        remoteMuteStateByPeerID.removeValue(forKey: peerID)
        iceStateByPeerID.removeValue(forKey: peerID)
        pendingRemoteICEByPeerID.removeValue(forKey: peerID)
        offerSentPeerIDs.remove(peerID)
        answerSentPeerIDs.remove(peerID)
        remoteAnswerAppliedPeerIDs.remove(peerID)
    }

    private func resetLocalState(clearError: Bool) {
        let previousCallID = activeCall?.id
        monitoringTask?.cancel()
        monitoringTask = nil
        durationTask?.cancel()
        durationTask = nil

        for engine in enginesByPeerID.values {
            engine.stop()
        }

        enginesByPeerID.removeAll()
        participantsByID.removeAll()
        remoteMuteStateByPeerID.removeAll()
        iceStateByPeerID.removeAll()
        pendingRemoteICEByPeerID.removeAll()
        offerSentPeerIDs.removeAll()
        answerSentPeerIDs.removeAll()
        remoteAnswerAppliedPeerIDs.removeAll()
        pendingIncomingPushByCallID.removeAll()
        pendingCallKitAnswerCallIDs.removeAll()
        callKitAnswerInFlightCallIDs.removeAll()
        lastEventSequence = 0
        activeChatID = nil
        activeCall = nil
        remoteParticipantStates = []
        isPresentingCallUI = false
        duration = 0
        isConnecting = false
        if let previousCallID {
            releaseCallKitState(for: previousCallID, reportEnded: true)
        }

        if audioSessionIsActive {
            audioSessionIsActive = false
            Task {
                await audioSessionCoordinator.deactivate()
            }
        }

        if clearError {
            lastErrorMessage = ""
        }
    }

    private func install(call: InternetCall, roomTitle: String, resetEventCursor: Bool) {
        if let previousCallID = activeCall?.id, previousCallID != call.id {
            releaseCallKitState(for: previousCallID, reportEnded: true)
        }
        activeCall = call
        activeChatID = call.chatID
        self.roomTitle = roomTitle
        updateParticipantsDirectory(with: call)
        rebuildRemoteParticipantStates()
        if resetEventCursor {
            lastEventSequence = max(call.lastEventSequence - bootstrapEventHistoryWindow, 0)
        }
        syncCallKitState(for: call)
    }

    private func updateParticipantsDirectory(with call: InternetCall) {
        for participant in call.participants {
            participantsByID[participant.id] = participant
        }
    }

    private func seedParticipantsDirectory(from chat: Chat) {
        for participant in chat.participants {
            participantsByID[participant.id] = InternetCallParticipant(
                id: participant.id,
                username: participant.username,
                displayName: participant.displayName,
                profilePhotoURL: participant.photoURL
            )
        }

        for member in chat.group?.members ?? [] {
            let username = member.username ?? "member"
            let trimmedDisplayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedDisplayName.isEmpty ? username : trimmedDisplayName
            participantsByID[member.userID] = InternetCallParticipant(
                id: member.userID,
                username: username,
                displayName: displayName,
                profilePhotoURL: nil
            )
        }
    }

    private func rebuildRemoteParticipantStates() {
        guard let activeCall, let currentUserID else {
            remoteParticipantStates = []
            return
        }

        let joinedIDs = activeCall.joinedParticipantIDSet
        let participants = activeCall.participants.isEmpty
            ? participantsByID.values.sorted(by: { $0.username < $1.username })
            : activeCall.participants.sorted(by: { $0.username < $1.username })

        remoteParticipantStates = participants.compactMap { participant in
            guard participant.id != currentUserID else { return nil }
            return RemoteParticipantState(
                participant: participant,
                isJoined: joinedIDs.contains(participant.id),
                isMuted: remoteMuteStateByPeerID[participant.id] ?? false,
                connectionState: iceStateByPeerID[participant.id] ?? .new
            )
        }
    }

    private func shouldLocalInitiatePeerNegotiation(with peerID: UUID) -> Bool {
        guard let currentUserID else { return false }
        return currentUserID.uuidString.lowercased() < peerID.uuidString.lowercased()
    }

    private func startDurationLoop() {
        durationTask?.cancel()
        guard activeCall != nil else {
            duration = 0
            return
        }

        durationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                if let currentCall = self.activeCall {
                    let anchor = currentCall.answeredAt ?? currentCall.createdAt
                    self.duration = max(Date.now.timeIntervalSince(anchor), 0)
                } else {
                    self.duration = 0
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func syncCallKitState(for call: InternetCall) {
        guard let currentUserID else { return }
        let displayName = callKitDisplayName(
            primary: roomTitle,
            fallback: "Group Call"
        )
        let handleValue = callKitReadableHandleValue(
            primary: displayName,
            fallback: "Group Call"
        )
        let isIncomingTrackedCall =
            pendingIncomingPushByCallID[call.id] != nil
            && callKitCoordinator.isTracking(callID: call.id)

        switch call.state {
        case .ringing, .active:
            guard call.joinedParticipantIDSet.contains(currentUserID) else { return }
            if isIncomingTrackedCall {
                return
            }
            if callKitStartedCallIDs.contains(call.id) == false {
                callKitStartedCallIDs.insert(call.id)
                callKitCoordinator.reportOutgoingStarted(
                    callID: call.id,
                    handleValue: handleValue,
                    displayName: displayName
                )
            }
            if call.state == .active, callKitConnectedCallIDs.contains(call.id) == false {
                callKitConnectedCallIDs.insert(call.id)
                callKitCoordinator.reportOutgoingConnected(callID: call.id)
            }
        case .ended, .cancelled, .rejected, .missed:
            releaseCallKitState(for: call.id, reportEnded: true)
        }
    }

    private func releaseCallKitState(for callID: UUID, reportEnded: Bool) {
        if reportEnded {
            callKitCoordinator.reportEnded(callID: callID)
        }
        callKitStartedCallIDs.remove(callID)
        callKitConnectedCallIDs.remove(callID)
    }
}
