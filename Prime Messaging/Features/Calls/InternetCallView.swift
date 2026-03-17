import SwiftUI

struct InternetCallView: View {
    @ObservedObject private var callManager = InternetCallManager.shared
    let call: InternetCallSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                }

                Spacer()

                HStack(spacing: 18) {
                    callControlButton(
                        systemName: callManager.activeCall?.isVideoEnabled == true ? "video.fill" : "video.slash.fill",
                        isActive: callManager.activeCall?.isVideoEnabled == true,
                        action: {
                            callManager.toggleVideo()
                        }
                    )

                    callControlButton(
                        systemName: callManager.activeCall?.isMuted == true ? "mic.slash.fill" : "mic.fill",
                        isActive: callManager.activeCall?.isMuted == false,
                        action: {
                            callManager.toggleMute()
                        }
                    )

                    callControlButton(
                        systemName: callManager.activeCall?.isSpeakerEnabled == true ? "speaker.wave.3.fill" : "speaker.slash.fill",
                        isActive: callManager.activeCall?.isSpeakerEnabled == true,
                        action: {
                            callManager.toggleSpeaker()
                        }
                    )

                    Button {
                        callManager.endCall()
                        dismiss()
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
                .padding(.bottom, 42)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
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
        let trimmed = call.user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? call.user.profile.username : trimmed
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
        switch callManager.activeCall?.state ?? call.state {
        case .calling:
            return "calls.state.internet".localized
        case .active:
            return "calls.state.active".localized
        case .ended:
            return "calls.state.ended".localized
        }
    }

    private var durationLabel: String {
        let duration = Int(callManager.activeCall?.duration ?? call.duration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
}
