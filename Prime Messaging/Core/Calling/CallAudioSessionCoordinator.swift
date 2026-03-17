import AVFoundation
import Foundation

actor CallAudioSessionCoordinator {
    func activate(speakerEnabled: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        try session.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
    }

    func setSpeakerEnabled(_ enabled: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func deactivate() async {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
