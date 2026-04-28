import SwiftUI

struct InternetCallView: View {
    @ObservedObject private var callManager = InternetCallManager.shared
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    let call: InternetCall

    @Environment(\.dismiss) private var dismiss
    @State private var areVideoControlsHidden = false
    @State private var localPreviewOffset: CGSize = .zero
    @State private var isShowingInfoSheet = false
    @State private var isShowingMessageComposer = false
    @State private var isShowingParticipantPicker = false
    @State private var selectedParticipantToAdd: User?
    @State private var isShowingParticipantModeDialog = false
    @State private var presentedProfileUser: User?
    @State private var callInfoStatusMessage = ""
    @GestureState private var localPreviewDragOffset: CGSize = .zero

    private let localPreviewSize = CGSize(width: 118, height: 178)
    private let localPreviewTopPadding: CGFloat = 84
    private let localPreviewTrailingPadding: CGFloat = 18
    private let localPreviewBottomPadding: CGFloat = 40

    private enum AddParticipantMode {
        case callOnly
        case createGroupAndAdd
    }

    var body: some View {
        GeometryReader { proxy in
            let resolvedCall = callManager.activeCall ?? call
            let isCallActive = resolvedCall.state == .active
            let isRemoteVideoActive = resolvedCall.state == .active && callManager.isRemoteVideoAvailable
            let isLocalPreviewVisible = resolvedCall.state == .active && callManager.isVideoEnabled
            let isVideoSurfaceVisible = isRemoteVideoActive || isLocalPreviewVisible
            let showsControls = !(areVideoControlsHidden && isVideoSurfaceVisible)
            let effectiveLocalPreviewTopPadding = showsControls
                ? localPreviewTopPadding
                : max(proxy.safeAreaInsets.top + 8, 8)
            let primaryTextColor: Color = isRemoteVideoActive ? .white : PrimeTheme.Colors.textPrimary
            let secondaryTextColor: Color = isRemoteVideoActive ? .white.opacity(0.85) : PrimeTheme.Colors.textSecondary
            let effectivePreviewOffset = clampedLocalPreviewOffset(
                localPreviewOffset + localPreviewDragOffset,
                in: proxy,
                topPadding: effectiveLocalPreviewTopPadding
            )

            ZStack {
                if isCallActive {
                    WebRTCVideoRendererView(stream: .remote)
                        .ignoresSafeArea()
                        .opacity(isRemoteVideoActive ? 1 : 0.001)
                        .allowsHitTesting(false)
                }

                if isRemoteVideoActive {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(showsControls ? 0.52 : 0.02),
                            Color.black.opacity(showsControls ? 0.16 : 0),
                            Color.black.opacity(showsControls ? 0.58 : 0.02),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
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
                }

                VStack(spacing: 0) {
                    if showsControls {
                        SwiftUI.Group {
                            if isRemoteVideoActive {
                                compactVideoTopBar(
                                    primaryTextColor: primaryTextColor,
                                    secondaryTextColor: secondaryTextColor
                                )
                            } else {
                                topBar
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                    }

                    if isRemoteVideoActive {
                        Spacer()
                    } else {
                        Spacer()
                        callCenterInfo(
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        )
                        Spacer()
                    }

                    if showsControls {
                        controlRow(for: resolvedCall)
                            .padding(.bottom, 42)
                    }
                }

                if isLocalPreviewVisible {
                    VStack {
                        HStack {
                            Spacer()
                            WebRTCVideoRendererView(stream: .local)
                                .frame(width: localPreviewSize.width, height: localPreviewSize.height)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.32), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.36), radius: 14, x: 0, y: 8)
                                .offset(effectivePreviewOffset)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .updating($localPreviewDragOffset) { value, state, _ in
                                            state = value.translation
                                        }
                                        .onEnded { value in
                                            localPreviewOffset = clampedLocalPreviewOffset(
                                                localPreviewOffset + value.translation,
                                                in: proxy,
                                                topPadding: effectiveLocalPreviewTopPadding
                                            )
                                        }
                                )
                        }
                        Spacer()
                    }
                    .padding(.top, effectiveLocalPreviewTopPadding)
                    .padding(.trailing, localPreviewTrailingPadding)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isCallActive, isVideoSurfaceVisible else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    areVideoControlsHidden.toggle()
                }
            }
            .animation(.easeInOut(duration: 0.24), value: isRemoteVideoActive)
            .animation(.easeInOut(duration: 0.18), value: isLocalPreviewVisible)
            .animation(.easeInOut(duration: 0.2), value: areVideoControlsHidden)
            .sheet(isPresented: $isShowingInfoSheet) {
                CallInfoSheet(
                    title: displayName,
                    subtitle: callStateLabel,
                    duration: durationLabel,
                    participants: infoSheetParticipants,
                    statusMessage: callInfoStatusMessage,
                    addParticipantTitle: "Add participant",
                    showsContactInfoAction: true,
                    onOpenChat: {
                        Task { @MainActor in
                            await openChatFromCall()
                        }
                    },
                    onSendMessage: {
                        isShowingMessageComposer = true
                    },
                    onOpenContactInfo: {
                        Task { @MainActor in
                            await openProfileFromCall()
                        }
                    },
                    onSendEmoji: { emoji in
                        Task { @MainActor in
                            await sendMessageFromCall(emoji)
                        }
                    },
                    onOpenParticipant: { _ in
                        Task { @MainActor in
                            await openProfileFromCall()
                        }
                    },
                    onAddParticipant: {
                        isShowingParticipantPicker = true
                    }
                )
            }
            .sheet(isPresented: $isShowingMessageComposer) {
                CallMessageComposerSheet(title: "Send message") { text in
                    Task { @MainActor in
                        await sendMessageFromCall(text)
                    }
                }
            }
            .sheet(isPresented: $isShowingParticipantPicker) {
                CallParticipantPickerSheet(
                    title: "Add participant",
                    excludedUserIDs: excludedParticipantIDs
                ) { user in
                    selectedParticipantToAdd = user
                    isShowingParticipantModeDialog = true
                }
                .environmentObject(appState)
            }
            .sheet(item: $presentedProfileUser) { user in
                ContactProfileView(user: user)
                    .environmentObject(appState)
            }
            .confirmationDialog(
                "How should this participant be added?",
                isPresented: $isShowingParticipantModeDialog,
                titleVisibility: .visible
            ) {
                Button("Add only to call") {
                    Task { @MainActor in
                        await addParticipant(using: .callOnly)
                    }
                }
                Button("Create group and add to call") {
                    Task { @MainActor in
                        await addParticipant(using: .createGroupAndAdd)
                    }
                }
                Button("Cancel", role: .cancel) {
                    selectedParticipantToAdd = nil
                }
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

            Button {
                isShowingInfoSheet = true
            } label: {
                topCircleButton(systemName: "info.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func compactVideoTopBar(
        primaryTextColor: Color,
        secondaryTextColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                callManager.dismissCallUI()
                dismiss()
            } label: {
                topCircleButton(systemName: "chevron.down")
            }
            .buttonStyle(.plain)

            VStack(spacing: 3) {
                Text(displayName)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)

                Text(callStateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)

                if callManager.isRemoteMuted {
                    remoteMutedBadge
                }

                Text(durationLabel)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(primaryTextColor.opacity(0.96))
                    .opacity(showsDuration ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)

            Button {
                isShowingInfoSheet = true
            } label: {
                topCircleButton(systemName: "info.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func callCenterInfo(
        primaryTextColor: Color,
        secondaryTextColor: Color
    ) -> some View {
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
                .foregroundStyle(primaryTextColor)

            Text(callStateLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(secondaryTextColor)

            if callManager.isRemoteMuted {
                remoteMutedBadge
            }

            Text(durationLabel)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(primaryTextColor.opacity(0.94))
                .opacity(showsDuration ? 1 : 0)
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
        let state = callManager.displayState(for: resolvedCall, viewerUserID: appState.currentUser.id)
        switch state {
        case .incoming:
            return "calls.state.incoming".localized
        case .calling:
            return "calls.state.calling".localized
        case .ringing:
            return "calls.state.ringing".localized
        case .connecting:
            return "calls.state.connecting".localized
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
        let totalSeconds = max(Int(callManager.duration), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var resolvedCall: InternetCall {
        callManager.activeCall ?? call
    }

    private var excludedParticipantIDs: Set<UUID> {
        Set(resolvedCall.participants.map(\.id)).union([appState.currentUser.id])
    }

    private var infoSheetParticipants: [CallInfoSheetParticipant] {
        resolvedCall.otherParticipants(for: appState.currentUser.id).map { participant in
            CallInfoSheetParticipant(
                id: participant.id,
                title: participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (participant.displayName ?? participant.username)
                    : participant.username,
                subtitle: participant.username.isEmpty ? nil : "@\(participant.username)",
                photoURL: participant.profilePhotoURL
            )
        }
    }

    @MainActor
    private func resolveCallChat() async throws -> Chat {
        if let chatID = resolvedCall.chatID {
            let cached = await environment.chatRepository.cachedChats(mode: resolvedCall.mode, for: appState.currentUser.id)
            if let chat = cached.first(where: { $0.id == chatID }) {
                return chat
            }
            if let fetched = try? await environment.chatRepository.fetchChats(mode: resolvedCall.mode, for: appState.currentUser.id),
               let chat = fetched.first(where: { $0.id == chatID }) {
                return chat
            }
        }

        guard let participantID = resolvedCall.otherParticipant(for: appState.currentUser.id)?.id else {
            throw ChatRepositoryError.chatNotFound
        }
        return try await environment.chatRepository.createDirectChat(
            with: participantID,
            currentUserID: appState.currentUser.id,
            mode: .online
        )
    }

    @MainActor
    private func sendMessageFromCall(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        do {
            let chat = try await resolveCallChat()
            _ = try await environment.chatRepository.sendMessage(
                OutgoingMessageDraft(text: trimmed),
                in: chat,
                senderID: appState.currentUser.id
            )
            callInfoStatusMessage = "Message sent."
        } catch {
            callInfoStatusMessage = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
        }
    }

    @MainActor
    private func openChatFromCall() async {
        do {
            let chat = try await resolveCallChat()
            callManager.dismissCallUI()
            dismiss()
            appState.routeToChat(chat)
        } catch {
            callInfoStatusMessage = error.localizedDescription.isEmpty ? "Could not open chat." : error.localizedDescription
        }
    }

    @MainActor
    private func openProfileFromCall() async {
        guard let participant = resolvedCall.otherParticipant(for: appState.currentUser.id) else {
            callInfoStatusMessage = "Could not open profile."
            return
        }

        if let resolvedUser = try? await environment.authRepository.userProfile(userID: participant.id) {
            presentedProfileUser = resolvedUser
            return
        }

        presentedProfileUser = User(
            id: participant.id,
            profile: Profile(
                displayName: participant.displayName?.isEmpty == false ? (participant.displayName ?? participant.username) : participant.username,
                username: participant.username,
                bio: "",
                status: "Last seen recently",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: participant.profilePhotoURL,
                socialLink: nil
            ),
            identityMethods: [],
            privacySettings: .defaultEmailOnly
        )
    }

    @MainActor
    private func addParticipant(using mode: AddParticipantMode) async {
        guard let selectedUser = selectedParticipantToAdd,
              let existingParticipant = resolvedCall.otherParticipant(for: appState.currentUser.id) else { return }

        selectedParticipantToAdd = nil

        let generatedTitle: String
        switch mode {
        case .callOnly:
            generatedTitle = "Call with \(displayName), \(selectedUser.profile.displayName)".trimmingCharacters(in: .whitespacesAndNewlines)
        case .createGroupAndAdd:
            generatedTitle = "Group call with \(displayName)"
        }

        do {
            let groupChat = try await environment.chatRepository.createGroupChat(
                title: generatedTitle.isEmpty ? "New group call" : generatedTitle,
                memberIDs: [existingParticipant.id, selectedUser.id],
                ownerID: appState.currentUser.id,
                mode: .online,
                communityDetails: nil
            )

            try? await callManager.endActiveCall()
            callManager.dismissCallUI()
            try await groupCallManager.startOrJoinCall(in: groupChat)
            if mode == .createGroupAndAdd {
                appState.routeToChat(groupChat)
            }
            callInfoStatusMessage = "Participant added to the call."
        } catch {
            callInfoStatusMessage = error.localizedDescription.isEmpty ? "Could not add the participant." : error.localizedDescription
        }
    }

    private var showsDuration: Bool {
        let resolvedCall = callManager.activeCall ?? call
        return callManager.shouldShowDuration(for: resolvedCall, viewerUserID: appState.currentUser.id)
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

                if callManager.isVideoEnabled {
                    callControlButton(
                        systemName: "arrow.triangle.2.circlepath.camera.fill",
                        isActive: true
                    ) {
                        callManager.switchCamera()
                    }
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
            callManager.endCall(source: "internet_call_view_hangup")
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

    private var remoteMutedBadge: some View {
        Label("Microphone off", systemImage: "mic.slash.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.94))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.28), in: Capsule())
    }

    private func clampedLocalPreviewOffset(_ candidate: CGSize, in proxy: GeometryProxy, topPadding: CGFloat) -> CGSize {
        let safeInsets = proxy.safeAreaInsets
        let availableWidth = proxy.size.width
        let availableHeight = proxy.size.height

        let minX = -(availableWidth - localPreviewSize.width - (localPreviewTrailingPadding * 2))
        let maxX: CGFloat = 0

        let minY = -max(0, topPadding - (safeInsets.top + 12))
        let maxY = max(
            minY,
            availableHeight - topPadding - localPreviewSize.height - localPreviewBottomPadding - safeInsets.bottom
        )

        return CGSize(
            width: min(max(candidate.width, minX), maxX),
            height: min(max(candidate.height, minY), maxY)
        )
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
