import SwiftUI

struct NewGroupView: View {
    private enum TemporaryRoomDuration: String, CaseIterable, Identifiable {
        case sixHours
        case oneDay
        case threeDays
        case oneWeek

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sixHours:
                return "6 hours"
            case .oneDay:
                return "24 hours"
            case .threeDays:
                return "3 days"
            case .oneWeek:
                return "7 days"
            }
        }

        var interval: TimeInterval {
            switch self {
            case .sixHours:
                return 6 * 60 * 60
            case .oneDay:
                return 24 * 60 * 60
            case .threeDays:
                return 3 * 24 * 60 * 60
            case .oneWeek:
                return 7 * 24 * 60 * 60
            }
        }
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var title = ""
    @State private var query = ""
    @State private var users: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var createdChat: Chat?
    @State private var errorText = ""
    @State private var isCreating = false
    @State private var createsTemporaryEventRoom = false
    @State private var temporaryRoomDuration: TemporaryRoomDuration = .oneDay
    @State private var communityKind: CommunityKind = .group
    @State private var enablesForumMode = false
    @State private var enablesComments = false
    @State private var isPublicCommunity = false
    @State private var topicSeedText = ""

    private var isOfflineMode: Bool {
        appState.selectedMode == .offline
    }

    private var effectiveCommunityKind: CommunityKind {
        isOfflineMode ? .group : communityKind
    }

    init(initialCommunityKind: CommunityKind = .group) {
        _communityKind = State(initialValue: initialCommunityKind)
        _enablesForumMode = State(initialValue: initialCommunityKind == .community)
        _enablesComments = State(initialValue: initialCommunityKind == .channel)
        _isPublicCommunity = State(initialValue: initialCommunityKind == .channel)
    }

    var body: some View {
        List {
            Section(setupSectionTitle) {
                TextField(titlePlaceholder, text: $title)

                if isOfflineMode == false {
                    Picker("Community type", selection: $communityKind) {
                        ForEach(CommunityKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbolName)
                                .tag(kind)
                        }
                    }

                    Toggle("Forum mode", isOn: $enablesForumMode)
                    Toggle("Allow comments", isOn: $enablesComments)
                    Toggle("Public room", isOn: $isPublicCommunity)

                    if enablesForumMode || communityKind == .channel || communityKind == .community {
                        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                            TextField("Seed topics (one per line)", text: $topicSeedText, axis: .vertical)
                                .lineLimit(3 ... 6)

                            Text("Topics will be created locally so the room already feels structured on first open.")
                                .font(.footnote)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                } else {
                    Text("Offline mode only supports normal groups.")
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Toggle("Create temporary event room", isOn: $createsTemporaryEventRoom)

                if createsTemporaryEventRoom {
                    Picker("Room duration", selection: $temporaryRoomDuration) {
                        ForEach(TemporaryRoomDuration.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    Text("This room will be marked as temporary and disappear from your list after it expires.")
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                if selectedUsers.isEmpty == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: PrimeTheme.Spacing.small) {
                            ForEach(selectedUsers) { user in
                                Button {
                                    toggle(user)
                                } label: {
                                    Text(user.profile.displayName)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, PrimeTheme.Spacing.medium)
                                        .padding(.vertical, PrimeTheme.Spacing.small)
                                        .background(PrimeTheme.Colors.accent.opacity(0.14))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, PrimeTheme.Spacing.xSmall)
                    }
                }
            }

            if showsMemberSelectionSection {
                Section("Members") {
                    TextField("Search username", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }

                    ForEach(users) { user in
                        Button {
                            toggle(user)
                        } label: {
                            HStack(spacing: PrimeTheme.Spacing.medium) {
                                AvatarBadgeView(profile: user.profile, size: 42)
                                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                    Text(user.profile.displayName)
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    Text("@\(user.profile.username)")
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }
                                Spacer()
                                if selectedUsers.contains(user) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Button(createButtonTitle) {
                    Task {
                        await createGroup()
                    }
                }
                .disabled(isCreateDisabled)
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationDestination(
            isPresented: Binding(
                get: { createdChat != nil },
                set: { isPresented in
                    if isPresented == false {
                        createdChat = nil
                    }
                }
            )
        ) {
            if let createdChat {
                ChatView(chat: createdChat)
            }
        }
        .task(id: query) {
            await searchUsers()
        }
        .task(id: appState.selectedMode) {
            guard isOfflineMode else { return }
            communityKind = .group
            enablesForumMode = false
            enablesComments = false
            isPublicCommunity = false
            topicSeedText = ""
        }
        .onChange(of: communityKind) { newValue in
            if newValue == .channel {
                selectedUsers = []
                users = []
                query = ""
                errorText = ""
            }
        }
    }

    private var isCreateDisabled: Bool {
        isCreating ||
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        (effectiveCommunityKind != .channel && selectedUsers.isEmpty)
    }

    private var showsMemberSelectionSection: Bool {
        effectiveCommunityKind != .channel
    }

    @MainActor
    private func searchUsers() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            users = []
            errorText = ""
            return
        }

        do {
            users = try await environment.authRepository.searchUsers(query: trimmed, excluding: appState.currentUser.id)
            errorText = ""
        } catch {
            users = []
            errorText = error.localizedDescription.isEmpty ? "Could not search users." : error.localizedDescription
        }
    }

    @MainActor
    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }

        do {
            let mode: ChatMode = appState.selectedMode == .smart ? .smart : .online
            let effectiveDetails = CommunityChatDetails(
                kind: effectiveCommunityKind,
                forumModeEnabled: isOfflineMode ? false : enablesForumMode,
                commentsEnabled: isOfflineMode ? false : enablesComments,
                isPublic: isOfflineMode ? false : isPublicCommunity,
                topics: isOfflineMode ? [] : parsedSeedTopics()
            )
            var newChat = try await environment.chatRepository.createGroupChat(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                memberIDs: selectedUsers.map(\.id),
                ownerID: appState.currentUser.id,
                mode: mode,
                communityDetails: effectiveDetails
            )

            if createsTemporaryEventRoom {
                let details = EventChatDetails(
                    kind: .temporaryRoom,
                    startsAt: .now,
                    endsAt: Date().addingTimeInterval(temporaryRoomDuration.interval),
                    createdByUserID: appState.currentUser.id
                )
                await EventChatMetadataStore.shared.setMetadata(
                    details,
                    ownerUserID: appState.currentUser.id,
                    chatID: newChat.id
                )
                newChat.eventDetails = details
            }

            let communityDetails = CommunityChatDetails(
                kind: effectiveCommunityKind,
                forumModeEnabled: isOfflineMode ? false : enablesForumMode,
                commentsEnabled: isOfflineMode ? false : enablesComments,
                isPublic: isOfflineMode ? false : isPublicCommunity,
                topics: isOfflineMode ? [] : parsedSeedTopics(),
                inviteCode: newChat.communityDetails?.inviteCode,
                inviteLink: newChat.communityDetails?.inviteLink,
                isOfficial: newChat.communityDetails?.isOfficial ?? false
            )
            if communityDetails.kind != .group
                || communityDetails.forumModeEnabled
                || communityDetails.commentsEnabled
                || communityDetails.isPublic
                || communityDetails.topics.isEmpty == false {
                await CommunityChatMetadataStore.shared.setDetails(
                    communityDetails,
                    ownerUserID: appState.currentUser.id,
                    chatID: newChat.id
                )
                newChat.communityDetails = communityDetails
            }

            createdChat = newChat
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not create group." : error.localizedDescription
        }
    }

    private func toggle(_ user: User) {
        if let existingIndex = selectedUsers.firstIndex(of: user) {
            selectedUsers.remove(at: existingIndex)
        } else {
            selectedUsers.append(user)
        }
    }

    private var createButtonTitle: String {
        switch effectiveCommunityKind {
        case .group:
            return "Create group"
        case .supergroup:
            return "Create supergroup"
        case .channel:
            return "Create channel"
        case .community:
            return "Create community"
        }
    }

    private var navigationTitleText: String {
        switch effectiveCommunityKind {
        case .group:
            return "New Group"
        case .supergroup:
            return "New Supergroup"
        case .channel:
            return "New Channel"
        case .community:
            return "New Community"
        }
    }

    private var setupSectionTitle: String {
        switch effectiveCommunityKind {
        case .channel:
            return "Channel"
        case .community:
            return "Community"
        case .supergroup:
            return "Supergroup"
        case .group:
            return "Group"
        }
    }

    private var titlePlaceholder: String {
        switch effectiveCommunityKind {
        case .channel:
            return "Channel title"
        case .community:
            return "Community title"
        case .supergroup:
            return "Supergroup title"
        case .group:
            return "Group title"
        }
    }

    private func parsedSeedTopics() -> [CommunityTopic] {
        topicSeedText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .prefix(8)
            .enumerated()
            .map { index, title in
                CommunityTopic(
                    title: title,
                    symbolName: index == 0 ? "pin.fill" : "number",
                    unreadCount: 0,
                    isPinned: index == 0
                )
            }
    }
}
