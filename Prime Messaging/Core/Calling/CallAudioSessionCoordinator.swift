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
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if speakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
        try session.setActive(true)
        #if !os(tvOS)
        try session.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
        #endif
    }

    func configureActivatedCallKitSession(
        _ audioSession: AVAudioSession,
        speakerEnabled: Bool
    ) async throws {
        #if !os(tvOS)
        let canPrompt = isAppActiveForPermissionPrompt()
        let hasMicPermission = try await ensureMicrophonePermission(canPrompt: canPrompt)
        if hasMicPermission == false {
            throw CallAudioSessionError.microphonePermissionDenied
        }
        #endif

        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if speakerEnabled {
            options.insert(.defaultToSpeaker)
        }
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
        try audioSession.setActive(true)
        #if !os(tvOS)
        try audioSession.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
        #endif
    }

    #if !os(tvOS)
    func ensureMicrophonePermissionGranted(canPrompt: Bool) async throws -> Bool {
        try await ensureMicrophonePermission(canPrompt: canPrompt)
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

    func currentAudioRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
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

    private func isAppActiveForPermissionPrompt() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }
    #endif
}
