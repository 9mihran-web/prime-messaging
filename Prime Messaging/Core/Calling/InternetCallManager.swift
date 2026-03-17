import Combine
import Foundation

enum InternetCallState: String {
    case calling
    case active
    case ended
}

struct InternetCallSession: Identifiable, Equatable {
    let id: UUID
    let user: User
    var state: InternetCallState
    var startedAt: Date
    var duration: TimeInterval
    var isMuted: Bool
    var isSpeakerEnabled: Bool
    var isVideoEnabled: Bool
}

@MainActor
final class InternetCallManager: ObservableObject {
    static let shared = InternetCallManager()

    @Published private(set) var activeCall: InternetCallSession?

    private var durationTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?

    private init() {}

    func startOutgoingCall(to user: User) {
        endCall()

        activeCall = InternetCallSession(
            id: UUID(),
            user: user,
            state: .calling,
            startedAt: .now,
            duration: 0,
            isMuted: false,
            isSpeakerEnabled: false,
            isVideoEnabled: false
        )

        activationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            guard self.activeCall?.user.id == user.id else { return }
            self.activeCall?.state = .active
            self.startDurationUpdates()
        }
    }

    func endCall() {
        durationTask?.cancel()
        durationTask = nil
        activationTask?.cancel()
        activationTask = nil
        activeCall = nil
    }

    func toggleMute() {
        activeCall?.isMuted.toggle()
    }

    func toggleSpeaker() {
        activeCall?.isSpeakerEnabled.toggle()
    }

    func toggleVideo() {
        activeCall?.isVideoEnabled.toggle()
    }

    private func startDurationUpdates() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let activeCall = self.activeCall else { continue }
                self.activeCall?.duration = Date.now.timeIntervalSince(activeCall.startedAt)
            }
        }
    }
}
