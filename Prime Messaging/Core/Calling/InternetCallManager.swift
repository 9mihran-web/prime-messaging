import Combine
import Foundation

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
    private var repository: (any CallRepository)?
    private var currentUserID: UUID?
    private var monitoringTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func configure(currentUserID: UUID, repository: any CallRepository) {
        let userDidChange = self.currentUserID != currentUserID
        self.currentUserID = currentUserID
        self.repository = repository

        if userDidChange || monitoringTask == nil {
            startMonitoring()
        }
    }

    func stopMonitoring() {
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
        await install(call)
    }

    func answerCall() async throws {
        guard let currentUserID, let repository, let activeCall else {
            throw CallRepositoryError.callNotFound
        }

        clearError()
        let updatedCall = try await repository.answerCall(activeCall.id, userID: currentUserID)
        await install(updatedCall)
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
                await clearCallState()
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

        switch call.state {
        case .active:
            await activateAudioIfNeeded()
            startDurationUpdates(startDate: call.answeredAt ?? call.createdAt)
        case .ringing:
            durationTask?.cancel()
            durationTask = nil
        case .ended, .cancelled, .rejected, .missed:
            durationTask?.cancel()
            durationTask = nil
            await audioSessionCoordinator.deactivate()
            scheduleDismissIfNeeded(for: call.id)
        }
    }

    private func clearCallState() async {
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
        await audioSessionCoordinator.deactivate()
    }

    private func activateAudioIfNeeded() async {
        do {
            try await audioSessionCoordinator.activate(speakerEnabled: isSpeakerEnabled)
        } catch {
            lastErrorMessage = "calls.unavailable.start".localized
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
}
