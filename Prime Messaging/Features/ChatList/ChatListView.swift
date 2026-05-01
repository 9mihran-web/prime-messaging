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
            return "chatfeed.filter.all".localized
        case .chats:
            return "chatfeed.filter.chats".localized
        case .groups:
            return "chatfeed.filter.groups".localized
        case .channels:
            return "chatfeed.filter.channels".localized
        case .communities:
            return "chatfeed.filter.communities".localized
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
    @State private var pendingForegroundRefreshAfterActivation = false
    @State private var isShowingPinLimitAlert = false
    @State private var selectedPremiumActivity: SelectedPremiumActivityDetails?
    @State private var realtimeFeedTask: Task<Void, Never>?
    @State private var deferredInitialRefreshTask: Task<Void, Never>?

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
        .task(id: refreshTaskID) {
            deferredInitialRefreshTask?.cancel()
            await hydrateChatsIfAppropriate(force: true)
            await startRealtimeFeedIfNeeded()
            deferredInitialRefreshTask = Task { @MainActor in
                await Task.yield()
                guard Task.isCancelled == false else { return }
                await refreshChatsIfAppropriate(force: true)
            }
            while !Task.isCancelled {
                await refreshChatsIfAppropriate()
                try? await Task.sleep(for: feedSafetyRefreshInterval)
            }
        }
        .onDisappear {
            deferredInitialRefreshTask?.cancel()
            realtimeFeedTask?.cancel()
            Task {
                await ChatRealtimeService.shared.unsubscribeFeed(userID: appState.currentUser.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDraftsChanged).receive(on: RunLoop.main)) { _ in
            if shouldDeferFeedRefresh {
                pendingDeferredHydration = true
            } else {
                viewModel.scheduleHydration(
                    mode: mode,
                    repository: environment.chatRepository,
                    authRepository: environment.authRepository,
                    localStore: environment.localStore,
                    userID: appState.currentUser.id
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged).receive(on: RunLoop.main)) { _ in
            if shouldDeferFeedRefresh {
                pendingDeferredHydration = true
            } else {
                viewModel.scheduleHydration(
                    mode: mode,
                    repository: environment.chatRepository,
                    authRepository: environment.authRepository,
                    localStore: environment.localStore,
                    userID: appState.currentUser.id
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                pendingForegroundRefreshAfterActivation = true
                guard appState.isSceneActive else { return }
                pendingForegroundRefreshAfterActivation = false
                await refreshChatsIfAppropriate(force: true)
            }
        }
        .onChange(of: appState.isSceneActive) { isSceneActive in
            guard isSceneActive, pendingForegroundRefreshAfterActivation else { return }
            Task { @MainActor in
                pendingForegroundRefreshAfterActivation = false
                await refreshChatsIfAppropriate(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingIncomingChatPush).receive(on: RunLoop.main)) { notification in
            guard
                let userInfo = notification.userInfo,
                let route = NotificationChatRoute(userInfo: userInfo),
                route.mode == mode
            else {
                return
            }
            Task { @MainActor in
                if await ChatRealtimeService.shared.isLikelyConnected(userID: appState.currentUser.id) {
                    return
                }
                await refreshChatsIfAppropriate(force: true)
            }
        }
        .onChange(of: mediaPlaybackActivity.isPlaybackActive) { isActive in
            guard isActive == false else { return }
            Task { @MainActor in
                await runDeferredFeedUpdatesIfNeeded()
            }
        }
        .alert("chat.pin.limit.title".localized, isPresented: $isShowingPinLimitAlert) {
            Button("common.ok".localized, role: .cancel) { }
        } message: {
            Text("chat.pin.limit.message".localized)
        }
        .sheet(item: $selectedPremiumActivity) { details in
            PrimePremiumActivityDetailsSheet(details: details)
                .presentationDetents([.medium, .large])
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

    private var feedSafetyRefreshInterval: Duration {
        switch mode {
        case .offline:
            return .seconds(8)
        case .smart, .online:
            return isChatScreenVisible ? .seconds(160) : .seconds(110)
        }
    }

    @MainActor
    private func startRealtimeFeedIfNeeded() async {
        realtimeFeedTask?.cancel()
        realtimeFeedTask = nil

        guard mode == .online else { return }

        await ChatRealtimeService.shared.subscribeFeed(
            userID: appState.currentUser.id,
            mode: mode
        )
        let stream = await ChatRealtimeService.shared.stream(for: appState.currentUser.id, mode: mode)
        realtimeFeedTask = Task { @MainActor in
            for await event in stream {
                guard Task.isCancelled == false else { return }
                await viewModel.applyRealtimeEvent(
                    event,
                    repository: environment.chatRepository,
                    authRepository: environment.authRepository,
                    localStore: environment.localStore,
                    currentUserID: appState.currentUser.id,
                    visibleMode: mode,
                    activeChatID: appState.selectedChat?.id
                )
                if (event.type == "chat.removed" || event.type == "chat.deleted"), let chatID = event.chatID {
                    appState.forgetChatRoutes(chatIDs: [chatID])
                }
                _ = appState.resolvePendingNotificationRoute(with: viewModel.chats)
            }
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
            authRepository: environment.authRepository,
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
            authRepository: environment.authRepository,
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
                    ChatRowView(
                        chat: chat,
                        presentation: row.presentation,
                        currentUserID: appState.currentUser.id,
                        visibleMode: mode,
                        onTapPremiumStatus: {
                            guard let activity = chat.primePremiumActivity else { return }
                            selectedPremiumActivity = SelectedPremiumActivityDetails(
                                chatTitle: chat.displayTitle(for: appState.currentUser.id),
                                participantName: chat.displayTitle(for: appState.currentUser.id),
                                activity: activity
                            )
                        }
                    )
                        .equatable()
                }

                if row.id != rows.last?.id {
                    Divider()
                        .background(PrimeTheme.Colors.separator.opacity(0.35))
                        .padding(.leading, 74)
                }
            }
        }
    }

    private var displayRows: [ChatFeedRow] {
        viewModel.chats.compactMap { chat -> ChatFeedRow? in
            guard matchesFilter(chat: chat) else { return nil }
            return ChatFeedRow(
                id: chatFeedIdentityKey(for: chat, currentUserID: appState.currentUser.id),
                chat: chat,
                presentation: makeRowPresentation(for: chat)
            )
        }
    }

    private func makeRowPresentation(for chat: Chat) -> ChatRowPresentation {
        let title = chat.displayTitle(for: appState.currentUser.id)
        let previewText = chat.lastMessagePreview ?? chat.subtitle
        let communityBadge: ChatRowPresentation.Badge? = {
            guard let communityDetails = chat.communityDetails else { return nil }
            return .init(title: communityDetails.badgeTitle, systemName: communityDetails.symbolName)
        }()
        let eventBadge: ChatRowPresentation.Badge? = {
            guard let eventDetails = chat.eventDetails, eventDetails.isExpired == false else { return nil }
            return .init(title: eventDetails.badgeTitle, systemName: eventDetails.symbolName)
        }()
        let avatarPhotoURL = chat.group?.photoURL
            ?? chat.directParticipant(for: appState.currentUser.id)?.photoURL
            ?? (chat.type == .direct
                ? chat.participantIDs
                    .first(where: { $0 != appState.currentUser.id })
                    .flatMap { viewModel.directAvatarURLByUserID[$0] }
                : nil)
        let avatarPlaceholderText = String(title.prefix(1))
        let timestampText: String? = {
            guard chat.type != .selfChat else { return nil }
            let calendar = Calendar.current
            if calendar.isDateInToday(chat.lastActivityAt) {
                return chat.lastActivityAt.formatted(.dateTime.hour().minute())
            }
            if calendar.isDateInYesterday(chat.lastActivityAt) {
                return "Yesterday"
            }
            return chat.lastActivityAt.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits))
        }()
        let premiumStatus = ChatRowPresentation.PremiumStatus(activity: chat.primePremiumActivity)

        return ChatRowPresentation(
            title: title,
            previewText: previewText,
            eventStatus: chat.eventStatusText(),
            communityStatus: chat.communityStatusText(),
            moderationStatus: chat.moderationStatusText(),
            premiumStatus: premiumStatus,
            timestampText: timestampText,
            avatarPhotoURL: avatarPhotoURL,
            avatarPlaceholderText: avatarPlaceholderText,
            isOfficial: chat.communityDetails?.isOfficial == true,
            communityBadge: communityBadge,
            eventBadge: eventBadge,
            unreadCount: chat.unreadCount,
            isPinned: chat.isPinned,
            draftText: chat.draft?.text
        )
    }

    private func matchesFilter(chat: Chat) -> Bool {
        switch categoryFilter {
        case .all:
            return true
        case .chats:
            return chat.type == .direct || chat.type == .selfChat || chat.type == .secret
        case .groups:
            guard chat.type == .group else { return false }
            let kind = chat.communityDetails?.kind ?? .group
            return kind == .group || kind == .supergroup
        case .channels:
            return chat.type == .group && chat.communityDetails?.kind == .channel
        case .communities:
            return chat.type == .group && chat.communityDetails?.kind == .community
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
                    let didToggle = await viewModel.togglePinned(chat, currentUserID: appState.currentUser.id)
                    if didToggle == false {
                        isShowingPinLimitAlert = true
                    }
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

struct ChatRowView: View, Equatable {
    let chat: Chat
    let presentation: ChatRowPresentation
    let currentUserID: UUID
    let visibleMode: ChatMode
    let onTapPremiumStatus: (() -> Void)?

    init(
        chat: Chat,
        presentation: ChatRowPresentation? = nil,
        currentUserID: UUID,
        visibleMode: ChatMode,
        onTapPremiumStatus: (() -> Void)? = nil
    ) {
        self.chat = chat
        self.currentUserID = currentUserID
        self.visibleMode = visibleMode
        self.presentation = presentation ?? Self.makePresentation(for: chat, currentUserID: currentUserID)
        self.onTapPremiumStatus = onTapPremiumStatus
    }

    static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.chat == rhs.chat
            && lhs.presentation == rhs.presentation
            && lhs.currentUserID == rhs.currentUserID
            && lhs.visibleMode == rhs.visibleMode
    }

    var body: some View {
        HStack(alignment: .center, spacing: PrimeTheme.Spacing.medium) {
            avatarView

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(presentation.title)
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                            if presentation.isOfficial {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            }

                            if let communityBadge = presentation.communityBadge {
                                Label(communityBadge.title, systemImage: communityBadge.systemName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                                    )
                            }

                            if let eventBadge = presentation.eventBadge {
                                Label(eventBadge.title, systemImage: eventBadge.systemName)
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

                        Text(presentation.previewText)
                            .font(.subheadline)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)

                        if let eventStatus = presentation.eventStatus {
                            Text(eventStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                .lineLimit(1)
                        } else if let communityStatus = presentation.communityStatus {
                            Text(communityStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.accentSoft)
                                .lineLimit(1)
                        } else if let moderationStatus = presentation.moderationStatus {
                            Text(moderationStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.warning)
                                .lineLimit(1)
                        } else if let premiumStatus = presentation.premiumStatus {
                            premiumStatusView(premiumStatus)
                        }
                    }

                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let timestampText = presentation.timestampText {
                            Text(timestampText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        if presentation.unreadCount > 0 {
                            Text("\(presentation.unreadCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule(style: .continuous).fill(PrimeTheme.Colors.accent))
                        }

                        if presentation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.accent)
                        }
                    }
                }

                if let draftText = presentation.draftText {
                    Text("Draft: \(draftText)")
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.accentSoft)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, PrimeTheme.Spacing.medium)
        .background(PrimeTheme.Colors.background)
    }

    @ViewBuilder
    private func premiumStatusView(_ premiumStatus: ChatRowPresentation.PremiumStatus) -> some View {
        let content = HStack(spacing: 6) {
            if premiumStatus.isViewingNow {
                PrimePremiumEyesIndicator()
            } else {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2.weight(.semibold))
            }
            Text(premiumStatus.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(premiumStatus.isViewingNow ? PrimeTheme.Colors.accent : PrimeTheme.Colors.textSecondary)

        if let onTapPremiumStatus {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture().onEnded {
                        onTapPremiumStatus()
                    }
                )
        } else {
            content
        }
    }

    private var avatarView: some View {
        SwiftUI.Group {
            if let photoURL = presentation.avatarPhotoURL {
                CachedRemoteImage(url: photoURL, maxPixelSize: 256) { image in
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

    private var avatarPlaceholder: some View {
        Circle()
            .fill(avatarAccentColor.opacity(0.92))
            .overlay(
                Text(presentation.avatarPlaceholderText)
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

    private static func makePresentation(for chat: Chat, currentUserID: UUID) -> ChatRowPresentation {
        let title = chat.displayTitle(for: currentUserID)
        let previewText = chat.lastMessagePreview ?? chat.subtitle
        let communityBadge: ChatRowPresentation.Badge? = {
            guard let communityDetails = chat.communityDetails else { return nil }
            return .init(title: communityDetails.badgeTitle, systemName: communityDetails.symbolName)
        }()
        let eventBadge: ChatRowPresentation.Badge? = {
            guard let eventDetails = chat.eventDetails, eventDetails.isExpired == false else { return nil }
            return .init(title: eventDetails.badgeTitle, systemName: eventDetails.symbolName)
        }()
        let avatarPhotoURL = chat.group?.photoURL
            ?? chat.directParticipant(for: currentUserID)?.photoURL
        let avatarPlaceholderText = String(title.prefix(1))
        let timestampText: String? = {
            guard chat.type != .selfChat else { return nil }
            let calendar = Calendar.current
            if calendar.isDateInToday(chat.lastActivityAt) {
                return chat.lastActivityAt.formatted(.dateTime.hour().minute())
            }
            if calendar.isDateInYesterday(chat.lastActivityAt) {
                return "Yesterday"
            }
            return chat.lastActivityAt.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits))
        }()

        return ChatRowPresentation(
            title: title,
            previewText: previewText,
            eventStatus: chat.eventStatusText(),
            communityStatus: chat.communityStatusText(),
            moderationStatus: chat.moderationStatusText(),
            premiumStatus: .init(activity: chat.primePremiumActivity),
            timestampText: timestampText,
            avatarPhotoURL: avatarPhotoURL,
            avatarPlaceholderText: avatarPlaceholderText,
            isOfficial: chat.communityDetails?.isOfficial == true,
            communityBadge: communityBadge,
            eventBadge: eventBadge,
            unreadCount: chat.unreadCount,
            isPinned: chat.isPinned,
            draftText: chat.draft?.text
        )
    }
}

private struct ChatFeedRow: Identifiable {
    let id: String
    let chat: Chat
    let presentation: ChatRowPresentation
}

struct ChatRowPresentation: Equatable {
    struct Badge: Equatable {
        let title: String
        let systemName: String
    }

    struct PremiumStatus: Equatable {
        let label: String
        let isViewingNow: Bool

        init?(activity: PrimePremiumChatActivity?) {
            guard let activity else { return nil }
            if activity.isViewingNow {
                self.label = "Viewing your chat now"
                self.isViewingNow = true
                return
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            if let closedAt = activity.closedAt {
                self.label = "Viewed \(formatter.localizedString(for: closedAt, relativeTo: .now))"
            } else if let lastEventAt = activity.lastEventAt {
                self.label = "Viewed \(formatter.localizedString(for: lastEventAt, relativeTo: .now))"
            } else {
                return nil
            }
            self.isViewingNow = false
        }
    }

    let title: String
    let previewText: String
    let eventStatus: String?
    let communityStatus: String?
    let moderationStatus: String?
    let premiumStatus: PremiumStatus?
    let timestampText: String?
    let avatarPhotoURL: URL?
    let avatarPlaceholderText: String
    let isOfficial: Bool
    let communityBadge: Badge?
    let eventBadge: Badge?
    let unreadCount: Int
    let isPinned: Bool
    let draftText: String?
}

struct SelectedPremiumActivityDetails: Identifiable, Equatable {
    let id = UUID()
    let chatTitle: String
    let participantName: String
    let activity: PrimePremiumChatActivity
}

private struct PrimePremiumActivityDetailsSheet: View {
    let details: SelectedPremiumActivityDetails

    var body: some View {
        NavigationStack {
            List {
                Section("Prime Premium") {
                    if let openedAt = details.activity.openedAt {
                        Text("\(details.participantName) opened your chat at \(openedAt.formatted(.dateTime.hour().minute()))")
                    }
                    if let duration = details.activity.viewedDurationSeconds, duration > 0 {
                        Text("\(details.participantName) viewed your chat for \(max(1, duration / 60)) min")
                    }
                    if let closedAt = details.activity.closedAt {
                        Text("\(details.participantName) closed the chat at \(closedAt.formatted(.dateTime.hour().minute()))")
                    }
                    if let screenshotAt = details.activity.lastScreenshotAt {
                        Text("Screenshot at \(screenshotAt.formatted(.dateTime.hour().minute()))")
                    }
                    if let recordingAt = details.activity.lastScreenRecordingAt {
                        Text("Screen recording at \(recordingAt.formatted(.dateTime.hour().minute()))")
                    }
                    if details.activity.isViewingNow {
                        Text("Currently viewing the chat")
                    }
                }
            }
            .navigationTitle(details.chatTitle)
        }
    }
}

private struct PrimePremiumEyesIndicator: View {
    @State private var lookOffset: CGFloat = -1.5

    var body: some View {
        HStack(spacing: 3) {
            eye
            eye
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                lookOffset = 1.5
            }
        }
    }

    private var eye: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.9))
                .frame(width: 14, height: 9)
            Circle()
                .fill(PrimeTheme.Colors.accent)
                .frame(width: 4.5, height: 4.5)
                .offset(x: lookOffset)
        }
    }
}

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var directAvatarURLByUserID: [UUID: URL] = [:]
    private var activeScopeID = ""
    private var pendingHydrationTask: Task<Void, Never>?
    private var directAvatarHydrationTask: Task<Void, Never>?
    private var preparedChatCache: [String: PreparedChatCacheEntry] = [:]

    private struct PreparedChatCacheEntry {
        let inputFingerprint: Int
        var chat: Chat
    }

    deinit {
        pendingHydrationTask?.cancel()
        directAvatarHydrationTask?.cancel()
    }

    @MainActor
    func scheduleHydration(
        mode: ChatMode,
        repository: ChatRepository,
        authRepository: AuthRepository,
        localStore: LocalStore,
        userID: UUID,
        delay: Duration = .milliseconds(180)
    ) {
        pendingHydrationTask?.cancel()
        pendingHydrationTask = Task { [mode, repository, authRepository, localStore, userID] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            await self.hydrateChats(
                mode: mode,
                repository: repository,
                authRepository: authRepository,
                localStore: localStore,
                userID: userID
            )
        }
    }

    @MainActor
    func hydrateChats(mode: ChatMode, repository: ChatRepository, authRepository: AuthRepository, localStore: LocalStore, userID: UUID) async {
        let scopeID = "\(mode.rawValue)-\(userID.uuidString)"
        activateScope(scopeID)

        let cachedChats = await repository.cachedChats(mode: mode, for: userID)
        guard activeScopeID == scopeID else { return }
        await applyFetchedChats(
            cachedChats,
            repository: repository,
            authRepository: authRepository,
            localStore: localStore,
            currentUserID: userID,
            visibleMode: mode,
            preserveExistingWhenEmpty: true
        )
    }

    @MainActor
    func refreshChats(mode: ChatMode, repository: ChatRepository, authRepository: AuthRepository, localStore: LocalStore, userID: UUID) async {
        let scopeID = "\(mode.rawValue)-\(userID.uuidString)"
        activateScope(scopeID)
        do {
            let fetchedChats = try await repository.fetchChats(mode: mode, for: userID)
            guard activeScopeID == scopeID else { return }
            await applyFetchedChats(
                fetchedChats,
                repository: repository,
                authRepository: authRepository,
                localStore: localStore,
                currentUserID: userID,
                visibleMode: mode,
                preserveExistingWhenEmpty: true
            )
        } catch { }
    }

    @MainActor
    func applyRealtimeEvent(
        _ event: RealtimeChatEvent,
        repository: ChatRepository,
        authRepository: AuthRepository,
        localStore: LocalStore,
        currentUserID: UUID,
        visibleMode: ChatMode,
        activeChatID: UUID?
    ) async {
        if let mode = event.mode, mode != visibleMode {
            return
        }

        if event.type == "chat.removed" || event.type == "chat.deleted" {
            guard let chatID = event.chatID else { return }
            chats.removeAll(where: { $0.id == chatID })
            invalidatePreparedChatCache(chatID: chatID, mode: visibleMode)
            await purgeLocalChatState(chatID: chatID, ownerUserID: currentUserID, repository: repository)
            updateApplicationBadge(using: chats)
            return
        }

        if let updatedChat = event.chat {
            await applyFetchedChats(
                [updatedChat],
                repository: repository,
                authRepository: authRepository,
                localStore: localStore,
                currentUserID: currentUserID,
                visibleMode: visibleMode,
                preserveExistingWhenEmpty: false
            )
            let persistedChat = chats.first(where: { $0.id == updatedChat.id }) ?? updatedChat
            await ChatSnapshotStore.shared.upsertChat(persistedChat, userID: currentUserID, mode: visibleMode)
        }

        if event.type == "chat.resync_required" {
            await refreshChats(
                mode: visibleMode,
                repository: repository,
                authRepository: authRepository,
                localStore: localStore,
                userID: currentUserID
            )
            return
        }

        guard let message = event.message else { return }

        if let chatIndex = chats.firstIndex(where: { $0.id == message.chatID }) {
            var nextChat = chats[chatIndex]
            nextChat.lastActivityAt = max(nextChat.lastActivityAt, message.createdAt)
            nextChat.lastMessagePreview = realtimePreviewText(for: message)
            if event.type == "message.created",
               message.senderID != currentUserID,
               activeChatID != message.chatID,
               message.isDeleted == false {
                nextChat.unreadCount = max(0, nextChat.unreadCount + 1)
            }

            chats[chatIndex] = nextChat
            updatePreparedChatCache(for: nextChat)
            updateDisplayedChats(chats, currentUserID: currentUserID)
            await ChatSnapshotStore.shared.upsertMessage(
                message,
                in: nextChat,
                userID: currentUserID,
                mode: visibleMode
            )
            await ChatSnapshotStore.shared.upsertChat(nextChat, userID: currentUserID, mode: visibleMode)
            return
        }

        if let eventChat = event.chat, eventChat.id == message.chatID {
            var fallbackChat = eventChat
            fallbackChat.lastActivityAt = max(fallbackChat.lastActivityAt, message.createdAt)
            fallbackChat.lastMessagePreview = realtimePreviewText(for: message)
            await ChatSnapshotStore.shared.upsertMessage(
                message,
                in: fallbackChat,
                userID: currentUserID,
                mode: visibleMode
            )
            await ChatSnapshotStore.shared.upsertChat(fallbackChat, userID: currentUserID, mode: visibleMode)
        }

        await refreshChats(
            mode: visibleMode,
            repository: repository,
            authRepository: authRepository,
            localStore: localStore,
            userID: currentUserID
        )
    }

    @MainActor
    private func applyFetchedChats(
        _ fetchedChats: [Chat],
        repository: ChatRepository,
        authRepository: AuthRepository,
        localStore: LocalStore,
        currentUserID: UUID,
        visibleMode: ChatMode,
        preserveExistingWhenEmpty: Bool
    ) async {
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

            let inputFingerprint = preparedChatFingerprint(for: chatWithDraft)

            if chat.mode == .online {
                chatWithDraft.unreadCount = chatWithDraft.type == .selfChat ? 0 : max(chatWithDraft.unreadCount, 0)
            } else {
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
            }

            let aliasedChat = await ContactAliasStore.shared.applyAlias(to: chatWithDraft, currentUserID: currentUserID)
            guard let eventDecoratedChat = await EventChatMetadataStore.shared.apply(to: aliasedChat, ownerUserID: currentUserID) else {
                invalidatePreparedChatCache(chatID: chat.id, mode: chat.mode)
                continue
            }
            if eventDecoratedChat.eventDetails?.isExpired == true {
                invalidatePreparedChatCache(chatID: chat.id, mode: chat.mode)
                await purgeLocalChatState(chatID: chat.id, ownerUserID: currentUserID, repository: repository)
                continue
            }
            let communityDecoratedChat = await CommunityChatMetadataStore.shared.apply(to: eventDecoratedChat, ownerUserID: currentUserID)
            let moderationDecoratedChat = await GroupModerationSettingsStore.shared.apply(to: communityDecoratedChat, ownerUserID: currentUserID)
            if let decoratedChat = await ChatThreadStateStore.shared.apply(to: moderationDecoratedChat, ownerUserID: currentUserID) {
                guard decoratedChat.isAvailable(in: visibleMode) else {
                    invalidatePreparedChatCache(chatID: decoratedChat.id, mode: decoratedChat.mode)
                    await purgeLocalChatState(chatID: decoratedChat.id, ownerUserID: currentUserID, repository: repository)
                    continue
                }
                preparedChats.append(decoratedChat)
                storePreparedChat(decoratedChat, inputFingerprint: inputFingerprint)
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

        if preserveExistingWhenEmpty, preparedChats.isEmpty, chats.isEmpty == false {
            let sanitizedExistingChats = await sanitizeExistingChats(
                chats,
                currentUserID: currentUserID,
                visibleMode: visibleMode,
                repository: repository
            )
            guard sanitizedExistingChats.isEmpty == false else {
                updateDisplayedChats(preparedChats, currentUserID: currentUserID)
                return
            }
            updateDisplayedChats(sanitizedExistingChats, currentUserID: currentUserID)
            return
        }

        let existingMergeSource: [Chat]
        if preserveExistingWhenEmpty {
            let incomingConversationKeys = Set(
                preparedChats.map { conversationKey(for: $0, currentUserID: currentUserID) }
            )
            existingMergeSource = chats.filter {
                incomingConversationKeys.contains(
                    conversationKey(for: $0, currentUserID: currentUserID)
                )
            }
        } else {
            existingMergeSource = chats
        }

        let mergedChats = mergeDisplayedChats(
            existing: existingMergeSource,
            incoming: preparedChats,
            currentUserID: currentUserID
        )
        updateDisplayedChats(mergedChats, currentUserID: currentUserID)
        hydrateDirectAvatarURLsIfNeeded(
            in: mergedChats,
            authRepository: authRepository,
            currentUserID: currentUserID
        )
    }

    @MainActor
    private func hydrateDirectAvatarURLsIfNeeded(
        in chats: [Chat],
        authRepository: AuthRepository,
        currentUserID: UUID
    ) {
        let directTargets = chats.compactMap { chat -> UUID? in
            guard chat.type == .direct else { return nil }
            if let participant = chat.directParticipant(for: currentUserID),
               let photoURL = participant.photoURL {
                directAvatarURLByUserID[participant.id] = photoURL
                return nil
            }
            return chat.participantIDs.first(where: { $0 != currentUserID })
        }

        let missingUserIDs = Array(Set(directTargets)).filter { directAvatarURLByUserID[$0] == nil }
        guard missingUserIDs.isEmpty == false else { return }

        directAvatarHydrationTask?.cancel()
        let scopeID = activeScopeID
        directAvatarHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for userID in missingUserIDs {
                guard Task.isCancelled == false else { return }
                do {
                    let user = try await authRepository.userProfile(userID: userID)
                    guard self.activeScopeID == scopeID else { return }
                    if let photoURL = user.profile.profilePhotoURL {
                        self.directAvatarURLByUserID[userID] = photoURL
                    }
                    if let chatIndex = self.chats.firstIndex(where: {
                        $0.type == .direct && $0.participantIDs.contains(userID)
                    }),
                       let participantIndex = self.chats[chatIndex].participants.firstIndex(where: { $0.id == userID }) {
                        self.chats[chatIndex].participants[participantIndex].photoURL = user.profile.profilePhotoURL
                        self.chats[chatIndex].participants[participantIndex].displayName = user.profile.displayName
                        self.chats[chatIndex].participants[participantIndex].username = user.profile.username
                    }
                } catch { }
            }
        }
    }

    private func sanitizeExistingChats(
        _ existingChats: [Chat],
        currentUserID: UUID,
        visibleMode: ChatMode,
        repository: ChatRepository
    ) async -> [Chat] {
        var sanitized: [Chat] = []
        sanitized.reserveCapacity(existingChats.count)

        for chat in existingChats {
            guard let eventDecoratedChat = await EventChatMetadataStore.shared.apply(to: chat, ownerUserID: currentUserID) else {
                continue
            }
            if eventDecoratedChat.eventDetails?.isExpired == true {
                await purgeLocalChatState(chatID: chat.id, ownerUserID: currentUserID, repository: repository)
                continue
            }
            let communityDecoratedChat = await CommunityChatMetadataStore.shared.apply(to: eventDecoratedChat, ownerUserID: currentUserID)
            let moderationDecoratedChat = await GroupModerationSettingsStore.shared.apply(to: communityDecoratedChat, ownerUserID: currentUserID)
            guard let visibleChat = await ChatThreadStateStore.shared.apply(to: moderationDecoratedChat, ownerUserID: currentUserID) else {
                continue
            }
            guard visibleChat.isAvailable(in: visibleMode) else {
                await purgeLocalChatState(chatID: visibleChat.id, ownerUserID: currentUserID, repository: repository)
                continue
            }
            sanitized.append(visibleChat)
        }

        return sanitized
    }

    private func purgeLocalChatState(chatID: UUID, ownerUserID: UUID, repository: ChatRepository) async {
        await repository.purgeLocalChatArtifacts(chatIDs: [chatID], currentUserID: ownerUserID)
        await ChatMessagePageStore.shared.purgeChats([chatID], userID: ownerUserID)
        await ChatReadStateStore.shared.purgeChat(chatID: chatID, userID: ownerUserID)
        await ShareChatDestinationStore.shared.purgeChats([chatID])
        await HiddenMessageStore.shared.purgeChat(ownerUserID: ownerUserID, chatID: chatID)
        await PinnedMessageStore.shared.purgeChat(ownerUserID: ownerUserID, chatID: chatID)
        await EventChatMetadataStore.shared.purgeChat(ownerUserID: ownerUserID, chatID: chatID)
        await OfflineChatArchiveStore.shared.purgeChats([chatID], ownerUserID: ownerUserID)
        for mode in ChatMode.allCases {
            await ChatSnapshotStore.shared.removeChat(chatID: chatID, userID: ownerUserID, mode: mode)
            await ChatThreadStateStore.shared.purgeChat(ownerUserID: ownerUserID, mode: mode, chatID: chatID)
        }
        await SmartConversationStore.shared.removeLink(for: chatID)
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
        updatePreparedChatCache(for: chats[index])
        updateApplicationBadge(using: chats)
    }

    @MainActor
    func togglePinned(_ chat: Chat, currentUserID: UUID) async -> Bool {
        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return false }
        let newPinnedState = chats[index].isPinned == false
        if newPinnedState {
            let pinnedCount = chats.filter(\.isPinned).count
            if pinnedCount >= 3 {
                return false
            }
        }
        chats[index].isPinned = newPinnedState
        updatePreparedChatCache(for: chats[index])
        await ChatThreadStateStore.shared.setPinned(
            newPinnedState,
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
        updateDisplayedChats(chats, currentUserID: currentUserID)
        return true
    }

    @MainActor
    func toggleMute(_ chat: Chat, currentUserID: UUID) async {
        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        let newMuteState: ChatMuteState = chats[index].notificationPreferences.muteState == .active
            ? .mutedPermanently
            : .active
        chats[index].notificationPreferences.muteState = newMuteState
        updatePreparedChatCache(for: chats[index])
        await ChatThreadStateStore.shared.setMuteState(
            newMuteState,
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
    }

    @MainActor
    func hideChat(_ chat: Chat, currentUserID: UUID) async {
        await ChatThreadStateStore.shared.hideChat(
            ownerUserID: currentUserID,
            mode: chat.mode,
            chatID: chat.id
        )
        chats.removeAll(where: { $0.id == chat.id })
        invalidatePreparedChatCache(chatID: chat.id, mode: chat.mode)
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

    private func realtimePreviewText(for message: Message) -> String {
        if message.isDeleted {
            return "Message deleted"
        }
        if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false {
            return text
        }
        if message.voiceMessage != nil {
            return "Voice message"
        }
        if let attachment = message.attachments.first {
            switch attachment.type {
            case .photo:
                return "Photo"
            case .video:
                return "Video"
            case .audio:
                return "Audio"
            case .document:
                return "File"
            case .contact:
                return "Contact"
            case .location:
                return "Location"
            }
        }
        return "Message"
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
            return "self:\(chat.id.uuidString)"
        case .direct:
            return "direct:\(chat.id.uuidString)"
        case .group:
            return "group:\(chat.id.uuidString)"
        case .secret:
            return "secret:\(chat.id.uuidString)"
        }
    }

    private func activateScope(_ scopeID: String) {
        guard activeScopeID != scopeID else { return }
        activeScopeID = scopeID
        preparedChatCache.removeAll()
    }

    private func preparedChatCacheKey(chatID: UUID, mode: ChatMode) -> String {
        "\(mode.rawValue):\(chatID.uuidString)"
    }

    private func preparedChatFingerprint(for chat: Chat) -> Int {
        var normalized = chat
        normalized.unreadCount = 0
        var hasher = Hasher()
        hasher.combine(normalized)
        return hasher.finalize()
    }

    private func cachedPreparedChat(for chat: Chat, visibleMode: ChatMode) -> Chat? {
        let cacheKey = preparedChatCacheKey(chatID: chat.id, mode: chat.mode)
        let fingerprint = preparedChatFingerprint(for: chat)
        guard let cachedEntry = preparedChatCache[cacheKey], cachedEntry.inputFingerprint == fingerprint else {
            return nil
        }

        let cachedChat = cachedEntry.chat
        guard cachedChat.eventDetails?.isExpired != true, cachedChat.isAvailable(in: visibleMode) else {
            preparedChatCache.removeValue(forKey: cacheKey)
            return nil
        }

        return cachedChat
    }

    private func storePreparedChat(_ chat: Chat, inputFingerprint: Int) {
        let cacheKey = preparedChatCacheKey(chatID: chat.id, mode: chat.mode)
        preparedChatCache[cacheKey] = PreparedChatCacheEntry(
            inputFingerprint: inputFingerprint,
            chat: chat
        )
    }

    private func updatePreparedChatCache(for chat: Chat) {
        let cacheKey = preparedChatCacheKey(chatID: chat.id, mode: chat.mode)
        guard let cachedEntry = preparedChatCache[cacheKey] else { return }
        preparedChatCache[cacheKey] = PreparedChatCacheEntry(
            inputFingerprint: cachedEntry.inputFingerprint,
            chat: chat
        )
    }

    private func invalidatePreparedChatCache(chatID: UUID, mode: ChatMode) {
        preparedChatCache.removeValue(forKey: preparedChatCacheKey(chatID: chatID, mode: mode))
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
        .background(PrimeTheme.Colors.background)
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
        return "self:\(chat.id.uuidString)"
    case .direct:
        return "direct:\(chat.id.uuidString)"
    case .group:
        return "group:\(chat.id.uuidString)"
    case .secret:
        return "secret:\(chat.id.uuidString)"
    }
}
