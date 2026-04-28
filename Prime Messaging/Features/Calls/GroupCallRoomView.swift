import SwiftUI

struct GroupCallRoomView: View {
    let chat: Chat

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared

    @State private var activeCall: InternetCall?
    @State private var isLoading = false
    @State private var isMutatingRoom = false
    @State private var errorText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                roomHeader

                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                        .multilineTextAlignment(.center)
                }

                roomStatusCard
                participantsCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Group Call")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshLoop()
        }
    }

    private var joinedParticipantIDs: Set<UUID> {
        Set(activeCall?.joinedParticipantIDs ?? [])
    }

    private var isCurrentUserJoined: Bool {
        joinedParticipantIDs.contains(appState.currentUser.id)
    }

    private var participantRoster: [InternetCallParticipant] {
        if let activeCall, activeCall.participants.isEmpty == false {
            return activeCall.participants
        }

        if chat.participants.isEmpty == false {
            return chat.participants.map {
                InternetCallParticipant(
                    id: $0.id,
                    username: $0.username,
                    displayName: $0.displayName,
                    profilePhotoURL: $0.photoURL
                )
            }
        }

        return (chat.group?.members ?? []).map {
            InternetCallParticipant(
                id: $0.userID,
                username: $0.username ?? "member",
                displayName: $0.displayName,
                profilePhotoURL: nil
            )
        }
    }

    private var roomHeader: some View {
        VStack(spacing: 10) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.14))
                .frame(width: 92, height: 92)
                .overlay(
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                )

            Text(chat.displayTitle(for: appState.currentUser.id))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text("Start or join a live group call for this chat.")
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var roomStatusCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activeCall == nil ? "No active group call" : "Live group call")
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button(actionTitle) {
                Task {
                    await performPrimaryAction()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isMutatingRoom || groupCallManager.isConnecting)

            if showsLeaveButton {
                Button("Leave Call") {
                    Task {
                        await leaveCall()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isMutatingRoom)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.25), lineWidth: 1)
        )
    }

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Participants")
                .font(.headline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            if participantRoster.isEmpty {
                Text("No participants available.")
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            } else {
                ForEach(participantRoster) { participant in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay(
                                Text(initials(for: participant))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: participant))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                            Text(participant.username)
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        Spacer()

                        if joinedParticipantIDs.contains(participant.id) {
                            Text("Live")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.success)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(PrimeTheme.Colors.success.opacity(0.12), in: Capsule())
                        } else {
                            Text("Waiting")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(PrimeTheme.Colors.separator.opacity(0.14), in: Capsule())
                        }
                    }
                    .padding(.vertical, 4)
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

    private var statusSubtitle: String {
        if activeCall != nil {
            let liveCount = max(joinedParticipantIDs.count, 1)
            if isCurrentUserJoined {
                return "\(liveCount) participant\(liveCount == 1 ? "" : "s") live in this room."
            }
            return "A room is live now. Join to take part."
        }
        return "Anyone in this chat can start the call room."
    }

    private var actionTitle: String {
        if activeCall == nil {
            return "Start Group Call"
        }
        return isCurrentUserJoined ? "Open Call" : "Join Call"
    }

    private var showsLeaveButton: Bool {
        activeCall != nil && isCurrentUserJoined
    }

    @MainActor
    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshActiveCall()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @MainActor
    private func refreshActiveCall() async {
        guard isMutatingRoom == false else { return }
        isLoading = true
        defer { isLoading = false }

        if let managedCall = groupCallManager.activeCall, managedCall.chatID == chat.id {
            activeCall = managedCall
        }

        do {
            activeCall = try await environment.callRepository.fetchActiveGroupCall(
                in: chat.id,
                userID: appState.currentUser.id
            )
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not load the group call state." : error.localizedDescription
        }
    }

    @MainActor
    private func performPrimaryAction() async {
        guard isMutatingRoom == false else { return }
        isMutatingRoom = true
        defer { isMutatingRoom = false }

        do {
            groupCallManager.configure(
                currentUserID: appState.currentUser.id,
                repository: environment.callRepository
            )
            try await groupCallManager.startOrJoinCall(in: chat)
            self.activeCall = groupCallManager.activeCall ?? self.activeCall
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not update the group call." : error.localizedDescription
        }
    }

    @MainActor
    private func leaveCall() async {
        guard isMutatingRoom == false else { return }
        isMutatingRoom = true
        defer { isMutatingRoom = false }

        do {
            if let managedCall = groupCallManager.activeCall,
               managedCall.chatID == chat.id,
               groupCallManager.isManaging(callID: managedCall.id) {
                try await groupCallManager.leaveCurrentCall()
                self.activeCall = nil
            } else if let activeCall {
                self.activeCall = try await environment.callRepository.leaveGroupCall(
                    activeCall.id,
                    userID: appState.currentUser.id
                )
            }
            errorText = ""
            await refreshActiveCall()
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not leave the group call." : error.localizedDescription
        }
    }

    private func displayName(for participant: InternetCallParticipant) -> String {
        let trimmed = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? participant.username : trimmed
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
}
