import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum ChatFeedCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case chats
    case groups
    case channels
    case communities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .chats:
            return "Chats"
        case .groups:
            return "Groups"
        case .channels:
            return "Channels"
        case .communities:
            return "Communities"
        }
    }
}

struct ChatListView: View {
    let mode: ChatMode
    let categoryFilter: ChatFeedCategoryFilter
    var embeddedInScroll = false

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var mediaPlaybackActivity = MediaPlaybackActivityStore.shared
    @StateObject private var viewModel = ChatListViewModel()
    @State private var pendingDeferredHydration = false
    @State private var pendingDeferredRefresh = false

    var body: some View {
        SwiftUI.Group {
            if embeddedInScroll {
                content
            } else {
                ScrollView {
                    content
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(PrimeTheme.Colors.background)
        .navigationDestination(for: Chat.self) { chat in
            ChatView(chat: chat)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { appState.routedChat != nil },
                set: { isPresented in
                    if isPresented == false {
                        appState.clearRoutedChat()
                    }
                }
            )
        ) {
            if let routedChat = appState.routedChat {
                ChatView(chat: routedChat)
            }
        }
        .task(id: refreshTaskID) {
            await hydrateChatsIfAppropriate(force: true)
            while !Task.isCancelled {
                await refreshChatsIfAppropriate()
                try? await Task.sleep(for: feedRefreshInterval)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDraftsChanged)) { _ in
            if shouldDeferFeedRefresh {
                pendingDeferredHydration = true
            } else {
                viewModel.scheduleHydration(
                    mode: mode,
                    repository: environment.chatRepository,
                    localStore: environment.localStore,
                    userID: appState.currentUser.id
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged)) { _ in
            if shouldDeferFeedRefresh {
                pendingDeferredHydration = true
            } else {
                viewModel.scheduleHydration(
                    mode: mode,
                    repository: environment.chatRepository,
                    localStore: environment.localStore,
                    userID: appState.currentUser.id
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await refreshChatsIfAppropriate(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingIncomingChatPush)) { notification in
            guard
                let userInfo = notification.userInfo,
                let route = NotificationChatRoute(userInfo: userInfo),
                route.mode == mode
            else {
                return
            }
            Task {
                await refreshChatsIfAppropriate(force: true)
            }
        }
        .onChange(of: mediaPlaybackActivity.isPlaybackActive) { isActive in
            guard isActive == false else { return }
            Task {
                await runDeferredFeedUpdatesIfNeeded()
            }
        }
    }

    private var refreshTaskID: String {
        "\(mode.rawValue)-\(appState.currentUser.id.uuidString)"
    }

    private var isChatScreenVisible: Bool {
        appState.selectedChat != nil
    }

    private var shouldDeferFeedRefresh: Bool {
        isChatScreenVisible && mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 1.75)
    }

    private var feedRefreshInterval: Duration {
        switch mode {
        case .offline:
            return .seconds(4)
        case .smart, .online:
            return isChatScreenVisible ? .seconds(18) : .seconds(8)
        }
    }

    @MainActor
    private func hydrateChatsIfAppropriate(force: Bool = false) async {
        if force == false, shouldDeferFeedRefresh {
            pendingDeferredHydration = true
            return
        }

        pendingDeferredHydration = false
        await viewModel.hydrateChats(
            mode: mode,
            repository: environment.chatRepository,
            localStore: environment.localStore,
            userID: appState.currentUser.id
        )
        _ = appState.resolvePendingNotificationRoute(with: viewModel.chats)
    }

    @MainActor
    private func refreshChatsIfAppropriate(force: Bool = false) async {
        if force == false, shouldDeferFeedRefresh {
            pendingDeferredRefresh = true
            return
        }

        pendingDeferredRefresh = false
        await viewModel.refreshChats(
            mode: mode,
            repository: environment.chatRepository,
            localStore: environment.localStore,
            userID: appState.currentUser.id
        )
        _ = appState.resolvePendingNotificationRoute(with: viewModel.chats)
    }

    @MainActor
    private func runDeferredFeedUpdatesIfNeeded() async {
        guard shouldDeferFeedRefresh == false else { return }

        if pendingDeferredHydration {
            await hydrateChatsIfAppropriate(force: true)
        }

        if pendingDeferredRefresh {
            await refreshChatsIfAppropriate(force: true)
        }
    }

    private var content: some View {
        let rows = displayRows
        return LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                let chat = row.chat
                ChatSwipeRow(
                    leadingActions: leadingActions(for: chat),
                    trailingActions: trailingActions(for: chat)
                ) {
                    appState.routeToChat(chat)
                } content: {
                    ChatRowView(chat: chat, currentUserID: appState.currentUser.id, visibleMode: mode)
                }
                .padding(.vertical, 2)

                if row.id != rows.last?.id {
                    Divider()
                        .background(PrimeTheme.Colors.separator.opacity(0.35))
                        .padding(.leading, 74)
                }
            }
        }
    }

    private var displayRows: [ChatFeedRow] {
        filteredChats.map { chat in
            ChatFeedRow(
                id: chatFeedIdentityKey(for: chat, currentUserID: appState.currentUser.id),
                chat: chat
            )
        }
    }

    private var filteredChats: [Chat] {
        viewModel.chats.filter { chat in
            matchesFilter(chat: chat)
        }
    }

    private func matchesFilter(chat: Chat) -> Bool {
        switch categoryFilter {
        case .all:
            return true
        case .chats:
            return chat.communityDetails == nil && chat.type != .group
        case .groups:
            if chat.type == .group {
                return true
            }
            guard let kind = chat.communityDetails?.kind else {
                return false
            }
            return kind == .group || kind == .supergroup
        case .channels:
            return chat.communityDetails?.kind == .channel
        case .communities:
            return chat.communityDetails?.kind == .community
        }
    }

    private func leadingActions(for chat: Chat) -> [ChatRowSwipeAction] {
        [
            ChatRowSwipeAction(
                title: "Read",
                systemName: "checkmark.circle",
                tint: PrimeTheme.Colors.offlineAccent
            ) {
                Task {
                    await viewModel.markChatRead(
                        chat,
                        repository: environment.chatRepository,
                        currentUserID: appState.currentUser.id
                    )
                }
            },
            ChatRowSwipeAction(
                title: chat.isPinned ? "Unpin" : "Pin",
                systemName: chat.isPinned ? "pin.slash.fill" : "pin.fill",
                tint: PrimeTheme.Colors.accent
            ) {
                Task {
                    await viewModel.togglePinned(chat, currentUserID: appState.currentUser.id)
                }
            },
        ]
    }

    private func trailingActions(for chat: Chat) -> [ChatRowSwipeAction] {
        [
            ChatRowSwipeAction(
                title: chat.notificationPreferences.muteState == .active ? "Mute" : "Unmute",
                systemName: chat.notificationPreferences.muteState == .active ? "bell.slash.fill" : "bell.fill",
                tint: PrimeTheme.Colors.warning
            ) {
                Task {
                    await viewModel.toggleMute(chat, currentUserID: appState.currentUser.id)
                }
            },
            ChatRowSwipeAction(
                title: "Delete",
                systemName: "trash.fill",
                tint: Color.red
            ) {
                Task {
                    await viewModel.hideChat(chat, currentUserID: appState.currentUser.id)
                }
            },
        ]
    }
}

struct ChatRowView: View {
    let chat: Chat
    let currentUserID: UUID
    let visibleMode: ChatMode

    var body: some View {
        HStack(alignment: .center, spacing: PrimeTheme.Spacing.medium) {
            avatarView

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(chat.displayTitle(for: currentUserID))
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                            if chat.communityDetails?.isOfficial == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            }

                            if let communityDetails = chat.communityDetails {
                                Label(communityDetails.badgeTitle, systemImage: communityDetails.symbolName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                                    )
                            }

                            if let eventDetails = chat.eventDetails, eventDetails.isExpired == false {
                                Label(eventDetails.badgeTitle, systemImage: eventDetails.symbolName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(PrimeTheme.Colors.offlineAccent.opacity(0.14))
                                    )
                            }
                        }

                        Text(chat.lastMessagePreview ?? chat.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)

                        if let eventStatus = chat.eventStatusText() {
                            Text(eventStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                .lineLimit(1)
                        } else if let communityStatus = chat.communityStatusText() {
                            Text(communityStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.accentSoft)
                                .lineLimit(1)
                        } else if let moderationStatus = chat.moderationStatusText() {
                            Text(moderationStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.warning)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let timestampText {
                            Text(timestampText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule(style: .continuous).fill(PrimeTheme.Colors.accent))
                        }
                    }
                }

                if let draft = chat.draft {
                    Text("Draft: \(draft.text)")
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.accentSoft)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 14)
    }

    private var avatarView: some View {
        SwiftUI.Group {
            if let photoURL = avatarPhotoURL {
                CachedRemoteImage(url: photoURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    private var avatarPhotoURL: URL? {
        if let groupPhotoURL = chat.group?.photoURL {
            return groupPhotoURL
        }
        return chat.directParticipant(for: currentUserID)?.photoURL
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(avatarAccentColor.opacity(0.92))
            .overlay(
                Text(String(chat.displayTitle(for: currentUserID).prefix(1)))
                    .font(.headline)
                    .foregroundStyle(Color.white)
            )
    }

    private var avatarAccentColor: Color {
        switch visibleMode {
        case .smart:
            return PrimeTheme.Colors.smartAccent
        case .online:
            return PrimeTheme.Colors.accent
        case .offline:
            return PrimeTheme.Colors.offlineAccent
        }
    }

    private var timestampText: String? {
        guard chat.type != .selfChat else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(chat.lastActivityAt) {
            return chat.lastActivityAt.formatted(.dateTime.hour().minute())
        }

        if calendar.isDateInYesterday(chat.lastActivityAt) {
            return "Yesterday"
        }

        return chat.lastActivityAt.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits))
    }
}

private struct ChatFeedRow: Identifiable {
    let id: String
    let chat: Chat
}

final class ChatListViewModel: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    private var activeScopeID = ""
    private var pendingHydrationTask: Task<Void, Never>?

    deinit {
        pendingHydrationTask?.cancel()
    }

    @MainActor
    func scheduleHydration(
        mode: ChatMode,
        repository: ChatRepository,
        localStore: LocalStore,
        userID: UUID,
        delay: Duration = .milliseconds(180)
    ) {
        pendingHydrationTask?.cancel()
        pendingHydrationTask = Task { [mode, repository, localStore, userID] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            await self.hydrateChats(
                mode: mode,
                repository: repository,
                localStore: localStore,
                userID: userID
            )
        }
    }

    @MainActor
    func hydrateChats(mode: ChatMode, repository: ChatRepository, localStore: LocalStore, userID: UUID) async {
        let scopeID = "\(mode.rawValue)-\(userID.uuidString)"
        if activeScopeID != scopeID {
            activeScopeID = scopeID
        }

        let cachedChats = await repository.cachedChats(mode: mode, for: userID)
        guard activeScopeID == scopeID else { return }
        await applyFetchedChats(
            cachedChats,
            repository: repository,
            localStore: localStore,
            currentUserID: userID,
            visibleMode: mode,
            preserveExistingWhenEmpty: true
        )
    }

    @MainActor
    func refreshChats(mode: ChatMode, repository: ChatRepository, localStore: LocalStore, userID: UUID) async {
        let scopeID = "\(mode.rawValue)-\(userID.uuidString)"
        if activeScopeID != scopeID {
            activeScopeID = scopeID
        }
        do {
            let fetchedChats = try await repository.fetchChats(mode: mode, for: userID)
            guard activeScopeID == scopeID else { return }
            await applyFetchedChats(
                fetchedChats,
                repository: repository,
                localStore: localStore,
                currentUserID: userID,
                visibleMode: mode,
                preserveExistingWhenEmpty: true
            )
        } catch { }
    }

    @MainActor
    private func applyFetchedChats(
        _ fetchedChats: [Chat],
        repository: ChatRepository,
        localStore: LocalStore,
        currentUserID: UUID,
        visibleMode: ChatMode,
        preserveExistingWhenEmpty: Bool
    ) async {
        let sanitizedExistingChats = await sanitizeExistingChats(
            chats,
            currentUserID: currentUserID,
            visibleMode: visibleMode
        )
        let drafts = await localStore.loadDrafts()
        let draftByChatKey = Dictionary(
            drafts.map { (draftKey(chatID: $0.chatID, mode: $0.mode), $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
            }
        )

        var preparedChats: [Chat] = []
        preparedChats.reserveCapacity(fetchedChats.count)
        for chat in fetchedChats {
            var chatWithDraft = chat
            if let draft = draftByChatKey[draftKey(chatID: chat.id, mode: chat.mode)] {
                chatWithDraft.draft = draft
            } else {
                chatWithDraft.draft = nil
            }

            let cachedMessages = await repository.cachedMessages(chatID: chat.id, mode: chat.mode)
            await ChatReadStateStore.shared.bootstrapReadMarkerIfNeeded(
                chat: chatWithDraft,
                messages: cachedMessages,
                currentUserID: currentUserID
            )
            chatWithDraft.unreadCount = await ChatReadStateStore.shared.unreadCount(
                for: chatWithDraft,
                messages: cachedMessages,
                currentUserID: currentUserID
            )

            let aliasedChat = await ContactAliasStore.shared.applyAlias(to: chatWithDraft, currentUserID: currentUserID)
            guard let eventDecoratedChat = await EventChatMetadataStore.shared.apply(to: aliasedChat, ownerUserID: currentUserID) else {
                continue
            }
            if eventDecoratedChat.eventDetails?.isExpired == true {
                await purgeLocalChatState(chatID: chat.id, ownerUserID: currentUserID)
                continue
            }
            let communityDecoratedChat = await CommunityChatMetadataStore.shared.apply(to: eventDecoratedChat, ownerUserID: currentUserID)
            let moderationDecoratedChat = await GroupModerationSettingsStore.shared.apply(to: communityDecoratedChat, ownerUserID: currentUserID)
            if let decoratedChat = await ChatThreadStateStore.shared.apply(to: moderationDecoratedChat, ownerUserID: currentUserID) {
                guard decoratedChat.isAvailable(in: visibleMode) else {
                    await purgeLocalChatState(chatID: decoratedChat.id, ownerUserID: currentUserID)
                    continue
                }
                preparedChats.append(decoratedChat)
            }
        }

        for index in preparedChats.indices where preparedChats[index].type == .selfChat {
            preparedChats[index].unreadCount = 0
        }

        let avatarURLs = preparedChats.prefix(14).compactMap { chat in
            if let groupPhotoURL = chat.group?.photoURL {
                return groupPhotoURL
            }
            return chat.directParticipant(for: currentUserID)?.photoURL
        }
        if avatarURLs.isEmpty == false {
            Task(priority: .utility) {
                await RemoteAssetCacheStore.shared.prewarm(urls: avatarURLs, limit: 14)
            }
        }

        guard preserveExistingWhenEmpty == false || preparedChats.isEmpty == false || sanitizedExistingChats.isEmpty else {
            updateDisplayedChats(sanitizedExistingChats, currentUserID: currentUserID)
            return
        }

        let mergedChats = mergeDisplayedChats(existing: sanitizedExistingChats, incoming: preparedChats, currentUserID: currentUserID)
        updateDisplayedChats(mergedChats, currentUserID: currentUserID)
    }

    private func sanitizeExistingChats(
        _ existingChats: [Chat],
        currentUserID: UUID,
        visibleMode: ChatMode
    ) async -> [Chat] {
        var sanitized: [Chat] = []
        sanitized.reserveCapacity(existingChats.count)

        for chat in existingChats {
            guard let eventDecoratedChat = await EventChatMetadataStore.shared.apply(to: chat, ownerUserID: currentUserID) else {
                continue
            }
            if eventDecoratedChat.eventDetails?.isExpired == true {
                await purgeLocalChatState(chatID: chat.id, ownerUserID: currentUserID)
                continue
            }
            let communityDecoratedChat = await CommunityChatMetadataStore.shared.apply(to: eventDecoratedChat, ownerUserID: currentUserID)
            let moderationDecoratedChat = await GroupModerationSettingsStore.shared.apply(to: communityDecoratedChat, ownerUserID: currentUserID)
            guard let visibleChat = await ChatThreadStateStore.shared.apply(to: moderationDecoratedChat, ownerUserID: currentUserID) else {
                continue
            }
            guard visibleChat.isAvailable(in: visibleMode) else {
                await purgeLocalChatState(chatID: visibleChat.id, ownerUserID: currentUserID)
                continue
            }
            sanitized.append(visibleChat)
        }

        return sanitized
    }

    private func purgeLocalChatState(chatID: UUID, ownerUserID: UUID) async {
        for mode in ChatMode.allCases {
            await ChatSnapshotStore.shared.removeChat(chatID: chatID, userID: ownerUserID, mode: mode)
            await ChatThreadStateStore.shared.clearChat(ownerUserID: ownerUserID, mode: mode, chatID: chatID)
        }
    }

    private func draftKey(chatID: UUID, mode: ChatMode) -> String {
        "\(mode.rawValue):\(chatID.uuidString)"
    }

    @MainActor
    func markChatRead(_ chat: Chat, repository: ChatRepository, currentUserID: UUID) async {
        try? await repository.markChatRead(chatID: chat.id, mode: chat.mode, readerID: currentUserID)
        let cachedMessages = await repository.cachedMessages(chatID: chat.id, mode: chat.mode)
        await ChatReadStateStore.shared.markChatRead(
            chatID: chat.id,
            mode: chat.mode,
            userID: currentUserID,
            messages: cachedMessages
        )

        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[index].unreadCount = 0
        updateApplicationBadge(using: chats)
    }

    @MainActor
    func togglePinned(_ chat: Chat, currentUserID: UUID) async {
        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        let newPinnedState = chats[index].isPinned == false
        chats[index].isPinned = newPinnedState
        await ChatThreadStateStore.shared.setPinned(
            newPinnedState,
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
        updateDisplayedChats(chats, currentUserID: currentUserID)
    }

    @MainActor
    func toggleMute(_ chat: Chat, currentUserID: UUID) async {
        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        let newMuteState: ChatMuteState = chats[index].notificationPreferences.muteState == .active
            ? .mutedPermanently
            : .active
        chats[index].notificationPreferences.muteState = newMuteState
        await ChatThreadStateStore.shared.setMuteState(
            newMuteState,
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
    }

    @MainActor
    func hideChat(_ chat: Chat, currentUserID: UUID) async {
        await ChatThreadStateStore.shared.clearChat(
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
        chats.removeAll(where: { $0.id == chat.id })
        updateApplicationBadge(using: chats)
    }

    @MainActor
    private func updateDisplayedChats(_ nextChats: [Chat], currentUserID: UUID) {
        let sortedChats = sortChats(nextChats, previousChats: chats, currentUserID: currentUserID)
        guard chats != sortedChats else {
            updateApplicationBadge(using: sortedChats)
            return
        }
        chats = sortedChats
        updateApplicationBadge(using: sortedChats)
    }

    @MainActor
    private func updateApplicationBadge(using chats: [Chat]) {
        #if os(iOS)
        let unread = chats.reduce(into: 0) { partial, chat in
            guard chat.mode == .online else { return }
            partial += max(chat.unreadCount, 0)
        }
        UIApplication.shared.applicationIconBadgeNumber = unread
        #endif
    }

    private func sortChats(_ sourceChats: [Chat], previousChats: [Chat], currentUserID: UUID) -> [Chat] {
        let previousPositions = Dictionary(
            uniqueKeysWithValues: previousChats.enumerated().map {
                (chatFeedIdentityKey(for: $0.element, currentUserID: currentUserID), $0.offset)
            }
        )

        return sourceChats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }

            let lhsIdentity = chatFeedIdentityKey(for: lhs, currentUserID: currentUserID)
            let rhsIdentity = chatFeedIdentityKey(for: rhs, currentUserID: currentUserID)

            if let lhsPreviousPosition = previousPositions[lhsIdentity],
               let rhsPreviousPosition = previousPositions[rhsIdentity],
               lhsPreviousPosition != rhsPreviousPosition {
                return lhsPreviousPosition < rhsPreviousPosition
            }

            return lhsIdentity < rhsIdentity
        }
    }

    private func mergeDisplayedChats(existing: [Chat], incoming: [Chat], currentUserID: UUID) -> [Chat] {
        guard existing.isEmpty == false else { return incoming }
        guard incoming.isEmpty == false else { return existing }

        var mergedByConversationKey = Dictionary(
            uniqueKeysWithValues: existing.map { (conversationKey(for: $0, currentUserID: currentUserID), $0) }
        )

        for chat in incoming {
            let key = conversationKey(for: chat, currentUserID: currentUserID)
            if let existingChat = mergedByConversationKey[key] {
                mergedByConversationKey[key] = mergeChat(existing: existingChat, incoming: chat)
            } else {
                mergedByConversationKey[key] = chat
            }
        }

        return Array(mergedByConversationKey.values)
    }

    private func mergeChat(existing: Chat, incoming: Chat) -> Chat {
        var merged = incoming
        if merged.lastMessagePreview == nil {
            merged.lastMessagePreview = existing.lastMessagePreview
        }
        if merged.communityDetails == nil {
            merged.communityDetails = existing.communityDetails
        }
        if merged.moderationSettings == nil {
            merged.moderationSettings = existing.moderationSettings
        }
        if merged.eventDetails == nil {
            merged.eventDetails = existing.eventDetails
        }
        if merged.lastActivityAt < existing.lastActivityAt {
            merged.lastActivityAt = existing.lastActivityAt
        }
        return merged
    }

    private func conversationKey(for chat: Chat, currentUserID: UUID) -> String {
        switch chat.type {
        case .selfChat:
            return "self:\(currentUserID.uuidString)"
        case .direct:
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "direct:\(participantKey)"
        case .group:
            if let groupID = chat.group?.id {
                return "group:\(groupID.uuidString)"
            }
            let participantKey = chat.participantIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            return "group-fallback:\(participantKey)"
        case .secret:
            return "secret:\(chat.id.uuidString)"
        }
    }
}

private struct ChatRowSwipeAction: Identifiable {
    let id = UUID()
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void
}

private struct ChatSwipeRow<Content: View>: View {
    let leadingActions: [ChatRowSwipeAction]
    let trailingActions: [ChatRowSwipeAction]
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var currentOffset: CGFloat = 0
    @State private var settledOffset: CGFloat = 0

    private let actionWidth: CGFloat = 84

    var body: some View {
        ZStack {
            swipeActionsBackground

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PrimeTheme.Colors.background)
                .contentShape(Rectangle())
                .offset(x: currentOffset)
        }
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(dragGesture)
        .onTapGesture {
            if currentOffset != 0 {
                closeActions()
            } else {
                onTap()
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: currentOffset)
    }

    private var swipeActionsBackground: some View {
        HStack(spacing: 0) {
            if leadingActions.isEmpty == false {
                HStack(spacing: 0) {
                    ForEach(leadingActions) { action in
                        actionButton(action)
                    }
                }
                .frame(width: leadingRevealWidth, alignment: .leading)
                .opacity(currentOffset > 0 ? 1 : 0)
            }

            Spacer(minLength: 0)

            if trailingActions.isEmpty == false {
                HStack(spacing: 0) {
                    ForEach(trailingActions) { action in
                        actionButton(action)
                    }
                }
                .frame(width: trailingRevealWidth, alignment: .trailing)
                .opacity(currentOffset < 0 ? 1 : 0)
            }
        }
        .background(PrimeTheme.Colors.elevated.opacity(0.92))
    }

    private func actionButton(_ action: ChatRowSwipeAction) -> some View {
        Button {
            action.action()
            closeActions()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: action.systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(Color.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 12)
            .background(action.tint)
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        #if os(tvOS)
        TapGesture()
        #else
        DragGesture(minimumDistance: 22)
            .onChanged { value in
                guard shouldTrackSwipe(translation: value.translation) else { return }
                currentOffset = clampedOffset(for: settledOffset + value.translation.width)
            }
            .onEnded { value in
                guard shouldTrackSwipe(translation: value.translation) else {
                    closeActions()
                    return
                }

                let projectedOffset = clampedOffset(for: settledOffset + value.translation.width)
                let target = snapTarget(for: projectedOffset)
                settledOffset = target
                currentOffset = target
            }
        #endif
    }

    private var leadingRevealWidth: CGFloat {
        CGFloat(leadingActions.count) * actionWidth
    }

    private var trailingRevealWidth: CGFloat {
        CGFloat(trailingActions.count) * actionWidth
    }

    private func clampedOffset(for proposed: CGFloat) -> CGFloat {
        min(max(proposed, -trailingRevealWidth), leadingRevealWidth)
    }

    private func snapTarget(for proposed: CGFloat) -> CGFloat {
        if proposed > 0 {
            guard leadingRevealWidth > 0 else { return 0 }
            return proposed >= max(76, leadingRevealWidth * 0.42) ? leadingRevealWidth : 0
        }

        if proposed < 0 {
            guard trailingRevealWidth > 0 else { return 0 }
            return abs(proposed) >= max(76, trailingRevealWidth * 0.42) ? -trailingRevealWidth : 0
        }

        return 0
    }

    private func shouldTrackSwipe(translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        guard horizontal > 20 else { return false }
        return horizontal > vertical * 1.6
    }

    private func closeActions() {
        settledOffset = 0
        currentOffset = 0
    }
}

private func chatFeedIdentityKey(for chat: Chat, currentUserID: UUID) -> String {
    switch chat.type {
    case .selfChat:
        return "self:\(currentUserID.uuidString)"
    case .direct:
        let participantKey = chat.participantIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ":")
        return "direct:\(participantKey)"
    case .group:
        if let groupID = chat.group?.id {
            return "group:\(groupID.uuidString)"
        }
        let participantKey = chat.participantIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ":")
        return "group-fallback:\(participantKey)"
    case .secret:
        return "secret:\(chat.id.uuidString)"
    }
}
