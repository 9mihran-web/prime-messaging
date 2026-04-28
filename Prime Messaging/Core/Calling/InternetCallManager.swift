import AVFoundation
import Combine
import Foundation
#if os(iOS) && canImport(AVKit)
import AVKit
#endif
#if canImport(WebRTC)
import WebRTC
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

@MainActor
final class InternetCallManager: ObservableObject {
    static let shared = InternetCallManager()

    enum CallDisplayState: String {
        case incoming
        case calling
        case ringing
        case connecting
        case active
        case ended
        case rejected
        case cancelled
        case missed
    }

    @Published private(set) var activeCall: InternetCall?
    @Published private(set) var isPresentingCallUI = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isRemoteMuted = false
    @Published private(set) var isSpeakerEnabled = false
    @Published private(set) var isVideoEnabled = false
    @Published private(set) var isUsingFrontCamera = true
    @Published private(set) var isRemoteVideoAvailable = false
    @Published private(set) var lastErrorMessage = ""

    private let audioSessionCoordinator = CallAudioSessionCoordinator()
    private let mediaEngine = WebRTCAudioCallEngine()
    private let callKitCoordinator = CallKitCoordinator()

    private var repository: (any CallRepository)? = BackendCallRepository(fallback: MockCallRepository())
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
    private var pendingLocalAnswerByCallID: [UUID: LocalAnswerPayload] = [:]
    private var terminalSnapshotByCallID: [UUID: TerminalCallSnapshot] = [:]
    private var pendingRemoteICEByCallID: [UUID: [WebRTCAudioCallEngine.ICECandidatePayload]] = [:]
    private var pendingLocalICEByCallID: [UUID: [WebRTCAudioCallEngine.ICECandidatePayload]] = [:]
    private var localICEFailureCountByCallID: [UUID: [String: Int]] = [:]
    private var localICERetryTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteAnswerAppliedCallIDs: Set<UUID> = []
    private var pendingPushCallIDs: Set<UUID> = []
    private var preferredIncomingUserIDByCallID: [UUID: UUID] = [:]
    private var pendingPushCallerNameByCallID: [UUID: String] = [:]
    private var recentIncomingPushQueuedAtByCallID: [UUID: Date] = [:]
    private var pendingPushResolutionTask: Task<Void, Never>?
    private var pendingCallKitAnswerCallIDs: Set<UUID> = []
    private var pendingCallKitAnswerResolutionTasks: [UUID: Task<Void, Never>] = [:]
    private var callKitAudioFallbackTasks: [UUID: Task<Void, Never>] = [:]
    private var incomingImmediateAnswerPendingCallIDs: Set<UUID> = []
    private var prewarmedIncomingCallIDs: Set<UUID> = []
    private var locallyOriginatedOutgoingCallIDs: Set<UUID> = []
    private var localOutgoingStartAtByCallID: [UUID: Date] = [:]
    private var incomingAnswerDispatchTasks: [UUID: Task<Void, Never>] = [:]
    private var offerDispatchInProgressCallIDs: Set<UUID> = []
    private var answerDispatchInProgressCallIDs: Set<UUID> = []
    private var callKitAnswerInFlightCallIDs: Set<UUID> = []
    private var localEndIntentCallIDs: Set<UUID> = []
    private var endRequestInFlightCallIDs: Set<UUID> = []
    private var callKitAudioBypassCallIDs: Set<UUID> = []
    private var answerRequestedAtByCallID: [UUID: Date] = [:]
    private var mediaStartInProgressCallID: UUID?
    private var isCallKitAudioSessionActive = false
    private var activeCallKitAudioSession: AVAudioSession?
    private var lastCriticalAudioRouteLossAt: Date?
    private var lastAudioRebindAt: Date?
    private var remoteVideoLastFrameAt: Date?
    private var remoteVideoWatchdogTask: Task<Void, Never>?
    private let remoteVideoFrameTimeout: TimeInterval = 2.0
    private let signalingAnswerSendTimeout: TimeInterval = 15.0
    private let callEventsFetchTimeout: TimeInterval = 10.0
    private let immediateOfferFetchTimeout: TimeInterval = 3.0
    private let immediateOfferWaitAttempts = 12
    private let immediateOfferWaitDelayMs: UInt64 = 120
    private let routeLossEndIgnoreWindow: TimeInterval = 1.5
    private let callKitEarlyIncomingEndIgnoreWindow: TimeInterval = 2.5
    private let minAudioRebindInterval: TimeInterval = 0.8
    private let callKitAudioFallbackMaxAttempts = 48
    private let callKitAudioFallbackAttemptDelayMs: UInt64 = 180
    private let callKitAudioFallbackWaitAttemptsBeforeSalvage = 2
    private let callKitAudioFallbackSalvageEveryAttempts = 3
    private let callKitAudioFallbackBypassAfterAttempt = 6
    private let callContextResolvePerUserTimeout: TimeInterval = 1.35
    private let callEventsFastPollingIntervalMs: UInt64 = 120
    private let callEventsNormalPollingIntervalMs: UInt64 = 350
    private let localICERetryBaseDelayMs: UInt64 = 160
    private let localICERetryMaxDelayMs: UInt64 = 1200
    private let localICEMaxRetryAttempts = 48
    private let localICEMaxBufferedCandidates = 256
    private let localICEPerCandidateMaxFailures = 3
    private let localICEHostCandidateLimit = 8
    private let localICEAllowTCPHostCandidates = false
    private let terminalSnapshotRetentionWindow: TimeInterval = 180
    private let incomingPushDuplicateSuppressWindow: TimeInterval = 3.5
    private let iceConfigFastFetchTimeout: TimeInterval = 0.85
    private let iceConfigCacheTTL: TimeInterval = 300
    private let videoDegradeTimeout: TimeInterval = 3.5
    private var videoDegradeTask: Task<Void, Never>?
    private var currentVideoQualityProfile: WebRTCAudioCallEngine.VideoQualityProfile = .high
    private var lastObservedICEConnectionState: WebRTCAudioCallEngine.ICEConnectionState = .new
    private var callMetricsByID: [UUID: CallRuntimeMetrics] = [:]
    private var cachedIceServers: [WebRTCAudioCallEngine.ICEServer] = []
    private var cachedIceServersFetchedAt: Date?
    private var iceConfigWarmupTask: Task<Void, Never>?
    private var reachabilityObserver: NSObjectProtocol?
    #if os(iOS) && canImport(UIKit)
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    #endif
    #if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
    private lazy var pictureInPictureCoordinator: CallPictureInPictureCoordinator = {
        let coordinator = CallPictureInPictureCoordinator(
            attachLocalRenderer: { [weak self] renderer in
                self?.mediaEngine.bindLocalVideoRenderer(renderer)
            },
            detachLocalRenderer: { [weak self] renderer in
                self?.mediaEngine.unbindLocalVideoRenderer(renderer)
            },
            attachRemoteRenderer: { [weak self] renderer in
                self?.mediaEngine.bindRemoteVideoRenderer(renderer)
            },
            detachRemoteRenderer: { [weak self] renderer in
                self?.mediaEngine.unbindRemoteVideoRenderer(renderer)
            },
            onRestoreUIRequested: { [weak self] in
                self?.presentCallUI()
            }
        )
        coordinator.onLog = { [weak self] message in
            self?.callDebugLog(message)
        }
        return coordinator
    }()
    #endif
    #if !os(tvOS)
    private var audioRouteChangeObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioMediaServicesResetObserver: NSObjectProtocol?
    #endif

    private init() {
        mediaEngine.onLocalICECandidate = { [weak self] payload in
            Task { @MainActor [weak self] in
                await self?.sendLocalICECandidate(payload)
            }
        }
        mediaEngine.onStateLog = { [weak self] state in
            self?.callDebugLog("webrtc.\(state)")
        }
        mediaEngine.onRemoteVideoAvailabilityChanged = { [weak self] isAvailable in
            guard let self else { return }
            self.isRemoteVideoAvailable = isAvailable
            if isAvailable {
                self.remoteVideoLastFrameAt = Date.now
                self.ensureRemoteVideoWatchdogRunning()
            } else {
                self.remoteVideoLastFrameAt = nil
            }
            self.updatePictureInPictureState(reason: "remote_video_availability_changed")
        }
        mediaEngine.onICEConnectionStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleICEConnectionStateChange(state)
            }
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
            guard let self else { return false }
            if self.callKitAnswerInFlightCallIDs.contains(callID) {
                self.callDebugLog("callkit.answer.skip_duplicate_inflight call=\(callID.uuidString)")
                return true
            }
            if self.sentAnswerCallIDs.contains(callID) {
                self.callDebugLog("callkit.answer.skip_already_answered call=\(callID.uuidString)")
                return true
            }
            if let activeCall = self.activeCall, activeCall.id == callID, activeCall.state == .active {
                self.callDebugLog("callkit.answer.skip_already_active call=\(callID.uuidString)")
                return true
            }
            self.callDebugLog("callkit.answer.action.received call=\(callID.uuidString)")
            self.callKitAnswerInFlightCallIDs.insert(callID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.callKitAnswerInFlightCallIDs.remove(callID)
                }
                let didStart = await self.answerCall(callID: callID, allowDeferredSuccess: true)
                self.callDebugLog("callkit.answer.action.result call=\(callID.uuidString) success=\(didStart)")
            }
            // Let CallKit fulfill answer quickly; signaling continues asynchronously.
            return true
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
            Task { @MainActor [weak self] in
                await self?.sendLocalMediaStateIfNeeded(reason: "callkit_set_muted")
            }
        }
        callKitCoordinator.onAudioSessionActivated = { [weak self] audioSession in
            self?.isCallKitAudioSessionActive = true
            self?.activeCallKitAudioSession = audioSession
            if let activeCallID = self?.activeCall?.id {
                self?.callKitAudioBypassCallIDs.remove(activeCallID)
            }
            self?.callDebugLog("callkit.audio.activated")
            self?.mediaEngine.notifyAudioSessionActivated(using: audioSession)
            if let activeCallID = self?.activeCall?.id {
                self?.cancelCallKitAudioFallback(for: activeCallID, reason: "callkit_didActivate")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let hasMicPermission = try await self.audioSessionCoordinator.configureActivatedCallKitSession(
                        audioSession,
                        speakerEnabled: self.isSpeakerEnabled
                    )
                    if hasMicPermission == false {
                        #if !os(tvOS)
                        self.callDebugLog(
                            "audio.callkit.microphone_unavailable status=\(await self.audioSessionCoordinator.microphonePermissionStatusDescription())"
                        )
                        #else
                        self.callDebugLog("audio.callkit.microphone_unavailable")
                        #endif
                    }
                    #if !os(tvOS)
                    self.callDebugLog("audio.route.activated \(await self.audioSessionCoordinator.currentAudioRouteDescription())")
                    self.callDebugLog("audio.session.snapshot \(await self.audioSessionCoordinator.audioSessionSnapshotDescription())")
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

                guard let activeCall = self.activeCall, activeCall.state == .active else {
                    return
                }

                self.rebindMediaAudioSession(reason: "callkit_didActivate")

                guard let activeCall = self.activeCall, activeCall.state == .active else {
                    return
                }
                if self.isAppActiveForCallAudioDebug() {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard let self,
                              let activeCall = self.activeCall,
                              activeCall.state == .active else {
                            return
                        }
                        self.mediaEngine.notifyAudioSessionActivated(using: audioSession)
                        self.mediaEngine.setMuted(self.isMuted)
                        self.callDebugLog("audio.callkit.app_active.rebind call=\(activeCall.id.uuidString)")
                    }
                }

                if let currentUserID = self.currentUserID,
                   let repository = self.repository,
                   activeCall.direction(for: currentUserID) == .incoming,
                   self.sentAnswerCallIDs.contains(activeCall.id) == false {
                    _ = await self.attemptImmediateAnswerDispatchIfPossible(
                        call: activeCall,
                        actingUserID: currentUserID,
                        repository: repository,
                        source: "callkit_didActivate"
                    )
                }
            }
        }
        callKitCoordinator.onAudioSessionDeactivated = { [weak self] audioSession in
            self?.isCallKitAudioSessionActive = false
            self?.activeCallKitAudioSession = nil
            self?.callDebugLog("callkit.audio.deactivated")
            if let activeCall = self?.activeCall, activeCall.state == .active {
                self?.callDebugLog("callkit.audio.deactivated.defer_for_active_call call=\(activeCall.id.uuidString)")
                self?.scheduleCallKitAudioFallbackIfNeeded(for: activeCall, reason: "callkit_deactivated")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.activateAudioIfNeeded()
                    self.rebindMediaAudioSession(reason: "callkit_deactivated_active")
                }
                return
            }
            self?.mediaEngine.notifyAudioSessionDeactivated(using: audioSession)
        }
        #if os(iOS) && canImport(UIKit)
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleApplicationDidBecomeActive()
            }
        }
        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleApplicationWillResignActive()
            }
        }
        willEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleApplicationWillEnterForeground()
            }
        }
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleApplicationDidEnterBackground()
            }
        }
        #endif
        #if !os(tvOS)
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioRouteChange(notification)
            }
        }
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioInterruption(notification)
            }
        }
        audioMediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioMediaServicesReset()
            }
        }
        #endif
        reachabilityObserver = NotificationCenter.default.addObserver(
            forName: .primeMessagingReachabilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            let snapshot = (notification.userInfo?["snapshot"] as? NetworkConnectionSnapshot)
                ?? NetworkReachabilityMonitor.shared.currentSnapshot
            Task { @MainActor [weak self] in
                self?.handleReachabilitySnapshot(snapshot)
            }
        }
        applyVideoQualityProfile(
            NetworkReachabilityMonitor.shared.currentSnapshot,
            reason: "bootstrap"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentUserID == nil else { return }
            if let resolvedUserID = await self.resolvedCurrentUserIDForBootstrap() {
                self.currentUserID = resolvedUserID
                self.callDebugLog(
                    "call.context.bootstrap user=\(resolvedUserID.uuidString) source=bootstrap_resolver"
                )
            }
        }
    }

    func displayState(for call: InternetCall, viewerUserID: UUID) -> CallDisplayState {
        switch call.state {
        case .ringing:
            if call.direction(for: viewerUserID) == .incoming {
                if answerRequestedAtByCallID[call.id] != nil {
                    return .connecting
                }
                return .incoming
            }
            return sentOfferCallIDs.contains(call.id) ? .ringing : .calling
        case .active:
            let activeStartDate = call.answeredAt ?? call.createdAt
            let elapsed = Date.now.timeIntervalSince(activeStartDate)
            if elapsed < 1.2 {
                return .connecting
            }
            if isMediaConnected(for: call.id) {
                return .active
            }
            return .connecting
        case .ended:
            return .ended
        case .rejected:
            return .rejected
        case .cancelled:
            return .cancelled
        case .missed:
            return .missed
        }
    }

    func shouldShowDuration(for call: InternetCall, viewerUserID: UUID) -> Bool {
        let state = displayState(for: call, viewerUserID: viewerUserID)
        switch state {
        case .connecting, .active:
            return true
        case .ended, .cancelled, .rejected, .missed:
            return call.answeredAt != nil
        case .incoming, .calling, .ringing:
            return false
        }
    }

    private func isMediaConnected(for callID: UUID) -> Bool {
        guard activeCall?.id == callID else { return false }
        return lastObservedICEConnectionState == .connected || lastObservedICEConnectionState == .completed
    }

    deinit {
        #if os(iOS) && canImport(UIKit)
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let willResignActiveObserver {
            NotificationCenter.default.removeObserver(willResignActiveObserver)
        }
        if let willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
        if let didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
        }
        #endif
        #if !os(tvOS)
        if let audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(audioRouteChangeObserver)
        }
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
        if let audioMediaServicesResetObserver {
            NotificationCenter.default.removeObserver(audioMediaServicesResetObserver)
        }
        #endif
        if let reachabilityObserver {
            NotificationCenter.default.removeObserver(reachabilityObserver)
        }
    }

    func configure(currentUserID: UUID, repository: any CallRepository) {
        let userDidChange = self.currentUserID != currentUserID
        self.currentUserID = currentUserID
        self.repository = repository

        if userDidChange {
            cachedIceServers.removeAll()
            cachedIceServersFetchedAt = nil
            iceConfigWarmupTask?.cancel()
            iceConfigWarmupTask = nil
        }

        if userDidChange || monitoringTask == nil {
            startMonitoring()
        }

        Task { [weak self] in
            await self?.primeIceServersCacheIfNeeded(reason: userDidChange ? "configure_user_changed" : "configure")
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
        preferredIncomingUserIDByCallID.removeAll()
        pendingPushCallerNameByCallID.removeAll()
        recentIncomingPushQueuedAtByCallID.removeAll()
        pendingPushResolutionTask?.cancel()
        pendingPushResolutionTask = nil
        iceConfigWarmupTask?.cancel()
        iceConfigWarmupTask = nil
        pendingCallKitAnswerCallIDs.removeAll()
        for task in pendingCallKitAnswerResolutionTasks.values {
            task.cancel()
        }
        pendingCallKitAnswerResolutionTasks.removeAll()
        remoteAnswerAppliedCallIDs.removeAll()
        prewarmedIncomingCallIDs.removeAll()
        locallyOriginatedOutgoingCallIDs.removeAll()
        localOutgoingStartAtByCallID.removeAll()
        offerDispatchInProgressCallIDs.removeAll()
        answerDispatchInProgressCallIDs.removeAll()
        callKitAnswerInFlightCallIDs.removeAll()
        localEndIntentCallIDs.removeAll()
        callKitAudioBypassCallIDs.removeAll()
        answerRequestedAtByCallID.removeAll()
        mediaStartInProgressCallID = nil
        isCallKitAudioSessionActive = false
        activeCallKitAudioSession = nil
        remoteVideoWatchdogTask?.cancel()
        remoteVideoWatchdogTask = nil
        remoteVideoLastFrameAt = nil
        cancelVideoDegradeTask(reason: "stop_monitoring")
        lastObservedICEConnectionState = .new
        callMetricsByID.removeAll()
        stopPictureInPicture(reason: "stop_monitoring")

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
        isUsingFrontCamera = true
        isRemoteVideoAvailable = false
        isRemoteMuted = false
        lastErrorMessage = ""

        Task {
            await audioSessionCoordinator.deactivate()
        }
        updateProximityMonitoringEnabled(false)
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
        guard let currentUserID, let activeCall else {
            throw CallRepositoryError.callNotFound
        }

        clearError()
        if sentAnswerCallIDs.contains(activeCall.id) {
            callDebugLog("answer.ui.skip_already_answered call=\(activeCall.id.uuidString)")
            return
        }
        if callKitAnswerInFlightCallIDs.contains(activeCall.id) {
            callDebugLog("answer.ui.skip_callkit_inflight call=\(activeCall.id.uuidString)")
            return
        }
        if activeCall.state == .active, activeCall.direction(for: currentUserID) == .incoming {
            callDebugLog("answer.ui.skip_already_active call=\(activeCall.id.uuidString)")
            return
        }
        if activeCall.direction(for: currentUserID) == .incoming,
           answerRequestedAtByCallID[activeCall.id] != nil {
            callDebugLog("answer.ui.skip_pending_request call=\(activeCall.id.uuidString)")
            return
        }

        if activeCall.direction(for: currentUserID) == .incoming {
            if answerRequestedAtByCallID[activeCall.id] == nil {
                answerRequestedAtByCallID[activeCall.id] = Date.now
            }
            let delegatedToCallKit = await callKitCoordinator.requestAnswer(callID: activeCall.id)
            if delegatedToCallKit {
                callDebugLog("answer.ui.delegated_to_callkit call=\(activeCall.id.uuidString)")
                callDebugLog("Answer UI Delegated to CallKit call=\(activeCall.id.uuidString)")
                return
            }
            callDebugLog("answer.ui.callkit_delegate_failed_fallback call=\(activeCall.id.uuidString)")
        }

        let didStart = await answerCall(callID: activeCall.id, allowDeferredSuccess: false)
        if didStart == false {
            throw CallRepositoryError.backendUnavailable
        }
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
        let direction = activeCall.direction(for: currentUserID)
        callDebugLog(
            "end_active.request call=\(activeCall.id.uuidString) state=\(activeCall.state.rawValue) direction=\(direction.rawValue) source=api_or_ui"
        )
        if activeCall.state == .ringing, direction == .incoming {
            // Incoming ringing is declined via explicit reject flow (UI reject button or CallKit end action).
            // Ignore generic endActiveCall to avoid accidental auto-decline paths.
            callDebugLog("end_active.ignored call=\(activeCall.id.uuidString) reason=incoming_ringing_requires_reject")
            return
        }

        localEndIntentCallIDs.insert(activeCall.id)
        let updatedCall = try await repository.endCall(activeCall.id, userID: currentUserID)
        await install(updatedCall)
    }

    func endCall(source: String = "public_api") {
        if let activeCall, let currentUserID {
            let direction = activeCall.direction(for: currentUserID)
            callDebugLog(
                "end_call.requested call=\(activeCall.id.uuidString) state=\(activeCall.state.rawValue) direction=\(direction.rawValue) source=\(source)"
            )
            if endRequestInFlightCallIDs.contains(activeCall.id) {
                callDebugLog("end_call.skip_inflight call=\(activeCall.id.uuidString) source=\(source)")
                return
            }
            endRequestInFlightCallIDs.insert(activeCall.id)
            let requestedCallID = activeCall.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.endRequestInFlightCallIDs.remove(requestedCallID)
                }
                do {
                    try await self.endActiveCall()
                } catch {
                    self.callDebugLog(
                        "end_call.failed call=\(requestedCallID.uuidString) source=\(source) error=\(error)"
                    )
                }
            }
        } else {
            callDebugLog("end_call.requested source=\(source) reason=no_active_call")
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
        Task { @MainActor [weak self] in
            await self?.sendLocalMediaStateIfNeeded(reason: "toggle_mute")
        }
    }

    func toggleSpeaker() {
        isSpeakerEnabled.toggle()
        Task {
            try? await audioSessionCoordinator.setSpeakerEnabled(isSpeakerEnabled)
        }
        if activeCall?.state == .active {
            updateProximityMonitoringEnabled(!isSpeakerEnabled)
        }
    }

    func toggleVideo() {
        Task { @MainActor in
            let targetEnabled = !isVideoEnabled
            if targetEnabled {
                cancelVideoDegradeTask(reason: "video_manual_enable")
            } else {
                cancelVideoDegradeTask(reason: "video_manual_disable")
            }

            if let activeCall {
                ensureCallMetrics(for: activeCall.id)
                var metrics = callMetricsByID[activeCall.id]
                metrics?.videoToggleRequestedAt = Date.now
                callMetricsByID[activeCall.id] = metrics
            }

            if targetEnabled {
                #if !os(tvOS)
                let canPromptCamera = isAppActiveForCallAudioDebug()
                let cameraGranted = await audioSessionCoordinator.ensureCameraPermissionGranted(
                    canPrompt: canPromptCamera
                )
                guard cameraGranted else {
                    callDebugLog(
                        "video.enable.blocked permission=\(await audioSessionCoordinator.cameraPermissionStatusDescription()) canPrompt=\(canPromptCamera)"
                    )
                    return
                }
                #endif
            }

            guard let activeCall, activeCall.state == .active else {
                isVideoEnabled = targetEnabled
                callDebugLog("video.state.queued enabled=\(isVideoEnabled)")
                updatePictureInPictureState(reason: "video_toggle_queued")
                return
            }

            do {
                try await ensureMediaSession(for: activeCall)
                try await mediaEngine.setVideoEnabled(targetEnabled)
                isVideoEnabled = targetEnabled
                isUsingFrontCamera = mediaEngine.isUsingFrontCamera
                if var metrics = callMetricsByID[activeCall.id],
                   let requestedAt = metrics.videoToggleRequestedAt {
                    let latency = Date.now.timeIntervalSince(requestedAt)
                    metrics.lastVideoToggleLatency = latency
                    metrics.videoToggleRequestedAt = nil
                    callMetricsByID[activeCall.id] = metrics
                    callDebugLog(
                        "video.toggle.latency call=\(activeCall.id.uuidString) enabled=\(targetEnabled) seconds=\(String(format: "%.3f", latency))"
                    )
                }
                callDebugLog("video.state.applied call=\(activeCall.id.uuidString) enabled=\(isVideoEnabled)")
                updatePictureInPictureState(reason: "video_toggle_applied")
                await sendLocalMediaStateIfNeeded(reason: "toggle_video_applied")
            } catch {
                if var metrics = callMetricsByID[activeCall.id] {
                    metrics.videoToggleRequestedAt = nil
                    callMetricsByID[activeCall.id] = metrics
                }
                callDebugLog("video.state.apply_failed call=\(activeCall.id.uuidString) target=\(targetEnabled) error=\(error)")
                updatePictureInPictureState(reason: "video_toggle_failed")
            }
        }
    }

    func switchCamera() {
        Task { @MainActor in
            guard let activeCall, activeCall.state == .active else {
                callDebugLog("video.camera.switch.skip reason:no_active_call")
                return
            }
            guard isVideoEnabled else {
                callDebugLog("video.camera.switch.skip reason:video_disabled")
                return
            }

            do {
                try await ensureMediaSession(for: activeCall)
                let switched = await mediaEngine.switchCamera()
                guard switched else {
                    callDebugLog("video.camera.switch.failed call=\(activeCall.id.uuidString)")
                    return
                }
                isUsingFrontCamera = mediaEngine.isUsingFrontCamera
                callDebugLog(
                    "video.camera.switch.applied call=\(activeCall.id.uuidString) facing=\(isUsingFrontCamera ? "front" : "back")"
                )
            } catch {
                callDebugLog("video.camera.switch.error call=\(activeCall.id.uuidString) error=\(error)")
            }
        }
    }

    func noteRemoteVideoFrameRendered() {
        remoteVideoLastFrameAt = Date.now
        if let callID = activeCall?.id, var metrics = callMetricsByID[callID] {
            if metrics.firstRemoteVideoFrameAt == nil {
                metrics.firstRemoteVideoFrameAt = .now
                if let mediaStartedAt = metrics.mediaStartedAt {
                    let latency = Date.now.timeIntervalSince(mediaStartedAt)
                    callDebugLog(
                        "video.remote.first_frame.latency call=\(callID.uuidString) seconds=\(String(format: "%.3f", latency))"
                    )
                }
            }
            callMetricsByID[callID] = metrics
        }
        if isRemoteVideoAvailable == false {
            isRemoteVideoAvailable = true
            updatePictureInPictureState(reason: "remote_video_first_frame")
        }
        ensureRemoteVideoWatchdogRunning()
    }

#if canImport(WebRTC)
    func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        mediaEngine.bindLocalVideoRenderer(renderer)
    }

    func detachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        mediaEngine.unbindLocalVideoRenderer(renderer)
    }

    func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        mediaEngine.bindRemoteVideoRenderer(renderer)
    }

    func detachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        mediaEngine.unbindRemoteVideoRenderer(renderer)
    }
#endif

    func queueIncomingCallFromPush(
        callID: UUID,
        callerName: String? = nil,
        preferredUserID: UUID? = nil,
        prewarmCallKit: Bool = true
    ) {
        if let activeCall, activeCall.id == callID, (activeCall.state == .ringing || activeCall.state == .active) {
            callDebugLog("push.call.queue.skip_active call=\(callID.uuidString) state=\(activeCall.state.rawValue)")
            if prewarmCallKit, callKitCoordinator.isTracking(callID: callID) == false {
                let displayName = callKitDisplayName(primary: callerName, fallback: "Prime Messaging")
                let handleValue = callKitHandleValue(
                    forRemoteUserID: nil,
                    callID: callID,
                    displayName: displayName
                )
                prewarmedIncomingCallIDs.insert(callID)
                callKitCoordinator.reportIncoming(callID: callID, handleValue: handleValue, displayName: displayName)
                callDebugLog("push.call.prewarm.recover call=\(callID.uuidString) handle=\(displayName)")
            }
            return
        }

        let now = Date.now
        if let lastQueuedAt = recentIncomingPushQueuedAtByCallID[callID],
           now.timeIntervalSince(lastQueuedAt) < incomingPushDuplicateSuppressWindow {
            callDebugLog(
                "push.call.queue.skip_duplicate_window call=\(callID.uuidString) delta=\(String(format: "%.3f", now.timeIntervalSince(lastQueuedAt)))"
            )
            return
        }
        recentIncomingPushQueuedAtByCallID[callID] = now
        recentIncomingPushQueuedAtByCallID = recentIncomingPushQueuedAtByCallID.filter {
            now.timeIntervalSince($0.value) < 60
        }

        pendingPushCallIDs.insert(callID)
        if let preferredUserID {
            preferredIncomingUserIDByCallID[callID] = preferredUserID
        }
        let resolvedHandle = callKitDisplayName(primary: callerName, fallback: "Prime Messaging")
        pendingPushCallerNameByCallID[callID] = resolvedHandle
        let handleValue = callKitHandleValue(
            forRemoteUserID: nil,
            callID: callID,
            displayName: resolvedHandle
        )
        if prewarmCallKit {
            let trackedByCallKit = callKitCoordinator.isTracking(callID: callID)
            if prewarmedIncomingCallIDs.contains(callID), trackedByCallKit == false {
                prewarmedIncomingCallIDs.remove(callID)
                callDebugLog("push.call.prewarm.reset_stale call=\(callID.uuidString)")
            }
            if prewarmedIncomingCallIDs.contains(callID) == false {
                prewarmedIncomingCallIDs.insert(callID)
                callKitCoordinator.reportIncoming(callID: callID, handleValue: handleValue, displayName: resolvedHandle)
                callDebugLog("push.call.prewarm callkit call=\(callID.uuidString) handle=\(resolvedHandle)")
            } else {
                callDebugLog("push.call.prewarm.skip_duplicate call=\(callID.uuidString) tracked=\(trackedByCallKit)")
            }
        }
        Task { [weak self] in
            await self?.processPendingPushCallsIfNeeded()
        }
        schedulePendingPushResolutionLoopIfNeeded()
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshActiveCalls()
                await self.processPendingPushCallsIfNeeded()
                await self.processPendingCallKitAnswersIfNeeded()
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
                if shouldReinstallCall(preferredCall, replacing: activeCall) {
                    await install(preferredCall)
                } else {
                    refreshActiveCallSnapshotWithoutReinstall(preferredCall)
                }
            } else if let activeCall {
                do {
                    let latestCall = try await repository.fetchCall(activeCall.id, for: currentUserID)
                    if shouldReinstallCall(latestCall, replacing: self.activeCall) {
                        await install(latestCall)
                    } else {
                        refreshActiveCallSnapshotWithoutReinstall(latestCall)
                    }
                } catch {
                    callDebugLog("call.refresh.snapshot.failed call=\(activeCall.id.uuidString) error=\(error)")
                    if case CallRepositoryError.callNotFound = error {
                        await clearCallState()
                    }
                }
            } else {
                // Keep idle monitoring side-effect free.
            }
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? "calls.unavailable.start".localized
        }
    }

    private func shouldReinstallCall(_ latest: InternetCall, replacing current: InternetCall?) -> Bool {
        guard let current else { return true }
        guard current.id == latest.id else { return true }

        if current.state != latest.state { return true }
        if current.mode != latest.mode || current.kind != latest.kind { return true }
        if current.chatID != latest.chatID || current.callerID != latest.callerID || current.calleeID != latest.calleeID {
            return true
        }
        if current.participants != latest.participants { return true }
        if current.answeredAt != latest.answeredAt || current.endedAt != latest.endedAt { return true }
        if current.latestRemoteOfferSequence != latest.latestRemoteOfferSequence { return true }
        if current.latestRemoteOfferSDP != latest.latestRemoteOfferSDP { return true }

        // Avoid reinstall churn from lastEventSequence-only changes.
        return false
    }

    private func refreshActiveCallSnapshotWithoutReinstall(_ latest: InternetCall) {
        guard activeCall?.id == latest.id else { return }
        if shouldIgnoreNonTerminalSnapshot(latest, source: "refresh_snapshot_without_reinstall") {
            return
        }
        activeCall = latest
        duration = resolvedDuration(for: latest)
    }

    private func applyCallSnapshotImmediately(_ call: InternetCall) {
        if shouldIgnoreNonTerminalSnapshot(call, source: "apply_snapshot_immediately") {
            return
        }
        activeCall = call
        isPresentingCallUI = true
        duration = resolvedDuration(for: call)
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

    private func isTerminalState(_ state: InternetCallState) -> Bool {
        switch state {
        case .ended, .cancelled, .rejected, .missed:
            return true
        case .ringing, .active:
            return false
        }
    }

    private func pruneTerminalSnapshotsIfNeeded() {
        guard terminalSnapshotByCallID.isEmpty == false else { return }
        let now = Date.now
        terminalSnapshotByCallID = terminalSnapshotByCallID.filter { _, snapshot in
            now.timeIntervalSince(snapshot.recordedAt) <= terminalSnapshotRetentionWindow
        }
    }

    private func recordTerminalSnapshot(_ call: InternetCall) {
        guard isTerminalState(call.state) else { return }
        pruneTerminalSnapshotsIfNeeded()
        if let existing = terminalSnapshotByCallID[call.id],
           existing.lastEventSequence >= call.lastEventSequence {
            terminalSnapshotByCallID[call.id] = TerminalCallSnapshot(
                state: existing.state,
                lastEventSequence: existing.lastEventSequence,
                recordedAt: .now
            )
            return
        }
        terminalSnapshotByCallID[call.id] = TerminalCallSnapshot(
            state: call.state,
            lastEventSequence: call.lastEventSequence,
            recordedAt: .now
        )
    }

    private func shouldIgnoreNonTerminalSnapshot(_ call: InternetCall, source: String) -> Bool {
        guard isTerminalState(call.state) == false else { return false }
        pruneTerminalSnapshotsIfNeeded()
        guard let terminal = terminalSnapshotByCallID[call.id] else { return false }
        if call.lastEventSequence <= terminal.lastEventSequence {
            callDebugLog(
                "call.snapshot.ignore_after_terminal call=\(call.id.uuidString) source=\(source) state=\(call.state.rawValue) seq=\(call.lastEventSequence) terminal_state=\(terminal.state.rawValue) terminal_seq=\(terminal.lastEventSequence)"
            )
            return true
        }
        terminalSnapshotByCallID.removeValue(forKey: call.id)
        callDebugLog(
            "call.snapshot.unseal_after_newer_seq call=\(call.id.uuidString) source=\(source) state=\(call.state.rawValue) seq=\(call.lastEventSequence) terminal_seq=\(terminal.lastEventSequence)"
        )
        return false
    }

    private func install(_ call: InternetCall) async {
        if shouldIgnoreNonTerminalSnapshot(call, source: "install") {
            return
        }
        let previousCall = activeCall
        let previousCallID = activeCall?.id
        dismissTask?.cancel()
        activeCall = call
        if call.state == .ringing || call.state == .active {
            ensureCallMetrics(for: call.id)
        }
        if previousCallID != call.id {
            isRemoteVideoAvailable = false
            remoteVideoLastFrameAt = nil
            isRemoteMuted = false
        }
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
            scheduleLocalICERetryLoopIfNeeded(for: call.id)
            clearCallNotifications(callID: call.id)
            updateProximityMonitoringEnabled(!isSpeakerEnabled)
            if let currentUserID,
               call.direction(for: currentUserID) == .incoming,
               incomingImmediateAnswerPendingCallIDs.contains(call.id) {
                callDebugLog("call.install.defer_heavy_answer_work call=\(call.id.uuidString)")
                startDurationUpdates(startDate: call.answeredAt ?? call.createdAt)
                updatePictureInPictureState(reason: "call_install_active_deferred_answer")
                return
            }
            do {
                try await ensureMediaSession(for: call)
                let shouldRefreshAudioPath =
                    previousCall?.id != call.id
                    || previousCall?.state != call.state
                    || mediaCallID != call.id
                    || isCallKitAudioSessionActive == false
                if shouldRefreshAudioPath {
                    await activateAudioIfNeeded()
                } else {
                    #if !os(tvOS)
                    if AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty {
                        callDebugLog("audio.activate.force_no_input call=\(call.id.uuidString) state=\(call.state.rawValue)")
                        await activateAudioIfNeeded()
                    } else {
                        callDebugLog("audio.activate.skip_redundant call=\(call.id.uuidString) state=\(call.state.rawValue)")
                    }
                    #else
                    callDebugLog("audio.activate.skip_redundant call=\(call.id.uuidString) state=\(call.state.rawValue)")
                    #endif
                }
                rebindMediaAudioSession(reason: "call_install_active")
                if let currentUserID {
                    let direction = call.direction(for: currentUserID)
                    if direction == .incoming {
                        scheduleCallKitAudioFallbackIfNeeded(for: call, reason: "call_install_active_incoming")
                    } else {
                        cancelCallKitAudioFallback(for: call.id, reason: "call_install_active_outgoing")
                    }
                    if direction == .incoming {
                        if incomingImmediateAnswerPendingCallIDs.contains(call.id) {
                            callDebugLog(
                                "answer.install.defer_background_dispatch call=\(call.id.uuidString) reason=immediate_answer_pending"
                            )
                        } else {
                            // Keep incoming answer generation in one place (answer.dispatch.loop),
                            // otherwise parallel offer application can reset peer state.
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                await self.recoverIncomingOfferIfNeeded(for: call)
                            }
                            try await flushPendingSignals(for: call.id, includeOffer: false)
                            startIncomingAnswerDispatchLoopIfNeeded(for: call)
                        }
                    } else {
                        await sendOfferIfNeeded(for: call, currentUserID: currentUserID, reason: "active_recovery")
                        try await flushPendingSignals(for: call.id, includeOffer: true)
                    }
                    if direction == .incoming, incomingImmediateAnswerPendingCallIDs.contains(call.id) {
                        Task { @MainActor [weak self] in
                            await self?.sendLocalMediaStateIfNeeded(reason: "call_install_active_deferred")
                        }
                    } else {
                        await sendLocalMediaStateIfNeeded(reason: "call_install_active")
                    }
                } else {
                    try await flushPendingSignals(for: call.id, includeOffer: false)
                }
            } catch {
                callDebugLog("media.start.failed: \(error)")
            }
            startDurationUpdates(startDate: call.answeredAt ?? call.createdAt)
            updatePictureInPictureState(reason: "call_install_active")
        case .ringing:
            startEventMonitoring(for: call)
            scheduleLocalICERetryLoopIfNeeded(for: call.id)
            cancelCallKitAudioFallback(for: call.id, reason: "call_install_ringing")
            durationTask?.cancel()
            durationTask = nil
            isRemoteVideoAvailable = false
            remoteVideoLastFrameAt = nil
            isRemoteMuted = false
            updateProximityMonitoringEnabled(false)
            if let currentUserID, call.direction(for: currentUserID) == .outgoing {
                do {
                    try await ensureMediaSession(for: call)
                    await sendOfferIfNeeded(for: call, currentUserID: currentUserID, reason: "ringing")
                    try await flushPendingSignals(for: call.id)
                } catch {
                    callDebugLog("outgoing.offer.failed: \(error)")
                }
            } else if let currentUserID, call.direction(for: currentUserID) == .incoming {
                do {
                    try await ensureMediaSession(for: call)
                    callDebugLog("media.prewarm.incoming.success call=\(call.id.uuidString) source=install_ringing")
                } catch {
                    callDebugLog("media.prewarm.incoming.failed call=\(call.id.uuidString) source=install_ringing error=\(error)")
                }
            }
            stopPictureInPicture(reason: "call_install_ringing")
        case .ended, .cancelled, .rejected, .missed:
            recordTerminalSnapshot(call)
            finalizeCallMetrics(for: call)
            localEndIntentCallIDs.remove(call.id)
            cancelCallKitAudioFallback(for: call.id, reason: "call_install_terminal")
            prewarmedIncomingCallIDs.remove(call.id)
            pendingPushCallIDs.remove(call.id)
            preferredIncomingUserIDByCallID.removeValue(forKey: call.id)
            pendingPushCallerNameByCallID.removeValue(forKey: call.id)
            recentIncomingPushQueuedAtByCallID.removeValue(forKey: call.id)
            locallyOriginatedOutgoingCallIDs.remove(call.id)
            localOutgoingStartAtByCallID.removeValue(forKey: call.id)
            isVideoEnabled = false
            isUsingFrontCamera = true
            isRemoteVideoAvailable = false
            isRemoteMuted = false
            clearCallNotifications(callID: call.id)
            updateProximityMonitoringEnabled(false)
            durationTask?.cancel()
            durationTask = nil
            stopEventMonitoring()
            stopMediaSession()
            clearSignalBacklog(for: call.id)
            stopIncomingAnswerDispatchLoop(for: call.id)
            offerDispatchInProgressCallIDs.remove(call.id)
            answerDispatchInProgressCallIDs.remove(call.id)
            callKitAnswerInFlightCallIDs.remove(call.id)
            answerRequestedAtByCallID.removeValue(forKey: call.id)
            incomingImmediateAnswerPendingCallIDs.remove(call.id)
            pendingCallKitAnswerCallIDs.remove(call.id)
            pendingCallKitAnswerResolutionTasks[call.id]?.cancel()
            pendingCallKitAnswerResolutionTasks.removeValue(forKey: call.id)
            if mediaStartInProgressCallID == call.id {
                mediaStartInProgressCallID = nil
            }
            isCallKitAudioSessionActive = false
            activeCallKitAudioSession = nil
            remoteVideoLastFrameAt = nil
            stopPictureInPicture(reason: "call_install_terminal")
            await audioSessionCoordinator.deactivate()
            scheduleDismissIfNeeded(for: call.id)
        }
    }

    private func clearCallState() async {
        let previousCallID = activeCall?.id
        if let previousCallID {
            cancelCallKitAudioFallback(for: previousCallID, reason: "clear_call_state_previous")
            prewarmedIncomingCallIDs.remove(previousCallID)
            pendingPushCallIDs.remove(previousCallID)
            preferredIncomingUserIDByCallID.removeValue(forKey: previousCallID)
            pendingPushCallerNameByCallID.removeValue(forKey: previousCallID)
            recentIncomingPushQueuedAtByCallID.removeValue(forKey: previousCallID)
            callKitCoordinator.reportEnded(callID: previousCallID)
        }
        durationTask?.cancel()
        durationTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        stopEventMonitoring()
        stopMediaSession()
        stopPictureInPicture(reason: "clear_call_state")
        clearSignalBacklog(for: previousCallID)
        stopIncomingAnswerDispatchLoop(for: previousCallID)
        locallyOriginatedOutgoingCallIDs.removeAll()
        localOutgoingStartAtByCallID.removeAll()
        pendingCallKitAnswerCallIDs.removeAll()
        for task in pendingCallKitAnswerResolutionTasks.values {
            task.cancel()
        }
        pendingCallKitAnswerResolutionTasks.removeAll()
        incomingImmediateAnswerPendingCallIDs.removeAll()
        for task in callKitAudioFallbackTasks.values {
            task.cancel()
        }
        callKitAudioFallbackTasks.removeAll()
        remoteAnswerAppliedCallIDs.removeAll()
        offerDispatchInProgressCallIDs.removeAll()
        answerDispatchInProgressCallIDs.removeAll()
        callKitAnswerInFlightCallIDs.removeAll()
        localEndIntentCallIDs.removeAll()
        answerRequestedAtByCallID.removeAll()
        mediaStartInProgressCallID = nil
        isCallKitAudioSessionActive = false
        activeCallKitAudioSession = nil
        remoteVideoWatchdogTask?.cancel()
        remoteVideoWatchdogTask = nil
        remoteVideoLastFrameAt = nil
        cancelVideoDegradeTask(reason: "clear_call_state")
        lastObservedICEConnectionState = .new
        callMetricsByID.removeAll()
        activeCall = nil
        isPresentingCallUI = false
        duration = 0
        isMuted = false
        isSpeakerEnabled = false
        isVideoEnabled = false
        isUsingFrontCamera = true
        isRemoteVideoAvailable = false
        isRemoteMuted = false
        updateProximityMonitoringEnabled(false)
        await audioSessionCoordinator.deactivate()
    }

    private func activateAudioIfNeeded() async {
        guard let activeCall, activeCall.state == .active else {
            callDebugLog("audio.activate.skip_non_active")
            return
        }

        if isCallKitAudioSessionActive {
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            do {
                let hasMicPermission = try await audioSessionCoordinator.configureActivatedCallKitSession(
                    session,
                    speakerEnabled: isSpeakerEnabled
                )
                if hasMicPermission == false {
                    #if !os(tvOS)
                    callDebugLog(
                        "audio.callkit-path.microphone_unavailable status=\(await audioSessionCoordinator.microphonePermissionStatusDescription())"
                    )
                    #else
                    callDebugLog("audio.callkit-path.microphone_unavailable")
                    #endif
                }
                #if !os(tvOS)
                callDebugLog("audio.route.callkit-path \(await audioSessionCoordinator.currentAudioRouteDescription())")
                callDebugLog("audio.session.snapshot.callkit-path \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
                if session.currentRoute.inputs.isEmpty {
                    callDebugLog("audio.callkit-path.no_input call=\(activeCall.id.uuidString) force_reactivate=true")
                    let fallbackPermission = try await audioSessionCoordinator.forceActivateForCallKitFallback(
                        speakerEnabled: isSpeakerEnabled
                    )
                    mediaEngine.notifyAudioSessionActivated(using: session)
                    callDebugLog(
                        "audio.callkit-path.reactivated_no_input call=\(activeCall.id.uuidString) mic_permission=\(fallbackPermission)"
                    )
                    callDebugLog("audio.route.callkit-path.reactivated \(await audioSessionCoordinator.currentAudioRouteDescription())")
                    callDebugLog("audio.session.snapshot.callkit-path.reactivated \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
                }
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

        let isTrackedByCallKit = isCallKitTrackingEffective(for: activeCall.id)
        let isAppActive = isAppActiveForCallAudioDebug()
        let isIncomingDirection: Bool = {
            guard let currentUserID else { return false }
            return activeCall.direction(for: currentUserID) == .incoming
        }()
        if mediaEngine.isAutomaticAudioSessionFallbackEnabled,
           isTrackedByCallKit,
           isIncomingDirection,
           isCallKitAudioSessionActive == false {
            callDebugLog(
                "audio.activate.auto_mode_active call=\(activeCall.id.uuidString) tracked=true incoming=true"
            )
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            do {
                _ = try await audioSessionCoordinator.configureActivatedCallKitSession(
                    session,
                    speakerEnabled: isSpeakerEnabled
                )
            } catch {
                #if !os(tvOS)
                callDebugLog(
                    "audio.auto_mode.configure.failed permission=\(await audioSessionCoordinator.microphonePermissionStatusDescription()) error=\(error)"
                )
                #else
                callDebugLog("audio.auto_mode.configure.failed error=\(error)")
                #endif
            }
            mediaEngine.notifyAudioSessionActivated(using: session)
            mediaEngine.setMuted(isMuted)
            return
        }
        let isBackgroundIncomingWithoutCallKitActivation: Bool = {
            guard let currentUserID else { return false }
            return activeCall.direction(for: currentUserID) == .incoming && isAppActive == false
        }()
        let shouldAwaitCallKitDidActivate =
            (isTrackedByCallKit && isIncomingDirection && isCallKitAudioSessionActive == false)
            || isBackgroundIncomingWithoutCallKitActivation

        if shouldAwaitCallKitDidActivate {
            if isTrackedByCallKit && isCallKitAudioSessionActive == false {
                var didNotifyWebRTC = false
                #if !os(tvOS)
                callDebugLog("audio.route.callkit-pending \(await audioSessionCoordinator.currentAudioRouteDescription())")
                callDebugLog("audio.session.snapshot.callkit-pending \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
                #endif
                let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
                do {
                    let hasMicPermission = try await audioSessionCoordinator.configureActivatedCallKitSession(
                        session,
                        speakerEnabled: isSpeakerEnabled
                    )
                    #if !os(tvOS)
                    let hasInput = session.currentRoute.inputs.isEmpty == false
                    #else
                    let hasInput = true
                    #endif
                    if hasInput || mediaEngine.isAutomaticAudioSessionFallbackEnabled {
                        mediaEngine.notifyAudioSessionActivated(using: session)
                        didNotifyWebRTC = true
                    } else {
                        callDebugLog("audio.callkit-pending.skip_notify_no_input call=\(activeCall.id.uuidString)")
                    }
                    #if !os(tvOS)
                    callDebugLog("audio.route.callkit-pending.prepared \(await audioSessionCoordinator.currentAudioRouteDescription())")
                    callDebugLog("audio.session.snapshot.callkit-pending.prepared \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
                    if hasMicPermission == false {
                        callDebugLog(
                            "audio.callkit-pending.microphone_unavailable status=\(await audioSessionCoordinator.microphonePermissionStatusDescription())"
                        )
                    }
                    if session.currentRoute.inputs.isEmpty {
                        callDebugLog("audio.callkit-pending.no_input call=\(activeCall.id.uuidString)")
                    }
                    if session.currentRoute.outputs.isEmpty {
                        callDebugLog("audio.callkit-pending.no_output call=\(activeCall.id.uuidString)")
                    }
                    var didLocalFallbackActivate = false
                    if session.currentRoute.inputs.isEmpty || session.currentRoute.outputs.isEmpty {
                        if isAppActive {
                            do {
                                let fallbackPermission = try await audioSessionCoordinator.forceActivateForCallKitFallback(
                                    speakerEnabled: isSpeakerEnabled
                                )
                                let fallbackSession = AVAudioSession.sharedInstance()
                                let hasFallbackInput = fallbackSession.currentRoute.inputs.isEmpty == false
                                let hasFallbackOutput = fallbackSession.currentRoute.outputs.isEmpty == false
                                callDebugLog(
                                    "audio.callkit-pending.local_activate call=\(activeCall.id.uuidString) has_input=\(hasFallbackInput) has_output=\(hasFallbackOutput)"
                                )
                                if hasFallbackInput && hasFallbackOutput {
                                    isCallKitAudioSessionActive = true
                                    activeCallKitAudioSession = fallbackSession
                                    mediaEngine.notifyAudioSessionActivated(using: fallbackSession)
                                    mediaEngine.setMuted(isMuted)
                                    didNotifyWebRTC = true
                                    didLocalFallbackActivate = true
                                    callDebugLog(
                                        "audio.callkit-pending.local_activate.success call=\(activeCall.id.uuidString) mic_permission=\(fallbackPermission)"
                                    )
                                    cancelCallKitAudioFallback(for: activeCall.id, reason: "callkit_pending_local_activate")
                                } else {
                                    callDebugLog("audio.callkit-pending.local_activate.no_route call=\(activeCall.id.uuidString)")
                                }
                            } catch {
                                callDebugLog("audio.callkit-pending.local_activate.failed call=\(activeCall.id.uuidString) error=\(error)")
                            }
                        }
                    }
                    if didLocalFallbackActivate {
                        callDebugLog("audio.activate.deferred.resolved_local_activation call=\(activeCall.id.uuidString)")
                        return
                    }
                    if session.currentRoute.inputs.isEmpty || session.currentRoute.outputs.isEmpty {
                        if mediaEngine.isAutomaticAudioSessionFallbackEnabled == false {
                            mediaEngine.enableAutomaticAudioSessionFallback(
                                reason: "callkit_pending_missing_route"
                            )
                        }
                        callDebugLog(
                            "audio.callkit-pending.auto_webrtc_enabled call=\(activeCall.id.uuidString) reason=missing_route"
                        )
                        rebindMediaAudioSession(reason: "callkit_pending_missing_route")
                    }
                    #else
                    if hasMicPermission == false {
                        callDebugLog("audio.callkit-pending.microphone_unavailable")
                    }
                    #endif
                } catch {
                    #if !os(tvOS)
                    callDebugLog(
                        "audio.callkit-pending.configure.failed permission=\(await audioSessionCoordinator.microphonePermissionStatusDescription()) error=\(error)"
                    )
                    #else
                    callDebugLog("audio.callkit-pending.configure.failed error=\(error)")
                    #endif
                }
                callDebugLog(
                    "audio.activate.deferred.awaiting_callkit_didActivate call=\(activeCall.id.uuidString) tracked=\(isTrackedByCallKit) incoming=\(isIncomingDirection) background_incoming=\(isBackgroundIncomingWithoutCallKitActivation) app_active=\(isAppActive) webrtc_notified=\(didNotifyWebRTC)"
                )
                if let currentUserID,
                   activeCall.direction(for: currentUserID) == .incoming {
                    scheduleCallKitAudioFallbackIfNeeded(for: activeCall, reason: "activate_deferred")
                }
                return
            }

            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            do {
                let hasMicPermission = try await audioSessionCoordinator.configureActivatedCallKitSession(
                    session,
                    speakerEnabled: isSpeakerEnabled
                )
                #if !os(tvOS)
                callDebugLog("audio.route.callkit-provisional \(await audioSessionCoordinator.currentAudioRouteDescription())")
                callDebugLog("audio.session.snapshot.callkit-provisional \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
                if hasMicPermission == false {
                    callDebugLog(
                        "audio.callkit-provisional.microphone_unavailable status=\(await audioSessionCoordinator.microphonePermissionStatusDescription())"
                    )
                }
                if session.currentRoute.inputs.isEmpty {
                    callDebugLog("audio.callkit-provisional.no_input call=\(activeCall.id.uuidString) wait_callkit_didActivate=true")
                }
                #else
                if hasMicPermission == false {
                    callDebugLog("audio.callkit-provisional.microphone_unavailable")
                }
                #endif
            } catch {
                #if !os(tvOS)
                callDebugLog(
                    "audio.callkit-provisional.configure.failed permission=\(await audioSessionCoordinator.microphonePermissionStatusDescription()) error=\(error)"
                )
                #else
                callDebugLog("audio.callkit-provisional.configure.failed error=\(error)")
                #endif
            }
            // CallKit may delay or occasionally skip didActivate callback timing for
            // background/system answer flows. Keep WebRTC audio graph armed anyway.
            callDebugLog(
                "audio.activate.deferred.awaiting_callkit_didActivate call=\(activeCall.id.uuidString) tracked=\(isTrackedByCallKit) incoming=\(isIncomingDirection) background_incoming=\(isBackgroundIncomingWithoutCallKitActivation) app_active=\(isAppActive) webrtc_notified=false"
            )
            if let currentUserID,
               activeCall.direction(for: currentUserID) == .incoming {
                scheduleCallKitAudioFallbackIfNeeded(for: activeCall, reason: "activate_deferred")
            }
            return
        }

        if isTrackedByCallKit, isIncomingDirection, isCallKitAudioSessionActive == false {
            callDebugLog(
                "audio.activate.skip_local_callkit_pending call=\(activeCall.id.uuidString) app_active=\(isAppActive)"
            )
            scheduleCallKitAudioFallbackIfNeeded(for: activeCall, reason: "skip_local_callkit_pending")
            return
        }

        do {
            try await audioSessionCoordinator.activate(speakerEnabled: isSpeakerEnabled)
            mediaEngine.notifyAudioSessionActivated(using: AVAudioSession.sharedInstance())
            #if !os(tvOS)
            callDebugLog("audio.route.activated.local \(await audioSessionCoordinator.currentAudioRouteDescription())")
            callDebugLog("audio.session.snapshot.local \(await audioSessionCoordinator.audioSessionSnapshotDescription())")
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
        let displayName = callKitDisplayName(
            primary: call.displayName(for: currentUserID),
            fallback: "Prime Messaging"
        )
        let direction = call.direction(for: currentUserID)
        let remoteUserID = remoteParticipantID(for: call, currentUserID: currentUserID)
        let handleValue = callKitHandleValue(
            forRemoteUserID: remoteUserID,
            callID: call.id,
            displayName: displayName
        )

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
            if direction == .outgoing,
               locallyOriginatedOutgoingCallIDs.contains(call.id),
               remoteAnswerAppliedCallIDs.contains(call.id) {
                callKitCoordinator.reportOutgoingConnected(callID: call.id)
            } else if direction == .outgoing, locallyOriginatedOutgoingCallIDs.contains(call.id) {
                callDebugLog("callkit.outgoing.connect.pending_remote_answer call=\(call.id.uuidString)")
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
                    try? await Task.sleep(for: .milliseconds(Int(self.callEventsNormalPollingIntervalMs)))
                    continue
                }

                do {
                    let events = try await self.runWithTimeout(seconds: self.callEventsFetchTimeout) {
                        try await repository.fetchEvents(
                            callID: callID,
                            userID: currentUserID,
                            sinceSequence: self.lastEventSequence
                        )
                    }.sorted { $0.sequence < $1.sequence }

                    for event in events where event.sequence > self.lastEventSequence {
                        self.lastEventSequence = event.sequence
                        await self.handleCallEvent(event, callID: callID)
                    }
                } catch {
                    self.callDebugLog("events.fetch.failed call=\(callID.uuidString) error=\(error)")
                }

                let pollInterval = self.callEventsPollingInterval(for: callID, currentUserID: currentUserID)
                try? await Task.sleep(for: .milliseconds(Int(pollInterval)))
            }
        }
    }

    private func callEventsPollingInterval(for callID: UUID, currentUserID: UUID) -> UInt64 {
        guard let activeCall, activeCall.id == callID else {
            return callEventsNormalPollingIntervalMs
        }

        if activeCall.state == .ringing {
            return callEventsFastPollingIntervalMs
        }

        let direction = activeCall.direction(for: currentUserID)
        let waitingForIncomingAnswerDispatch =
            direction == .incoming && sentAnswerCallIDs.contains(callID) == false
        let waitingForRemoteAnswer = direction == .outgoing && remoteAnswerAppliedCallIDs.contains(callID) == false
        let waitingForICEConnection =
            activeCall.state == .active
            && (lastObservedICEConnectionState == .new || lastObservedICEConnectionState == .checking)

        if waitingForIncomingAnswerDispatch || waitingForRemoteAnswer || waitingForICEConnection {
            return callEventsFastPollingIntervalMs
        }
        return callEventsNormalPollingIntervalMs
    }

    private func stopEventMonitoring() {
        callEventsTask?.cancel()
        callEventsTask = nil
        callEventsCallID = nil
        lastEventSequence = 0
    }

    private func ensureMediaSession(for call: InternetCall) async throws {
        ensureCallMetrics(for: call.id)
        if mediaCallID == call.id {
            return
        }
        if mediaStartInProgressCallID == call.id {
            callDebugLog("media.start.wait_inflight call=\(call.id.uuidString)")
            for _ in 1 ... 40 {
                if mediaCallID == call.id {
                    callDebugLog("media.start.wait_inflight.done call=\(call.id.uuidString)")
                    return
                }
                if mediaStartInProgressCallID != call.id {
                    break
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            if mediaCallID == call.id {
                callDebugLog("media.start.wait_inflight.done call=\(call.id.uuidString)")
                return
            }
        }

        mediaStartInProgressCallID = call.id
        defer {
            if mediaStartInProgressCallID == call.id {
                mediaStartInProgressCallID = nil
            }
        }
        stopMediaSession()
        isRemoteVideoAvailable = false
        remoteVideoLastFrameAt = nil
        applyVideoQualityProfile(
            NetworkReachabilityMonitor.shared.currentSnapshot,
            reason: "media_start"
        )
        let iceServers = await resolveIceServers()
        try mediaEngine.start(iceServers: iceServers)
        mediaEngine.setVideoQualityProfile(currentVideoQualityProfile)
        callDebugLog(
            "video.profile.active call=\(call.id.uuidString) profile=\(currentVideoQualityProfile.rawValue)"
        )
        mediaEngine.setMuted(isMuted)
        if isVideoEnabled {
            do {
                try await mediaEngine.setVideoEnabled(true)
                isUsingFrontCamera = mediaEngine.isUsingFrontCamera
                callDebugLog("video.media.start.applied call=\(call.id.uuidString)")
            } catch {
                isVideoEnabled = false
                isUsingFrontCamera = true
                callDebugLog("video.media.start.failed call=\(call.id.uuidString) error=\(error)")
            }
        }
        if isCallKitAudioSessionActive {
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            mediaEngine.notifyAudioSessionActivated(using: session)
        }
        mediaCallID = call.id
        if var metrics = callMetricsByID[call.id], metrics.mediaStartedAt == nil {
            metrics.mediaStartedAt = .now
            callMetricsByID[call.id] = metrics
        }
        callDebugLog("media.started call=\(call.id.uuidString)")
    }

    private func sendOfferIfNeeded(for call: InternetCall, currentUserID: UUID, reason: String) async {
        guard let repository else { return }
        if sentOfferCallIDs.contains(call.id) {
            return
        }
        if remoteAnswerAppliedCallIDs.contains(call.id) {
            callDebugLog("offer.skip.remote_answer_already_applied call=\(call.id.uuidString) reason=\(reason)")
            return
        }
        if offerDispatchInProgressCallIDs.contains(call.id) {
            callDebugLog("offer.skip.inflight call=\(call.id.uuidString) reason=\(reason)")
            return
        }

        offerDispatchInProgressCallIDs.insert(call.id)
        defer {
            offerDispatchInProgressCallIDs.remove(call.id)
        }

        do {
            let offer = try await mediaEngine.createOffer()
            _ = try await repository.sendOffer(offer, in: call.id, userID: currentUserID)
            sentOfferCallIDs.insert(call.id)
            callDebugLog("offer.sent call=\(call.id.uuidString) reason=\(reason) sdp_size=\(offer.count)")
        } catch {
            callDebugLog("offer.send.failed call=\(call.id.uuidString) reason=\(reason) error=\(error)")
        }
    }

    private func sendLocalMediaStateIfNeeded(reason: String) async {
        guard let activeCall, activeCall.state == .active else { return }
        guard let currentUserID, let repository else { return }
        do {
            _ = try await repository.sendMediaState(
                isMuted: isMuted,
                isVideoEnabled: isVideoEnabled,
                in: activeCall.id,
                userID: currentUserID
            )
            callDebugLog(
                "media_state.sent call=\(activeCall.id.uuidString) muted=\(isMuted) video_enabled=\(isVideoEnabled) reason=\(reason)"
            )
        } catch {
            callDebugLog(
                "media_state.send.failed call=\(activeCall.id.uuidString) reason=\(reason) error=\(error)"
            )
        }
    }

    private func stopMediaSession() {
        let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
        mediaEngine.notifyAudioSessionDeactivated(using: session)
        mediaCallID = nil
        mediaEngine.stop()
        remoteVideoWatchdogTask?.cancel()
        remoteVideoWatchdogTask = nil
        remoteVideoLastFrameAt = nil
        isRemoteVideoAvailable = false
        cancelVideoDegradeTask(reason: "stop_media_session")
        lastObservedICEConnectionState = .new
        stopPictureInPicture(reason: "stop_media_session")
    }

    private func clearSignalBacklog(for callID: UUID?) {
        if let callID {
            pendingRemoteOfferByCallID.removeValue(forKey: callID)
            pendingRemoteAnswerByCallID.removeValue(forKey: callID)
            pendingLocalAnswerByCallID.removeValue(forKey: callID)
            pendingRemoteICEByCallID.removeValue(forKey: callID)
            clearLocalICEQueue(for: callID)
            remoteAnswerAppliedCallIDs.remove(callID)
            sentOfferCallIDs.remove(callID)
            sentAnswerCallIDs.remove(callID)
            answerDispatchInProgressCallIDs.remove(callID)
            answerRequestedAtByCallID.removeValue(forKey: callID)
            return
        }
        pendingRemoteOfferByCallID.removeAll()
        pendingRemoteAnswerByCallID.removeAll()
        pendingLocalAnswerByCallID.removeAll()
        pendingRemoteICEByCallID.removeAll()
        clearLocalICEQueue(for: nil)
        remoteAnswerAppliedCallIDs.removeAll()
        sentOfferCallIDs.removeAll()
        sentAnswerCallIDs.removeAll()
        answerDispatchInProgressCallIDs.removeAll()
        answerRequestedAtByCallID.removeAll()
    }

    private func handleCallEvent(_ event: InternetCallEvent, callID: UUID) async {
        let isLocalSender = event.senderID == currentUserID
        if isLocalSender && (event.type == .offer || event.type == .answer || event.type == .ice || event.type == .mediaState) {
            return
        }

        callDebugLog(
            "event.received call=\(callID.uuidString) type=\(event.type.rawValue) seq=\(event.sequence) sender=\(event.senderID?.uuidString ?? "nil") localSender=\(isLocalSender)"
        )

        switch event.type {
        case .offer:
            guard let sdp = event.sdp, sdp.isEmpty == false else { return }
            if let call = activeCall,
               call.id == callID,
               let currentUserID,
               call.direction(for: currentUserID) == .incoming {
                pendingRemoteOfferByCallID[callID] = sdp
                callDebugLog("offer.cached.incoming call=\(callID.uuidString) seq=\(event.sequence) sdp_size=\(sdp.count)")
                if call.state == .ringing {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            try await self.ensureMediaSession(for: call)
                            self.callDebugLog("media.prewarm.incoming.success call=\(callID.uuidString) source=event_offer_ringing")
                        } catch {
                            self.callDebugLog("media.prewarm.incoming.failed call=\(callID.uuidString) source=event_offer_ringing error=\(error)")
                        }
                    }
                }
                startIncomingAnswerDispatchLoopIfNeeded(for: call)
                if call.state == .active, let repository {
                    _ = await attemptImmediateAnswerDispatchIfPossible(
                        call: call,
                        actingUserID: currentUserID,
                        repository: repository,
                        preferredOfferSDP: sdp,
                        source: "event_offer_active"
                    )
                }
                return
            }
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
            if remoteAnswerAppliedCallIDs.contains(callID) {
                callDebugLog("answer.handle.skip_duplicate call=\(callID.uuidString) seq=\(event.sequence)")
                return
            }
            do {
                try await mediaEngine.applyRemoteAnswer(sdp)
                remoteAnswerAppliedCallIDs.insert(callID)
                if var metrics = callMetricsByID[callID], metrics.remoteAnswerAppliedAt == nil {
                    metrics.remoteAnswerAppliedAt = .now
                    callMetricsByID[callID] = metrics
                }
                await activateAudioIfNeeded()
                rebindMediaAudioSession(reason: "remote_answer_applied")
                if let call = activeCall,
                   call.id == callID,
                   let currentUserID,
                   call.direction(for: currentUserID) == .outgoing,
                   locallyOriginatedOutgoingCallIDs.contains(callID) {
                    callKitCoordinator.reportOutgoingConnected(callID: callID)
                }
            } catch {
                if isBenignStableRemoteAnswerError(error) {
                    remoteAnswerAppliedCallIDs.insert(callID)
                    callDebugLog("answer.handle.ignored_stable_duplicate call=\(callID.uuidString) seq=\(event.sequence)")
                    return
                }
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

        case .accepted:
            await refreshCallSnapshot(callID: callID)
            if let call = activeCall, call.id == callID {
                startIncomingAnswerDispatchLoopIfNeeded(for: call)
            }

        case .rejected, .ended:
            if isLocalSender, localEndIntentCallIDs.contains(callID) == false {
                callDebugLog(
                    "event.terminal.local_without_intent call=\(callID.uuidString) type=\(event.type.rawValue) seq=\(event.sequence)"
                )
            }
            stopIncomingAnswerDispatchLoop(for: callID)
            pendingCallKitAnswerCallIDs.remove(callID)
            pendingCallKitAnswerResolutionTasks[callID]?.cancel()
            pendingCallKitAnswerResolutionTasks.removeValue(forKey: callID)
            await refreshCallSnapshot(callID: callID)

        case .created:
            break
        case .mediaState:
            if let remoteMuted = event.isMuted {
                isRemoteMuted = remoteMuted
            }
            if let remoteVideoEnabled = event.isVideoEnabled, remoteVideoEnabled == false {
                isRemoteVideoAvailable = false
            }
            callDebugLog(
                "media_state.received call=\(callID.uuidString) remote_muted=\(event.isMuted.map { $0 ? "true" : "false" } ?? "nil") remote_video_enabled=\(event.isVideoEnabled.map { $0 ? "true" : "false" } ?? "nil")"
            )
        }
    }

    private func refreshCallSnapshot(callID: UUID) async {
        guard let repository, let currentUserID else { return }
        do {
            let latest = try await repository.fetchCall(callID, for: currentUserID)
            if activeCall?.id == latest.id,
               latest.state == .active,
               latest.direction(for: currentUserID) == .incoming,
               (incomingImmediateAnswerPendingCallIDs.contains(latest.id)
                   || answerDispatchInProgressCallIDs.contains(latest.id)) {
                callDebugLog("call.refresh.defer_install call=\(latest.id.uuidString) reason=answer_dispatch_in_progress")
                refreshActiveCallSnapshotWithoutReinstall(latest)
                return
            }
            if shouldReinstallCall(latest, replacing: activeCall) {
                await install(latest)
            } else {
                refreshActiveCallSnapshotWithoutReinstall(latest)
            }
        } catch {
            callDebugLog("call.refresh.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func isBenignStableRemoteAnswerError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let parts: [String] = [
            String(describing: error),
            nsError.localizedDescription,
            nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? "",
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "",
        ]
        let message = parts.joined(separator: " | ").lowercased()
        let mentionsStable = message.contains("stable")
        let mentionsStateProblem = message.contains("wrong state")
            || message.contains("invalid state")
            || message.contains("state:")
        let mentionsAnswerPath = message.contains("remote answer")
            || message.contains("answer sdp")
            || message.contains("set remote")
        return mentionsStable && (mentionsStateProblem || mentionsAnswerPath)
    }

    private func flushPendingSignals(for callID: UUID, includeOffer: Bool = true) async throws {
        if includeOffer,
           let offer = pendingRemoteOfferByCallID.removeValue(forKey: callID),
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
            if remoteAnswerAppliedCallIDs.contains(callID) {
                callDebugLog("answer.pending.skip_duplicate call=\(callID.uuidString)")
            } else {
                do {
                    try await mediaEngine.applyRemoteAnswer(answer)
                    remoteAnswerAppliedCallIDs.insert(callID)
                    if let call = activeCall,
                       call.id == callID,
                       let currentUserID,
                       call.direction(for: currentUserID) == .outgoing,
                       locallyOriginatedOutgoingCallIDs.contains(callID) {
                        callKitCoordinator.reportOutgoingConnected(callID: callID)
                    }
                } catch {
                    if isBenignStableRemoteAnswerError(error) {
                        remoteAnswerAppliedCallIDs.insert(callID)
                        callDebugLog("answer.pending.ignored_stable_duplicate call=\(callID.uuidString)")
                    } else {
                        pendingRemoteAnswerByCallID[callID] = answer
                        throw error
                    }
                }
            }
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
        guard let callID = mediaCallID ?? activeCall?.id else { return }
        enqueueLocalICECandidate(payload, for: callID)
        scheduleLocalICERetryLoopIfNeeded(for: callID)
    }

    private func sendLocalICECandidateImmediately(
        _ payload: WebRTCAudioCallEngine.ICECandidatePayload,
        callID: UUID
    ) async throws {
        guard let repository, let currentUserID else {
            throw CallRepositoryError.backendUnavailable
        }
        _ = try await repository.sendICECandidate(
            payload.candidate,
            sdpMid: payload.sdpMid,
            sdpMLineIndex: payload.sdpMLineIndex,
            in: callID,
            userID: currentUserID
        )
        callDebugLog(
            "ice.sent call=\(callID.uuidString) type=\(iceCandidateType(payload.candidate)) sdpMid=\(payload.sdpMid ?? "nil") mline=\(payload.sdpMLineIndex ?? -1)"
        )
    }

    private func enqueueLocalICECandidate(
        _ payload: WebRTCAudioCallEngine.ICECandidatePayload,
        for callID: UUID
    ) {
        var queue = pendingLocalICEByCallID[callID] ?? []
        let duplicateExists = queue.contains { item in
            item.candidate == payload.candidate
                && item.sdpMid == payload.sdpMid
                && item.sdpMLineIndex == payload.sdpMLineIndex
        }
        guard duplicateExists == false else { return }

        let candidateType = iceCandidateType(payload.candidate)
        let candidateTransport = iceCandidateTransport(payload.candidate)
        if candidateType == "host",
           candidateTransport == "tcp",
           localICEAllowTCPHostCandidates == false {
            callDebugLog(
                "ice.enqueue.drop_tcp call=\(callID.uuidString) type=\(candidateType) sdpMid=\(payload.sdpMid ?? "nil") mline=\(payload.sdpMLineIndex ?? -1)"
            )
            return
        }
        if candidateType == "host", localICEHostCandidateLimit >= 0 {
            let existingHostCount = queue.reduce(into: 0) { count, item in
                if iceCandidateType(item.candidate) == "host" {
                    count += 1
                }
            }
            if existingHostCount >= localICEHostCandidateLimit {
                callDebugLog(
                    "ice.enqueue.drop_limited call=\(callID.uuidString) type=\(candidateType) limit=\(localICEHostCandidateLimit)"
                )
                return
            }
        }

        if queue.count >= localICEMaxBufferedCandidates {
            queue.removeFirst(queue.count - localICEMaxBufferedCandidates + 1)
        }
        queue.append(payload)
        queue = queue.enumerated().sorted { lhs, rhs in
            let leftPriority = localICEPriority(for: lhs.element)
            let rightPriority = localICEPriority(for: rhs.element)
            if leftPriority == rightPriority {
                return lhs.offset < rhs.offset
            }
            return leftPriority < rightPriority
        }.map(\.element)
        pendingLocalICEByCallID[callID] = queue
    }

    private func scheduleLocalICERetryLoopIfNeeded(for callID: UUID) {
        guard pendingLocalICEByCallID[callID]?.isEmpty == false else { return }

        if let existingTask = localICERetryTasks[callID], existingTask.isCancelled == false {
            return
        }

        localICERetryTasks[callID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.localICERetryTasks.removeValue(forKey: callID)
            }

            var attempt = 1
            while Task.isCancelled == false {
                guard self.shouldKeepRetryingLocalICE(for: callID) else { return }
                if self.shouldDeferLocalICESend(for: callID) {
                    try? await Task.sleep(for: .milliseconds(90))
                    continue
                }

                let flushed = await self.flushPendingLocalICECandidates(for: callID)
                let remaining = self.pendingLocalICEByCallID[callID]?.count ?? 0
                if remaining == 0 {
                    return
                }

                if attempt >= self.localICEMaxRetryAttempts {
                    self.callDebugLog("ice.retry.give_up call=\(callID.uuidString) remaining=\(remaining)")
                    return
                }

                let delayMs = self.localICERetryDelayMs(forAttempt: attempt)
                if flushed {
                    attempt = 1
                } else {
                    attempt += 1
                }
                try? await Task.sleep(for: .milliseconds(Int(delayMs)))
            }
        }
    }

    private func shouldKeepRetryingLocalICE(for callID: UUID) -> Bool {
        guard let activeCall, activeCall.id == callID else { return false }
        return activeCall.state == .ringing || activeCall.state == .active
    }

    private func shouldDeferLocalICESend(for callID: UUID) -> Bool {
        guard let activeCall,
              activeCall.id == callID,
              let currentUserID else {
            return false
        }
        if answerDispatchInProgressCallIDs.contains(callID), activeCall.state != .active {
            return true
        }
        if activeCall.direction(for: currentUserID) == .incoming,
           sentAnswerCallIDs.contains(callID) == false,
           activeCall.state != .active {
            return true
        }
        return false
    }

    @discardableResult
    private func flushPendingLocalICECandidates(for callID: UUID) async -> Bool {
        var flushedAtLeastOne = false
        while true {
            guard var queue = pendingLocalICEByCallID[callID], queue.isEmpty == false else {
                localICEFailureCountByCallID.removeValue(forKey: callID)
                return flushedAtLeastOne
            }
            let nextPayload = queue.removeFirst()
            if queue.isEmpty {
                pendingLocalICEByCallID.removeValue(forKey: callID)
            } else {
                pendingLocalICEByCallID[callID] = queue
            }
            do {
                try await sendLocalICECandidateImmediately(nextPayload, callID: callID)
                flushedAtLeastOne = true
                resetLocalICEFailureCount(for: nextPayload, callID: callID)
            } catch {
                let failureCount = incrementLocalICEFailureCount(for: nextPayload, callID: callID)
                let shouldDropCandidate = failureCount >= localICEPerCandidateMaxFailures
                callDebugLog(
                    "ice.retry.failed call=\(callID.uuidString) remaining=\(pendingLocalICEByCallID[callID]?.count ?? 0) candidate_failures=\(failureCount) drop=\(shouldDropCandidate) error=\(error)"
                )
                if shouldDropCandidate == false {
                    var restoredQueue = pendingLocalICEByCallID[callID] ?? []
                    restoredQueue.append(nextPayload)
                    pendingLocalICEByCallID[callID] = restoredQueue
                } else {
                    resetLocalICEFailureCount(for: nextPayload, callID: callID)
                }
                return flushedAtLeastOne
            }
        }
    }

    private func localICERetryDelayMs(forAttempt attempt: Int) -> UInt64 {
        let safeAttempt = max(1, attempt)
        let shift = min(safeAttempt - 1, 4)
        let multiplier = UInt64(1 << shift)
        let delay = localICERetryBaseDelayMs * multiplier
        return min(delay, localICERetryMaxDelayMs)
    }

    private func iceCandidateType(_ candidate: String) -> String {
        let parts = candidate.split(separator: " ")
        guard let typeIndex = parts.firstIndex(of: "typ"), parts.indices.contains(parts.index(after: typeIndex)) else {
            return "unknown"
        }
        return String(parts[parts.index(after: typeIndex)])
    }

    private func iceCandidateTransport(_ candidate: String) -> String {
        let parts = candidate.split(separator: " ")
        guard parts.count >= 3 else { return "unknown" }
        return String(parts[2]).lowercased()
    }

    private func localICEPriority(for payload: WebRTCAudioCallEngine.ICECandidatePayload) -> Int {
        switch iceCandidateType(payload.candidate) {
        case "relay":
            return 0
        case "srflx", "prflx":
            return 1
        case "host":
            return 2
        default:
            return 3
        }
    }

    private func localICECandidateKey(_ payload: WebRTCAudioCallEngine.ICECandidatePayload) -> String {
        "\(payload.sdpMid ?? "nil")|\(payload.sdpMLineIndex ?? -1)|\(payload.candidate)"
    }

    private func incrementLocalICEFailureCount(
        for payload: WebRTCAudioCallEngine.ICECandidatePayload,
        callID: UUID
    ) -> Int {
        let key = localICECandidateKey(payload)
        var map = localICEFailureCountByCallID[callID] ?? [:]
        let nextCount = (map[key] ?? 0) + 1
        map[key] = nextCount
        localICEFailureCountByCallID[callID] = map
        return nextCount
    }

    private func resetLocalICEFailureCount(
        for payload: WebRTCAudioCallEngine.ICECandidatePayload,
        callID: UUID
    ) {
        let key = localICECandidateKey(payload)
        guard var map = localICEFailureCountByCallID[callID] else { return }
        map.removeValue(forKey: key)
        if map.isEmpty {
            localICEFailureCountByCallID.removeValue(forKey: callID)
        } else {
            localICEFailureCountByCallID[callID] = map
        }
    }

    private func clearLocalICEQueue(for callID: UUID?) {
        if let callID {
            pendingLocalICEByCallID.removeValue(forKey: callID)
            localICEFailureCountByCallID.removeValue(forKey: callID)
            localICERetryTasks.removeValue(forKey: callID)?.cancel()
            return
        }

        pendingLocalICEByCallID.removeAll()
        localICEFailureCountByCallID.removeAll()
        for task in localICERetryTasks.values {
            task.cancel()
        }
        localICERetryTasks.removeAll()
    }

    private func recoverIncomingOfferIfNeeded(for call: InternetCall) async {
        guard let currentUserID, let repository else { return }
        guard call.direction(for: currentUserID) == .incoming else { return }
        guard sentAnswerCallIDs.contains(call.id) == false else { return }

        if pendingRemoteOfferByCallID[call.id] != nil {
            return
        }

        let snapshotOffer = call.latestRemoteOfferSDP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if snapshotOffer.isEmpty == false {
            pendingRemoteOfferByCallID[call.id] = snapshotOffer
            callDebugLog(
                "offer.recovered.snapshot call=\(call.id.uuidString) seq=\(call.latestRemoteOfferSequence ?? -1) sdp_size=\(snapshotOffer.count)"
            )
            return
        }

        do {
            let events = try await runWithTimeout(seconds: immediateOfferFetchTimeout) {
                try await repository.fetchEvents(
                    callID: call.id,
                    userID: currentUserID,
                    sinceSequence: 0
                )
            }
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

    private func recoverIncomingOfferIfNeeded(
        callID: UUID,
        actingUserID: UUID,
        repository: any CallRepository
    ) async {
        guard sentAnswerCallIDs.contains(callID) == false else { return }
        guard pendingRemoteOfferByCallID[callID] == nil else { return }

        if let activeCall, activeCall.id == callID, activeCall.direction(for: actingUserID) == .incoming {
            await recoverIncomingOfferIfNeeded(for: activeCall)
            return
        }

        do {
            let call = try await repository.fetchCall(callID, for: actingUserID)
            guard call.direction(for: actingUserID) == .incoming else { return }
            await recoverIncomingOfferIfNeeded(for: call)
        } catch {
            callDebugLog("offer.recover.prefetch.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func processPendingPushCallsIfNeeded() async {
        guard let repository else { return }
        guard pendingPushCallIDs.isEmpty == false else { return }
        await bootstrapCurrentUserContextIfNeeded(source: "pending_push_resolution")
        reassertCallKitPrewarmForPendingPushes()

        let callIDs = Array(pendingPushCallIDs)
        for callID in callIDs {
            let preferredIncomingUserID = preferredIncomingUserIDByCallID[callID]
            guard let resolved = await resolveCallContext(
                callID: callID,
                preferredUserID: preferredIncomingUserID ?? currentUserID,
                repository: repository,
                requiredDirection: .incoming
            ) else {
                if let activeCall,
                   activeCall.id == callID,
                   let currentUserID,
                   activeCall.direction(for: currentUserID) == .incoming,
                   isTerminalState(activeCall.state) == false {
                    pendingPushCallIDs.remove(callID)
                    preferredIncomingUserIDByCallID.removeValue(forKey: callID)
                    pendingPushCallerNameByCallID.removeValue(forKey: callID)
                    callDebugLog(
                        "push.call.resolve.use_active_snapshot call=\(callID.uuidString) state=\(activeCall.state.rawValue)"
                    )
                    continue
                }
                if let activeCall,
                   activeCall.id == callID,
                   isTerminalState(activeCall.state) {
                    pendingPushCallIDs.remove(callID)
                    preferredIncomingUserIDByCallID.removeValue(forKey: callID)
                    pendingPushCallerNameByCallID.removeValue(forKey: callID)
                    callDebugLog(
                        "push.call.resolve.drop_terminal_local call=\(callID.uuidString) state=\(activeCall.state.rawValue)"
                    )
                    continue
                }
                callDebugLog(
                    "push.call.resolve.failed call=\(callID.uuidString) preferred_user=\(preferredIncomingUserID?.uuidString ?? "nil") error=unresolved_incoming_context"
                )
                continue
            }

            let resolvedUserID = resolved.userID
            let call = resolved.call
            pendingPushCallIDs.remove(callID)
            preferredIncomingUserIDByCallID.removeValue(forKey: callID)
            pendingPushCallerNameByCallID.removeValue(forKey: callID)

            if currentUserID != resolvedUserID {
                let previousUserID = currentUserID
                self.currentUserID = resolvedUserID
                callDebugLog(
                    "call.context.switched call=\(callID.uuidString) old=\(previousUserID?.uuidString ?? "nil") new=\(resolvedUserID.uuidString)"
                )
            }

            if isTerminalState(call.state) {
                recordTerminalSnapshot(call)
                prewarmedIncomingCallIDs.remove(callID)
                callKitCoordinator.reportEnded(callID: callID)
                clearCallNotifications(callID: callID)
                callDebugLog("push.call.resolve.ignored_terminal call=\(callID.uuidString) state=\(call.state.rawValue)")
                continue
            }

            if let activeCall,
               activeCall.id == call.id,
               shouldReinstallCall(call, replacing: activeCall) == false {
                refreshActiveCallSnapshotWithoutReinstall(call)
                callDebugLog("push.call.resolve.skip_reinstall call=\(callID.uuidString) state=\(call.state.rawValue)")
                continue
            }

            callDebugLog("push.call.resolve.success call=\(callID.uuidString) state=\(call.state.rawValue)")
            await install(call)
        }
    }

    private func schedulePendingPushResolutionLoopIfNeeded() {
        guard pendingPushResolutionTask == nil else { return }
        pendingPushResolutionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingPushResolutionTask = nil }

            for attempt in 1 ... 90 {
                if Task.isCancelled {
                    return
                }
                if self.pendingPushCallIDs.isEmpty {
                    return
                }
                await self.processPendingPushCallsIfNeeded()
                if self.pendingPushCallIDs.isEmpty {
                    self.callDebugLog("push.call.resolve.loop.done attempts=\(attempt)")
                    return
                }
                if attempt == 1 || attempt % 10 == 0 {
                    self.callDebugLog(
                        "push.call.resolve.loop.pending attempts=\(attempt) remaining=\(self.pendingPushCallIDs.count)"
                    )
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            if self.pendingPushCallIDs.isEmpty == false {
                self.callDebugLog(
                    "push.call.resolve.loop.timeout remaining=\(self.pendingPushCallIDs.count)"
                )
            }
        }
    }

    private func reassertCallKitPrewarmForPendingPushes() {
        guard pendingPushCallIDs.isEmpty == false else { return }
        for callID in pendingPushCallIDs {
            guard prewarmedIncomingCallIDs.contains(callID) else { continue }
            if callKitCoordinator.isTracking(callID: callID) {
                continue
            }
            let displayName = callKitDisplayName(
                primary: pendingPushCallerNameByCallID[callID],
                fallback: "Prime Messaging"
            )
            let handleValue = callKitHandleValue(
                forRemoteUserID: nil,
                callID: callID,
                displayName: displayName
            )
            callKitCoordinator.reportIncoming(callID: callID, handleValue: handleValue, displayName: displayName)
            callDebugLog("push.call.prewarm.reassert call=\(callID.uuidString)")
        }
    }

    private func processPendingCallKitAnswersIfNeeded() async {
        guard pendingCallKitAnswerCallIDs.isEmpty == false else { return }
        await bootstrapCurrentUserContextIfNeeded(source: "pending_callkit_answer")
        guard currentUserID != nil, repository != nil else { return }

        let callIDs = Array(pendingCallKitAnswerCallIDs)
        for callID in callIDs {
            let didStart = await answerCall(callID: callID, allowDeferredSuccess: false)
            if didStart {
                pendingCallKitAnswerCallIDs.remove(callID)
                pendingCallKitAnswerResolutionTasks[callID]?.cancel()
                pendingCallKitAnswerResolutionTasks.removeValue(forKey: callID)
                callDebugLog("callkit.answer.pending.resolved call=\(callID.uuidString)")
            }
        }
    }

    @discardableResult
    private func answerCall(callID: UUID, allowDeferredSuccess: Bool = true) async -> Bool {
        if sentAnswerCallIDs.contains(callID) {
            callDebugLog("callkit.answer.skip_already_answered call=\(callID.uuidString)")
            return true
        }
        if let activeCall, activeCall.id == callID, activeCall.state == .active {
            if let currentUserID, activeCall.direction(for: currentUserID) == .incoming {
                callDebugLog("callkit.answer.skip_already_active call=\(callID.uuidString)")
                return true
            }
        }
        if answerRequestedAtByCallID[callID] == nil {
            answerRequestedAtByCallID[callID] = Date.now
        }
        #if os(iOS) && canImport(UIKit)
        let backgroundTaskID = beginBackgroundTaskThreadSafe(
            named: "pm.call.answer.request.\(callID.uuidString)"
        )
        #endif
        defer {
            #if os(iOS) && canImport(UIKit)
            if backgroundTaskID != .invalid {
                endBackgroundTaskThreadSafe(backgroundTaskID)
            }
            #endif
        }

        guard let (bootstrappedUserID, repository) = await waitForAnswerContext(callID: callID, timeoutSeconds: 16) else {
            pendingCallKitAnswerCallIDs.insert(callID)
            schedulePendingCallKitAnswerResolution(callID: callID)
            callDebugLog(
                "callkit.answer.deferred.missing_context call=\(callID.uuidString) fulfills_action=\(allowDeferredSuccess)"
            )
            return allowDeferredSuccess
        }

        var actingUserID = bootstrappedUserID
        var resolvedIncomingCallSnapshot: InternetCall?
        let preferredUserID = preferredIncomingUserIDByCallID[callID] ?? bootstrappedUserID
        if let resolved = await resolveCallContext(
            callID: callID,
            preferredUserID: preferredUserID,
            repository: repository,
            requiredDirection: .incoming
        ) {
            actingUserID = resolved.userID
            resolvedIncomingCallSnapshot = resolved.call
            if currentUserID != actingUserID {
                currentUserID = actingUserID
                callDebugLog(
                    "callkit.answer.context.switched call=\(callID.uuidString) old=\(bootstrappedUserID.uuidString) new=\(actingUserID.uuidString)"
                )
            }
            if activeCall?.id != callID {
                await install(resolved.call)
            }
        }

        let preAcceptCallSnapshot: InternetCall? = {
            if let activeCall, activeCall.id == callID {
                return activeCall
            }
            return resolvedIncomingCallSnapshot
        }()
        var didSendImmediateAnswer = false
        if let preAcceptCallSnapshot,
           preAcceptCallSnapshot.direction(for: actingUserID) == .incoming,
           preAcceptCallSnapshot.state == .active {
            didSendImmediateAnswer = await attemptImmediateAnswerDispatchIfPossible(
                call: preAcceptCallSnapshot,
                actingUserID: actingUserID,
                repository: repository,
                source: "callkit_accept_pre_accept"
            )
            if didSendImmediateAnswer {
                callDebugLog("answer.pre_accept.sent call=\(callID.uuidString)")
            }
        } else if let preAcceptCallSnapshot,
                  preAcceptCallSnapshot.direction(for: actingUserID) == .incoming,
                  preAcceptCallSnapshot.state == .ringing {
            // Do not block answer UX on a pre-accept SDP round-trip while backend is still in ringing state.
            callDebugLog("answer.pre_accept.skipped call=\(callID.uuidString) reason=ringing_state")
        }

        do {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let repository = self.repository else { return }
                await self.recoverIncomingOfferIfNeeded(callID: callID, actingUserID: actingUserID, repository: repository)
            }

            let updatedCall = try await repository.answerCall(callID, userID: actingUserID)
            let updatedDirection = updatedCall.direction(for: actingUserID)
            if activeCall?.id == updatedCall.id {
                refreshActiveCallSnapshotWithoutReinstall(updatedCall)
            } else {
                applyCallSnapshotImmediately(updatedCall)
            }
            let shouldDispatchImmediateIncomingAnswer =
                updatedDirection == .incoming
                && updatedCall.state != .ended
                && updatedCall.state != .cancelled
                && updatedCall.state != .rejected
                && updatedCall.state != .missed
            if shouldDispatchImmediateIncomingAnswer {
                incomingImmediateAnswerPendingCallIDs.insert(callID)
            }
            defer {
                incomingImmediateAnswerPendingCallIDs.remove(callID)
            }
            if shouldDispatchImmediateIncomingAnswer, didSendImmediateAnswer == false {
                // Send SDP answer before install-side network work (media state flush, etc.).
                didSendImmediateAnswer = await attemptImmediateAnswerDispatchIfPossible(
                    call: updatedCall,
                    actingUserID: actingUserID,
                    repository: repository,
                    source: "callkit_accept"
                )
            }
            await install(updatedCall)
            callDebugLog(
                "callkit.answer.post_state call=\(callID.uuidString) state=\(updatedCall.state.rawValue) direction=\(updatedDirection.rawValue) user=\(actingUserID.uuidString)"
            )
            if shouldDispatchImmediateIncomingAnswer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.activateAudioIfNeeded()
                    self.rebindMediaAudioSession(reason: "callkit_answer_accept")
                    self.scheduleCallKitAudioFallbackIfNeeded(for: updatedCall, reason: "callkit_answer_accept")
                }
                if didSendImmediateAnswer == false {
                    incomingImmediateAnswerPendingCallIDs.remove(callID)
                    startIncomingAnswerDispatchLoopIfNeeded(for: updatedCall)
                } else {
                    try? await flushPendingSignals(for: updatedCall.id, includeOffer: false)
                }
                callDebugLog(
                    "callkit.answer.accepted.awaiting_sdp_answer call=\(callID.uuidString) answer_dispatched=\(sentAnswerCallIDs.contains(callID))"
                )
            } else if updatedCall.state == .active {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.activateAudioIfNeeded()
                    self.rebindMediaAudioSession(reason: "callkit_answer_accept")
                }
                callDebugLog(
                    "callkit.answer.context_mismatch call=\(callID.uuidString) expected=incoming got=\(updatedDirection.rawValue) user=\(actingUserID.uuidString)"
                )
            }
            pendingCallKitAnswerCallIDs.remove(callID)
            pendingCallKitAnswerResolutionTasks[callID]?.cancel()
            pendingCallKitAnswerResolutionTasks.removeValue(forKey: callID)
            callDebugLog("callkit.answer.accepted call=\(callID.uuidString)")
            return true
        } catch {
            callDebugLog(
                "callkit.answer.failed call=\(callID.uuidString) error=\(error.localizedDescription) type=\(String(reflecting: type(of: error)))"
            )
            if shouldDeferCallKitAnswerAfterError(error) {
                pendingCallKitAnswerCallIDs.insert(callID)
                schedulePendingCallKitAnswerResolution(callID: callID)
                callDebugLog(
                    "callkit.answer.deferred.transient_error call=\(callID.uuidString) fulfills_action=\(allowDeferredSuccess)"
                )
                return allowDeferredSuccess
            }
            return false
        }
    }

    private func shouldDeferCallKitAnswerAfterError(_ error: Error) -> Bool {
        if let callError = error as? CallRepositoryError {
            switch callError {
            case .backendUnavailable:
                return true
            case .groupCallsNotSupported, .callNotFound, .userNotFound, .callPermissionDenied, .callRequiresSavedContact, .invalidOperation:
                return false
            }
        }

        if let authError = error as? AuthRepositoryError {
            switch authError {
            case .backendUnavailable:
                return true
            case .invalidCredentials, .accountNotFound:
                return false
            default:
                return false
            }
        }

        if error is TimeoutError {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func waitForAnswerContext(
        callID: UUID,
        timeoutSeconds: TimeInterval
    ) async -> (UUID, any CallRepository)? {
        if currentUserID == nil,
           let preferredUserID = preferredIncomingUserIDByCallID[callID],
           repository != nil {
            currentUserID = preferredUserID
            callDebugLog("call.context.bootstrap.preferred call=\(callID.uuidString) user=\(preferredUserID.uuidString)")
        }
        await bootstrapCurrentUserContextIfNeeded(source: "wait_for_answer_context_initial")
        let deadline = Date.now.addingTimeInterval(max(timeoutSeconds, 0.5))
        while Date.now < deadline {
            if let currentUserID, let repository {
                return (currentUserID, repository)
            }
            await bootstrapCurrentUserContextIfNeeded(source: "wait_for_answer_context_retry")
            callDebugLog("callkit.answer.wait_context call=\(callID.uuidString)")
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    private func schedulePendingCallKitAnswerResolution(callID: UUID) {
        guard pendingCallKitAnswerResolutionTasks[callID] == nil else { return }

        pendingCallKitAnswerResolutionTasks[callID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pendingCallKitAnswerResolutionTasks.removeValue(forKey: callID)
            }

            for _ in 1 ... 80 {
                if Task.isCancelled {
                    return
                }
                if self.pendingCallKitAnswerCallIDs.contains(callID) == false {
                    return
                }
                await self.bootstrapCurrentUserContextIfNeeded(source: "pending_callkit_answer_fast_retry")
                await self.processPendingCallKitAnswersIfNeeded()
                if self.pendingCallKitAnswerCallIDs.contains(callID) == false {
                    self.callDebugLog("callkit.answer.pending.fast_resolved call=\(callID.uuidString)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
    }

    private func bootstrapCurrentUserContextIfNeeded(source: String) async {
        guard currentUserID == nil else { return }
        guard let resolvedUserID = await resolvedCurrentUserIDForBootstrap() else { return }
        currentUserID = resolvedUserID
        callDebugLog("call.context.bootstrap user=\(resolvedUserID.uuidString) source=\(source)")
    }

    private func resolvedCurrentUserIDForBootstrap(defaults: UserDefaults = .standard) async -> UUID? {
        if let data = defaults.data(forKey: "app_state.current_user"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }

        let sessions = await AuthSessionStore.shared.allSessions()
        if sessions.count == 1, let session = sessions.first {
            return session.userID
        }

        return nil
    }

    private func endCall(callID: UUID) async {
        guard let repository else {
            callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=missing_repository")
            return
        }

        var actingUserID = currentUserID
        var callSnapshot: InternetCall?
        if let activeCall, activeCall.id == callID {
            callSnapshot = activeCall
        } else if let resolved = await resolveCallContext(
            callID: callID,
            preferredUserID: currentUserID,
            repository: repository,
            requiredDirection: nil
        ) {
            actingUserID = resolved.userID
            callSnapshot = resolved.call
            if currentUserID != resolved.userID {
                currentUserID = resolved.userID
                callDebugLog("callkit.end.context.switched call=\(callID.uuidString) user=\(resolved.userID.uuidString)")
            }
            callDebugLog(
                "callkit.end.context.recovered call=\(callID.uuidString) state=\(resolved.call.state.rawValue)"
            )
        }

        guard let callSnapshot, let actingUserID else {
            callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=unresolved_context")
            return
        }

        if callSnapshot.state == .active,
           let lastCriticalAudioRouteLossAt,
           Date.now.timeIntervalSince(lastCriticalAudioRouteLossAt) <= routeLossEndIgnoreWindow {
            callDebugLog(
                "callkit.end.ignored call=\(callID.uuidString) reason=recent_audio_route_loss delta=\(String(format: "%.3f", Date.now.timeIntervalSince(lastCriticalAudioRouteLossAt)))"
            )
            return
        }

        let direction = callSnapshot.direction(for: actingUserID)
        let referenceDate = callSnapshot.answeredAt ?? callSnapshot.createdAt
        let elapsed = Date.now.timeIntervalSince(referenceDate)
        callDebugLog(
            "callkit.end.request call=\(callID.uuidString) state=\(callSnapshot.state.rawValue) direction=\(direction.rawValue) elapsed=\(String(format: "%.3f", elapsed)) local_answer_sent=\(sentAnswerCallIDs.contains(callID)) remote_answer_applied=\(remoteAnswerAppliedCallIDs.contains(callID))"
        )

        if callSnapshot.state == .active,
           direction == .incoming,
           sentAnswerCallIDs.contains(callID),
           remoteAnswerAppliedCallIDs.contains(callID) == false,
           elapsed <= callKitEarlyIncomingEndIgnoreWindow,
           lastObservedICEConnectionState != .connected,
           lastObservedICEConnectionState != .completed {
            callDebugLog(
                "callkit.end.ignored call=\(callID.uuidString) reason=spurious_early_end_after_accept elapsed=\(String(format: "%.3f", elapsed)) ice=\(lastObservedICEConnectionState.rawValue)"
            )
            return
        }

        if callSnapshot.state == .ringing, direction == .outgoing {
            guard locallyOriginatedOutgoingCallIDs.contains(callID) else {
                callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=non_local_outgoing")
                return
            }

            let startedAt = localOutgoingStartAtByCallID[callID] ?? callSnapshot.createdAt
            let elapsed = Date.now.timeIntervalSince(startedAt)
            if elapsed < 0.9 {
                callDebugLog(
                    "callkit.end.ignored call=\(callID.uuidString) reason=spurious_early_end elapsed=\(String(format: "%.3f", elapsed))"
                )
                return
            }
        }

        guard callSnapshot.state == .ringing || callSnapshot.state == .active else {
            if activeCall?.id == callID {
                await install(callSnapshot)
            }
            callDebugLog("callkit.end.ignored call=\(callID.uuidString) reason=already_terminal state=\(callSnapshot.state.rawValue)")
            return
        }

        do {
            let updatedCall: InternetCall
            localEndIntentCallIDs.insert(callID)
            if callSnapshot.state == .ringing, direction == .incoming {
                updatedCall = try await repository.rejectCall(callID, userID: actingUserID)
                callDebugLog("callkit.end.mapped_to_reject call=\(callID.uuidString)")
            } else {
                updatedCall = try await repository.endCall(callID, userID: actingUserID)
            }
            await install(updatedCall)
        } catch {
            localEndIntentCallIDs.remove(callID)
            callDebugLog("callkit.end.failed call=\(callID.uuidString) error=\(error)")
        }
    }

    private func resolveIceServers() async -> [WebRTCAudioCallEngine.ICEServer] {
        guard let baseURL = BackendConfiguration.currentBaseURL,
              let currentUserID else {
            return normalizedIceServersWithFallback(cachedIceServers)
        }

        if isIceConfigCacheFresh() {
            return normalizedIceServersWithFallback(cachedIceServers)
        }

        let fetchTask = Task { [weak self] in
            guard let self else { return [WebRTCAudioCallEngine.ICEServer]() }
            return await self.fetchIceServersFromBackend(baseURL: baseURL, currentUserID: currentUserID) ?? []
        }

        if let fetched = try? await runWithTimeout(seconds: iceConfigFastFetchTimeout, operation: {
            await fetchTask.value
        }),
            fetched.isEmpty == false
        {
            cachedIceServers = fetched
            cachedIceServersFetchedAt = .now
            callDebugLog(
                "ice-config.fast_fetch.success count=\(fetched.count) timeout_s=\(String(format: "%.2f", iceConfigFastFetchTimeout))"
            )
            return normalizedIceServersWithFallback(fetched)
        }

        callDebugLog(
            "ice-config.fast_fetch.timeout_or_failed timeout_s=\(String(format: "%.2f", iceConfigFastFetchTimeout)) using_cached_count=\(cachedIceServers.count)"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched = await fetchTask.value
            guard fetched.isEmpty == false else { return }
            self.cachedIceServers = fetched
            self.cachedIceServersFetchedAt = .now
            self.callDebugLog("ice-config.cache.async_updated count=\(fetched.count)")
        }

        return normalizedIceServersWithFallback(cachedIceServers)
    }

    private func primeIceServersCacheIfNeeded(reason: String) async {
        guard let baseURL = BackendConfiguration.currentBaseURL,
              let currentUserID else { return }
        guard isIceConfigCacheFresh() == false else { return }
        guard iceConfigWarmupTask == nil else { return }

        iceConfigWarmupTask = Task { [weak self] in
            guard let self else { return }
            let fetched = await self.fetchIceServersFromBackend(baseURL: baseURL, currentUserID: currentUserID) ?? []
            guard fetched.isEmpty == false else { return }
            self.cachedIceServers = fetched
            self.cachedIceServersFetchedAt = .now
            self.callDebugLog("ice-config.cache.warmed reason=\(reason) count=\(fetched.count)")
        }
        await iceConfigWarmupTask?.value
        iceConfigWarmupTask = nil
    }

    private func fetchIceServersFromBackend(
        baseURL: URL,
        currentUserID: UUID
    ) async -> [WebRTCAudioCallEngine.ICEServer]? {
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/calls/ice-config",
                method: "GET",
                userID: currentUserID
            )

            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode else {
                callDebugLog("ice-config.fetch.unexpected_status")
                return nil
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
            return servers
        } catch {
            callDebugLog("ice-config.fetch.failed error=\(error)")
            return nil
        }
    }

    private func normalizedIceServersWithFallback(_ raw: [WebRTCAudioCallEngine.ICEServer]) -> [WebRTCAudioCallEngine.ICEServer] {
        var servers = raw.isEmpty ? WebRTCAudioCallEngine.ICEServer.fallbackSet : raw
        if WebRTCAudioCallEngine.ICEServer.hasTURN(servers) == false {
            servers.append(.publicFallbackTURN)
            callDebugLog("ice-config.turn.missing -> appended_public_fallback_turn")
        }
        return servers
    }

    private func isIceConfigCacheFresh(referenceDate: Date = .now) -> Bool {
        guard let fetchedAt = cachedIceServersFetchedAt else { return false }
        return referenceDate.timeIntervalSince(fetchedAt) <= iceConfigCacheTTL
    }

    private func ensureCallMetrics(for callID: UUID) {
        guard callMetricsByID[callID] == nil else { return }
        let snapshot = NetworkReachabilityMonitor.shared.currentSnapshot
        callMetricsByID[callID] = CallRuntimeMetrics(
            callStartedAt: .now,
            selectedVideoProfile: currentVideoQualityProfile,
            networkSnapshotAtStart: snapshot
        )
        callDebugLog(
            "metrics.call.start call=\(callID.uuidString) profile=\(currentVideoQualityProfile.rawValue) \(networkSnapshotDescription(snapshot))"
        )
    }

    private func finalizeCallMetrics(for call: InternetCall) {
        guard let metrics = callMetricsByID.removeValue(forKey: call.id) else { return }
        let startedAt = call.answeredAt ?? call.createdAt
        let finishedAt = call.endedAt ?? Date.now
        let durationSeconds = max(finishedAt.timeIntervalSince(startedAt), 0)
        let mediaStartLatency = metrics.mediaStartedAt.map { $0.timeIntervalSince(metrics.callStartedAt) }
        let remoteAnswerLatency = metrics.remoteAnswerAppliedAt.map { $0.timeIntervalSince(metrics.callStartedAt) }
        let firstICEConnectedLatency = metrics.firstICEConnectedAt.map { $0.timeIntervalSince(metrics.callStartedAt) }
        let firstRemoteVideoLatency = metrics.firstRemoteVideoFrameAt.map { $0.timeIntervalSince(metrics.callStartedAt) }
        let startedNetwork = metrics.networkSnapshotAtStart.map(networkSnapshotDescription) ?? "unknown"
        callDebugLog(
            "metrics.call.summary call=\(call.id.uuidString) state=\(call.state.rawValue) duration_s=\(formatMetric(durationSeconds)) media_start_s=\(formatMetric(mediaStartLatency)) remote_answer_s=\(formatMetric(remoteAnswerLatency)) ice_connected_s=\(formatMetric(firstICEConnectedLatency)) remote_video_first_frame_s=\(formatMetric(firstRemoteVideoLatency)) video_toggle_s=\(formatMetric(metrics.lastVideoToggleLatency)) video_degrades=\(metrics.videoDegradeCount) video_profile=\(metrics.selectedVideoProfile.rawValue) network_start=\(startedNetwork)"
        )
    }

    private func formatMetric(_ value: TimeInterval?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
    }

    private func formatMetric(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
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

    private func callKitHandleValue(forRemoteUserID remoteUserID: UUID?, callID: UUID, displayName: String? = nil) -> String {
        let fallback = remoteUserID == nil ? "Prime Messaging call" : "Prime Messaging"
        return callKitReadableHandleValue(primary: displayName, fallback: fallback)
    }

    private func clearCallNotifications(callID: UUID) {
        Task { @MainActor in
            await LocalPushNotificationService.shared.clearCallNotifications(for: callID)
        }
    }

    private func attemptImmediateAnswerDispatchIfPossible(
        call: InternetCall,
        actingUserID: UUID,
        repository: any CallRepository,
        preferredOfferSDP: String? = nil,
        source: String
    ) async -> Bool {
        guard call.state == .active || call.state == .ringing else { return false }
        guard call.direction(for: actingUserID) == .incoming else { return false }
        guard sentAnswerCallIDs.contains(call.id) == false else { return true }

        if answerDispatchInProgressCallIDs.contains(call.id) {
            callDebugLog("answer.immediate.skip_inflight call=\(call.id.uuidString) source=\(source)")
            return false
        }

        var offerSDP: String?
        var offerSource = "none"
        for attempt in 1 ... immediateOfferWaitAttempts {
            if offerSDP == nil, let preferredOfferSDP {
                let trimmed = preferredOfferSDP.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    offerSDP = trimmed
                    offerSource = "preferred"
                }
            }

            if offerSDP == nil,
               let pendingOffer = pendingRemoteOfferByCallID[call.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               pendingOffer.isEmpty == false {
                offerSDP = pendingOffer
                offerSource = "pending_cache"
            }

            if offerSDP == nil {
                let snapshotOffer = call.latestRemoteOfferSDP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if snapshotOffer.isEmpty == false {
                    offerSDP = snapshotOffer
                    offerSource = "call_snapshot"
                }
            }

            if offerSDP == nil, attempt == 1 || attempt % 4 == 0 {
                do {
                    let events = try await runWithTimeout(seconds: immediateOfferFetchTimeout) {
                        try await repository.fetchEvents(callID: call.id, userID: actingUserID, sinceSequence: 0)
                    }
                    if let latestRemoteOffer = events
                        .filter({ $0.type == .offer && $0.senderID != actingUserID })
                        .max(by: { $0.sequence < $1.sequence }),
                       let sdp = latestRemoteOffer.sdp,
                       sdp.isEmpty == false {
                        offerSDP = sdp
                        offerSource = "events"
                    }
                } catch {
                    callDebugLog("answer.immediate.events_fetch_failed call=\(call.id.uuidString) source=\(source) attempt=\(attempt) error=\(error)")
                }
            }

            if offerSDP != nil {
                break
            }
            if attempt < immediateOfferWaitAttempts {
                callDebugLog("answer.immediate.wait_offer call=\(call.id.uuidString) source=\(source) attempt=\(attempt)")
                try? await Task.sleep(for: .milliseconds(Int(immediateOfferWaitDelayMs)))
            }
        }

        guard let resolvedOffer = offerSDP, resolvedOffer.isEmpty == false else {
            callDebugLog("answer.immediate.no_offer call=\(call.id.uuidString) source=\(source)")
            return false
        }

        answerDispatchInProgressCallIDs.insert(call.id)
        stopIncomingAnswerDispatchLoop(for: call.id)
        defer {
            answerDispatchInProgressCallIDs.remove(call.id)
        }

        do {
            callDebugLog("answer.immediate.start call=\(call.id.uuidString) source=\(source) offer_size=\(resolvedOffer.count) offer_source=\(offerSource)")
            let answerSDP: String
            if let cachedAnswer = pendingLocalAnswerByCallID[call.id],
               cachedAnswer.offerSDP == resolvedOffer {
                answerSDP = cachedAnswer.answerSDP
                callDebugLog(
                    "answer.immediate.cached_reuse call=\(call.id.uuidString) source=\(source) sdp_size=\(answerSDP.count)"
                )
            } else {
                try await ensureMediaSession(for: call)
                answerSDP = try await self.mediaEngine.applyRemoteOfferAndCreateAnswer(resolvedOffer)
                pendingLocalAnswerByCallID[call.id] = LocalAnswerPayload(
                    offerSDP: resolvedOffer,
                    answerSDP: answerSDP
                )
            }
            if let latestOffer = pendingRemoteOfferByCallID[call.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               latestOffer.isEmpty == false,
               latestOffer != resolvedOffer {
                callDebugLog(
                    "answer.immediate.restart_new_offer call=\(call.id.uuidString) source=\(source) latest_offer_size=\(latestOffer.count)"
                )
                pendingLocalAnswerByCallID.removeValue(forKey: call.id)
                startIncomingAnswerDispatchLoopIfNeeded(for: call)
                return false
            }
            _ = try await runWithTimeout(seconds: signalingAnswerSendTimeout) {
                try await repository.sendAnswer(answerSDP, in: call.id, userID: actingUserID)
            }
            sentAnswerCallIDs.insert(call.id)
            pendingRemoteOfferByCallID.removeValue(forKey: call.id)
            pendingLocalAnswerByCallID.removeValue(forKey: call.id)
            scheduleLocalICERetryLoopIfNeeded(for: call.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.flushPendingLocalICECandidates(for: call.id)
            }
            if let requestedAt = answerRequestedAtByCallID.removeValue(forKey: call.id) {
                let latency = Date.now.timeIntervalSince(requestedAt)
                callDebugLog("answer.latency call=\(call.id.uuidString) source=\(source) seconds=\(String(format: "%.3f", latency))")
            }
            callDebugLog("answer.sent.immediate call=\(call.id.uuidString) source=\(source) sdp_size=\(answerSDP.count)")
            return true
        } catch {
            callDebugLog("answer.immediate.failed call=\(call.id.uuidString) source=\(source) error=\(error)")
            startIncomingAnswerDispatchLoopIfNeeded(for: call)
            return false
        }
    }

    private func updateProximityMonitoringEnabled(_ enabled: Bool) {
        #if os(iOS) && canImport(UIKit)
        UIDevice.current.isProximityMonitoringEnabled = enabled
        #endif
    }

    private func isAppActiveForCallAudioDebug() -> Bool {
        #if os(iOS) && canImport(UIKit)
        if Thread.isMainThread {
            return UIApplication.shared.applicationState == .active
        }
        var isActive = false
        DispatchQueue.main.sync {
            isActive = UIApplication.shared.applicationState == .active
        }
        return isActive
        #else
        return true
        #endif
    }

    #if os(iOS) && canImport(UIKit)
    private func beginBackgroundTaskThreadSafe(named name: String) -> UIBackgroundTaskIdentifier {
        if Thread.isMainThread {
            return UIApplication.shared.beginBackgroundTask(withName: name) { }
        }
        var identifier: UIBackgroundTaskIdentifier = .invalid
        DispatchQueue.main.sync {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { }
        }
        return identifier
    }

    private func endBackgroundTaskThreadSafe(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(identifier)
            return
        }
        DispatchQueue.main.sync {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
    #endif

    private func updatePictureInPictureState(reason: String) {
        #if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.updatePictureInPictureState(reason: reason)
            }
            return
        }
        let shouldEnablePiP: Bool = {
            guard let activeCall else { return false }
            return activeCall.state == .active && isVideoEnabled
        }()

        pictureInPictureCoordinator.update(
            callID: activeCall?.id,
            shouldEnable: shouldEnablePiP,
            isRemoteVideoAvailable: isRemoteVideoAvailable,
            isLocalVideoEnabled: isVideoEnabled,
            reason: reason
        )
        #else
        _ = reason
        #endif
    }

    private func startPictureInPictureIfNeeded(reason: String) {
        #if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.startPictureInPictureIfNeeded(reason: reason)
            }
            return
        }
        guard let activeCall, activeCall.state == .active, isVideoEnabled else { return }
        pictureInPictureCoordinator.update(
            callID: activeCall.id,
            shouldEnable: true,
            isRemoteVideoAvailable: isRemoteVideoAvailable,
            isLocalVideoEnabled: isVideoEnabled,
            reason: reason
        )
        pictureInPictureCoordinator.startIfPossible(reason: reason)
        #else
        _ = reason
        #endif
    }

    private func stopPictureInPicture(reason: String) {
        #if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.stopPictureInPicture(reason: reason)
            }
            return
        }
        guard pictureInPictureCoordinator.hasLivePresentationState else { return }
        pictureInPictureCoordinator.stop(reason: reason)
        #else
        _ = reason
        #endif
    }

    private var pictureInPictureHasLiveState: Bool {
        #if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
        return pictureInPictureCoordinator.hasLivePresentationState
        #else
        return false
        #endif
    }

    private func routeDescription(_ route: AVAudioSessionRouteDescription?) -> String {
        guard let route else { return "inputs=[] outputs=[]" }
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    private func isBuiltInSpeakerRoute(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains(where: { $0.portType == .builtInSpeaker })
    }

    private func routeChangeReasonName(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown:
            return "unknown"
        case .newDeviceAvailable:
            return "new_device_available"
        case .oldDeviceUnavailable:
            return "old_device_unavailable"
        case .categoryChange:
            return "category_change"
        case .override:
            return "override"
        case .wakeFromSleep:
            return "wake_from_sleep"
        case .noSuitableRouteForCategory:
            return "no_suitable_route_for_category"
        case .routeConfigurationChange:
            return "route_configuration_change"
        @unknown default:
            return "unknown_future"
        }
    }

    private func interruptionTypeName(_ type: AVAudioSession.InterruptionType) -> String {
        switch type {
        case .began:
            return "began"
        case .ended:
            return "ended"
        @unknown default:
            return "unknown"
        }
    }

    private func interruptionReasonName(_ rawValue: UInt?) -> String {
        guard let rawValue else { return "none" }
        if #available(iOS 14.5, tvOS 14.5, *) {
            let reason = AVAudioSession.InterruptionReason(rawValue: rawValue) ?? .default
            switch reason {
            case .default:
                return "default"
            case .appWasSuspended:
                return "app_was_suspended"
            case .builtInMicMuted:
                return "built_in_mic_muted"
            case .routeDisconnected:
                return "route_disconnected"
            @unknown default:
                return "unknown"
            }
        }
        return "legacy"
    }

    private func handleApplicationWillResignActive() async {
        guard activeCall != nil || pictureInPictureHasLiveState else { return }
        callDebugLog("app.will_resign_active")
        startPictureInPictureIfNeeded(reason: "app_will_resign_active")
    }

    private func handleApplicationWillEnterForeground() async {
        let shouldHandleCallLifecycle = activeCall != nil
            || pendingPushCallIDs.isEmpty == false
            || pendingCallKitAnswerCallIDs.isEmpty == false
            || pictureInPictureHasLiveState
        guard shouldHandleCallLifecycle else { return }
        callDebugLog("app.will_enter_foreground")
        if pictureInPictureHasLiveState {
            stopPictureInPicture(reason: "app_will_enter_foreground")
        }
        await processPendingPushCallsIfNeeded()
        await processPendingCallKitAnswersIfNeeded()
        guard let activeCall,
              activeCall.state == .active else { return }

        await activateAudioIfNeeded()
        rebindMediaAudioSession(reason: "app_will_enter_foreground")
        if isVideoEnabled {
            do {
                try await mediaEngine.setVideoEnabled(true)
                callDebugLog("video.will_enter_foreground.revalidate call=\(activeCall.id.uuidString) enabled=true")
            } catch {
                callDebugLog("video.will_enter_foreground.revalidate.failed call=\(activeCall.id.uuidString) error=\(error)")
            }
        }
    }

    private func handleApplicationDidEnterBackground() async {
        guard let activeCall else { return }
        callDebugLog("app.did_enter_background call=\(activeCall.id.uuidString) state=\(activeCall.state.rawValue)")
        if activeCall.state == .active, isVideoEnabled {
            callDebugLog("video.background.state call=\(activeCall.id.uuidString) local_video_enabled=true")
            startPictureInPictureIfNeeded(reason: "app_did_enter_background")
        }
    }

    private func handleReachabilitySnapshot(_ snapshot: NetworkConnectionSnapshot) {
        callDebugLog("network.reachability \(networkSnapshotDescription(snapshot))")
        applyVideoQualityProfile(snapshot, reason: "reachability_change")
    }

    private func networkSnapshotDescription(_ snapshot: NetworkConnectionSnapshot) -> String {
        "satisfied=\(snapshot.isSatisfied) wifi=\(snapshot.usesWiFi) ethernet=\(snapshot.usesWiredEthernet) cellular=\(snapshot.usesCellular)"
    }

    private func resolvedVideoQualityProfile(
        for snapshot: NetworkConnectionSnapshot
    ) -> WebRTCAudioCallEngine.VideoQualityProfile {
        if snapshot.usesCellular {
            return .low
        }
        if snapshot.usesWiFi || snapshot.usesWiredEthernet {
            return .high
        }
        if snapshot.isSatisfied {
            return .medium
        }
        return .low
    }

    private func applyVideoQualityProfile(_ snapshot: NetworkConnectionSnapshot, reason: String) {
        let nextProfile = resolvedVideoQualityProfile(for: snapshot)
        guard currentVideoQualityProfile != nextProfile else { return }

        let previousProfile = currentVideoQualityProfile
        currentVideoQualityProfile = nextProfile
        mediaEngine.setVideoQualityProfile(nextProfile)
        if let callID = activeCall?.id, var metrics = callMetricsByID[callID] {
            metrics.selectedVideoProfile = nextProfile
            callMetricsByID[callID] = metrics
        }
        callDebugLog(
            "video.profile.selected reason=\(reason) from=\(previousProfile.rawValue) to=\(nextProfile.rawValue) \(networkSnapshotDescription(snapshot))"
        )
    }

    private func handleICEConnectionStateChange(_ state: WebRTCAudioCallEngine.ICEConnectionState) {
        let previousState = lastObservedICEConnectionState
        lastObservedICEConnectionState = state
        guard let activeCall, activeCall.state == .active else {
            cancelVideoDegradeTask(reason: "ice_\(state.rawValue)_inactive_call")
            return
        }
        let transitionedToConnected =
            (state == .connected || state == .completed)
            && (previousState != .connected && previousState != .completed)
        if transitionedToConnected,
           var metrics = callMetricsByID[activeCall.id],
           metrics.firstICEConnectedAt == nil {
            metrics.firstICEConnectedAt = .now
            callMetricsByID[activeCall.id] = metrics
            let latency = Date.now.timeIntervalSince(metrics.callStartedAt)
            callDebugLog(
                "ice.connected.first_latency call=\(activeCall.id.uuidString) seconds=\(String(format: "%.3f", latency))"
            )
        }
        if transitionedToConnected,
           let currentUserID,
           activeCall.direction(for: currentUserID) == .incoming,
           isCallKitAudioSessionActive == false {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activateAudioIfNeeded()
                self.scheduleCallKitAudioFallbackIfNeeded(for: activeCall, reason: "ice_connected_revalidate")
                self.rebindMediaAudioSession(reason: "ice_connected_revalidate")
            }
        }

        switch state {
        case .connected, .completed, .checking:
            cancelVideoDegradeTask(reason: "ice_\(state.rawValue)")
        case .failed, .disconnected:
            scheduleVideoDegradeTask(callID: activeCall.id, reason: "ice_\(state.rawValue)")
        case .closed:
            cancelVideoDegradeTask(reason: "ice_closed")
        case .new, .unknown:
            break
        }
    }

    private func scheduleVideoDegradeTask(callID: UUID, reason: String) {
        guard isVideoEnabled else { return }
        guard videoDegradeTask == nil else { return }

        callDebugLog(
            "video.degrade.scheduled call=\(callID.uuidString) reason=\(reason) timeout_s=\(String(format: "%.1f", videoDegradeTimeout))"
        )
        videoDegradeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(videoDegradeTimeout))
            guard Task.isCancelled == false else { return }
            defer {
                self.videoDegradeTask = nil
            }

            guard let activeCall = self.activeCall,
                  activeCall.id == callID,
                  activeCall.state == .active else {
                return
            }
            guard self.isVideoEnabled else { return }

            let state = self.lastObservedICEConnectionState
            guard state == .failed || state == .disconnected else {
                self.callDebugLog(
                    "video.degrade.skip_recovered call=\(callID.uuidString) state=\(state.rawValue)"
                )
                return
            }

            do {
                try await self.mediaEngine.setVideoEnabled(false)
                self.isVideoEnabled = false
                self.isUsingFrontCamera = self.mediaEngine.isUsingFrontCamera
                if var metrics = self.callMetricsByID[callID] {
                    metrics.videoDegradeCount += 1
                    self.callMetricsByID[callID] = metrics
                }
                self.callDebugLog(
                    "video.degrade.applied call=\(callID.uuidString) reason=\(reason) state=\(state.rawValue)"
                )
            } catch {
                self.callDebugLog(
                    "video.degrade.failed call=\(callID.uuidString) reason=\(reason) error=\(error)"
                )
            }
        }
    }

    private func cancelVideoDegradeTask(reason: String) {
        guard videoDegradeTask != nil else { return }
        videoDegradeTask?.cancel()
        videoDegradeTask = nil
        callDebugLog("video.degrade.cancelled reason=\(reason)")
    }

    private func handleAudioRouteChange(_ notification: Notification) async {
        guard let activeCall, activeCall.state == .active else { return }

        let userInfo = notification.userInfo ?? [:]
        let reasonRaw = (userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) ?? .unknown
        let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        callDebugLog(
            "audio.route.change call=\(activeCall.id.uuidString) reason=\(routeChangeReasonName(reason)) previous=\(routeDescription(previousRoute))"
        )

        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let speakerRouteSelectedBySystem = isBuiltInSpeakerRoute(currentRoute)
        if speakerRouteSelectedBySystem != isSpeakerEnabled {
            isSpeakerEnabled = speakerRouteSelectedBySystem
            callDebugLog(
                "audio.route.sync_speaker call=\(activeCall.id.uuidString) enabled=\(isSpeakerEnabled) source=system_route"
            )
        }

        let isCriticalRouteLoss = reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory
        if isCriticalRouteLoss {
            lastCriticalAudioRouteLossAt = .now
        }

        let shouldReconfigureAudioPath =
            reason == .newDeviceAvailable
            || reason == .oldDeviceUnavailable
            || reason == .routeConfigurationChange
            || reason == .noSuitableRouteForCategory
            || reason == .wakeFromSleep

        if shouldReconfigureAudioPath {
            await activateAudioIfNeeded()
            rebindMediaAudioSession(reason: "route_\(routeChangeReasonName(reason))")
        } else {
            callDebugLog("audio.route.change.skip_reconfigure call=\(activeCall.id.uuidString) reason=\(routeChangeReasonName(reason))")
        }
        #if !os(tvOS)
        callDebugLog("audio.route.current \(await audioSessionCoordinator.currentAudioRouteDescription())")
        #endif
    }

    private func handleAudioInterruption(_ notification: Notification) async {
        guard let activeCall, activeCall.state == .active else { return }
        guard
            let userInfo = notification.userInfo,
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        let optionsRaw = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt

        callDebugLog(
            "audio.interruption call=\(activeCall.id.uuidString) type=\(interruptionTypeName(type)) should_resume=\(options.contains(.shouldResume)) reason=\(interruptionReasonName(reasonRaw))"
        )

        switch type {
        case .began:
            // Do not proactively deactivate WebRTC audio for short route/interruption
            // transitions (e.g. AirPods in/out). Let CallKit/system drive activation.
            callDebugLog("audio.interruption.began keep_webrtc_audio_state=true")
        case .ended:
            await activateAudioIfNeeded()
            rebindMediaAudioSession(reason: "interruption_ended")
            if isVideoEnabled {
                do {
                    try await mediaEngine.setVideoEnabled(true)
                    callDebugLog("video.interruption.revalidate enabled=true")
                } catch {
                    callDebugLog("video.interruption.revalidate.failed error=\(error)")
                }
            }
        @unknown default:
            break
        }
    }

    private func handleAudioMediaServicesReset() async {
        guard let activeCall, activeCall.state == .active else { return }
        callDebugLog("audio.media_services.reset call=\(activeCall.id.uuidString) -> reactivating")
        await activateAudioIfNeeded()
        rebindMediaAudioSession(reason: "media_services_reset")
    }

    private func rebindMediaAudioSession(reason: String) {
        guard let activeCall, activeCall.state == .active else { return }
        let isIncomingDirection: Bool = {
            guard let currentUserID else { return false }
            return activeCall.direction(for: currentUserID) == .incoming
        }()
        if mediaEngine.isAutomaticAudioSessionFallbackEnabled,
           isIncomingDirection,
           callKitCoordinator.isTracking(callID: activeCall.id),
           isCallKitAudioSessionActive == false {
            let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
            mediaEngine.notifyAudioSessionActivated(using: session)
            mediaEngine.setMuted(isMuted)
            callDebugLog(
                "audio.media.rebound.auto_mode_keep call=\(activeCall.id.uuidString) reason=\(reason) muted=\(isMuted)"
            )
            return
        }
        if shouldDeferMediaRebindForPendingCallKitActivation(call: activeCall) {
            callDebugLog(
                "audio.media.rebound.skip_pending_callkit_activation call=\(activeCall.id.uuidString) reason=\(reason)"
            )
            return
        }
        if let lastAudioRebindAt,
           Date.now.timeIntervalSince(lastAudioRebindAt) < minAudioRebindInterval {
            callDebugLog(
                "audio.media.rebound.skip_throttle call=\(activeCall.id.uuidString) reason=\(reason) delta=\(String(format: "%.3f", Date.now.timeIntervalSince(lastAudioRebindAt)))"
            )
            return
        }
        lastAudioRebindAt = .now
        let session = activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
        mediaEngine.notifyAudioSessionActivated(using: session)
        mediaEngine.setMuted(isMuted)
        callDebugLog(
            "audio.media.rebound call=\(activeCall.id.uuidString) reason=\(reason) muted=\(isMuted)"
        )
    }

    private func shouldDeferMediaRebindForPendingCallKitActivation(call: InternetCall) -> Bool {
        if mediaEngine.isAutomaticAudioSessionFallbackEnabled {
            return false
        }
        guard isCallKitTrackingEffective(for: call.id) else {
            return false
        }
        guard isCallKitAudioSessionActive == false else {
            return false
        }
        guard let currentUserID, call.direction(for: currentUserID) == .incoming else {
            return false
        }
        #if !os(tvOS)
        return AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
        #else
        return true
        #endif
    }

    private func isCallKitTrackingEffective(for callID: UUID) -> Bool {
        guard callKitCoordinator.isTracking(callID: callID) else { return false }
        return callKitAudioBypassCallIDs.contains(callID) == false
    }

    private func cancelCallKitAudioFallback(for callID: UUID, reason: String) {
        guard let task = callKitAudioFallbackTasks.removeValue(forKey: callID) else { return }
        task.cancel()
        callDebugLog("audio.callkit_fallback.cancelled call=\(callID.uuidString) reason=\(reason)")
    }

    private func scheduleCallKitAudioFallbackIfNeeded(for call: InternetCall, reason: String) {
        guard call.state == .active else { return }
        guard let currentUserID, call.direction(for: currentUserID) == .incoming else { return }
        guard isCallKitAudioSessionActive == false else { return }

        if let existing = callKitAudioFallbackTasks[call.id] {
            guard existing.isCancelled else { return }
            callKitAudioFallbackTasks.removeValue(forKey: call.id)
        }

        callDebugLog("audio.callkit_fallback.scheduled call=\(call.id.uuidString) reason=\(reason)")
        callKitAudioFallbackTasks[call.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.callKitAudioFallbackTasks.removeValue(forKey: call.id)
            }

            for attempt in 1 ... self.callKitAudioFallbackMaxAttempts {
                if Task.isCancelled {
                    return
                }
                if attempt > 1 {
                    try? await Task.sleep(for: .milliseconds(self.callKitAudioFallbackAttemptDelayMs))
                }

                guard let activeCall = self.activeCall,
                      activeCall.id == call.id,
                      activeCall.state == .active else {
                    return
                }
                if self.isCallKitAudioSessionActive {
                    self.callDebugLog("audio.callkit_fallback.skip_callkit_active call=\(call.id.uuidString) attempt=\(attempt)")
                    return
                }

                let appActive = self.isAppActiveForCallAudioDebug()
                let trackedByCallKit = self.isCallKitTrackingEffective(for: call.id)
                do {
                    var hasMicPermission: Bool
                    var sessionForActivation: AVAudioSession

                    if trackedByCallKit {
                        if attempt <= self.callKitAudioFallbackWaitAttemptsBeforeSalvage {
                            self.callDebugLog(
                                "audio.callkit_fallback.wait_callkit_didActivate call=\(call.id.uuidString) attempt=\(attempt) app_active=\(appActive) tracked=true"
                            )
                            continue
                        }

                        if self.mediaEngine.isAutomaticAudioSessionFallbackEnabled == false {
                            self.mediaEngine.enableAutomaticAudioSessionFallback(
                                reason: "callkit_missing_didActivate_wait_attempt_\(attempt)"
                            )
                        }
                        self.callDebugLog(
                            "audio.callkit_fallback.auto_webrtc_enabled call=\(call.id.uuidString) attempt=\(attempt) reason=await_callkit_didActivate"
                        )
                        self.rebindMediaAudioSession(
                            reason: appActive ? "callkit_fallback_auto_webrtc_wait_fg" : "callkit_fallback_auto_webrtc_wait_bg"
                        )

                        let shouldAttemptSalvageActivate =
                            appActive
                            && (
                                attempt == self.callKitAudioFallbackWaitAttemptsBeforeSalvage + 1
                                || attempt % self.callKitAudioFallbackSalvageEveryAttempts == 0
                                || self.lastObservedICEConnectionState == .connected
                                || self.lastObservedICEConnectionState == .completed
                            )
                        guard shouldAttemptSalvageActivate else {
                            continue
                        }

                        hasMicPermission = try await self.audioSessionCoordinator.forceActivateForCallKitFallback(
                            speakerEnabled: self.isSpeakerEnabled
                        )
                        sessionForActivation = AVAudioSession.sharedInstance()
                        self.callDebugLog(
                            "audio.callkit_fallback.salvage_local_activate call=\(call.id.uuidString) attempt=\(attempt) app_active=true ice=\(self.lastObservedICEConnectionState.rawValue)"
                        )
                    } else if appActive {
                        try await self.audioSessionCoordinator.activate(
                            speakerEnabled: self.isSpeakerEnabled
                        )
                        hasMicPermission = true
                        sessionForActivation = AVAudioSession.sharedInstance()
                    } else {
                        let session = self.activeCallKitAudioSession ?? AVAudioSession.sharedInstance()
                        hasMicPermission = try await self.audioSessionCoordinator.configureActivatedCallKitSession(
                            session,
                            speakerEnabled: self.isSpeakerEnabled
                        )
                        sessionForActivation = session
                        #if !os(tvOS)
                        if session.currentRoute.inputs.isEmpty {
                            self.callDebugLog(
                                "audio.callkit_fallback.wait_callkit_didActivate call=\(call.id.uuidString) attempt=\(attempt) app_active=false tracked=false"
                            )
                            continue
                        }
                        #endif
                    }

                    #if !os(tvOS)
                    if sessionForActivation.currentRoute.inputs.isEmpty {
                        self.callDebugLog(
                            "audio.callkit_fallback.local_activate.no_input call=\(call.id.uuidString) attempt=\(attempt)"
                        )
                        if self.mediaEngine.isAutomaticAudioSessionFallbackEnabled == false {
                            self.mediaEngine.enableAutomaticAudioSessionFallback(
                                reason: "callkit_missing_didActivate_no_input_attempt_\(attempt)"
                            )
                        }
                        self.callDebugLog(
                            "audio.callkit_fallback.auto_webrtc_enabled call=\(call.id.uuidString) attempt=\(attempt) reason=no_input"
                        )
                        self.rebindMediaAudioSession(reason: "callkit_fallback_auto_webrtc")
                        continue
                    }
                    #endif

                    self.mediaEngine.notifyAudioSessionActivated(using: sessionForActivation)
                    self.mediaEngine.setMuted(self.isMuted)
                    if trackedByCallKit && self.isCallKitAudioSessionActive == false {
                        self.isCallKitAudioSessionActive = true
                        self.activeCallKitAudioSession = sessionForActivation
                        self.callDebugLog("audio.callkit_fallback.assume_active call=\(call.id.uuidString) source=local_activation")
                    }
                    #if !os(tvOS)
                    self.callDebugLog("audio.route.callkit_fallback \(await self.audioSessionCoordinator.currentAudioRouteDescription())")
                    self.callDebugLog("audio.session.snapshot.callkit_fallback \(await self.audioSessionCoordinator.audioSessionSnapshotDescription())")
                    #endif
                    self.callDebugLog(
                        "audio.callkit_fallback.activated call=\(call.id.uuidString) attempt=\(attempt) app_active=\(appActive) tracked=\(trackedByCallKit) mic_permission=\(hasMicPermission)"
                    )
                    self.rebindMediaAudioSession(reason: "callkit_fallback")
                    return
                } catch {
                    let nsError = error as NSError
                    if trackedByCallKit,
                       nsError.domain == NSOSStatusErrorDomain,
                       (nsError.code == 1701737535 || nsError.code == 561017449) {
                        if appActive, attempt >= self.callKitAudioFallbackBypassAfterAttempt {
                            if self.callKitAudioBypassCallIDs.contains(call.id) == false {
                                self.callKitAudioBypassCallIDs.insert(call.id)
                                self.callDebugLog(
                                    "audio.callkit_fallback.bypass_enabled call=\(call.id.uuidString) attempt=\(attempt) reason=activation_failed"
                                )
                            }
                        }
                        if self.mediaEngine.isAutomaticAudioSessionFallbackEnabled == false {
                            self.mediaEngine.enableAutomaticAudioSessionFallback(
                                reason: "callkit_missing_didActivate_activation_failed_attempt_\(attempt)"
                            )
                        }
                        self.callDebugLog(
                            "audio.callkit_fallback.auto_webrtc_enabled call=\(call.id.uuidString) attempt=\(attempt) error=\(nsError)"
                        )
                        self.rebindMediaAudioSession(reason: "callkit_fallback_auto_webrtc")
                        continue
                    }
                    self.callDebugLog(
                        "audio.callkit_fallback.retry call=\(call.id.uuidString) attempt=\(attempt) error=\(error)"
                    )
                }
            }

            self.callDebugLog("audio.callkit_fallback.give_up call=\(call.id.uuidString)")
        }
    }

    private func handleApplicationDidBecomeActive() async {
        await processPendingPushCallsIfNeeded()
        await processPendingCallKitAnswersIfNeeded()
        guard let activeCall,
              activeCall.state == .active else { return }

        callDebugLog("app.active.revalidate call=\(activeCall.id.uuidString)")
        await activateAudioIfNeeded()
        if isVideoEnabled {
            do {
                try await mediaEngine.setVideoEnabled(true)
                callDebugLog("video.active.revalidate call=\(activeCall.id.uuidString) enabled=true")
            } catch {
                callDebugLog("video.active.revalidate.failed call=\(activeCall.id.uuidString) error=\(error)")
            }
        }

        guard let currentUserID,
              let repository,
              activeCall.direction(for: currentUserID) == .incoming,
              sentAnswerCallIDs.contains(activeCall.id) == false else {
            return
        }

        _ = await attemptImmediateAnswerDispatchIfPossible(
            call: activeCall,
            actingUserID: currentUserID,
            repository: repository,
            source: "app_active_revalidate"
        )
    }

    private func ensureIncomingAnswerDispatched(callID: UUID) async -> Bool {
        guard let repository else { return false }
        let resolvedContext = await resolveCallContext(
            callID: callID,
            preferredUserID: preferredIncomingUserIDByCallID[callID] ?? currentUserID,
            repository: repository,
            requiredDirection: .incoming
        )

        var actingUserID: UUID
        if let resolvedContext {
            actingUserID = resolvedContext.userID
            if currentUserID != actingUserID {
                currentUserID = actingUserID
                callDebugLog(
                    "answer.accept_flow.context.switched call=\(callID.uuidString) new=\(actingUserID.uuidString)"
                )
            }
            if activeCall?.id != callID {
                await install(resolvedContext.call)
            }
        } else if let activeCall,
                  activeCall.id == callID,
                  let currentUserID,
                  activeCall.direction(for: currentUserID) == .incoming,
                  isTerminalState(activeCall.state) == false {
            actingUserID = currentUserID
            callDebugLog(
                "answer.accept_flow.context.fallback_active call=\(callID.uuidString) user=\(currentUserID.uuidString)"
            )
        } else {
            callDebugLog("answer.accept_flow.context.unresolved call=\(callID.uuidString)")
            return false
        }

        guard sentAnswerCallIDs.contains(callID) == false else { return true }

        #if os(iOS) && canImport(UIKit)
        let backgroundTaskID = beginBackgroundTaskThreadSafe(
            named: "pm.call.answer.\(callID.uuidString)"
        )
        #endif
        defer {
            #if os(iOS) && canImport(UIKit)
            if backgroundTaskID != .invalid {
                endBackgroundTaskThreadSafe(backgroundTaskID)
            }
            #endif
        }

        for attempt in 1 ... 120 {
            if Task.isCancelled {
                callDebugLog("answer.accept_flow.cancelled call=\(callID.uuidString)")
                return false
            }
            if answerDispatchInProgressCallIDs.contains(callID) {
                callDebugLog("answer.accept_flow.wait_inflight call=\(callID.uuidString) attempt=\(attempt)")
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            let waitBackoffMs = attempt <= 8 ? 120 : 250
            let retryBackoffMs = attempt <= 8 ? 180 : 320

            if let activeCall,
               activeCall.id == callID,
               isTerminalState(activeCall.state) {
                callDebugLog(
                    "answer.accept_flow.stop_terminal_local call=\(callID.uuidString) state=\(activeCall.state.rawValue)"
                )
                return false
            }

            if sentAnswerCallIDs.contains(callID) {
                return true
            }

            do {
                let latestCall: InternetCall
                let fetchUserID = actingUserID
                do {
                    latestCall = try await runWithTimeout(seconds: callContextResolvePerUserTimeout) {
                        try await repository.fetchCall(callID, for: fetchUserID)
                    }
                } catch {
                    if let localActiveCall = activeCall,
                       localActiveCall.id == callID,
                       isTerminalState(localActiveCall.state) == false,
                       localActiveCall.direction(for: fetchUserID) == .incoming {
                        latestCall = localActiveCall
                        callDebugLog(
                            "answer.accept_flow.fetch_call_fallback_active call=\(callID.uuidString) attempt=\(attempt) user=\(fetchUserID.uuidString) error=\(error)"
                        )
                    } else {
                        throw error
                    }
                }
                if isTerminalState(latestCall.state) {
                    callDebugLog("answer.accept_flow.stop_terminal_state call=\(callID.uuidString) state=\(latestCall.state.rawValue)")
                    return false
                }
                guard latestCall.state == .active || latestCall.state == .ringing else {
                    callDebugLog("answer.accept_flow.wait_state call=\(callID.uuidString) state=\(latestCall.state.rawValue) attempt=\(attempt)")
                    try? await Task.sleep(for: .milliseconds(waitBackoffMs))
                    continue
                }
                guard latestCall.direction(for: actingUserID) == .incoming else {
                    callDebugLog(
                        "answer.accept_flow.retry_context_for_direction call=\(callID.uuidString) attempt=\(attempt) current_user=\(actingUserID.uuidString)"
                    )
                    if let recovered = await resolveCallContext(
                        callID: callID,
                        preferredUserID: preferredIncomingUserIDByCallID[callID] ?? actingUserID,
                        repository: repository,
                        requiredDirection: .incoming
                    ) {
                        actingUserID = recovered.userID
                        if currentUserID != actingUserID {
                            currentUserID = actingUserID
                            callDebugLog(
                                "answer.accept_flow.context.recovered call=\(callID.uuidString) new=\(actingUserID.uuidString)"
                            )
                        }
                        if activeCall?.id != callID {
                            await install(recovered.call)
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    callDebugLog("answer.accept_flow.skip_non_incoming call=\(callID.uuidString)")
                    return false
                }
                let snapshotOffer = latestCall.latestRemoteOfferSDP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var resolvedOfferSDP = snapshotOffer.isEmpty ? nil : snapshotOffer
                var resolvedOfferSequence = latestCall.latestRemoteOfferSequence ?? -1
                var resolvedOfferSource = "snapshot"

                if resolvedOfferSDP == nil,
                   let pendingOffer = pendingRemoteOfferByCallID[callID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   pendingOffer.isEmpty == false {
                    resolvedOfferSDP = pendingOffer
                    resolvedOfferSource = "pending_cache"
                }

                if resolvedOfferSDP == nil {
                    let eventFetchUserID = actingUserID
                    let events = try await runWithTimeout(seconds: immediateOfferFetchTimeout) {
                        try await repository.fetchEvents(
                            callID: callID,
                            userID: eventFetchUserID,
                            sinceSequence: 0
                        )
                    }
                    callDebugLog("answer.accept_flow.events call=\(callID.uuidString) attempt=\(attempt) count=\(events.count)")
                    if let latestRemoteOffer = events
                        .filter({ $0.type == .offer && $0.senderID != eventFetchUserID })
                        .max(by: { $0.sequence < $1.sequence }),
                       let offerSDP = latestRemoteOffer.sdp,
                       offerSDP.isEmpty == false {
                        resolvedOfferSDP = offerSDP
                        resolvedOfferSequence = latestRemoteOffer.sequence
                        resolvedOfferSource = "events"
                    }
                }

                guard let offerSDP = resolvedOfferSDP, offerSDP.isEmpty == false else {
                    callDebugLog("answer.accept_flow.wait_offer call=\(callID.uuidString) attempt=\(attempt)")
                    try? await Task.sleep(for: .milliseconds(waitBackoffMs))
                    continue
                }

                callDebugLog(
                    "answer.accept_flow.offer_source call=\(callID.uuidString) attempt=\(attempt) source=\(resolvedOfferSource) seq=\(resolvedOfferSequence) sdp_size=\(offerSDP.count)"
                )

                #if !os(tvOS)
                let canPromptMicrophone = {
                    #if os(iOS) && canImport(UIKit)
                    isAppActiveForCallAudioDebug()
                    #else
                    true
                    #endif
                }()
                let hasMicPermission = try await audioSessionCoordinator.ensureMicrophonePermissionGranted(
                    canPrompt: canPromptMicrophone
                )
                if hasMicPermission == false {
                    callDebugLog(
                        "answer.accept_flow.microphone_not_granted call=\(callID.uuidString) attempt=\(attempt) canPrompt=\(canPromptMicrophone) status=\(await audioSessionCoordinator.microphonePermissionStatusDescription()) continue_signaling=true"
                    )
                } else {
                    callDebugLog(
                        "answer.accept_flow.microphone_granted call=\(callID.uuidString) attempt=\(attempt) status=\(await audioSessionCoordinator.microphonePermissionStatusDescription())"
                    )
                }
                #endif

                let answerSDP: String
                if let cachedAnswer = pendingLocalAnswerByCallID[callID],
                   cachedAnswer.offerSDP == offerSDP {
                    answerSDP = cachedAnswer.answerSDP
                    callDebugLog(
                        "answer.accept_flow.cached_reuse call=\(callID.uuidString) attempt=\(attempt) sdp_size=\(answerSDP.count)"
                    )
                } else {
                    try await ensureMediaSession(for: latestCall)
                    do {
                        answerSDP = try await self.mediaEngine.applyRemoteOfferAndCreateAnswer(offerSDP)
                        pendingLocalAnswerByCallID[callID] = LocalAnswerPayload(
                            offerSDP: offerSDP,
                            answerSDP: answerSDP
                        )
                    } catch {
                        callDebugLog("answer.accept_flow.apply_failed call=\(callID.uuidString) attempt=\(attempt) error=\(error)")
                        throw error
                    }
                }
                if let latestOffer = pendingRemoteOfferByCallID[callID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   latestOffer.isEmpty == false,
                   latestOffer != offerSDP {
                    callDebugLog(
                        "answer.accept_flow.restart_new_offer call=\(callID.uuidString) attempt=\(attempt) latest_offer_size=\(latestOffer.count)"
                    )
                    pendingLocalAnswerByCallID.removeValue(forKey: callID)
                    try? await Task.sleep(for: .milliseconds(waitBackoffMs))
                    continue
                }

                callDebugLog("answer.accept_flow.send call=\(callID.uuidString) attempt=\(attempt) sdp_size=\(answerSDP.count)")
                let answerUserID = actingUserID
                _ = try await runWithTimeout(seconds: signalingAnswerSendTimeout) {
                    try await repository.sendAnswer(answerSDP, in: callID, userID: answerUserID)
                }
                sentAnswerCallIDs.insert(callID)
                pendingLocalAnswerByCallID.removeValue(forKey: callID)
                scheduleLocalICERetryLoopIfNeeded(for: callID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.flushPendingLocalICECandidates(for: callID)
                }
                if let requestedAt = answerRequestedAtByCallID.removeValue(forKey: callID) {
                    let latency = Date.now.timeIntervalSince(requestedAt)
                    callDebugLog("answer.latency call=\(callID.uuidString) source=accept_flow seconds=\(String(format: "%.3f", latency))")
                }
                callDebugLog(
                    "answer.sent.accept_flow call=\(callID.uuidString) seq=\(resolvedOfferSequence) source=\(resolvedOfferSource) attempt=\(attempt)"
                )
                return true
            } catch {
                if Task.isCancelled {
                    callDebugLog("answer.accept_flow.cancelled call=\(callID.uuidString) attempt=\(attempt)")
                    return false
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    callDebugLog("answer.accept_flow.stop_url_cancelled call=\(callID.uuidString) attempt=\(attempt)")
                    return false
                }
                if let nsError = error as NSError?,
                   nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorCancelled {
                    callDebugLog("answer.accept_flow.stop_nsurl_cancelled call=\(callID.uuidString) attempt=\(attempt)")
                    return false
                }
                if let repositoryError = error as? CallRepositoryError,
                   case .callNotFound = repositoryError {
                    callDebugLog("answer.accept_flow.stop_call_missing call=\(callID.uuidString) attempt=\(attempt)")
                    return false
                }
                callDebugLog("answer.accept_flow.retry call=\(callID.uuidString) attempt=\(attempt) error=\(error)")
            }

            try? await Task.sleep(for: .milliseconds(retryBackoffMs))
        }

        callDebugLog("answer.accept_flow.give_up call=\(callID.uuidString)")
        answerRequestedAtByCallID.removeValue(forKey: callID)
        return false
    }

    private func resolveCallContext(
        callID: UUID,
        preferredUserID: UUID?,
        repository: any CallRepository,
        requiredDirection: InternetCallDirection? = nil
    ) async -> (userID: UUID, call: InternetCall)? {
        var candidateUserIDs: [UUID] = []
        if let preferredUserID {
            candidateUserIDs.append(preferredUserID)
        }
        let storedSessions = await AuthSessionStore.shared.allSessions()
        for session in storedSessions where candidateUserIDs.contains(session.userID) == false {
            candidateUserIDs.append(session.userID)
        }

        for candidateUserID in candidateUserIDs {
            guard let call = try? await runWithTimeout(seconds: callContextResolvePerUserTimeout, operation: {
                try await repository.fetchCall(callID, for: candidateUserID)
            }) else {
                continue
            }
            guard let direction = callDirection(for: call, userID: candidateUserID) else {
                continue
            }
            if let requiredDirection, direction != requiredDirection {
                continue
            }
            return (candidateUserID, call)
        }
        return nil
    }

    private func callDirection(for call: InternetCall, userID: UUID) -> InternetCallDirection? {
        if idsEqual(call.callerID, userID) {
            return .outgoing
        }
        if idsEqual(call.calleeID, userID) {
            return .incoming
        }
        return nil
    }

    private func idsEqual(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.caseInsensitiveCompare(rhs.uuidString) == .orderedSame
    }

    private func startIncomingAnswerDispatchLoopIfNeeded(for call: InternetCall) {
        guard let currentUserID else { return }
        guard call.state == .active else { return }
        guard call.direction(for: currentUserID) == .incoming else { return }
        guard sentAnswerCallIDs.contains(call.id) == false else { return }
        guard incomingImmediateAnswerPendingCallIDs.contains(call.id) == false else {
            callDebugLog("answer.dispatch.loop.skip_immediate_pending call=\(call.id.uuidString)")
            return
        }
        guard incomingAnswerDispatchTasks[call.id] == nil else { return }

        callDebugLog("answer.dispatch.loop.start call=\(call.id.uuidString)")
        incomingAnswerDispatchTasks[call.id] = Task { [weak self] in
            guard let self else { return }
            let didDispatch = await self.ensureIncomingAnswerDispatched(callID: call.id)
            await MainActor.run {
                self.callDebugLog("answer.dispatch.loop.stop call=\(call.id.uuidString) success=\(didDispatch)")
                self.incomingAnswerDispatchTasks.removeValue(forKey: call.id)
            }
        }
    }

    private func ensureRemoteVideoWatchdogRunning() {
        guard remoteVideoWatchdogTask == nil else { return }
        remoteVideoWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.activeCall?.state != .active {
                    self.isRemoteVideoAvailable = false
                    self.remoteVideoLastFrameAt = nil
                    break
                }
                if let lastFrame = self.remoteVideoLastFrameAt,
                   Date.now.timeIntervalSince(lastFrame) > self.remoteVideoFrameTimeout,
                   self.isRemoteVideoAvailable {
                    self.isRemoteVideoAvailable = false
                    self.callDebugLog("video.remote.frame_timeout hidden=true")
                    self.updatePictureInPictureState(reason: "remote_video_watchdog_timeout")
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
            self.remoteVideoWatchdogTask = nil
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

    private func runWithTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = UInt64(max(seconds, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: duration)
                throw TimeoutError(seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw TimeoutError(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}

#if os(iOS) && canImport(AVKit) && canImport(WebRTC) && canImport(UIKit)
@MainActor
private final class CallPictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private let attachLocalRenderer: (RTCVideoRenderer) -> Void
    private let detachLocalRenderer: (RTCVideoRenderer) -> Void
    private let attachRemoteRenderer: (RTCVideoRenderer) -> Void
    private let detachRemoteRenderer: (RTCVideoRenderer) -> Void
    private let onRestoreUIRequested: () -> Void

    var onLog: ((String) -> Void)?

    private var pipController: AVPictureInPictureController?
    private var contentViewController: AVPictureInPictureVideoCallViewController?
    private weak var sourceAnchorView: UIView?
    private weak var remoteVideoView: RTCMTLVideoView?
    private weak var localVideoView: RTCMTLVideoView?
    private let remoteRenderer = PiPFrameAwareVideoRenderer()
    private let localRenderer = PiPFrameAwareVideoRenderer()
    private var renderersAttached = false
    private var preparedCallID: UUID?
    private var startRetryTask: Task<Void, Never>?

    var hasLivePresentationState: Bool {
        pipController != nil || sourceAnchorView != nil || preparedCallID != nil
    }

    init(
        attachLocalRenderer: @escaping (RTCVideoRenderer) -> Void,
        detachLocalRenderer: @escaping (RTCVideoRenderer) -> Void,
        attachRemoteRenderer: @escaping (RTCVideoRenderer) -> Void,
        detachRemoteRenderer: @escaping (RTCVideoRenderer) -> Void,
        onRestoreUIRequested: @escaping () -> Void
    ) {
        self.attachLocalRenderer = attachLocalRenderer
        self.detachLocalRenderer = detachLocalRenderer
        self.attachRemoteRenderer = attachRemoteRenderer
        self.detachRemoteRenderer = detachRemoteRenderer
        self.onRestoreUIRequested = onRestoreUIRequested
        super.init()
    }

    func update(
        callID: UUID?,
        shouldEnable: Bool,
        isRemoteVideoAvailable: Bool,
        isLocalVideoEnabled: Bool,
        reason: String
    ) {
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.update(
                    callID: callID,
                    shouldEnable: shouldEnable,
                    isRemoteVideoAvailable: isRemoteVideoAvailable,
                    isLocalVideoEnabled: isLocalVideoEnabled,
                    reason: reason
                )
            }
            return
        }
        guard shouldEnable, let callID else {
            stop(reason: "update_disable_\(reason)")
            return
        }
        guard prepareIfNeeded(
            callID: callID,
            isRemoteVideoAvailable: isRemoteVideoAvailable,
            isLocalVideoEnabled: isLocalVideoEnabled,
            reason: reason
        ) else {
            return
        }
        applyVideoVisibility(
            isRemoteVideoAvailable: isRemoteVideoAvailable,
            isLocalVideoEnabled: isLocalVideoEnabled
        )
    }

    func startIfPossible(reason: String) {
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.startIfPossible(reason: reason)
            }
            return
        }
        guard #available(iOS 15.0, *) else { return }
        guard let pipController else {
            onLog?("pip.start.skip reason=\(reason) no_controller=true")
            return
        }
        guard pipController.isPictureInPictureActive == false else { return }

        startRetryTask?.cancel()
        startRetryTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1 ... 8 {
                guard let pipController = self.pipController else { return }
                if pipController.isPictureInPictureActive {
                    return
                }
                if pipController.isPictureInPicturePossible {
                    self.onLog?("pip.start.request reason=\(reason) attempt=\(attempt)")
                    pipController.startPictureInPicture()
                    return
                }
                self.onLog?("pip.start.wait_possible reason=\(reason) attempt=\(attempt)")
                try? await Task.sleep(for: .milliseconds(140))
            }
            self.onLog?("pip.start.give_up reason=\(reason)")
        }
    }

    func stop(reason: String) {
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.stop(reason: reason)
            }
            return
        }
        startRetryTask?.cancel()
        startRetryTask = nil
        if #available(iOS 15.0, *),
           let pipController,
           pipController.isPictureInPictureActive {
            onLog?("pip.stop.request reason=\(reason)")
            pipController.stopPictureInPicture()
        }
        teardown(reason: reason)
    }

    private func prepareIfNeeded(
        callID: UUID,
        isRemoteVideoAvailable: Bool,
        isLocalVideoEnabled: Bool,
        reason: String
    ) -> Bool {
        guard #available(iOS 15.0, *) else {
            onLog?("pip.unsupported reason=\(reason) api=iOS15")
            return false
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onLog?("pip.unsupported reason=\(reason) device=false")
            return false
        }
        if preparedCallID == callID, pipController != nil {
            return true
        }

        teardown(reason: "prepare_reset_\(reason)")
        guard let sourceAnchorView = ensureSourceAnchorView() else {
            onLog?("pip.prepare.failed reason=\(reason) source_anchor_missing=true")
            return false
        }

        let contentViewController = AVPictureInPictureVideoCallViewController()
        contentViewController.view.backgroundColor = .black

        let remoteVideoView = RTCMTLVideoView(frame: .zero)
        remoteVideoView.translatesAutoresizingMaskIntoConstraints = false
        remoteVideoView.videoContentMode = .scaleAspectFill
        remoteVideoView.clipsToBounds = true
        remoteVideoView.backgroundColor = .black
        contentViewController.view.addSubview(remoteVideoView)

        let localVideoView = RTCMTLVideoView(frame: .zero)
        localVideoView.translatesAutoresizingMaskIntoConstraints = false
        localVideoView.videoContentMode = .scaleAspectFill
        localVideoView.clipsToBounds = true
        localVideoView.layer.cornerRadius = 12
        localVideoView.layer.cornerCurve = .continuous
        localVideoView.layer.masksToBounds = true
        localVideoView.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        localVideoView.layer.borderWidth = 1
        localVideoView.backgroundColor = .black
        contentViewController.view.addSubview(localVideoView)

        NSLayoutConstraint.activate([
            remoteVideoView.leadingAnchor.constraint(equalTo: contentViewController.view.leadingAnchor),
            remoteVideoView.trailingAnchor.constraint(equalTo: contentViewController.view.trailingAnchor),
            remoteVideoView.topAnchor.constraint(equalTo: contentViewController.view.topAnchor),
            remoteVideoView.bottomAnchor.constraint(equalTo: contentViewController.view.bottomAnchor),

            localVideoView.widthAnchor.constraint(equalToConstant: 96),
            localVideoView.heightAnchor.constraint(equalToConstant: 142),
            localVideoView.topAnchor.constraint(equalTo: contentViewController.view.safeAreaLayoutGuide.topAnchor, constant: 10),
            localVideoView.trailingAnchor.constraint(equalTo: contentViewController.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
        ])

        remoteRenderer.targetView = remoteVideoView
        localRenderer.targetView = localVideoView
        bindRenderersIfNeeded()
        applyVideoVisibility(
            isRemoteVideoAvailable: isRemoteVideoAvailable,
            isLocalVideoEnabled: isLocalVideoEnabled
        )

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceAnchorView,
            contentViewController: contentViewController
        )
        let pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController.delegate = self
        pipController.canStartPictureInPictureAutomaticallyFromInline = true

        self.contentViewController = contentViewController
        self.remoteVideoView = remoteVideoView
        self.localVideoView = localVideoView
        self.pipController = pipController
        self.preparedCallID = callID

        onLog?("pip.prepared call=\(callID.uuidString) reason=\(reason)")
        return true
    }

    private func applyVideoVisibility(
        isRemoteVideoAvailable: Bool,
        isLocalVideoEnabled: Bool
    ) {
        remoteVideoView?.isHidden = !isRemoteVideoAvailable
        localVideoView?.isHidden = !isLocalVideoEnabled
    }

    private func bindRenderersIfNeeded() {
        guard renderersAttached == false else { return }
        attachRemoteRenderer(remoteRenderer)
        attachLocalRenderer(localRenderer)
        renderersAttached = true
    }

    private func unbindRenderersIfNeeded() {
        guard renderersAttached else { return }
        detachRemoteRenderer(remoteRenderer)
        detachLocalRenderer(localRenderer)
        renderersAttached = false
    }

    private func ensureSourceAnchorView() -> UIView? {
        if let sourceAnchorView, sourceAnchorView.window != nil {
            return sourceAnchorView
        }
        guard let window = keyWindow() else { return nil }

        let size: CGFloat = 4
        let anchor = UIView(
            frame: CGRect(
                x: max(window.bounds.width - size - 2, 0),
                y: max(window.bounds.height - size - 2, 0),
                width: size,
                height: size
            )
        )
        anchor.backgroundColor = .clear
        anchor.alpha = 0.01
        anchor.isUserInteractionEnabled = false
        anchor.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        window.addSubview(anchor)
        sourceAnchorView = anchor
        return anchor
    }

    private func keyWindow() -> UIWindow? {
        let scenes: [UIWindowScene]
        if Thread.isMainThread {
            scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { scene in
                    scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
                }
        } else {
            var resolvedScenes: [UIWindowScene] = []
            DispatchQueue.main.sync {
                resolvedScenes = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .filter { scene in
                        scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
                    }
            }
            scenes = resolvedScenes
        }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
                return keyWindow
            }
            if let fallbackWindow = scene.windows.first {
                return fallbackWindow
            }
        }
        return nil
    }

    private func teardown(reason: String) {
        if Thread.isMainThread == false {
            Task { @MainActor [weak self] in
                self?.teardown(reason: reason)
            }
            return
        }
        startRetryTask?.cancel()
        startRetryTask = nil
        unbindRenderersIfNeeded()
        remoteRenderer.targetView = nil
        localRenderer.targetView = nil
        remoteVideoView = nil
        localVideoView = nil
        pipController?.delegate = nil
        pipController = nil
        contentViewController = nil
        sourceAnchorView?.removeFromSuperview()
        sourceAnchorView = nil
        preparedCallID = nil
        onLog?("pip.teardown reason=\(reason)")
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onLog?("pip.state.will_start")
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onLog?("pip.state.did_start")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.onLog?("pip.state.failed_to_start error=\(error)")
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onLog?("pip.state.will_stop")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onLog?("pip.state.did_stop")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(false)
                return
            }
            self.onLog?("pip.restore_ui.requested")
            self.onRestoreUIRequested()
            completionHandler(true)
        }
    }
}

private final class PiPFrameAwareVideoRenderer: NSObject, RTCVideoRenderer {
    weak var targetView: RTCMTLVideoView?

    func setSize(_ size: CGSize) {
        targetView?.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        targetView?.renderFrame(frame)
    }
}
#endif

private struct LocalAnswerPayload {
    let offerSDP: String
    let answerSDP: String
}

private struct TerminalCallSnapshot {
    let state: InternetCallState
    let lastEventSequence: Int
    let recordedAt: Date
}

private struct CallRuntimeMetrics {
    var callStartedAt: Date
    var mediaStartedAt: Date?
    var remoteAnswerAppliedAt: Date?
    var firstICEConnectedAt: Date?
    var firstRemoteVideoFrameAt: Date?
    var videoToggleRequestedAt: Date?
    var lastVideoToggleLatency: TimeInterval?
    var videoDegradeCount: Int = 0
    var selectedVideoProfile: WebRTCAudioCallEngine.VideoQualityProfile
    var networkSnapshotAtStart: NetworkConnectionSnapshot?
}

private struct TimeoutError: LocalizedError {
    let seconds: TimeInterval

    var errorDescription: String? {
        "Operation timed out after \(String(format: "%.1f", seconds))s"
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
