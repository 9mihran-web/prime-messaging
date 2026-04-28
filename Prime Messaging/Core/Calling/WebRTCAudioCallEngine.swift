import AVFoundation
import Foundation

#if canImport(WebRTC)
import WebRTC
#endif

enum WebRTCAudioCallEngineError: LocalizedError {
    case webRTCUnavailable
    case peerConnectionMissing
    case invalidRemoteDescription
    case localVideoSourceMissing

    var errorDescription: String? {
        switch self {
        case .webRTCUnavailable:
            return "WebRTC framework is not available in this build."
        case .peerConnectionMissing:
            return "WebRTC peer connection is not initialized."
        case .invalidRemoteDescription:
            return "Remote SDP is invalid."
        case .localVideoSourceMissing:
            return "Local WebRTC video source is not initialized."
        }
    }
}

@MainActor
final class WebRTCAudioCallEngine: NSObject {
    struct ICEServer: Sendable, Hashable {
        var urls: [String]
        var username: String?
        var credential: String?

        static let defaultSTUN = ICEServer(
            urls: ["stun:stun.l.google.com:19302"],
            username: nil,
            credential: nil
        )

        static let publicFallbackTURN = ICEServer(
            urls: [
                "turn:openrelay.metered.ca:80?transport=udp",
                "turn:openrelay.metered.ca:443?transport=tcp",
                "turns:openrelay.metered.ca:443?transport=tcp",
            ],
            username: "openrelayproject",
            credential: "openrelayproject"
        )

        static let fallbackSet: [ICEServer] = [
            .defaultSTUN,
            .publicFallbackTURN,
        ]

        static func hasTURN(_ servers: [ICEServer]) -> Bool {
            for server in servers {
                for url in server.urls {
                    let value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if value.hasPrefix("turn:") || value.hasPrefix("turns:") {
                        return true
                    }
                }
            }
            return false
        }
    }

    struct ICECandidatePayload: Sendable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int?
    }

    enum VideoQualityProfile: String, Sendable, CaseIterable {
        case low
        case medium
        case high

        var width: Int {
            switch self {
            case .low:
                return 320
            case .medium:
                return 640
            case .high:
                return 960
            }
        }

        var height: Int {
            switch self {
            case .low:
                return 240
            case .medium:
                return 360
            case .high:
                return 540
            }
        }

        var fps: Int {
            switch self {
            case .low:
                return 15
            case .medium:
                return 20
            case .high:
                return 24
            }
        }

        var minBitrateBps: Int {
            switch self {
            case .low:
                return 80_000
            case .medium:
                return 150_000
            case .high:
                return 250_000
            }
        }

        var maxBitrateBps: Int {
            switch self {
            case .low:
                return 350_000
            case .medium:
                return 1_000_000
            case .high:
                return 2_000_000
            }
        }
    }

    enum ICEConnectionState: String, Sendable {
        case new
        case checking
        case connected
        case completed
        case failed
        case disconnected
        case closed
        case unknown
    }

    var onLocalICECandidate: ((ICECandidatePayload) -> Void)?
    var onStateLog: ((String) -> Void)?
    var onRemoteVideoAvailabilityChanged: ((Bool) -> Void)?
    var onICEConnectionStateChanged: ((ICEConnectionState) -> Void)?

#if canImport(WebRTC)
    private static let peerFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private static var startedEngineCount = 0

    private var peerConnection: RTCPeerConnection?
    private var hasRegisteredStartedEngine = false
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoCapturer: RTCCameraVideoCapturer?
    private var localVideoCaptureStopTask: Task<Void, Never>?
    private var isVideoCaptureActive = false
    private var isVideoCaptureStarting = false
    private var shouldStopCaptureAfterStart = false
    private var videoCaptureStartBeganAt: Date?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localVideoRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var remoteVideoRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var isRemoteVideoAvailable = false
    private var isCallAudioSessionActivated = false
    private var activeSystemAudioSession: AVAudioSession?
    private var prefersAutomaticAudioSessionManagement = false
    private var prefersFrontCamera = true
    private var videoQualityProfile: VideoQualityProfile = .high
    private var hasLocalVideoRelayCandidate = false
    private var hasRemoteVideoRelayCandidate = false
    private var didLogVideoRelayPathAvailability = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private let maxBufferedRemoteICECandidates = 256
#endif

    func start(iceServers: [ICEServer]) throws {
#if canImport(WebRTC)
        guard peerConnection == nil else { return }
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.useManualAudio = prefersAutomaticAudioSessionManagement == false
        if prefersAutomaticAudioSessionManagement {
            rtcAudioSession.isAudioEnabled = true
            onStateLog?("audio_session:auto_mode_on_start")
        } else if isCallAudioSessionActivated {
            let session = activeSystemAudioSession ?? AVAudioSession.sharedInstance()
            rtcAudioSession.audioSessionDidActivate(session)
            rtcAudioSession.isAudioEnabled = true
            onStateLog?("audio_session:restored_on_start")
        } else {
            rtcAudioSession.isAudioEnabled = false
        }

        let resolvedServers = iceServers.isEmpty ? ICEServer.fallbackSet : iceServers
        let hasTURN = ICEServer.hasTURN(resolvedServers)
        onStateLog?("start.ice_servers count:\(resolvedServers.count) has_turn:\(hasTURN)")
        let rtcIceServers = resolvedServers.map { server in
            RTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceCandidatePoolSize = 6
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceServers = rtcIceServers

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let peer = Self.peerFactory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        let audioSource = Self.peerFactory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = Self.peerFactory.audioTrack(with: audioSource, trackId: "prime-audio-0")
        audioTrack.isEnabled = true
        _ = peer.add(audioTrack, streamIds: ["prime-stream-0"])

        let profile = videoQualityProfile
        let videoSource = Self.peerFactory.videoSource()
        videoSource.adaptOutputFormat(
            toWidth: Int32(profile.width),
            height: Int32(profile.height),
            fps: Int32(profile.fps)
        )
        let videoTrack = Self.peerFactory.videoTrack(with: videoSource, trackId: "prime-video-0")
        videoTrack.isEnabled = false
        _ = peer.add(videoTrack, streamIds: ["prime-stream-0"])

        localAudioTrack = audioTrack
        localVideoSource = videoSource
        localVideoTrack = videoTrack
        localVideoCapturer = nil
        localVideoCaptureStopTask?.cancel()
        localVideoCaptureStopTask = nil
        isVideoCaptureActive = false
        remoteVideoTrack = nil
        hasLocalVideoRelayCandidate = false
        hasRemoteVideoRelayCandidate = false
        didLogVideoRelayPathAvailability = false
        setRemoteVideoAvailable(false)
        for renderer in localVideoRenderers.values {
            videoTrack.add(renderer)
        }
        configureVideoSenderParameters(for: peer)
        peerConnection = peer
        if hasRegisteredStartedEngine == false {
            Self.startedEngineCount += 1
            hasRegisteredStartedEngine = true
            onStateLog?("audio_session:engine_started active_engines:\(Self.startedEngineCount)")
        }
        onStateLog?(
            "local_audio_track.started id:\(audioTrack.trackId) enabled:\(audioTrack.isEnabled) senders:\(peer.senders.count) transceivers:\(peer.transceivers.count)"
        )
        onStateLog?(
            "local_video_track.prepared id:\(videoTrack.trackId) enabled:\(videoTrack.isEnabled)"
        )
#else
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    func stop() {
#if canImport(WebRTC)
        onStateLog?("stop.begin")
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        if hasRegisteredStartedEngine {
            Self.startedEngineCount = max(Self.startedEngineCount - 1, 0)
            hasRegisteredStartedEngine = false
        }
        if Self.startedEngineCount == 0 {
            rtcAudioSession.isAudioEnabled = false
            rtcAudioSession.useManualAudio = true
            if prefersAutomaticAudioSessionManagement {
                onStateLog?("audio_session:auto_mode_cleared_on_stop")
            }
        } else {
            onStateLog?("audio_session:retain_shared active_engines:\(Self.startedEngineCount)")
        }
        prefersAutomaticAudioSessionManagement = false
        localVideoCaptureStopTask?.cancel()
        localVideoCaptureStopTask = nil
        Task { @MainActor [weak self] in
            await self?.stopLocalVideoCaptureIfNeeded()
        }
        if let localVideoTrack {
            for renderer in localVideoRenderers.values {
                localVideoTrack.remove(renderer)
            }
        }
        if let remoteVideoTrack {
            for renderer in remoteVideoRenderers.values {
                remoteVideoTrack.remove(renderer)
            }
        }
        localAudioTrack = nil
        localVideoTrack = nil
        localVideoSource = nil
        localVideoCapturer = nil
        remoteVideoTrack = nil
        setRemoteVideoAvailable(false)
        isVideoCaptureActive = false
        isVideoCaptureStarting = false
        shouldStopCaptureAfterStart = false
        videoCaptureStartBeganAt = nil
        hasLocalVideoRelayCandidate = false
        hasRemoteVideoRelayCandidate = false
        didLogVideoRelayPathAvailability = false
        prefersFrontCamera = true
        pendingRemoteICECandidates.removeAll()
        peerConnection?.close()
        peerConnection = nil
        onStateLog?("stop.completed")
#endif
    }

    func notifyAudioSessionActivated(using audioSession: AVAudioSession = AVAudioSession.sharedInstance()) {
#if canImport(WebRTC)
        isCallAudioSessionActivated = true
        activeSystemAudioSession = audioSession
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        #if !os(tvOS)
        let hasInputRoute = audioSession.currentRoute.inputs.isEmpty == false
        #else
        let hasInputRoute = true
        #endif
        if prefersAutomaticAudioSessionManagement {
            guard hasInputRoute else {
                rtcAudioSession.useManualAudio = false
                rtcAudioSession.isAudioEnabled = true
                onStateLog?("audio_session:auto_mode_hold_no_input")
                return
            }
            prefersAutomaticAudioSessionManagement = false
            rtcAudioSession.useManualAudio = true
            onStateLog?("audio_session:auto_mode_recovered_callkit")
        }
        rtcAudioSession.audioSessionDidActivate(audioSession)
        rtcAudioSession.isAudioEnabled = true
        onStateLog?("audio_session:activated")
#endif
    }

    func notifyAudioSessionDeactivated(using audioSession: AVAudioSession = AVAudioSession.sharedInstance()) {
#if canImport(WebRTC)
        isCallAudioSessionActivated = false
        activeSystemAudioSession = nil
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.isAudioEnabled = false
        rtcAudioSession.audioSessionDidDeactivate(audioSession)
        onStateLog?("audio_session:deactivated")
#endif
    }

    var isAutomaticAudioSessionFallbackEnabled: Bool {
#if canImport(WebRTC)
        return prefersAutomaticAudioSessionManagement
#else
        return false
#endif
    }

    func enableAutomaticAudioSessionFallback(reason: String) {
#if canImport(WebRTC)
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        guard prefersAutomaticAudioSessionManagement == false else {
            onStateLog?("audio_session:auto_mode_skip_already_enabled reason:\(reason)")
            return
        }
        prefersAutomaticAudioSessionManagement = true
        rtcAudioSession.useManualAudio = false
        rtcAudioSession.isAudioEnabled = true
        onStateLog?("audio_session:auto_mode_enabled reason:\(reason)")
#else
        _ = reason
#endif
    }

    func setMuted(_ isMuted: Bool) {
#if canImport(WebRTC)
        localAudioTrack?.isEnabled = !isMuted
        onStateLog?("local_audio_track.muted:\(isMuted) enabled:\(localAudioTrack?.isEnabled ?? false)")
#endif
    }

    func setVideoEnabled(_ enabled: Bool) async throws {
#if canImport(WebRTC)
        guard peerConnection != nil else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        if enabled {
            shouldStopCaptureAfterStart = false
            if let stopTask = localVideoCaptureStopTask {
                await stopTask.value
                localVideoCaptureStopTask = nil
            }
            try startLocalVideoCaptureIfNeeded()
            localVideoTrack?.isEnabled = true
            onStateLog?(
                "local_video_track.enabled:true capturer_active:\(isVideoCaptureActive)"
            )
        } else {
            shouldStopCaptureAfterStart = true
            localVideoTrack?.isEnabled = false
            stopLocalVideoCaptureAsynchronouslyIfNeeded()
            onStateLog?(
                "local_video_track.enabled:false capturer_active:\(isVideoCaptureActive)"
            )
        }
#else
        _ = enabled
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    var isUsingFrontCamera: Bool {
#if canImport(WebRTC)
        return prefersFrontCamera
#else
        return true
#endif
    }

    func switchCamera() async -> Bool {
#if canImport(WebRTC)
        #if os(iOS)
        let devices = RTCCameraVideoCapturer.captureDevices()
        let hasFront = devices.contains(where: { $0.position == .front })
        let hasBack = devices.contains(where: { $0.position == .back })
        guard hasFront, hasBack else {
            onStateLog?("local_video_capture.switch.skip reason:single_facing_device")
            return false
        }

        prefersFrontCamera.toggle()
        let targetFacing = prefersFrontCamera ? "front" : "back"

        if isVideoCaptureStarting {
            onStateLog?("local_video_capture.switch.deferred reason:capture_starting target:\(targetFacing)")
            return true
        }

        guard localVideoTrack?.isEnabled == true else {
            onStateLog?("local_video_capture.switch.queued reason:video_disabled target:\(targetFacing)")
            return true
        }

        await stopLocalVideoCaptureIfNeeded()

        do {
            try startLocalVideoCaptureIfNeeded()
            onStateLog?("local_video_capture.switch.applied target:\(targetFacing)")
            return true
        } catch {
            prefersFrontCamera.toggle()
            onStateLog?("local_video_capture.switch.failed target:\(targetFacing) error:\(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
#else
        return false
#endif
    }

    func setVideoQualityProfile(_ profile: VideoQualityProfile) {
#if canImport(WebRTC)
        let previousProfile = videoQualityProfile
        guard previousProfile != profile else {
            onStateLog?("video.profile.skip_same profile:\(profile.rawValue)")
            return
        }

        videoQualityProfile = profile
        localVideoSource?.adaptOutputFormat(
            toWidth: Int32(profile.width),
            height: Int32(profile.height),
            fps: Int32(profile.fps)
        )
        if let peerConnection {
            configureVideoSenderParameters(for: peerConnection)
            onStateLog?(
                "video.profile.applied from:\(previousProfile.rawValue) to:\(profile.rawValue) width:\(profile.width) height:\(profile.height) fps:\(profile.fps) min_bps:\(profile.minBitrateBps) max_bps:\(profile.maxBitrateBps)"
            )
        } else {
            onStateLog?(
                "video.profile.queued from:\(previousProfile.rawValue) to:\(profile.rawValue) width:\(profile.width) height:\(profile.height) fps:\(profile.fps)"
            )
        }
#else
        _ = profile
#endif
    }

    var currentVideoQualityProfile: VideoQualityProfile {
#if canImport(WebRTC)
        return videoQualityProfile
#else
        return .high
#endif
    }

    #if canImport(WebRTC)
    func bindLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        let key = rendererKey(for: renderer)
        if localVideoRenderers[key] != nil {
            return
        }
        localVideoRenderers[key] = renderer
        localVideoTrack?.add(renderer)
        onStateLog?("local_video_renderer.bound count:\(localVideoRenderers.count)")
    }

    func unbindLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.remove(renderer)
        localVideoRenderers.removeValue(forKey: rendererKey(for: renderer))
        onStateLog?("local_video_renderer.unbound count:\(localVideoRenderers.count)")
    }

    func bindRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        let key = rendererKey(for: renderer)
        if remoteVideoRenderers[key] != nil {
            return
        }
        remoteVideoRenderers[key] = renderer
        remoteVideoTrack?.add(renderer)
        onStateLog?(
            "remote_video_renderer.bound available:\(isRemoteVideoAvailable) count:\(remoteVideoRenderers.count)"
        )
    }

    func unbindRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        remoteVideoTrack?.remove(renderer)
        remoteVideoRenderers.removeValue(forKey: rendererKey(for: renderer))
        onStateLog?("remote_video_renderer.unbound count:\(remoteVideoRenderers.count)")
    }
    #endif

    func createOffer() async throws -> String {
#if canImport(WebRTC)
        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let description else {
                    continuation.resume(throwing: WebRTCAudioCallEngineError.peerConnectionMissing)
                    return
                }
                continuation.resume(returning: description)
            }
        }

        try await setLocal(description: offer)
        onStateLog?("offer.local.set size:\(offer.sdp.count) has_audio_mline:\(offer.sdp.contains("m=audio"))")
        return offer.sdp
#else
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    func applyRemoteOfferAndCreateAnswer(_ sdp: String) async throws -> String {
#if canImport(WebRTC)
        guard sdp.isEmpty == false else {
            throw WebRTCAudioCallEngineError.invalidRemoteDescription
        }
        let normalizedOfferSDP = canonicalizedSDP(sdp)
        guard normalizedOfferSDP.hasPrefix("v=0") else {
            throw WebRTCAudioCallEngineError.invalidRemoteDescription
        }

        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }
        let offerHasAudioMLine = normalizedOfferSDP.contains("m=audio")

        onStateLog?(
            "offer.remote.normalize raw_size:\(sdp.count) normalized_size:\(normalizedOfferSDP.count) has_audio_mline:\(offerHasAudioMLine)"
        )
        let remoteOffer = RTCSessionDescription(type: .offer, sdp: normalizedOfferSDP)
        try await setRemote(description: remoteOffer)
        onStateLog?("offer.remote.set size:\(normalizedOfferSDP.count) has_audio_mline:\(offerHasAudioMLine)")

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )

        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let description else {
                    continuation.resume(throwing: WebRTCAudioCallEngineError.peerConnectionMissing)
                    return
                }
                continuation.resume(returning: description)
            }
        }

        try await setLocal(description: answer)
        onStateLog?("answer.local.set size:\(answer.sdp.count) has_audio_mline:\(answer.sdp.contains("m=audio"))")
        return answer.sdp
#else
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    func applyRemoteAnswer(_ sdp: String) async throws {
#if canImport(WebRTC)
        guard sdp.isEmpty == false else {
            throw WebRTCAudioCallEngineError.invalidRemoteDescription
        }
        let normalizedAnswerSDP = canonicalizedSDP(sdp)
        guard normalizedAnswerSDP.hasPrefix("v=0") else {
            throw WebRTCAudioCallEngineError.invalidRemoteDescription
        }
        let answerHasAudioMLine = normalizedAnswerSDP.contains("m=audio")
        onStateLog?(
            "answer.remote.normalize raw_size:\(sdp.count) normalized_size:\(normalizedAnswerSDP.count) has_audio_mline:\(answerHasAudioMLine)"
        )
        let remoteAnswer = RTCSessionDescription(type: .answer, sdp: normalizedAnswerSDP)
        try await setRemote(description: remoteAnswer)
        onStateLog?("answer.remote.set size:\(normalizedAnswerSDP.count) has_audio_mline:\(answerHasAudioMLine)")
#else
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    func addRemoteICECandidate(
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?
    ) {
#if canImport(WebRTC)
        guard let peerConnection, candidate.isEmpty == false else { return }
        let lineIndex = Int32(sdpMLineIndex ?? 0)
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: lineIndex, sdpMid: sdpMid)
        if peerConnection.remoteDescription == nil {
            if pendingRemoteICECandidates.count >= maxBufferedRemoteICECandidates {
                pendingRemoteICECandidates.removeFirst(
                    pendingRemoteICECandidates.count - maxBufferedRemoteICECandidates + 1
                )
            }
            pendingRemoteICECandidates.append(ice)
            let type = candidateType(for: candidate)
            onStateLog?(
                "ice.remote.queued size:\(candidate.count) type:\(type) sdpMid:\(sdpMid ?? "nil") mline:\(sdpMLineIndex ?? -1) pending:\(pendingRemoteICECandidates.count)"
            )
            return
        }
        peerConnection.add(ice) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.onStateLog?("ice.remote.add.failed error:\(error.localizedDescription)")
            }
        }
        let type = candidateType(for: candidate)
        onStateLog?(
            "ice.remote.added size:\(candidate.count) type:\(type) sdpMid:\(sdpMid ?? "nil") mline:\(sdpMLineIndex ?? -1)"
        )
        if type == "relay" {
            markRelayVideoCandidateObserved(isLocal: false, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        }
#endif
    }

#if canImport(WebRTC)
    private func canonicalizedSDP(_ rawSDP: String) -> String {
        let withoutNullBytes = rawSDP.replacingOccurrences(of: "\u{0000}", with: "")
        let normalizedLineBreaks = withoutNullBytes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalizedLineBreaks
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard lines.isEmpty == false else { return "" }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func candidateType(for candidate: String) -> String {
        let parts = candidate.split(separator: " ")
        guard let typIndex = parts.firstIndex(of: "typ"),
              typIndex < parts.index(before: parts.endIndex) else {
            return "unknown"
        }
        return String(parts[parts.index(after: typIndex)])
    }

    private func isVideoCandidate(sdpMid: String?, sdpMLineIndex: Int?) -> Bool {
        if let sdpMid {
            let normalized = sdpMid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "1" || normalized.contains("video") {
                return true
            }
        }
        if let sdpMLineIndex, sdpMLineIndex == 1 {
            return true
        }
        return false
    }

    private func markRelayVideoCandidateObserved(isLocal: Bool, sdpMid: String?, sdpMLineIndex: Int?) {
        guard isVideoCandidate(sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex) else { return }
        if isLocal {
            guard hasLocalVideoRelayCandidate == false else { return }
            hasLocalVideoRelayCandidate = true
            onStateLog?("ice.relay.video.local.detected sdpMid:\(sdpMid ?? "nil") mline:\(sdpMLineIndex ?? -1)")
        } else {
            guard hasRemoteVideoRelayCandidate == false else { return }
            hasRemoteVideoRelayCandidate = true
            onStateLog?("ice.relay.video.remote.detected sdpMid:\(sdpMid ?? "nil") mline:\(sdpMLineIndex ?? -1)")
        }
        maybeLogRelayVideoPathAvailability()
    }

    private func maybeLogRelayVideoPathAvailability() {
        guard hasLocalVideoRelayCandidate,
              hasRemoteVideoRelayCandidate,
              didLogVideoRelayPathAvailability == false else { return }
        didLogVideoRelayPathAvailability = true
        onStateLog?("ice.relay.video.path.candidate_pair_available local:true remote:true")
    }

    private func rendererKey(for renderer: RTCVideoRenderer) -> ObjectIdentifier {
        ObjectIdentifier(renderer as AnyObject)
    }

    private func setRemoteVideoAvailable(_ available: Bool) {
        guard isRemoteVideoAvailable != available else { return }
        isRemoteVideoAvailable = available
        onRemoteVideoAvailabilityChanged?(available)
        onStateLog?("remote_video.available:\(available)")
    }

    private func configureVideoSenderParameters(for peer: RTCPeerConnection) {
        guard let videoSender = peer.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) else {
            onStateLog?("video.sender.missing")
            return
        }

        let profile = videoQualityProfile
        let parameters = videoSender.parameters
        var encodings = parameters.encodings
        if encodings.isEmpty {
            encodings = [RTCRtpEncodingParameters()]
        }
        for encoding in encodings {
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: profile.minBitrateBps)
            encoding.maxFramerate = NSNumber(value: profile.fps)
            encoding.isActive = true
        }
        parameters.encodings = encodings
        videoSender.parameters = parameters

        let appliedBWE = peer.setBweMinBitrateBps(
            NSNumber(value: profile.minBitrateBps),
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: profile.maxBitrateBps)
        )
        onStateLog?(
            "video.sender.configured profile:\(profile.rawValue) encodings:\(encodings.count) min_bps:\(profile.minBitrateBps) max_bps:\(profile.maxBitrateBps) fps:\(profile.fps) bwe_applied:\(appliedBWE)"
        )
    }

    private func mappedICEConnectionState(from rtcState: RTCIceConnectionState) -> ICEConnectionState {
        switch rtcState {
        case .new:
            return .new
        case .checking:
            return .checking
        case .connected:
            return .connected
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .disconnected:
            return .disconnected
        case .closed:
            return .closed
        case .count:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private func signalingStateName(_ state: RTCSignalingState) -> String {
        switch state {
        case .stable:
            return "stable"
        case .haveLocalOffer:
            return "haveLocalOffer"
        case .haveLocalPrAnswer:
            return "haveLocalPrAnswer"
        case .haveRemoteOffer:
            return "haveRemoteOffer"
        case .haveRemotePrAnswer:
            return "haveRemotePrAnswer"
        case .closed:
            return "closed"
        @unknown default:
            return "unknown"
        }
    }

    private func iceConnectionStateName(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        case .count:
            return "count"
        @unknown default:
            return "unknown"
        }
    }

    private func iceGatheringStateName(_ state: RTCIceGatheringState) -> String {
        switch state {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        @unknown default:
            return "unknown"
        }
    }

    private func peerConnectionStateName(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new:
            return "new"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "failed"
        case .closed:
            return "closed"
        @unknown default:
            return "unknown"
        }
    }

    private func setLocal(description: RTCSessionDescription) async throws {
        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemote(description: RTCSessionDescription) async throws {
        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        flushPendingRemoteICECandidates(reason: "remote_description_set")
    }

    private func flushPendingRemoteICECandidates(reason: String) {
        guard let peerConnection else { return }
        guard peerConnection.remoteDescription != nil else { return }
        guard pendingRemoteICECandidates.isEmpty == false else { return }

        let queued = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll()
        onStateLog?("ice.remote.flush.start count:\(queued.count) reason:\(reason)")
        for candidate in queued {
            peerConnection.add(candidate) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.onStateLog?("ice.remote.flush.failed error:\(error.localizedDescription)")
                }
            }
            let type = candidateType(for: candidate.sdp)
            onStateLog?(
                "ice.remote.flush.added size:\(candidate.sdp.count) type:\(type) sdpMid:\(candidate.sdpMid ?? "nil") mline:\(Int(candidate.sdpMLineIndex))"
            )
            if type == "relay" {
                markRelayVideoCandidateObserved(
                    isLocal: false,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: Int(candidate.sdpMLineIndex)
                )
            }
        }
        onStateLog?("ice.remote.flush.done count:\(queued.count) reason:\(reason)")
    }

    private func startLocalVideoCaptureIfNeeded() throws {
        guard let localVideoSource else {
            throw WebRTCAudioCallEngineError.localVideoSourceMissing
        }

        if isVideoCaptureActive || isVideoCaptureStarting {
            return
        }

        #if os(iOS)
        if localVideoCapturer == nil {
            localVideoCapturer = RTCCameraVideoCapturer(delegate: localVideoSource)
        }
        guard let localVideoCapturer else {
            throw WebRTCAudioCallEngineError.localVideoSourceMissing
        }
        guard let captureDevice = preferredCaptureDevice() else {
            onStateLog?("local_video_capture.unavailable reason:no_device")
            return
        }
        guard let captureFormat = preferredCaptureFormat(for: captureDevice) else {
            onStateLog?("local_video_capture.unavailable reason:no_format device:\(captureDevice.localizedName)")
            return
        }
        let deviceName = captureDevice.localizedName
        let fps = preferredCaptureFPS(for: captureFormat)
        let dimensions = CMVideoFormatDescriptionGetDimensions(captureFormat.formatDescription)
        isVideoCaptureStarting = true
        shouldStopCaptureAfterStart = false
        videoCaptureStartBeganAt = Date.now
        localVideoCapturer.startCapture(with: captureDevice, format: captureFormat, fps: fps) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isVideoCaptureStarting = false
                if let error {
                    self.isVideoCaptureActive = false
                    self.videoCaptureStartBeganAt = nil
                    self.onStateLog?("local_video_capture.failed error:\(error.localizedDescription)")
                    return
                }
                self.isVideoCaptureActive = true
                let startup = self.videoCaptureStartBeganAt.map { Date.now.timeIntervalSince($0) } ?? 0
                self.videoCaptureStartBeganAt = nil
                self.onStateLog?(
                    "local_video_capture.started device:\(deviceName) width:\(dimensions.width) height:\(dimensions.height) fps:\(fps) startup_s:\(String(format: "%.3f", startup))"
                )
                if self.shouldStopCaptureAfterStart || self.localVideoTrack?.isEnabled == false {
                    self.stopLocalVideoCaptureAsynchronouslyIfNeeded()
                }
            }
        }
        onStateLog?(
            "local_video_capture.starting device:\(deviceName) width:\(dimensions.width) height:\(dimensions.height) fps:\(fps)"
        )
        #else
        onStateLog?("local_video_capture.unsupported_platform")
        #endif
    }

    private func stopLocalVideoCaptureIfNeeded() async {
        #if os(iOS)
        if isVideoCaptureStarting {
            shouldStopCaptureAfterStart = true
            onStateLog?("local_video_capture.stop_deferred reason:starting")
            return
        }
        guard isVideoCaptureActive, let localVideoCapturer else {
            return
        }

        await withCheckedContinuation { continuation in
            localVideoCapturer.stopCapture {
                continuation.resume()
            }
        }
        isVideoCaptureActive = false
        shouldStopCaptureAfterStart = false
        onStateLog?("local_video_capture.stopped")
        #else
        isVideoCaptureActive = false
        #endif
    }

    private func stopLocalVideoCaptureAsynchronouslyIfNeeded() {
        #if os(iOS)
        if isVideoCaptureStarting {
            shouldStopCaptureAfterStart = true
            onStateLog?("local_video_capture.stop_deferred_async reason:starting")
            return
        }
        guard isVideoCaptureActive, localVideoCaptureStopTask == nil else {
            return
        }
        localVideoCaptureStopTask = Task { @MainActor [weak self] in
            await self?.stopLocalVideoCaptureIfNeeded()
            self?.localVideoCaptureStopTask = nil
        }
        #else
        isVideoCaptureActive = false
        #endif
    }

    #if os(iOS)
    private func preferredCaptureDevice() -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        if prefersFrontCamera {
            if let front = devices.first(where: { $0.position == .front }) {
                return front
            }
            if let back = devices.first(where: { $0.position == .back }) {
                return back
            }
            return devices.first
        }

        if let back = devices.first(where: { $0.position == .back }) {
            return back
        }
        if let front = devices.first(where: { $0.position == .front }) {
            return front
        }
        return devices.first
    }

    private func preferredCaptureFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard formats.isEmpty == false else { return nil }

        let profile = videoQualityProfile
        let targetPixels = profile.width * profile.height
        let candidates = formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width >= 640 && dims.height >= 480
        }
        let pool = candidates.isEmpty ? formats : candidates

        let best = pool.min { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsPixels = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsPixels = Int(rhsDims.width) * Int(rhsDims.height)
            let lhsDistance = abs(lhsPixels - targetPixels)
            let rhsDistance = abs(rhsPixels - targetPixels)
            if lhsDistance == rhsDistance {
                return preferredCaptureFPS(for: lhs) > preferredCaptureFPS(for: rhs)
            }
            return lhsDistance < rhsDistance
        }
        if let best {
            return best
        }
        return pool.first
    }

    private func preferredCaptureFPS(for format: AVCaptureDevice.Format) -> Int {
        let maxSupported = format.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }
            .max() ?? 15
        return min(maxSupported, videoQualityProfile.fps)
    }
    #endif
#endif
}

#if canImport(WebRTC)
extension WebRTCAudioCallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStateLog?("signaling:\(stateChanged.rawValue) name:\(self.signalingStateName(stateChanged))")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStateLog?("ice:\(newState.rawValue) name:\(self.iceConnectionStateName(newState))")
            self.onICEConnectionStateChanged?(self.mappedICEConnectionState(from: newState))
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStateLog?("gathering:\(newState.rawValue) name:\(self.iceGatheringStateName(newState))")
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            let candidateType = self?.candidateType(for: candidate.sdp) ?? "unknown"
            self?.onStateLog?(
                "ice.local.generated size:\(candidate.sdp.count) type:\(candidateType) sdpMid:\(candidate.sdpMid ?? "nil") mline:\(candidate.sdpMLineIndex)"
            )
            if candidateType == "relay" {
                self?.markRelayVideoCandidateObserved(
                    isLocal: true,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: Int(candidate.sdpMLineIndex)
                )
            }
            self?.onLocalICECandidate?(
                .init(
                    candidate: candidate.sdp,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: Int(candidate.sdpMLineIndex)
                )
            )
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStateLog?("connection:\(newState.rawValue) name:\(self.peerConnectionStateName(newState))")
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kind = rtpReceiver.track?.kind ?? "unknown"
            let enabled = rtpReceiver.track?.isEnabled ?? false
            let trackID = rtpReceiver.track?.trackId ?? "nil"
            self.onStateLog?("receiver.added kind:\(kind) enabled:\(enabled) track:\(trackID) streams:\(mediaStreams.count)")
            if kind == kRTCMediaStreamTrackKindVideo,
               let videoTrack = rtpReceiver.track as? RTCVideoTrack {
                if let previousTrack = self.remoteVideoTrack,
                   previousTrack.trackId != videoTrack.trackId {
                    for renderer in self.remoteVideoRenderers.values {
                        previousTrack.remove(renderer)
                    }
                }
                self.remoteVideoTrack = videoTrack
                for renderer in self.remoteVideoRenderers.values {
                    videoTrack.add(renderer)
                }
                self.onStateLog?(
                    "receiver.video.track.ready id:\(videoTrack.trackId) renderers:\(self.remoteVideoRenderers.count)"
                )
            }
        }
    }
}
#endif
