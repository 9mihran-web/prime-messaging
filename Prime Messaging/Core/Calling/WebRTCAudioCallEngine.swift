import AVFoundation
import Foundation

#if canImport(WebRTC)
import WebRTC
#endif

enum WebRTCAudioCallEngineError: LocalizedError {
    case webRTCUnavailable
    case peerConnectionMissing
    case invalidRemoteDescription

    var errorDescription: String? {
        switch self {
        case .webRTCUnavailable:
            return "WebRTC framework is not available in this build."
        case .peerConnectionMissing:
            return "WebRTC peer connection is not initialized."
        case .invalidRemoteDescription:
            return "Remote SDP is invalid."
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

    var onLocalICECandidate: ((ICECandidatePayload) -> Void)?
    var onStateLog: ((String) -> Void)?

#if canImport(WebRTC)
    private static let peerFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var isCallAudioSessionActivated = false
    private var activeSystemAudioSession: AVAudioSession?
#endif

    func start(iceServers: [ICEServer]) throws {
#if canImport(WebRTC)
        guard peerConnection == nil else { return }
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.useManualAudio = true
        if isCallAudioSessionActivated {
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

        localAudioTrack = audioTrack
        peerConnection = peer
        onStateLog?("local_audio_track.started id:\(audioTrack.trackId)")
#else
        throw WebRTCAudioCallEngineError.webRTCUnavailable
#endif
    }

    func stop() {
#if canImport(WebRTC)
        onStateLog?("stop.begin")
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.isAudioEnabled = false
        localAudioTrack = nil
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

    func setMuted(_ isMuted: Bool) {
#if canImport(WebRTC)
        localAudioTrack?.isEnabled = !isMuted
        onStateLog?("local_audio_track.muted:\(isMuted)")
#endif
    }

    func createOffer() async throws -> String {
#if canImport(WebRTC)
        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
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
        onStateLog?("offer.local.set size:\(offer.sdp.count)")
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

        guard let peerConnection else {
            throw WebRTCAudioCallEngineError.peerConnectionMissing
        }

        let remoteOffer = RTCSessionDescription(type: .offer, sdp: sdp)
        try await setRemote(description: remoteOffer)
        onStateLog?("offer.remote.set size:\(sdp.count)")

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
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
        onStateLog?("answer.local.set size:\(answer.sdp.count)")
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
        let remoteAnswer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await setRemote(description: remoteAnswer)
        onStateLog?("answer.remote.set size:\(sdp.count)")
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
        peerConnection.add(ice)
        onStateLog?("ice.remote.added size:\(candidate.count) sdpMid:\(sdpMid ?? "nil") mline:\(sdpMLineIndex ?? -1)")
#endif
    }

#if canImport(WebRTC)
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
    }
#endif
}

#if canImport(WebRTC)
extension WebRTCAudioCallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor [weak self] in
            self?.onStateLog?("signaling:\(stateChanged.rawValue)")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            self?.onStateLog?("ice:\(newState.rawValue)")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor [weak self] in
            self?.onStateLog?("gathering:\(newState.rawValue)")
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
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
            self?.onStateLog?("connection:\(newState.rawValue)")
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor [weak self] in
            let kind = rtpReceiver.track?.kind ?? "unknown"
            let enabled = rtpReceiver.track?.isEnabled ?? false
            self?.onStateLog?("receiver.added kind:\(kind) enabled:\(enabled) streams:\(mediaStreams.count)")
        }
    }
}
#endif
