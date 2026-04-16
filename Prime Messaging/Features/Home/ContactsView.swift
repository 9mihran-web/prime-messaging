import SwiftUI

struct ContactsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var contacts: [ContactAliasStore.StoredContact] = []
    @State private var errorText = ""

    var body: some View {
        List {
            Section {
                TextField("Search contacts", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }

            if filteredContacts.isEmpty {
                Section {
                    Text("Saved Prime contacts will appear here.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section {
                    ForEach(filteredContacts) { contact in
                        Button {
                            Task {
                                await openChat(with: contact)
                            }
                        } label: {
                            HStack(spacing: PrimeTheme.Spacing.medium) {
                                Circle()
                                    .fill(PrimeTheme.Colors.accent.opacity(0.9))
                                    .frame(width: 46, height: 46)
                                    .overlay(
                                        Text(String(contact.localDisplayName.prefix(1)).uppercased())
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(Color.white)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(contact.localDisplayName)
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    Text("@\(contact.remoteUsername)")
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("tab.contacts".localized)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if appState.selectedMode == .offline {
                        AddContactView()
                    } else {
                        GlobalChatSearchView(mode: appState.selectedMode)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: appState.currentUser.id) {
            await loadContacts()
        }
    }

    private var filteredContacts: [ContactAliasStore.StoredContact] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return contacts }

        return contacts.filter { contact in
            contact.localDisplayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.remoteUsername.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    @MainActor
    private func loadContacts() async {
        contacts = await ContactAliasStore.shared.contacts(ownerUserID: appState.currentUser.id)
    }

    @MainActor
    private func openChat(with contact: ContactAliasStore.StoredContact) async {
        do {
            let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode
            var chat = try await environment.chatRepository.createDirectChat(
                with: contact.remoteUserID,
                currentUserID: appState.currentUser.id,
                mode: preferredMode
            )
            chat.title = contact.localDisplayName
            chat.subtitle = "@\(contact.remoteUsername)"
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this contact." : error.localizedDescription
        }
    }
}

struct GlobalChatSearchView: View {
    let mode: ChatMode

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var chats: [Chat] = []
    @State private var contacts: [ContactAliasStore.StoredContact] = []
    @State private var users: [User] = []
    @State private var discoverableChats: [Chat] = []
    @State private var nearbyPeers: [OfflinePeer] = []
    @State private var errorText = ""
    @State private var recentSearches: [String] = []
    @State private var isSearchingRemotely = false
    @State private var pendingJoinRequestChat: Chat?
    @State private var joinRequestAnswers: [String] = []
    @State private var isSubmittingJoinRequest = false

    var body: some View {
        List {
            Section {
                TextField("People, chats, channels, communities", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            await persistQueryIfNeeded()
                        }
                    }
            }

            if isSearchingRemotely {
                Section {
                    HStack(spacing: PrimeTheme.Spacing.small) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               recentSearches.isEmpty == false {
                Section("Recent searches") {
                    ForEach(recentSearches, id: \.self) { recentQuery in
                        Button {
                            query = recentQuery
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                Text(recentQuery)
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if contacts.isEmpty == false {
                    Section("Saved contacts") {
                        ForEach(contacts.prefix(6)) { contact in
                            Button {
                                Task {
                                    await openChat(with: contact)
                                }
                            } label: {
                                savedContactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if chats.isEmpty == false {
                    Section("Recent chats") {
                        ForEach(chats.prefix(8)) { chat in
                            Button {
                                dismiss()
                                appState.routeToChatAfterCurrentTransition(chat)
                            } label: {
                                ChatRowView(chat: chat, currentUserID: appState.currentUser.id, visibleMode: chat.mode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if hasVisibleResults == false {
                Section {
                    Text(mode == .offline ? "No nearby peers or local chats matched that search." : "No people, chats, or public spaces matched that search.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                if filteredChats.isEmpty == false {
                    Section("Chats") {
                        ForEach(filteredChats) { chat in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                }
                                dismiss()
                                appState.routeToChatAfterCurrentTransition(chat)
                            } label: {
                                ChatRowView(chat: chat, currentUserID: appState.currentUser.id, visibleMode: chat.mode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredContacts.isEmpty == false {
                    Section("Saved contacts") {
                        ForEach(filteredContacts) { contact in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openChat(with: contact)
                                }
                            } label: {
                                savedContactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if users.isEmpty == false {
                    Section("People") {
                        ForEach(users) { user in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
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
                            .buttonStyle(.plain)
                        }
                    }
                }

                if discoverableChats.isEmpty == false {
                    Section("Channels & Communities") {
                        ForEach(discoverableChats) { chat in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openDiscoverableChat(chat)
                                }
                            } label: {
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

                                    Text(discoverableChatActionTitle(chat))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredNearbyPeers.isEmpty == false {
                    Section("Nearby") {
                        ForEach(filteredNearbyPeers) { peer in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openNearbyChat(with: peer)
                                }
                            } label: {
                                HStack(spacing: PrimeTheme.Spacing.medium) {
                                    Circle()
                                        .fill(PrimeTheme.Colors.offlineAccent.opacity(0.14))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                                .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                        )

                                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                        Text(peer.displayName)
                                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        Text(peer.alias.isEmpty ? "Nearby peer" : "@\(peer.alias)")
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }

                                    Spacer()

                                    Text("Open")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Discover")
        .task(id: "\(mode.rawValue)-\(appState.currentUser.id.uuidString)") {
            await loadDiscoveryContext()
        }
        .task(id: searchTaskID) {
            await refreshSearchResults()
        }
        .sheet(item: $pendingJoinRequestChat) { chat in
            NavigationStack {
                joinRequestSheet(for: chat)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var searchTaskID: String {
        "\(mode.rawValue)-\(appState.currentUser.id.uuidString)-\(query)"
    }

    private var filteredChats: [Chat] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return chats.filter { chat in
            chat.displayTitle(for: appState.currentUser.id).localizedCaseInsensitiveContains(trimmedQuery)
                || chat.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
                || (chat.lastMessagePreview?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    private var filteredContacts: [ContactAliasStore.StoredContact] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return contacts.filter { contact in
            contact.localDisplayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.remoteUsername.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredNearbyPeers: [OfflinePeer] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return nearbyPeers.filter { peer in
            peer.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || peer.alias.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var hasVisibleResults: Bool {
        filteredChats.isEmpty == false
            || filteredContacts.isEmpty == false
            || users.isEmpty == false
            || discoverableChats.isEmpty == false
            || filteredNearbyPeers.isEmpty == false
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func savedContactRow(_ contact: ContactAliasStore.StoredContact) -> some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.9))
                .frame(width: 46, height: 46)
                .overlay(
                    Text(String(contact.localDisplayName.prefix(1)).uppercased())
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.localDisplayName)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text("@\(contact.remoteUsername)")
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
    }

    @MainActor
    private func loadDiscoveryContext() async {
        recentSearches = await ChatNavigationStateStore.shared.recentGlobalSearches(ownerUserID: appState.currentUser.id)
        contacts = await ContactAliasStore.shared.contacts(ownerUserID: appState.currentUser.id)
        nearbyPeers = await environment.offlineTransport.discoveredPeers()
        await loadChats()
    }

    @MainActor
    private func refreshSearchResults() async {
        let trimmedQuery = normalizedQuery
        isSearchingRemotely = false

        if mode == .offline {
            users = []
            discoverableChats = []
            nearbyPeers = await environment.offlineTransport.discoveredPeers()
            errorText = ""
            return
        }

        guard trimmedQuery.isEmpty == false else {
            users = []
            discoverableChats = []
            errorText = ""
            return
        }

        isSearchingRemotely = true
        defer { isSearchingRemotely = false }
        do {
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }

            async let foundUsers = environment.authRepository.searchUsers(query: trimmedQuery, excluding: appState.currentUser.id)
            async let foundDiscoverableChats = environment.chatRepository.searchDiscoverableChats(
                query: trimmedQuery,
                mode: mode == .smart ? .smart : .online,
                currentUserID: appState.currentUser.id
            )

            let fetchedUsers = try await foundUsers
            let fetchedDiscoverableChats = try await foundDiscoverableChats
            guard Task.isCancelled == false, trimmedQuery == normalizedQuery else { return }

            users = fetchedUsers
            discoverableChats = fetchedDiscoverableChats
            errorText = ""
        } catch {
            guard Task.isCancelled == false else { return }
            users = []
            discoverableChats = []
            errorText = error.localizedDescription.isEmpty ? "Could not search right now." : error.localizedDescription
        }
    }

    @MainActor
    private func loadChats() async {
        let cachedChats = await environment.chatRepository.cachedChats(mode: mode, for: appState.currentUser.id)
        if cachedChats.isEmpty == false {
            chats = await cachedChats.asyncMap { chat in
                await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            }
        }

        do {
            let fetchedChats = try await environment.chatRepository.fetchChats(mode: mode, for: appState.currentUser.id)
            chats = await fetchedChats.asyncMap { chat in
                await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            }
            if normalizedQuery.isEmpty {
                errorText = ""
            }
        } catch {
            if chats.isEmpty {
                errorText = error.localizedDescription.isEmpty ? "Could not load chats." : error.localizedDescription
            }
        }
    }

    @MainActor
    private func openChat(with contact: ContactAliasStore.StoredContact) async {
        do {
            let preferredMode: ChatMode = mode == .offline ? .smart : mode
            var chat = try await environment.chatRepository.createDirectChat(
                with: contact.remoteUserID,
                currentUserID: appState.currentUser.id,
                mode: preferredMode
            )
            chat.title = contact.localDisplayName
            chat.subtitle = "@\(contact.remoteUsername)"
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this contact." : error.localizedDescription
        }
    }

    @MainActor
    private func openOnlineChat(with user: User) async {
        do {
            var chat = try await environment.chatRepository.createDirectChat(
                with: user.id,
                currentUserID: appState.currentUser.id,
                mode: mode == .smart ? .smart : .online
            )
            let otherDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.title = otherDisplayName.isEmpty ? user.profile.username : otherDisplayName
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
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
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
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
        }
    }

    @MainActor
    private func openDiscoverableChat(_ chat: Chat) async {
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

    private func persistQueryIfNeeded() async {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return }
        await ChatNavigationStateStore.shared.saveGlobalSearch(trimmedQuery, ownerUserID: appState.currentUser.id)
        recentSearches = await ChatNavigationStateStore.shared.recentGlobalSearches(ownerUserID: appState.currentUser.id)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)

        for element in self {
            results.append(await transform(element))
        }

        return results
    }
}
