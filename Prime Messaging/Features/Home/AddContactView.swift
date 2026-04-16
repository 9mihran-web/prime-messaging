import SwiftUI

struct AddContactView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var manualName = ""
    @State private var manualUsername = ""
    @State private var users: [User] = []
    @State private var discoverableChats: [Chat] = []
    @State private var nearbyPeers: [OfflinePeer] = []
    @State private var errorText = ""
    @State private var isSavingContact = false
    @State private var pendingJoinRequestChat: Chat?
    @State private var joinRequestAnswers: [String] = []
    @State private var isSubmittingJoinRequest = false

    var body: some View {
        List {
            if appState.selectedMode != .offline {
                Section("contact.search.section".localized) {
                    TextField("contact.search.placeholder".localized, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }

                    if users.isEmpty && errorText.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("contact.search.empty".localized)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else {
                        ForEach(users) { user in
                            Button {
                                Task {
                                    await openOnlineChat(with: user)
                                }
                            } label: {
                                HStack(spacing: PrimeTheme.Spacing.medium) {
                                    AvatarBadgeView(profile: user.profile, size: 44)
                                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                        Text(user.profile.displayName)
                                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        Text("@\(user.profile.username)")
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if discoverableChats.isEmpty == false {
                    Section("Channels & Communities") {
                        ForEach(discoverableChats) { chat in
                            HStack(spacing: PrimeTheme.Spacing.medium) {
                                Circle()
                                    .fill(PrimeTheme.Colors.accent.opacity(0.14))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: chat.communityDetails?.symbolName ?? "megaphone.fill")
                                            .foregroundStyle(PrimeTheme.Colors.accent)
                                    )

                                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                    HStack(spacing: 6) {
                                        Text(chat.displayTitle(for: appState.currentUser.id))
                                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        if chat.communityDetails?.isOfficial == true {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(PrimeTheme.Colors.accent)
                                        }
                                    }
                                    Text(chat.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }

                                Spacer()

                                if chat.participantIDs.contains(appState.currentUser.id) {
                                    Text("Open")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                } else {
                                    Button(discoverableChatActionTitle(chat)) {
                                        Task {
                                            await joinDiscoverableChat(chat)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(PrimeTheme.Colors.accent)
                                    .font(.caption.weight(.semibold))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await openDiscoverableChatPreview(chat)
                                }
                            }
                        }
                    }
                }

                Section("contact.manual.section".localized) {
                    TextField("contact.name.placeholder".localized, text: $manualName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    TextField("contact.handle.placeholder".localized, text: $manualUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await saveManualContact()
                        }
                    } label: {
                        if isSavingContact {
                            HStack(spacing: PrimeTheme.Spacing.small) {
                                ProgressView()
                                Text("contact.create.chat".localized)
                            }
                        } else {
                            Text("contact.create.chat".localized)
                        }
                    }
                    .disabled(isManualSaveDisabled)
                }
            } else {
                Section("contact.search.section".localized) {
                    Text("contact.search.offline".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            if appState.selectedMode == .offline {
                Section("contact.bluetooth.section".localized) {
                    if nearbyPeers.isEmpty {
                        Text("contact.bluetooth.empty".localized)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else {
                        ForEach(nearbyPeers) { peer in
                            Button {
                                Task {
                                    await openNearbyChat(with: peer)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                    Text(peer.displayName)
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    Text("\(peer.alias) • RSSI \(peer.signalStrength)")
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("contact.add.title".localized)
        .task(id: appState.currentUser.id.uuidString) {
            await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        }
        .task(id: refreshTaskID) {
            await environment.offlineTransport.startScanning()
            while !Task.isCancelled {
                nearbyPeers = await environment.offlineTransport.discoveredPeers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: query + appState.selectedMode.rawValue) {
            if appState.selectedMode != .offline {
                await searchUsers()
            } else {
                users = []
                discoverableChats = []
                errorText = ""
            }
        }
        .sheet(item: $pendingJoinRequestChat) { chat in
            NavigationStack {
                joinRequestSheet(for: chat)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var refreshTaskID: String {
        "\(appState.selectedMode.rawValue)-\(appState.currentUser.id.uuidString)"
    }

    @MainActor
    private func searchUsers() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            users = []
            discoverableChats = []
            errorText = ""
            return
        }

        do {
            users = try await environment.authRepository.searchUsers(query: trimmed, excluding: appState.currentUser.id)
            discoverableChats = try await environment.chatRepository.searchDiscoverableChats(
                query: trimmed,
                mode: appState.selectedMode == .smart ? .smart : .online,
                currentUserID: appState.currentUser.id
            )
            errorText = ""
        } catch {
            users = []
            discoverableChats = []
            errorText = error.localizedDescription.isEmpty ? "contact.search.failed".localized : error.localizedDescription
        }
    }

    @MainActor
    private func openOnlineChat(with user: User) async {
        _ = await openOnlineChat(with: user, localDisplayName: nil)
    }

    @MainActor
    private func openOnlineChat(with user: User, localDisplayName: String?) async -> Bool {
        do {
            if let localDisplayName {
                await ContactAliasStore.shared.saveAlias(
                    ownerUserID: appState.currentUser.id,
                    remoteUserID: user.id,
                    remoteUsername: user.profile.username,
                    localDisplayName: localDisplayName
                )
            }

            var chat = try await environment.chatRepository.createDirectChat(
                with: user.id,
                currentUserID: appState.currentUser.id,
                mode: appState.selectedMode
            )
            let otherDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (localDisplayName ?? otherDisplayName)
                : (otherDisplayName.isEmpty ? user.profile.username : otherDisplayName)
            chat.title = resolvedTitle
            chat.subtitle = "@\(user.profile.username)"
            chat.participants = [
                ChatParticipant(
                    id: appState.currentUser.id,
                    username: appState.currentUser.profile.username,
                    displayName: appState.currentUser.profile.displayName
                ),
                ChatParticipant(
                    id: user.id,
                    username: user.profile.username,
                    displayName: user.profile.displayName
                )
            ]
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
            return true
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
            return false
        }
    }

    @MainActor
    private func openNearbyChat(with peer: OfflinePeer) async {
        do {
            let chat = try await environment.chatRepository.createNearbyChat(
                with: peer,
                currentUser: appState.currentUser
            )
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
        }
    }

    @MainActor
    private func openDiscoverableChatPreview(_ chat: Chat) async {
        errorText = ""
        dismiss()
        appState.routeToChatAfterCurrentTransition(chat)
    }

    @MainActor
    private func joinDiscoverableChat(_ chat: Chat) async {
        if shouldRequestApprovalBeforeJoin(chat) {
            beginJoinRequest(for: chat)
            return
        }

        do {
            let resolvedChat: Chat
            if chat.participantIDs.contains(appState.currentUser.id) {
                resolvedChat = chat
            } else {
                resolvedChat = try await environment.chatRepository.joinDiscoverableChat(
                    chat,
                    requesterID: appState.currentUser.id
                )
            }
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(resolvedChat)
        } catch {
            if let repositoryError = error as? ChatRepositoryError,
               case .joinApprovalRequired = repositoryError {
                beginJoinRequest(for: chat)
                return
            }
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
        }
    }

    private func discoverableChatActionTitle(_ chat: Chat) -> String {
        if chat.participantIDs.contains(appState.currentUser.id) {
            return "Open"
        }
        if shouldRequestApprovalBeforeJoin(chat) {
            return "Request"
        }
        return "Join"
    }

    private func shouldRequestApprovalBeforeJoin(_ chat: Chat) -> Bool {
        chat.participantIDs.contains(appState.currentUser.id) == false
            && chat.moderationSettings?.requiresJoinApproval == true
    }

    @MainActor
    private func beginJoinRequest(for chat: Chat) {
        pendingJoinRequestChat = chat
        let questions = chat.moderationSettings?.normalizedEntryQuestions ?? []
        joinRequestAnswers = Array(repeating: "", count: questions.count)
        errorText = ""
    }

    @MainActor
    private func submitJoinRequest(for chat: Chat) async {
        isSubmittingJoinRequest = true
        defer { isSubmittingJoinRequest = false }

        let normalizedAnswers = joinRequestAnswers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        do {
            try await environment.chatRepository.submitJoinRequest(
                for: chat,
                requesterID: appState.currentUser.id,
                answers: normalizedAnswers
            )
            pendingJoinRequestChat = nil
            joinRequestAnswers = []
            errorText = "Join request sent."
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not submit the join request." : error.localizedDescription
        }
    }

    @ViewBuilder
    private func joinRequestSheet(for chat: Chat) -> some View {
        let entryQuestions = chat.moderationSettings?.normalizedEntryQuestions ?? []

        List {
            Section {
                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                    Text(chat.displayTitle(for: appState.currentUser.id))
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text("This chat requires approval before joining.")
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .padding(.vertical, 4)
            }

            if entryQuestions.isEmpty == false {
                Section("Entry questions") {
                    ForEach(Array(entryQuestions.enumerated()), id: \.offset) { index, question in
                        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                            Text(question)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            TextField("Your answer", text: joinRequestAnswerBinding(at: index), axis: .vertical)
                                .lineLimit(2 ... 4)
                                #if os(tvOS)
                                .textFieldStyle(.automatic)
                                #else
                                .textFieldStyle(.roundedBorder)
                                #endif
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Button {
                    Task {
                        await submitJoinRequest(for: chat)
                    }
                } label: {
                    HStack {
                        if isSubmittingJoinRequest {
                            ProgressView()
                        }
                        Text(isSubmittingJoinRequest ? "Sending..." : "Send join request")
                    }
                }
                .disabled(isSubmittingJoinRequest)
            }
        }
        .navigationTitle("Join Request")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    pendingJoinRequestChat = nil
                    joinRequestAnswers = []
                }
            }
        }
    }

    private func joinRequestAnswerBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard joinRequestAnswers.indices.contains(index) else { return "" }
                return joinRequestAnswers[index]
            },
            set: { newValue in
                guard joinRequestAnswers.indices.contains(index) else { return }
                joinRequestAnswers[index] = newValue
            }
        )
    }

    @MainActor
    private func saveManualContact() async {
        let trimmedName = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = appState.normalizedUsername(
            manualUsername
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "@", with: "")
        )

        guard trimmedName.isEmpty == false, trimmedUsername.isEmpty == false else {
            return
        }

        isSavingContact = true
        defer { isSavingContact = false }

        do {
            let matches = try await environment.authRepository.searchUsers(query: trimmedUsername, excluding: appState.currentUser.id)
            guard let user = matches.first(where: { $0.profile.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame }) else {
                errorText = "contact.search.empty".localized
                return
            }

            let didOpenChat = await openOnlineChat(with: user, localDisplayName: trimmedName)
            guard didOpenChat else {
                return
            }
            manualName = ""
            manualUsername = ""
            query = ""
            users = []
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
        }
    }

    private var isManualSaveDisabled: Bool {
        isSavingContact
            || manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || appState.normalizedUsername(
                manualUsername
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "@", with: "")
            ).isEmpty
    }
}

struct AvatarBadgeView: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        if let url = profile.profilePhotoURL {
            CachedRemoteImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            placeholder
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(PrimeTheme.Colors.accent.opacity(0.85))
            .overlay(
                Text(String(profile.displayName.prefix(1)))
                    .font(.headline)
                    .foregroundStyle(Color.white)
            )
    }
}
