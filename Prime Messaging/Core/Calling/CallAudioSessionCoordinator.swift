import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum CallAudioSessionError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for internet calls."
        }
    }
}

actor CallAudioSessionCoordinator {
    func activate(speakerEnabled: Bool) async throws {
        #if !os(tvOS)
        let hasMicPermission = try await ensureMicrophonePermission(canPrompt: true)
        if hasMicPermission == false {
            throw CallAudioSessionError.microphonePermissionDenied
        }
        #endif

        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if speakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
        }
        try activateSessionWithRetry(session)
        #if !os(tvOS)
        let isCurrentlySpeaker = session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker })
        if speakerEnabled != isCurrentlySpeaker {
            try session.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
        }
        #endif
    }

    func configureActivatedCallKitSession(
        _ audioSession: AVAudioSession,
        speakerEnabled: Bool
    ) async throws -> Bool {
        var hasMicPermission = true
        #if !os(tvOS)
        let canPrompt = await isAppActiveForPermissionPrompt()
        hasMicPermission = try await ensureMicrophonePermission(canPrompt: canPrompt)
        #endif

        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if speakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        if audioSession.category != .playAndRecord || audioSession.mode != .voiceChat || audioSession.categoryOptions != options {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
        }
        // CallKit owns activation lifecycle (provider:didActivate). Forcing
        // setActive(true) here can throw 561017449 on background answer flow.
        #if !os(tvOS)
        let isCurrentlySpeaker = audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker })
        if speakerEnabled != isCurrentlySpeaker {
            do {
                try audioSession.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
            } catch {
                if shouldIgnoreCallKitOverrideFailure(error) == false {
                    throw error
                }
            }
        }
        #endif
        return hasMicPermission
    }

    func forceActivateForCallKitFallback(speakerEnabled: Bool) async throws -> Bool {
        var hasMicPermission = true
        #if !os(tvOS)
        let canPrompt = await isAppActiveForPermissionPrompt()
        hasMicPermission = try await ensureMicrophonePermission(canPrompt: canPrompt)
        #endif

        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if speakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: options
            )
        }
        try activateSessionWithRetry(session)
        #if !os(tvOS)
        let isCurrentlySpeaker = session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker })
        if speakerEnabled != isCurrentlySpeaker {
            try session.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
        }
        #endif
        return hasMicPermission
    }

    #if !os(tvOS)
    func ensureMicrophonePermissionGranted(canPrompt: Bool) async throws -> Bool {
        try await ensureMicrophonePermission(canPrompt: canPrompt)
    }

    func ensureCameraPermissionGranted(canPrompt: Bool) async -> Bool {
        await ensureCameraPermission(canPrompt: canPrompt)
    }

    func microphonePermissionStatusDescription() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }

    func cameraPermissionStatusDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    func currentAudioRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    func audioSessionSnapshotDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return
            "category=\(session.category.rawValue) mode=\(session.mode.rawValue) options_raw=\(session.categoryOptions.rawValue) " +
            "sample_rate=\(String(format: "%.0f", session.sampleRate)) io_buffer=\(String(format: "%.4f", session.ioBufferDuration)) " +
            "inputs=[\(inputs)] outputs=[\(outputs)]"
    }
    #endif

    func setSpeakerEnabled(_ enabled: Bool) async throws {
        #if !os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        #endif
    }

    func deactivate() async {
        let session = AVAudioSession.sharedInstance()
        #if !os(tvOS)
        try? session.overrideOutputAudioPort(.none)
        #endif
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    #if !os(tvOS)
    private func ensureMicrophonePermission(canPrompt: Bool) async throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            guard canPrompt else {
                return false
            }
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func ensureCameraPermission(canPrompt: Bool) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            guard canPrompt else {
                return false
            }
            return await AVCaptureDevice.requestAccess(for: .video)
        @unknown default:
            return false
        }
    }

    private func isAppActiveForPermissionPrompt() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #else
        return true
        #endif
    }

    private func activateSessionWithRetry(_ session: AVAudioSession) throws {
        do {
            try session.setActive(true)
        } catch {
            guard shouldRetryActivation(error) else { throw error }
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            try session.setActive(true)
        }
    }

    private func shouldRetryActivation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            if nsError.code == 561017449 || nsError.code == 1701737535 {
                return true
            }
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("session activation failed")
            || message.contains("cannot interrupt others")
    }

    private func shouldIgnoreCallKitOverrideFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            if nsError.code == 561017449 || nsError.code == 1701737535 {
                return true
            }
        }
        return nsError.localizedDescription.lowercased().contains("session activation failed")
    }
    #endif
}
