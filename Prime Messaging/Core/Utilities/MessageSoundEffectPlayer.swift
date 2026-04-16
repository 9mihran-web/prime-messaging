import AudioToolbox
import Foundation

@MainActor
final class MessageSoundEffectPlayer {
    static let shared = MessageSoundEffectPlayer()

    private enum SoundAsset: String, CaseIterable {
        case send
        case receive

        var fileExtension: String { "wav" }
    }

    private var soundIDs: [SoundAsset: SystemSoundID] = [:]
    private var lastReceivePlaybackAt: Date = .distantPast

    private init() {}

    func playSend() {
        play(.send)
    }

    func playReceive() {
        let now = Date()
        guard now.timeIntervalSince(lastReceivePlaybackAt) > 0.12 else { return }
        lastReceivePlaybackAt = now
        play(.receive)
    }

    private func play(_ asset: SoundAsset) {
        guard let soundID = soundID(for: asset) else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    private func soundID(for asset: SoundAsset) -> SystemSoundID? {
        if let cached = soundIDs[asset] {
            return cached
        }

        guard let url = Bundle.main.url(forResource: asset.rawValue, withExtension: asset.fileExtension) else {
            return nil
        }

        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            return nil
        }

        soundIDs[asset] = soundID
        return soundID
    }

    deinit {
        for soundID in soundIDs.values {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }
}
