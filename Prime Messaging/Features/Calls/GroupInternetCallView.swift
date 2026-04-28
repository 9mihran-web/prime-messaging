import SwiftUI

struct GroupInternetCallView: View {
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingInfoSheet = false
    @State private var isShowingMessageComposer = false
    @State private var isShowingParticipantPicker = false
    @State private var presentedProfileUser: User?
    @State private var callInfoStatusMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    PrimeTheme.Colors.background,
                    PrimeTheme.Colors.elevated.opacity(0.96),
                    PrimeTheme.Colors.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 22)
                    .padding(.top, 16)

                Spacer()

                centerInfo
                    .padding(.horizontal, 24)

                Spacer()

                participantsCard
                    .padding(.horizontal, 18)

                controlRow
                    .padding(.top, 24)
                    .padding(.bottom, 42)
            }
        }
        .interactiveDismissDisabled()
    }

    private var resolvedCall: InternetCall? {
        groupCallManager.activeCall
    }

    private var liveCount: Int {
        max(resolvedCall?.joinedParticipantIDs?.count ?? 1, 1)
    }

    private var statusLabel: String {
        if groupCallManager.isConnecting {
            return "Connecting participants…"
        }
        if liveCount == 1 {
            return "Waiting for others to join"
        }
        return "\(liveCount) participants live"
    }

    private var durationLabel: String {
        let totalSeconds = max(Int(groupCallManager.duration), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var headerBar: some View {
        HStack {
            Button {
                groupCallManager.dismissCallUI()
                dismiss()
            } label: {
                Circle()
                    .fill(PrimeTheme.Colors.elevated)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                isShowingInfoSheet = true
            } label: {
                Circle()
                    .fill(PrimeTheme.Colors.elevated)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $isShowingInfoSheet) {
            CallInfoSheet(
                title: groupCallManager.roomTitle,
                subtitle: statusLabel,
                duration: durationLabel,
                participants: infoSheetParticipants,
                statusMessage: callInfoStatusMessage,
                addParticipantTitle: "Add participant",
                showsContactInfoAction: false,
                onOpenChat: {
                    Task { @MainActor in
                        await openChatFromCall()
                    }
                },
                onSendMessage: {
                    isShowingMessageComposer = true
                },
                onOpenContactInfo: { },
                onSendEmoji: { emoji in
                    Task { @MainActor in
                        await sendMessageFromCall(emoji)
                    }
                },
                onOpenParticipant: { participant in
                    Task { @MainActor in
                        await openProfile(for: participant.id)
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
                Task { @MainActor in
                    await addParticipant(user)
                }
            }
            .environmentObject(appState)
        }
        .sheet(item: $presentedProfileUser) { user in
            ContactProfileView(user: user)
                .environmentObject(appState)
        }
    }

    private var centerInfo: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.16))
                .frame(width: 128, height: 128)
                .overlay(
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                )

            Text(groupCallManager.roomTitle)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            Text(statusLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Text(durationLabel)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary.opacity(0.92))

            if groupCallManager.lastErrorMessage.isEmpty == false {
                Text(groupCallManager.lastErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Participants")
                .font(.headline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            if groupCallManager.remoteParticipantStates.isEmpty {
                Text("Only you are in the call right now.")
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            } else {
                ForEach(groupCallManager.remoteParticipantStates) { state in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay(
                                Text(initials(for: state.participant))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: state.participant))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                            Text(connectionLabel(for: state))
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        Spacer()

                        if state.isMuted {
                            Image(systemName: "mic.slash.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PrimeTheme.Colors.warning)
                        }

                        Text(state.isJoined ? "Live" : "Waiting")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.isJoined ? PrimeTheme.Colors.success : PrimeTheme.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (state.isJoined ? PrimeTheme.Colors.success.opacity(0.12) : PrimeTheme.Colors.separator.opacity(0.14)),
                                in: Capsule()
                            )
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.25), lineWidth: 1)
        )
    }

    private var controlRow: some View {
        HStack(spacing: 18) {
            callControlButton(
                systemName: groupCallManager.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: !groupCallManager.isMuted
            ) {
                groupCallManager.toggleMute()
            }

            callControlButton(
                systemName: groupCallManager.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill",
                isActive: groupCallManager.isSpeakerEnabled
            ) {
                groupCallManager.toggleSpeaker()
            }

            Button {
                Task {
                    try? await groupCallManager.leaveCurrentCall()
                    dismiss()
                }
            } label: {
                Circle()
                    .fill(PrimeTheme.Colors.warning)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func callControlButton(systemName: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    private func displayName(for participant: InternetCallParticipant) -> String {
        let trimmedDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedDisplayName.isEmpty ? participant.username : trimmedDisplayName
    }

    private func initials(for participant: InternetCallParticipant) -> String {
        let label = displayName(for: participant)
        let parts = label.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        if letters.isEmpty {
            return String(label.prefix(2)).uppercased()
        }
        return String(letters.prefix(2)).uppercased()
    }

    private func connectionLabel(for state: GroupInternetCallManager.RemoteParticipantState) -> String {
        guard state.isJoined else { return "Joined room is waiting" }

        switch state.connectionState {
        case .connected, .completed:
            return "Connected"
        case .checking:
            return "Connecting audio…"
        case .failed:
            return "Connection failed"
        case .disconnected:
            return "Reconnecting…"
        case .closed:
            return "Disconnected"
        case .new, .unknown:
            return "Negotiating…"
        }
    }

    private var excludedParticipantIDs: Set<UUID> {
        Set((resolvedCall?.participants ?? []).map(\.id)).union([appState.currentUser.id])
    }

    private var infoSheetParticipants: [CallInfoSheetParticipant] {
        (resolvedCall?.otherParticipants(for: appState.currentUser.id) ?? []).map { participant in
            CallInfoSheetParticipant(
                id: participant.id,
                title: displayName(for: participant),
                subtitle: participant.username.isEmpty ? nil : "@\(participant.username)",
                photoURL: participant.profilePhotoURL
            )
        }
    }

    @MainActor
    private func resolveCallChat() async throws -> Chat {
        guard let chatID = resolvedCall?.chatID else {
            throw ChatRepositoryError.chatNotFound
        }
        let cached = await environment.chatRepository.cachedChats(mode: resolvedCall?.mode ?? .online, for: appState.currentUser.id)
        if let chat = cached.first(where: { $0.id == chatID }) {
            return chat
        }
        if let fetched = try? await environment.chatRepository.fetchChats(mode: resolvedCall?.mode ?? .online, for: appState.currentUser.id),
           let chat = fetched.first(where: { $0.id == chatID }) {
            return chat
        }
        throw ChatRepositoryError.chatNotFound
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
            groupCallManager.dismissCallUI()
            dismiss()
            appState.routeToChat(chat)
        } catch {
            callInfoStatusMessage = error.localizedDescription.isEmpty ? "Could not open chat." : error.localizedDescription
        }
    }

    @MainActor
    private func addParticipant(_ user: User) async {
        do {
            var chat = try await resolveCallChat()
            chat = try await environment.chatRepository.addMembers([user.id], to: chat, requesterID: appState.currentUser.id)
            callInfoStatusMessage = "Participant added to the call."
            if resolvedCall != nil {
                try? await groupCallManager.startOrJoinCall(in: chat)
            }
        } catch {
            callInfoStatusMessage = error.localizedDescription.isEmpty ? "Could not add the participant." : error.localizedDescription
        }
    }

    @MainActor
    private func openProfile(for userID: UUID) async {
        if let resolvedUser = try? await environment.authRepository.userProfile(userID: userID) {
            presentedProfileUser = resolvedUser
            return
        }
        guard let participant = resolvedCall?.participants.first(where: { $0.id == userID }) else {
            callInfoStatusMessage = "Could not open profile."
            return
        }
        presentedProfileUser = User(
            id: participant.id,
            profile: Profile(
                displayName: displayName(for: participant),
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
}

struct ActiveGroupCallMiniOverlay: View {
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared
    @State private var cardOffset: CGSize = .zero
    @GestureState private var cardDragOffset: CGSize = .zero

    private let cardWidth: CGFloat = 184
    private let cardHeight: CGFloat = 104

    var body: some View {
        GeometryReader { proxy in
            let combinedDragOffset = CGSize(
                width: cardOffset.width + cardDragOffset.width,
                height: cardOffset.height + cardDragOffset.height
            )
            let resolvedOffset = clampedCardOffset(combinedDragOffset, in: proxy)

            VStack {
                HStack {
                    Spacer()
                    ZStack(alignment: .topLeading) {
                        miniCard
                            .overlay {
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        groupCallManager.presentCallUI()
                                    }
                            }
                            .offset(resolvedOffset)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($cardDragOffset) { value, state, _ in
                                        state = value.translation
                                    }
                                    .onEnded { value in
                                        cardOffset = clampedCardOffset(
                                            CGSize(
                                                width: cardOffset.width + value.translation.width,
                                                height: cardOffset.height + value.translation.height
                                            ),
                                            in: proxy
                                        )
                                    }
                            )

                        Button {
                            Task {
                                try? await groupCallManager.leaveCurrentCall()
                            }
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(PrimeTheme.Colors.warning)
                                )
                        }
                        .buttonStyle(.plain)
                        .offset(x: -10 + resolvedOffset.width, y: -10 + resolvedOffset.height)
                    }
                }
                Spacer()
            }
            .padding(.top, max(proxy.safeAreaInsets.top + 8, 56))
            .padding(.trailing, 14)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var miniCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)

                Text("Group Call")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                Spacer()
            }

            Text(groupCallManager.roomTitle)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .lineLimit(2)

            Text("\(max(groupCallManager.activeCall?.joinedParticipantIDs?.count ?? 1, 1)) live")
                .font(.caption)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(14)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 10)
    }

    private func clampedCardOffset(_ candidate: CGSize, in proxy: GeometryProxy) -> CGSize {
        let safeInsets = proxy.safeAreaInsets
        let topPadding = max(proxy.safeAreaInsets.top + 8, 56)
        let minX = -(proxy.size.width - cardWidth - 28)
        let maxX: CGFloat = 0
        let minY = -max(0, topPadding - (safeInsets.top + 12))
        let maxY = max(minY, proxy.size.height - topPadding - cardHeight - safeInsets.bottom - 40)

        return CGSize(
            width: min(max(candidate.width, minX), maxX),
            height: min(max(candidate.height, minY), maxY)
        )
    }
}
