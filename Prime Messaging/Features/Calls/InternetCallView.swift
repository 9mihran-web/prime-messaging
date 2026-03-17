import SwiftUI

struct InternetCallView: View {
    @ObservedObject private var callManager = InternetCallManager.shared
    @EnvironmentObject private var appState: AppState
    let call: InternetCall

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let resolvedCall = callManager.activeCall ?? call
        ZStack {
            LinearGradient(
                colors: [
                    PrimeTheme.Colors.background,
                    PrimeTheme.Colors.elevated.opacity(0.96),
                    PrimeTheme.Colors.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                Spacer()

                VStack(spacing: 14) {
                    Circle()
                        .fill(PrimeTheme.Colors.accent.opacity(0.18))
                        .frame(width: 128, height: 128)
                        .overlay(
                            Text(initials)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        )

                    Text(displayName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)

                    Text(callStateLabel)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)

                    Text(durationLabel)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary.opacity(0.92))
                        .opacity(showsDuration ? 1 : 0)
                }

                Spacer()

                controlRow(for: resolvedCall)
                .padding(.bottom, 42)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                callManager.dismissCallUI()
                dismiss()
            } label: {
                topCircleButton(systemName: "chevron.down")
            }
            .buttonStyle(.plain)

            Spacer()

            topCircleButton(systemName: "info.circle")
        }
    }

    private var displayName: String {
        (callManager.activeCall ?? call).displayName(for: appState.currentUser.id)
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        if letters.isEmpty {
            return String(displayName.prefix(2)).uppercased()
        }

        return String(letters.prefix(2)).uppercased()
    }

    private var callStateLabel: String {
        let resolvedCall = callManager.activeCall ?? call
        switch resolvedCall.state {
        case .ringing:
            return resolvedCall.direction(for: appState.currentUser.id) == .incoming
                ? "calls.state.incoming".localized
                : "calls.state.calling".localized
        case .active:
            return "calls.state.active".localized
        case .ended:
            return "calls.state.ended".localized
        case .rejected:
            return "calls.state.rejected".localized
        case .cancelled:
            return "calls.state.cancelled".localized
        case .missed:
            return "calls.state.missed".localized
        }
    }

    private var durationLabel: String {
        let duration = Int(callManager.duration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var showsDuration: Bool {
        let resolvedState = (callManager.activeCall ?? call).state
        switch resolvedState {
        case .active, .ended, .cancelled, .rejected, .missed:
            return true
        case .ringing:
            return false
        }
    }

    @ViewBuilder
    private func topCircleButton(systemName: String) -> some View {
        Circle()
            .fill(PrimeTheme.Colors.elevated)
            .frame(width: 42, height: 42)
            .overlay(
                Circle()
                    .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
            )
    }

    @ViewBuilder
    private func callControlButton(systemName: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Circle()
                .fill(isActive ? PrimeTheme.Colors.elevated : PrimeTheme.Colors.textSecondary.opacity(0.2))
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func controlRow(for call: InternetCall) -> some View {
        switch (call.state, call.direction(for: appState.currentUser.id)) {
        case (.ringing, .incoming):
            HStack(spacing: 20) {
                Button {
                    Task {
                        try? await callManager.rejectCall()
                    }
                } label: {
                    Circle()
                        .fill(PrimeTheme.Colors.warning)
                        .frame(width: 70, height: 70)
                        .overlay(
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color.white)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        try? await callManager.answerCall()
                    }
                } label: {
                    Circle()
                        .fill(PrimeTheme.Colors.success)
                        .frame(width: 70, height: 70)
                        .overlay(
                            Image(systemName: "phone.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }

        case (.active, _):
            HStack(spacing: 18) {
                callControlButton(
                    systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                    isActive: !callManager.isMuted
                ) {
                    callManager.toggleMute()
                }

                callControlButton(
                    systemName: callManager.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill",
                    isActive: callManager.isSpeakerEnabled
                ) {
                    callManager.toggleSpeaker()
                }

                callControlButton(
                    systemName: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    isActive: callManager.isVideoEnabled
                ) {
                    callManager.toggleVideo()
                }

                hangupButton
            }

        default:
            HStack(spacing: 18) {
                callControlButton(
                    systemName: callManager.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill",
                    isActive: callManager.isSpeakerEnabled
                ) {
                    callManager.toggleSpeaker()
                }

                hangupButton
            }
        }
    }

    private var hangupButton: some View {
        Button {
            callManager.endCall()
        } label: {
            Circle()
                .fill(PrimeTheme.Colors.warning)
                .frame(width: 62, height: 62)
                .overlay(
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                )
        }
        .buttonStyle(.plain)
    }
}
