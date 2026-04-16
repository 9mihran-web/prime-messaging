import Combine
import SwiftUI
import UIKit

struct ChatView: View {
    private enum SmartTransportState {
        case unknown
        case nearby
        case relay
        case online
        case waiting
    }

    let chat: Chat

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var mediaPlaybackActivity = MediaPlaybackActivityStore.shared
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var attachmentPresentation = ChatAttachmentPresentationStore()
    @State private var currentChat: Chat
    @State private var isShowingGroupInfo = false
    @State private var contactProfile: User?
    @State private var isShowingContactProfile = false
    @State private var isShowingChatSearch = false
    @State private var currentPresence: Presence?
    @State private var localFocusedMessageID: UUID?
    @State private var didInitialScrollToBottom = false
    @State private var isNearBottom = true
    @State private var visibleDayText: String?
    @State private var isShowingFloatingDayChip = false
    @State private var pendingSearchMessageID: UUID?
    @State private var topOverlayHeight: CGFloat = 76
    @State private var bottomOverlayHeight: CGFloat = 88
    @State private var dayChipHideTask: Task<Void, Never>?
    @State private var replyingToMessage: Message?
    @State private var forwardingMessage: Message?
    @State private var isShowingForwardSheet = false
    @State private var pendingDeleteMessage: Message?
    @State private var pendingReportMessage: Message?
    @State private var hiddenMessageIDs = Set<UUID>()
    @State private var pinnedMessageID: UUID?
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardRealignmentRequest = 0
    @State private var pendingAutoScrollAfterOutgoingMessage = false
    @State private var isUpdatingGuestRequest = false
    @State private var isOfflineBannerVisible = true
    @State private var pendingOnlinePreviewDraft: OutgoingMessageDraft?
    @State private var isShowingOnlinePreviewSendOptions = false
    @State private var clearedThreadCutoff: Date?
    @State private var messageMenuFrames: [UUID: CGRect] = [:]
    @State private var activeMessageMenuMessage: Message?
    @State private var pressingMessageMenuID: UUID?
    @State private var messageMenuActivationTask: Task<Void, Never>?
    @State private var reactionPickerMessage: Message?
    @State private var smartTransportState: SmartTransportState = .unknown
    @State private var smartDeliveryConfidence: SmartDeliveryConfidence = .waiting
    @State private var smartPreferredOfflinePath: OfflineTransportPath?
    @State private var smartShouldPreferOnline = false
    @State private var draftPersistenceTask: Task<Void, Never>?
    @State private var unreadAnchorMessageID: UUID?
    @State private var readingAnchorMessageID: UUID?
    @State private var topVisibleMessageID: UUID?
    @State private var selectedCommunityTopicID: UUID?
    @State private var selectedCommentPostID: UUID?
    @State private var pendingDeferredMessageRefresh = false
    @State private var pendingDeferredSnapshotRefresh = false
    @State private var previousMessageIDs: [UUID] = []
    @State private var lastServerReadMarkAttemptAt: Date?
    @State private var selfDestructNow: Date = .now

    init(chat: Chat) {
        self.chat = chat
        _currentChat = State(initialValue: chat)
    }

    private var visibleMessages: [Message] {
        let baseMessages = viewModel.messages.filter { message in
            guard hiddenMessageIDs.contains(message.id) == false else { return false }
            guard message.shouldHideDeletedPlaceholder == false else { return false }
            guard message.isExpiredForSelfDestruct(relativeTo: selfDestructNow) == false else { return false }
            if let clearedThreadCutoff {
                return message.createdAt > clearedThreadCutoff
            }
            return true
        }

        return filteredCommunityMessages(from: baseMessages)
    }

    private var pinnedMessage: Message? {
        guard let pinnedMessageID else { return nil }
        return visibleMessages.first(where: { $0.id == pinnedMessageID && $0.isDeleted == false })
    }

    private var guestRequestState: ChatGuestRequestState? {
        currentChat.guestRequestState(for: appState.currentUser.id)
    }

    private var supportsServerBackedFeatures: Bool {
        currentChat.mode != .offline
    }

    private var communityTopics: [CommunityTopic] {
        (currentChat.communityDetails?.topics ?? []).sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private var selectedCommunityTopic: CommunityTopic? {
        guard let selectedCommunityTopicID else { return nil }
        return communityTopics.first(where: { $0.id == selectedCommunityTopicID })
    }

    private var selectedCommentPost: Message? {
        guard let selectedCommentPostID else { return nil }
        return viewModel.messages.first(where: { $0.id == selectedCommentPostID })
    }

    private var currentChannelRole: GroupMemberRole? {
        if let explicitRole = currentChat.group?.members.first(where: { $0.userID == appState.currentUser.id })?.role {
            return explicitRole
        }
        if currentChat.group?.ownerID == appState.currentUser.id {
            return .owner
        }
        return nil
    }

    private var canManageCurrentChannel: Bool {
        guard currentChat.communityDetails?.kind == .channel else { return false }
        guard let currentChannelRole else { return false }
        return currentChannelRole == .owner || currentChannelRole == .admin
    }

    private var showsComposer: Bool {
        guard currentChat.isAvailable(in: currentChat.mode) else { return false }
        guard currentChat.communityDetails?.kind == .channel else { return true }

        if selectedCommentPostID != nil {
            return currentChat.communityDetails?.commentsEnabled == true
        }

        return canManageCurrentChannel
    }

    private var showsCommunityTopicStrip: Bool {
        currentChat.type == .group
            && selectedCommentPostID == nil
            && (currentChat.communityDetails?.forumModeEnabled == true || communityTopics.isEmpty == false)
    }

    private var communityComposeContext: CommunityMessageContext? {
        let context = CommunityMessageContext(
            topicID: selectedCommunityTopicID,
            parentPostID: selectedCommentPostID
        )
        return context.hasRoutingContext ? context : nil
    }

    private var communityComposeContextTitle: String? {
        if let selectedCommentPost {
            let title = messagePreviewText(for: selectedCommentPost)
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty ? "Comment thread" : "Commenting on: \(trimmedTitle)"
        }
        if let selectedCommunityTopic {
            return "Posting in topic: \(selectedCommunityTopic.title)"
        }
        return nil
    }

    private var isOfflineOnlineChat: Bool {
        currentChat.mode == .online && NetworkUsagePolicy.isActuallyOffline()
    }

    private var isSmartDirectChat: Bool {
        currentChat.mode == .smart && currentChat.type == .direct
    }

    private var smartQueuedMessageCount: Int {
        guard isSmartDirectChat else { return 0 }
        return visibleMessages.filter { message in
            message.senderID == appState.currentUser.id &&
            (message.status == .localPending || message.status == .sending)
        }.count
    }

    private var edgeBackSwipeHandle: some View {
        #if os(tvOS)
        Color.clear
            .frame(width: 18)
            .contentShape(Rectangle())
        #else
        Color.clear
            .frame(width: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { value in
                        guard value.translation.width > 96 else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                        dismiss()
                    }
            )
        #endif
    }

    private var photoAttachmentPresentationBinding: Binding<Attachment?> {
        Binding(
            get: { attachmentPresentation.presentedPhotoAttachment },
            set: { newValue in
                if newValue == nil {
                    attachmentPresentation.presentedPhotoAttachment = nil
                }
            }
        )
    }

    private var videoAttachmentPresentationBinding: Binding<Attachment?> {
        Binding(
            get: { attachmentPresentation.presentedVideoAttachment },
            set: { newValue in
                if newValue == nil {
                    VideoPlaybackControllerRegistry.shared.stopAll()
                    attachmentPresentation.presentedVideoAttachment = nil
                }
            }
        )
    }

    private var documentAttachmentPresentationBinding: Binding<Attachment?> {
        Binding(
            get: { attachmentPresentation.presentedDocumentAttachment },
            set: { newValue in
                if newValue == nil {
                    attachmentPresentation.presentedDocumentAttachment = nil
                }
            }
        )
    }

    @ViewBuilder
    private func chatCanvas(geometry: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowDayDivider(at: index) {
                            ChatDayDivider(text: contextualDayText(for: message.createdAt))
                        }

                        MessageBubbleView(
                            chat: currentChat,
                            message: message,
                            replyMessage: replyMessage(for: message),
                            rowWidth: messageColumnWidth(containerWidth: geometry.size.width),
                            currentUserID: appState.currentUser.id,
                            showsIncomingSenderName: shouldShowIncomingSenderName(at: index),
                            showsIncomingAvatar: shouldShowIncomingAvatar(at: index),
                            showsTail: shouldShowBubbleTail(at: index),
                            isActionMenuPresented: activeMessageMenuMessage?.id == message.id,
                            isPressingActionMenu: pressingMessageMenuID == message.id,
                            isPinned: pinnedMessageID == message.id,
                            isOutgoing: message.senderID == appState.currentUser.id,
                            canEdit: viewModel.canEdit(message, currentUserID: appState.currentUser.id),
                            canDelete: viewModel.canDelete(message, currentUserID: appState.currentUser.id),
                            showsCommentsButton: currentChat.communityDetails?.kind == .channel
                                && currentChat.communityDetails?.commentsEnabled == true
                                && message.communityParentPostID == nil
                                && message.isDeleted == false,
                            commentCount: commentCount(for: message),
                            onEdit: {
                                replyingToMessage = nil
                                viewModel.beginEditing(message)
                            },
                            onReply: {
                                beginReplying(to: message)
                            },
                            onOpenReplyTarget: {
                                if let resolvedReplyMessage = replyMessage(for: message) {
                                    localFocusedMessageID = resolvedReplyMessage.id
                                } else if let replyTargetID = message.replyToMessageID {
                                    localFocusedMessageID = replyTargetID
                                }
                            },
                            onCopy: {
                                copyMessageContents(message)
                            },
                            onOpenActionMenu: {
                                openMessageActionMenu(for: message)
                            },
                            onActionMenuPressingChanged: { isPressing in
                                if isPressing {
                                    pressingMessageMenuID = message.id
                                    scheduleMessageActionMenuOpen(for: message)
                                } else if pressingMessageMenuID == message.id {
                                    cancelMessageActionMenuActivation(for: message.id)
                                }
                            },
                            onToggleReaction: { emoji in
                                Task {
                                    await toggleReaction(emoji, for: message)
                                }
                            },
                            onOpenComments: {
                                openComments(for: message)
                            },
                            onPin: {
                                Task {
                                    await togglePin(for: message)
                                }
                            },
                            onForward: {
                                forwardingMessage = message
                                isShowingForwardSheet = true
                            },
                            onRequestDeleteOptions: {
                                pendingDeleteMessage = message
                            },
                            onDelete: {
                                Task {
                                    await viewModel.deleteMessage(
                                        message.id,
                                        chat: currentChat,
                                        requesterID: appState.currentUser.id,
                                        repository: environment.chatRepository
                                    )
                                }
                            },
                            isFloatingPreview: false
                        )
                        .id(message.id)
                        .padding(.bottom, messageRowSpacing(after: index))
                        .background(
                            GeometryReader { frameReader in
                                Color.clear
                                    .preference(
                                        key: ChatMessageFramePreferenceKey.self,
                                        value: [message.id: frameReader.frame(in: .named("chat-scroll"))]
                                    )
                            }
                        )
                    }

                    Color.clear
                        .frame(height: max(bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom), 1))
                        .id(scrollBottomAnchorID)
                        .background(
                            GeometryReader { frameReader in
                                Color.clear.preference(
                                    key: ChatBottomAnchorPreferenceKey.self,
                                    value: frameReader.frame(in: .named("chat-scroll"))
                                )
                            }
                        )
                }
                .padding(.top, topContentInset(safeAreaTop: geometry.safeAreaInsets.top))
                .padding(.bottom, 4)
                .frame(width: messageColumnWidth(containerWidth: geometry.size.width), alignment: .leading)
                .padding(.horizontal, PrimeTheme.Spacing.large)
            }
            .coordinateSpace(name: "chat-scroll")
            .scrollDismissesKeyboard(.interactively)
            .background(Color.clear)
            .onAppear {
                scrollToRelevantMessage(using: proxy, animated: false)
            }
            .onChange(of: viewModel.messages.map(\.id)) { newIDs in
                handleMessageListChange(using: proxy, oldIDs: previousMessageIDs)
                previousMessageIDs = newIDs
            }
            .onChange(of: keyboardRealignmentRequest) { _ in
                guard isNearBottom || pendingAutoScrollAfterOutgoingMessage else { return }
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: localFocusedMessageID) { newValue in
                guard newValue != nil else { return }
                _ = scrollToPendingMessageIfNeeded(using: proxy)
            }
            .onChange(of: bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom)) { _ in
                guard visibleMessages.isEmpty == false else { return }
                if didInitialScrollToBottom == false {
                    scrollToRelevantMessage(using: proxy, animated: false)
                    return
                }
                guard isNearBottom || pendingAutoScrollAfterOutgoingMessage else { return }
                scrollToBottom(using: proxy, animated: false)
            }
            .onPreferenceChange(ChatMessageFramePreferenceKey.self) { frames in
                updateVisibleDay(
                    from: frames,
                    viewportHeight: geometry.size.height,
                    safeAreaTop: geometry.safeAreaInsets.top,
                    safeAreaBottom: geometry.safeAreaInsets.bottom
                )
            }
            .onPreferenceChange(ChatMessageMenuFramePreferenceKey.self) { frames in
                messageMenuFrames = frames
            }
            .onPreferenceChange(ChatBottomAnchorPreferenceKey.self) { frame in
                updateBottomProximity(
                    from: frame,
                    viewportHeight: geometry.size.height,
                    safeAreaBottom: geometry.safeAreaInsets.bottom
                )
            }

            topOverlay
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatTopOverlayHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .padding(.horizontal, 18)
                .padding(.top, topOverlayTopPadding(safeAreaTop: geometry.safeAreaInsets.top))
                .onPreferenceChange(ChatTopOverlayHeightPreferenceKey.self) { height in
                    topOverlayHeight = max(height, 76)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if isShowingFloatingDayChip,
               let visibleDayText,
               visibleMessages.isEmpty == false {
                ChatFloatingDayChip(text: visibleDayText)
                    .padding(.top, topContentInset(safeAreaTop: geometry.safeAreaInsets.top))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            bottomOverlay
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatBottomOverlayHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, bottomOverlayPadding(safeAreaBottom: geometry.safeAreaInsets.bottom))
                .offset(y: bottomOverlayRestingOffset(safeAreaBottom: geometry.safeAreaInsets.bottom))
                .onPreferenceChange(ChatBottomOverlayHeightPreferenceKey.self) { height in
                    bottomOverlayHeight = max(height, 88)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if let activeMessageMenuMessage,
               let messageFrame = messageMenuFrames[activeMessageMenuMessage.id],
               let messageIndex = visibleMessages.firstIndex(where: { $0.id == activeMessageMenuMessage.id }) {
                MessageActionMenuOverlay(
                    chat: currentChat,
                    message: activeMessageMenuMessage,
                    replyMessage: replyMessage(for: activeMessageMenuMessage),
                    currentUserID: appState.currentUser.id,
                    showsIncomingSenderName: shouldShowIncomingSenderName(at: messageIndex),
                    showsTail: shouldShowBubbleTail(at: messageIndex),
                    frame: messageFrame,
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets,
                    isOutgoing: activeMessageMenuMessage.senderID == appState.currentUser.id,
                    isPinned: pinnedMessageID == activeMessageMenuMessage.id,
                    canEdit: viewModel.canEdit(activeMessageMenuMessage, currentUserID: appState.currentUser.id),
                    canDelete: viewModel.canDelete(activeMessageMenuMessage, currentUserID: appState.currentUser.id),
                    showsUndoAction: shouldShowUndoAction(for: activeMessageMenuMessage),
                    canReport: activeMessageMenuMessage.senderID != appState.currentUser.id
                        && activeMessageMenuMessage.isDeleted == false
                        && currentChat.mode != .offline,
                    showsCommentsButton: currentChat.communityDetails?.kind == .channel
                        && currentChat.communityDetails?.commentsEnabled == true
                        && activeMessageMenuMessage.communityParentPostID == nil
                        && activeMessageMenuMessage.isDeleted == false,
                    commentCount: commentCount(for: activeMessageMenuMessage),
                    onDismiss: closeMessageActionMenu,
                    onOpenExpandedPicker: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        reactionPickerMessage = message
                    },
                    onSelectReaction: { emoji in
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        Task {
                            await toggleReaction(emoji, for: message)
                        }
                    },
                    onEdit: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        replyingToMessage = nil
                        viewModel.beginEditing(message)
                    },
                    onReply: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        beginReplying(to: message)
                    },
                    onForward: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        forwardingMessage = message
                        isShowingForwardSheet = true
                    },
                    onCopy: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        copyMessageContents(message)
                    },
                    onPin: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        Task {
                            await togglePin(for: message)
                        }
                    },
                    onReport: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        pendingReportMessage = message
                    },
                    onUndo: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        Task {
                            await undoMessageFromMenu(message)
                        }
                    },
                    onDelete: {
                        let message = activeMessageMenuMessage
                        closeMessageActionMenu()
                        pendingDeleteMessage = message
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }

            if let transitioningAttachment = attachmentPresentation.transitioningAttachment {
                AttachmentOpenTransitionOverlay(
                    attachment: transitioningAttachment,
                    sourceFrame: attachmentPresentation.transitionSourceFrame,
                    containerSize: geometry.size
                )
                .allowsHitTesting(false)
                .zIndex(95)
            }

            if let dismissingAttachment = attachmentPresentation.dismissingAttachment {
                AttachmentCloseTransitionOverlay(
                    attachment: dismissingAttachment,
                    targetFrame: attachmentPresentation.dismissTargetFrame,
                    containerSize: geometry.size
                ) {
                    attachmentPresentation.finishDismissalTransition()
                }
                .allowsHitTesting(false)
                .zIndex(96)
            }

            if !isNearBottom, visibleMessages.isEmpty == false {
                Button {
                    scrollToBottom(using: proxy)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 48, height: 48)
                        Circle()
                            .fill(PrimeTheme.Colors.glassTint)
                            .frame(width: 48, height: 48)
                        Circle()
                            .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    }
                    .shadow(color: Color.black.opacity(0.1), radius: 14, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.trailing, PrimeTheme.Spacing.large)
                .padding(.bottom, bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom) + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .coordinateSpace(name: "chat-root")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                chatCanvas(geometry: geometry, proxy: proxy)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(ChatWallpaperBackground().ignoresSafeArea())
        .overlay(alignment: .leading) {
            edgeBackSwipeHandle
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog(
            "online.preview.send.title".localized,
            isPresented: $isShowingOnlinePreviewSendOptions,
            titleVisibility: .visible
        ) {
            Button("online.preview.send.smart".localized) {
                Task {
                    await continueOfflineSend(as: .smart)
                }
            }
            Button("online.preview.send.offline".localized) {
                Task {
                    await continueOfflineSend(as: .offline)
                }
            }
            Button("common.cancel".localized, role: .cancel) {
                pendingOnlinePreviewDraft = nil
                pendingAutoScrollAfterOutgoingMessage = false
            }
        } message: {
            Text("online.preview.send.message".localized)
        }
        .onAppear {
            appState.selectedChat = currentChat
        }
        .onDisappear {
            if appState.selectedChat?.id == currentChat.id {
                appState.selectedChat = nil
            }
            attachmentPresentation.dismissAll()
            VideoPlaybackControllerRegistry.shared.stopAll()
            VoicePlaybackControllerRegistry.shared.stopAll()
            dayChipHideTask?.cancel()
            draftPersistenceTask?.cancel()
            Task { @MainActor in
                await persistDraftImmediately()
                await persistReadingAnchorImmediately()
            }
        }
        .onChange(of: currentChat) { newValue in
            appState.selectedChat = newValue
        }
        .onChange(of: viewModel.draftText) { _ in
            scheduleDraftPersistence()
        }
        .onChange(of: viewModel.editingMessage?.id) { _ in
            scheduleDraftPersistence()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingReachabilityChanged)) { _ in
            if isSmartDirectChat {
                Task {
                    await refreshSmartTransportState(forceStartScanning: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged)) { _ in
            Task {
                await refreshLocalSnapshotIfAppropriate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingIncomingChatPush)) { notification in
            guard
                let userInfo = notification.userInfo,
                let route = NotificationChatRoute(userInfo: userInfo),
                route.chatID == currentChat.id,
                route.mode == currentChat.mode
            else {
                return
            }

            Task {
                await refreshMessagesIfAppropriate(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await refreshMessagesIfAppropriate(force: true)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            selfDestructNow = value
        }
        #if !os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            let shouldRealignBottom = isNearBottom || pendingAutoScrollAfterOutgoingMessage
            withAnimation(.easeOut(duration: 0.22)) {
                keyboardHeight = 0
            }
            if shouldRealignBottom {
                keyboardRealignmentRequest += 1
            }
        }
        #endif
        .task(id: currentChat.id) {
            attachmentPresentation.dismissAll()
            VideoPlaybackControllerRegistry.shared.stopAll()
            VoicePlaybackControllerRegistry.shared.stopAll()
            didInitialScrollToBottom = false
            visibleDayText = nil
            isShowingFloatingDayChip = false
            pendingSearchMessageID = nil
            localFocusedMessageID = nil
            unreadAnchorMessageID = nil
            readingAnchorMessageID = nil
            topVisibleMessageID = nil
            isNearBottom = true
            isOfflineBannerVisible = true
            activeMessageMenuMessage = nil
            reactionPickerMessage = nil
            previousMessageIDs = []
            lastServerReadMarkAttemptAt = nil
            replyingToMessage = nil
            pendingDeleteMessage = nil
            pendingReportMessage = nil
            forwardingMessage = nil
            selectedCommunityTopicID = nil
            selectedCommentPostID = nil
            await loadLocalPresentationState()
            dayChipHideTask?.cancel()
            if isSmartDirectChat {
                await refreshSmartTransportState(forceStartScanning: true)
            } else {
                smartTransportState = .unknown
                smartDeliveryConfidence = .waiting
                smartPreferredOfflinePath = nil
                smartShouldPreferOnline = false
            }
            await viewModel.hydrateMessages(
                chat: currentChat,
                repository: environment.chatRepository,
                localStore: environment.localStore,
                currentUserID: appState.currentUser.id
            )
            previousMessageIDs = viewModel.messages.map(\.id)
            unreadAnchorMessageID = await ChatReadStateStore.shared.firstUnreadMessageID(
                for: currentChat,
                messages: viewModel.messages,
                currentUserID: appState.currentUser.id
            )
            await refreshCurrentChatMetadataIfNeeded()
            await syncChatPresentationAndReadState()
            await refreshPresenceIfNeeded()
            await refreshMessagesIfAppropriate(force: true)
            var lastSmartTransportRefreshAt = Date()
            while !Task.isCancelled {
                await refreshMessagesIfAppropriate()
                if isSmartDirectChat,
                   Date().timeIntervalSince(lastSmartTransportRefreshAt) >= 60 {
                    await refreshSmartTransportState(forceStartScanning: false)
                    lastSmartTransportRefreshAt = Date()
                }
                try? await Task.sleep(for: openChatRefreshInterval)
            }
        }
        .fullScreenCover(item: photoAttachmentPresentationBinding) { attachment in
            PhotoAttachmentViewer(
                attachment: attachment,
                context: attachmentPresentation.presentedContext
            )
        }
        .fullScreenCover(item: videoAttachmentPresentationBinding) { attachment in
            VideoAttachmentViewer(
                attachment: attachment,
                context: attachmentPresentation.presentedContext
            )
        }
        .sheet(item: documentAttachmentPresentationBinding) { attachment in
            DocumentAttachmentViewer(attachment: attachment)
        }
        .sheet(item: $reactionPickerMessage) { message in
            EmojiReactionPickerSheet { emoji in
                reactionPickerMessage = nil
                Task {
                    await toggleReaction(emoji, for: message)
                }
            }
        }
        .environmentObject(attachmentPresentation)
        .onChange(of: mediaPlaybackActivity.isPlaybackActive) { isActive in
            guard isActive == false else { return }
            Task {
                await runDeferredRefreshesIfNeeded()
            }
        }
        .onChange(of: viewModel.messages.map(\.id)) { _ in
            Task {
                await syncChatPresentationAndReadState()
            }
            if let activeMessageMenuMessage,
               visibleMessages.contains(where: { $0.id == activeMessageMenuMessage.id }) == false {
                closeMessageActionMenu()
            }
            if let selectedCommentPostID,
               viewModel.messages.contains(where: { $0.id == selectedCommentPostID }) == false {
                self.selectedCommentPostID = nil
            }
            if let selectedCommunityTopicID,
               communityTopics.contains(where: { $0.id == selectedCommunityTopicID }) == false {
                self.selectedCommunityTopicID = nil
            }
        }
        .sheet(isPresented: $isShowingGroupInfo) {
            NavigationStack {
                ChatInfoRouterView(
                    chat: $currentChat,
                    onRequestSearch: {
                        isShowingGroupInfo = false
                        isShowingChatSearch = true
                    },
                    onGroupDeleted: {
                        isShowingGroupInfo = false
                        dismiss()
                    },
                    onGroupLeft: {
                        isShowingGroupInfo = false
                        dismiss()
                    }
                )
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingContactProfile) {
            if let contactProfile {
                NavigationStack {
                    ContactProfileView(
                        user: contactProfile,
                        chatBinding: currentChat.type == .direct ? $currentChat : nil,
                        onRequestSearch: {
                            isShowingContactProfile = false
                            isShowingChatSearch = true
                        }
                    )
                }
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $isShowingChatSearch, onDismiss: {
            guard let pendingSearchMessageID else { return }
            localFocusedMessageID = pendingSearchMessageID
            self.pendingSearchMessageID = nil
        }) {
            NavigationStack {
                ChatMessageSearchSheet(
                    title: currentChat.displayTitle(for: appState.currentUser.id),
                    messages: visibleMessages,
                    currentUserID: appState.currentUser.id,
                    chatID: currentChat.id,
                    mode: currentChat.mode
                ) { messageID in
                    pendingSearchMessageID = messageID
                    isShowingChatSearch = false
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingForwardSheet, onDismiss: {
            forwardingMessage = nil
        }) {
            if let forwardingMessage {
                NavigationStack {
                    ChatForwardSheet(
                        currentUserID: appState.currentUser.id,
                        sourceChatID: currentChat.id,
                        currentMode: currentChat.mode,
                        message: forwardingMessage
                    ) { targetChat in
                        Task {
                            await forward(message: forwardingMessage, to: targetChat)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            "Delete message",
            isPresented: Binding(
                get: { pendingDeleteMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteMessage = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMessage
        ) { message in
            Button("Delete for me", systemImage: "trash", role: .destructive) {
                Task {
                    await hideMessageLocally(message)
                }
            }

            if message.senderID == appState.currentUser.id && message.isDeleted == false {
                Button("Delete for everyone", systemImage: "trash.slash", role: .destructive) {
                    Task {
                        await viewModel.deleteMessage(
                            message.id,
                            chat: currentChat,
                            requesterID: appState.currentUser.id,
                            repository: environment.chatRepository
                        )
                        pendingDeleteMessage = nil
                    }
                }
            }

            Button("common.cancel".localized, systemImage: "xmark", role: .cancel) {
                pendingDeleteMessage = nil
            }
        } message: { message in
            Text(message.senderID == appState.currentUser.id ? "Choose how to delete this message." : "This message will be removed only on this device.")
        }
        .confirmationDialog(
            "Report message",
            isPresented: Binding(
                get: { pendingReportMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingReportMessage = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingReportMessage
        ) { message in
            ForEach(ModerationReportReason.allCases) { reason in
                Button(reason.title) {
                    Task {
                        await report(message, reason: reason)
                    }
                }
            }

            Button("common.cancel".localized, role: .cancel) {
                pendingReportMessage = nil
            }
        } message: { _ in
            Text("Choose a reason for reporting this message.")
        }
    }

    private var scrollBottomAnchorID: String {
        "chat-bottom-\(currentChat.id.uuidString)"
    }

    private var openChatRefreshInterval: Duration {
        if AudioRecorderController.hasActiveRecording() {
            return .seconds(18)
        }
        return currentChat.mode == .offline ? .seconds(6) : .seconds(12)
    }

    @MainActor
    private func refreshLocalSnapshotIfAppropriate() async {
        if AudioRecorderController.hasActiveRecording() {
            pendingDeferredSnapshotRefresh = true
            return
        }
        if mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 1.5) {
            pendingDeferredSnapshotRefresh = true
            return
        }

        pendingDeferredSnapshotRefresh = false
        await viewModel.refreshLocalSnapshot(
            chat: currentChat,
            repository: environment.chatRepository,
            currentUserID: appState.currentUser.id
        )
        await syncChatPresentationAndReadState()
    }

    @MainActor
    private func refreshMessagesIfAppropriate(force: Bool = false) async {
        if AudioRecorderController.hasActiveRecording() {
            pendingDeferredMessageRefresh = true
            return
        }
        if force == false, mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 2.0) {
            pendingDeferredMessageRefresh = true
            return
        }

        pendingDeferredMessageRefresh = false
        await viewModel.refreshMessages(
            chat: currentChat,
            repository: environment.chatRepository,
            currentUserID: appState.currentUser.id
        )
        await refreshCurrentChatMetadataIfNeeded()
        await syncChatPresentationAndReadState()
        await refreshPresenceIfNeeded()
    }

    @MainActor
    private func runDeferredRefreshesIfNeeded() async {
        guard mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 1.25) == false else { return }

        if pendingDeferredSnapshotRefresh {
            await refreshLocalSnapshotIfAppropriate()
        }

        if pendingDeferredMessageRefresh {
            await refreshMessagesIfAppropriate(force: true)
        }
    }

    private func topOverlayTopPadding(safeAreaTop: CGFloat) -> CGFloat {
        max(safeAreaTop - 58, 0)
    }

    @MainActor
    private func report(_ message: Message, reason: ModerationReportReason) async {
        defer { pendingReportMessage = nil }

        do {
            try await environment.chatRepository.reportChatContent(
                in: currentChat,
                requesterID: appState.currentUser.id,
                targetMessageID: message.id,
                targetUserID: message.senderID,
                reason: reason,
                details: nil
            )
            viewModel.messageActionError = "Report sent."
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty ? "Could not submit the report." : error.localizedDescription
        }
    }

    private func messageColumnWidth(containerWidth: CGFloat) -> CGFloat {
        max(containerWidth - (PrimeTheme.Spacing.large * 2), 0)
    }

    private func topContentInset(safeAreaTop: CGFloat) -> CGFloat {
        topOverlayHeight + topOverlayTopPadding(safeAreaTop: safeAreaTop) + 6
    }

    private func effectiveKeyboardInset(safeAreaBottom: CGFloat) -> CGFloat {
        max(keyboardHeight - safeAreaBottom, 0)
    }

    private func bottomOverlayPadding(safeAreaBottom: CGFloat) -> CGFloat {
        let keyboardInset = effectiveKeyboardInset(safeAreaBottom: safeAreaBottom)
        if keyboardInset > 0 {
            return keyboardInset
        }
        return 0
    }

    private func bottomOverlayRestingOffset(safeAreaBottom: CGFloat) -> CGFloat {
        effectiveKeyboardInset(safeAreaBottom: safeAreaBottom) > 0 ? 0 : 6
    }

    private func bottomContentInset(safeAreaBottom: CGFloat) -> CGFloat {
        bottomOverlayHeight + bottomOverlayPadding(safeAreaBottom: safeAreaBottom) + 10
    }

    private func scrollToRelevantMessage(using proxy: ScrollViewProxy, animated: Bool) {
        if scrollToPendingMessageIfNeeded(using: proxy, animated: animated) {
            return
        }

        if scrollToUnreadAnchorIfNeeded(using: proxy, animated: animated) {
            return
        }

        if scrollToReadingAnchorIfNeeded(using: proxy, animated: animated) {
            return
        }

        guard visibleMessages.isEmpty == false else { return }

        guard didInitialScrollToBottom == false else { return }
        didInitialScrollToBottom = true
        scrollToBottom(using: proxy, animated: animated)
    }

    private func scrollToPendingMessageIfNeeded(using proxy: ScrollViewProxy, animated: Bool = true) -> Bool {
        if localFocusedMessageID == nil {
            localFocusedMessageID = appState.consumeFocusedMessageID(for: currentChat.id)
        }

        guard let targetMessageID = localFocusedMessageID else {
            return false
        }

        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            return false
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(targetMessageID, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetMessageID, anchor: .center)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                if localFocusedMessageID == targetMessageID {
                    localFocusedMessageID = nil
                }
            }
        }
        return true
    }

    private func scrollToUnreadAnchorIfNeeded(using proxy: ScrollViewProxy, animated: Bool = true) -> Bool {
        guard let targetMessageID = unreadAnchorMessageID else { return false }
        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            unreadAnchorMessageID = nil
            return false
        }

        didInitialScrollToBottom = true
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(targetMessageID, anchor: .top)
                }
            } else {
                proxy.scrollTo(targetMessageID, anchor: .top)
            }
            unreadAnchorMessageID = nil
        }
        return true
    }

    private func scrollToReadingAnchorIfNeeded(using proxy: ScrollViewProxy, animated: Bool = true) -> Bool {
        guard let targetMessageID = readingAnchorMessageID else { return false }
        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            readingAnchorMessageID = nil
            return false
        }

        didInitialScrollToBottom = true
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(targetMessageID, anchor: .top)
                }
            } else {
                proxy.scrollTo(targetMessageID, anchor: .top)
            }
            readingAnchorMessageID = nil
        }
        return true
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool = true) {
        dayChipHideTask?.cancel()
        isNearBottom = true
        topVisibleMessageID = nil
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingFloatingDayChip = false
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func handleMessageListChange(using proxy: ScrollViewProxy, oldIDs: [UUID]) {
        if scrollToPendingMessageIfNeeded(using: proxy) {
            return
        }

        if didInitialScrollToBottom == false {
            scrollToRelevantMessage(using: proxy, animated: false)
            return
        }

        let newIDs = viewModel.messages.map(\.id)
        let oldIDSet = Set(oldIDs)
        let hasInsertedMessages = newIDs.contains(where: { oldIDSet.contains($0) == false })

        if pendingAutoScrollAfterOutgoingMessage {
            pendingAutoScrollAfterOutgoingMessage = false
            if hasInsertedMessages || isNearBottom {
                scrollToBottom(using: proxy)
            }
            return
        }

        if hasInsertedMessages, isNearBottom {
            scrollToBottom(using: proxy)
        }
    }

    private func shouldShowDayDivider(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let currentDate = visibleMessages[index].createdAt
        let previousDate = visibleMessages[index - 1].createdAt
        return Calendar.autoupdatingCurrent.isDate(currentDate, inSameDayAs: previousDate) == false
    }

    private func shouldShowIncomingSenderName(at index: Int) -> Bool {
        guard currentChat.type == .group else { return false }
        let message = visibleMessages[index]
        guard message.senderID != appState.currentUser.id else { return false }
        guard let previousMessage = previousVisibleMessage(at: index) else { return true }
        return isGroupedMessage(message, with: previousMessage) == false
    }

    private func shouldShowIncomingAvatar(at index: Int) -> Bool {
        guard currentChat.type == .group else { return false }
        let message = visibleMessages[index]
        guard message.senderID != appState.currentUser.id else { return false }
        guard let nextMessage = nextVisibleMessage(at: index) else { return true }
        return isGroupedMessage(message, with: nextMessage) == false
    }

    private func shouldShowBubbleTail(at index: Int) -> Bool {
        let message = visibleMessages[index]
        guard let nextMessage = nextVisibleMessage(at: index) else { return true }
        return isGroupedMessage(message, with: nextMessage) == false
    }

    private func messageRowSpacing(after index: Int) -> CGFloat {
        guard let nextMessage = nextVisibleMessage(at: index) else { return PrimeTheme.Spacing.medium / 2 }
        let currentMessage = visibleMessages[index]
        return isGroupedMessage(currentMessage, with: nextMessage)
            ? PrimeTheme.Spacing.medium / 4
            : PrimeTheme.Spacing.medium / 2
    }

    private func previousVisibleMessage(at index: Int) -> Message? {
        guard index > 0 else { return nil }
        return visibleMessages[index - 1]
    }

    private func nextVisibleMessage(at index: Int) -> Message? {
        guard index + 1 < visibleMessages.count else { return nil }
        return visibleMessages[index + 1]
    }

    private func isGroupedMessage(_ lhs: Message, with rhs: Message) -> Bool {
        lhs.senderID == rhs.senderID
            && Calendar.autoupdatingCurrent.isDate(lhs.createdAt, inSameDayAs: rhs.createdAt)
    }

    private func updateBottomProximity(from frame: CGRect, viewportHeight: CGFloat, safeAreaBottom: CGFloat) {
        let distanceFromVisibleBottom = frame.maxY - viewportHeight
        let nextValue: Bool

        if isNearBottom {
            nextValue = distanceFromVisibleBottom <= max(bottomContentInset(safeAreaBottom: safeAreaBottom) * 0.24, 96)
        } else {
            nextValue = distanceFromVisibleBottom <= 72
        }

        isNearBottom = nextValue
        if nextValue {
            topVisibleMessageID = nil
            dayChipHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingFloatingDayChip = false
            }
        }
    }

    private func updateVisibleDay(from frames: [UUID: CGRect], viewportHeight: CGFloat, safeAreaTop: CGFloat, safeAreaBottom: CGFloat) {
        let visibleTop = max(topContentInset(safeAreaTop: safeAreaTop) - 8, 0)
        let visibleBottom = max(
            viewportHeight - bottomContentInset(safeAreaBottom: safeAreaBottom) + 18,
            visibleTop + 1
        )

        guard let visibleMessage = visibleMessages.first(where: { message in
            guard let frame = frames[message.id] else { return false }
            return frame.maxY >= visibleTop && frame.minY <= visibleBottom
        }) else {
            visibleDayText = nil
            topVisibleMessageID = nil
            dayChipHideTask?.cancel()
            isShowingFloatingDayChip = false
            return
        }

        topVisibleMessageID = visibleMessage.id
        visibleDayText = contextualDayText(for: visibleMessage.createdAt)

        guard isNearBottom == false else {
            dayChipHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingFloatingDayChip = false
            }
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            isShowingFloatingDayChip = true
        }
        scheduleDayChipHide()
    }

    private func scheduleDayChipHide() {
        dayChipHideTask?.cancel()
        dayChipHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingFloatingDayChip = false
            }
        }
    }

    private func contextualDayText(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent

        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: Date.now),
           currentWeek.contains(date) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date).capitalized
        }

        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter.string(from: date)
    }

    @MainActor
    private func loadLocalPresentationState() async {
        hiddenMessageIDs = await HiddenMessageStore.shared.hiddenMessageIDs(
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id
        )
        pinnedMessageID = await PinnedMessageStore.shared.pinnedMessageID(
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id
        )
        clearedThreadCutoff = await ChatThreadStateStore.shared.clearedAt(
            ownerUserID: appState.currentUser.id,
            mode: currentChat.mode,
            chatID: currentChat.id
        )
        readingAnchorMessageID = await ChatNavigationStateStore.shared.readingAnchorMessageID(
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id,
            mode: currentChat.mode
        )
    }

    private func replyMessage(for message: Message) -> Message? {
        guard let replyToMessageID = message.replyToMessageID else { return nil }
        return viewModel.messages.first(where: {
            $0.id == replyToMessageID && $0.shouldHideDeletedPlaceholder == false
        })
    }

    private func beginReplying(to message: Message) {
        replyingToMessage = message
        if viewModel.editingMessage != nil {
            viewModel.cancelEditing()
        }
    }

    private func shouldShowUndoAction(for message: Message) -> Bool {
        guard message.senderID == appState.currentUser.id else { return false }
        guard message.isDeleted == false else { return false }
        return Date.now.timeIntervalSince(message.createdAt) <= Message.hiddenDeletePlaceholderWindow
    }

    private func openMessageActionMenu(for message: Message) {
        guard activeMessageMenuMessage?.id != message.id else { return }
        messageMenuActivationTask?.cancel()
        messageMenuActivationTask = nil
        pressingMessageMenuID = nil
        #if !os(tvOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            activeMessageMenuMessage = message
        }
        #if !os(tvOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func closeMessageActionMenu() {
        messageMenuActivationTask?.cancel()
        messageMenuActivationTask = nil
        pressingMessageMenuID = nil
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            activeMessageMenuMessage = nil
        }
    }

    private func scheduleMessageActionMenuOpen(for message: Message) {
        messageMenuActivationTask?.cancel()
        let messageID = message.id
        messageMenuActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }
            guard pressingMessageMenuID == messageID else { return }
            openMessageActionMenu(for: message)
        }
    }

    private func cancelMessageActionMenuActivation(for messageID: UUID) {
        messageMenuActivationTask?.cancel()
        messageMenuActivationTask = nil
        if activeMessageMenuMessage?.id != messageID, pressingMessageMenuID == messageID {
            pressingMessageMenuID = nil
        }
    }

    private func copyMessageContents(_ message: Message) {
        #if !os(tvOS)
        UIPasteboard.general.string = messagePreviewText(for: message)
        #endif
    }

    @MainActor
    private func toggleReaction(_ emoji: String, for message: Message) async {
        do {
            let updated = try await environment.chatRepository.toggleReaction(
                emoji,
                on: message.id,
                in: currentChat.id,
                mode: currentChat.mode,
                userID: appState.currentUser.id
            )
            viewModel.replaceOrAppend(updated)
            viewModel.messageActionError = ""
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty ? "Could not update the reaction." : error.localizedDescription
        }
    }

    @MainActor
    private func togglePin(for message: Message) async {
        let nextPinnedMessageID = pinnedMessageID == message.id ? nil : message.id
        await PinnedMessageStore.shared.pinMessage(
            nextPinnedMessageID,
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id
        )
        pinnedMessageID = nextPinnedMessageID
    }

    @MainActor
    private func hideMessageLocally(_ message: Message) async {
        await HiddenMessageStore.shared.hideMessage(
            message.id,
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id
        )
        hiddenMessageIDs.insert(message.id)
        if pinnedMessageID == message.id {
            await PinnedMessageStore.shared.pinMessage(
                nil,
                ownerUserID: appState.currentUser.id,
                chatID: currentChat.id
            )
            pinnedMessageID = nil
        }
        if replyingToMessage?.id == message.id {
            replyingToMessage = nil
        }
        pendingDeleteMessage = nil
    }

    @MainActor
    private func undoMessageFromMenu(_ message: Message) async {
        let targetClientMessageID = message.clientMessageID
        var deferredError: String?

        if message.status == .localPending || message.status == .sending {
            await environment.chatRepository.cancelPendingOutgoingMessage(
                clientMessageID: targetClientMessageID,
                in: currentChat,
                ownerUserID: appState.currentUser.id
            )
            viewModel.removeMessageLocally(clientMessageID: targetClientMessageID)
        }

        do {
            let deleted = try await environment.chatRepository.deleteMessage(
                message.id,
                in: currentChat.id,
                mode: currentChat.mode,
                requesterID: appState.currentUser.id
            )
            viewModel.replaceOrAppend(deleted)
            await hideMessageLocally(deleted)
            viewModel.messageActionError = ""
            return
        } catch {
            deferredError = error.localizedDescription.isEmpty
                ? "Could not undo the message."
                : error.localizedDescription
        }

        for attempt in 0..<3 {
            await viewModel.refreshMessages(
                chat: currentChat,
                repository: environment.chatRepository,
                currentUserID: appState.currentUser.id
            )

            if let replicatedMessage = viewModel.messages.first(where: {
                $0.clientMessageID == targetClientMessageID &&
                $0.senderID == appState.currentUser.id &&
                $0.isDeleted == false
            }) {
                do {
                    let deleted = try await environment.chatRepository.deleteMessage(
                        replicatedMessage.id,
                        in: currentChat.id,
                        mode: currentChat.mode,
                        requesterID: appState.currentUser.id
                    )
                    viewModel.replaceOrAppend(deleted)
                    await hideMessageLocally(deleted)
                    viewModel.messageActionError = ""
                    return
                } catch {
                    deferredError = error.localizedDescription.isEmpty
                        ? "Could not undo the message."
                        : error.localizedDescription
                }
            }

            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(320))
            }
        }

        viewModel.removeMessageLocally(clientMessageID: targetClientMessageID)
        if let deferredError {
            viewModel.messageActionError = deferredError
        } else {
            viewModel.messageActionError = ""
        }
    }

    @MainActor
    private func forward(message: Message, to targetChat: Chat) async {
        guard let draft = makeForwardDraft(from: message) else {
            isShowingForwardSheet = false
            forwardingMessage = nil
            return
        }

        do {
            _ = try await environment.chatRepository.sendMessage(
                draft,
                in: targetChat,
                senderID: appState.currentUser.id
            )
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty ? "Could not forward the message." : error.localizedDescription
        }

        isShowingForwardSheet = false
        forwardingMessage = nil
    }

    private func makeForwardDraft(from message: Message) -> OutgoingMessageDraft? {
        guard message.isDeleted == false else { return nil }

        return OutgoingMessageDraft(
            text: message.text ?? "",
            attachments: message.attachments,
            voiceMessage: message.voiceMessage,
            replyToMessageID: nil
        )
    }

    private func messagePreviewText(for message: Message) -> String {
        if message.isDeleted {
            return message.shouldHideDeletedPlaceholder ? "Original message" : "Message deleted"
        }

        if let structuredContent = StructuredChatMessageContent.parse(message.text) {
            return structuredContent.previewText
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
            case .document:
                return attachment.fileName
            case .audio:
                return "Audio"
            case .contact:
                return "Contact"
            case .location:
                return "Location"
            }
        }

        return "Message"
    }

    private var topOverlay: some View {
        VStack(spacing: PrimeTheme.Spacing.small) {
            chatHeader

            if isSmartDirectChat {
                smartDeliveryBanner
            }

            if currentChat.type == .group,
               currentChat.communityDetails != nil,
               (showsCommunityTopicStrip || selectedCommentPostID != nil) {
                communityTimelineBanner
            }

            if let pinnedMessage {
                ChatPinnedMessageBanner(
                    message: pinnedMessage,
                    previewText: messagePreviewText(for: pinnedMessage)
                ) {
                    localFocusedMessageID = pinnedMessage.id
                } onClear: {
                    Task {
                        await togglePin(for: pinnedMessage)
                    }
                }
            }

            if currentChat.mode == .offline, isOfflineBannerVisible {
                OfflineSessionBanner {
                    isOfflineBannerVisible = false
                }
            }
        }
    }

    private var communityTimelineBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedCommentPost {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Comments thread")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        Text(messagePreviewText(for: selectedCommentPost))
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Button("Back to posts") {
                        closeCommentsThread()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.accent)
                }
                commentThreadSourceCard(for: selectedCommentPost)
            } else if showsCommunityTopicStrip {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        communityTopicChip(
                            title: "All",
                            systemName: "tray.full.fill",
                            isSelected: selectedCommunityTopicID == nil
                        ) {
                            selectedCommunityTopicID = nil
                        }

                        ForEach(communityTopics) { topic in
                            communityTopicChip(
                                title: topic.title,
                                systemName: topic.symbolName,
                                isSelected: selectedCommunityTopicID == topic.id
                            ) {
                                selectedCommunityTopicID = topic.id
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .chatGlassCard(cornerRadius: 18)
    }

    private func communityTopicChip(
        title: String,
        systemName: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : PrimeTheme.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? PrimeTheme.Colors.accent : PrimeTheme.Colors.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? PrimeTheme.Colors.accent.opacity(0.3) : PrimeTheme.Colors.separator.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var bottomOverlay: some View {
        VStack(spacing: PrimeTheme.Spacing.small) {
            if !viewModel.messageActionError.isEmpty {
                Text(viewModel.messageActionError)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.vertical, 12)
                    .chatGlassCard(cornerRadius: 18)
            }

            if let guestRequestState {
                guestRequestPanel(for: guestRequestState)
            } else if showsComposer {
                MessageComposerView(
                    draftText: $viewModel.draftText,
                    chatTitle: currentChat.displayTitle(for: appState.currentUser.id),
                    chatMode: currentChat.mode,
                    isSending: viewModel.isSending,
                    editingMessage: viewModel.editingMessage,
                    replyMessage: replyingToMessage,
                    communityContextTitle: communityComposeContextTitle,
                    communityContext: communityComposeContext,
                    onCancelEditing: {
                        viewModel.cancelEditing()
                    },
                    onCancelReply: {
                        replyingToMessage = nil
                    },
                    onCancelCommunityContext: communityComposeContextTitle == nil ? nil : {
                        clearCommunityComposeContext()
                    },
                    onSend: { draft in
                        if isOfflineOnlineChat {
                            guard viewModel.editingMessage == nil else {
                                viewModel.messageActionError = "online.preview.editing_unavailable".localized
                                pendingAutoScrollAfterOutgoingMessage = false
                                return
                            }

                            pendingAutoScrollAfterOutgoingMessage = true
                            pendingOnlinePreviewDraft = draft
                            isShowingOnlinePreviewSendOptions = true
                            return
                        }

                        let wasEditingMessage = viewModel.editingMessage != nil
                        pendingAutoScrollAfterOutgoingMessage = !wasEditingMessage
                        do {
                            _ = try await viewModel.submitComposer(
                                draft,
                                chat: currentChat,
                                senderID: appState.currentUser.id,
                                repository: environment.chatRepository
                            )
                            replyingToMessage = nil
                            await persistDraftImmediately()
                        } catch {
                            pendingAutoScrollAfterOutgoingMessage = false
                            if let chatError = error as? ChatRepositoryError {
                                switch chatError {
                                case .guestRequestPending, .guestRequestApprovalRequired, .guestRequestIntroRequired, .guestRequestDeclined:
                                    await refreshCurrentChatMetadataIfNeeded()
                                default:
                                    break
                                }
                            }
                            throw error
                        }
                    }
                )
                .chatGlassCard(cornerRadius: 28)
            }
        }
    }

    private func commentThreadSourceCard(for post: Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (post.senderDisplayName ?? "Post") : "Channel post")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)

            Text(messagePreviewText(for: post))
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func guestRequestPanel(for state: ChatGuestRequestState) -> some View {
        switch state {
        case let .pendingOutgoing(canSubmitIntro):
            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                GuestRequestStatusCard(
                    title: canSubmitIntro ? "Send request to chat" : "Request sent",
                    message: guestRequestDescription(for: state),
                    introText: currentChat.guestRequest?.introText,
                    isWarning: false
                )

                if canSubmitIntro {
                    GuestRequestIntroComposer(
                        text: $viewModel.draftText,
                        isSubmitting: isUpdatingGuestRequest
                    ) {
                        await submitGuestRequestIntro()
                    }
                    .chatGlassCard(cornerRadius: 28)
                }
            }
        case .pendingIncoming:
            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                GuestRequestStatusCard(
                    title: "Guest request",
                    message: guestRequestDescription(for: state),
                    introText: currentChat.guestRequest?.introText,
                    isWarning: false
                )

                HStack(spacing: PrimeTheme.Spacing.small) {
                    Button {
                        Task {
                            await respondToGuestRequest(approve: false)
                        }
                    } label: {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.warning.opacity(0.18))
                    )

                    Button {
                        Task {
                            await respondToGuestRequest(approve: true)
                        }
                    } label: {
                        Text("Approve")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.accent)
                    )
                }
                .disabled(isUpdatingGuestRequest)
                .chatGlassCard(cornerRadius: 24)
            }
        case .declinedOutgoing, .declinedIncoming:
            GuestRequestStatusCard(
                title: "Request unavailable",
                message: guestRequestDescription(for: state),
                introText: currentChat.guestRequest?.introText,
                isWarning: true
            )
            .chatGlassCard(cornerRadius: 24)
        }
    }

    private func guestRequestDescription(for state: ChatGuestRequestState) -> String {
        switch state {
        case let .pendingOutgoing(canSubmitIntro):
            return canSubmitIntro
                ? "Write a short introduction up to 150 characters. It will be sent as your guest chat request."
                : "Your request is waiting for approval. Until then, regular messages are locked."
        case .pendingIncoming:
            return "Approve this guest request to unlock the conversation, or decline it to keep the chat closed."
        case .declinedOutgoing:
            return "This request was declined. The guest chat stays locked."
        case .declinedIncoming:
            return "You declined this guest request. Regular messages remain locked."
        }
    }

    @MainActor
    private func submitGuestRequestIntro() async {
        guard let guestRequestState else { return }
        guard case let .pendingOutgoing(canSubmitIntro) = guestRequestState, canSubmitIntro else { return }

        let introText = viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard introText.isEmpty == false else {
            viewModel.messageActionError = ChatRepositoryError.guestRequestIntroRequired.localizedDescription
            return
        }
        guard introText.count <= 150 else {
            viewModel.messageActionError = ChatRepositoryError.guestRequestIntroTooLong.localizedDescription
            return
        }

        isUpdatingGuestRequest = true
        defer { isUpdatingGuestRequest = false }

        do {
            currentChat = try await environment.chatRepository.submitGuestRequest(
                introText: introText,
                in: currentChat.id,
                senderID: appState.currentUser.id
            )
            viewModel.draftText = ""
            await persistDraftImmediately()
            viewModel.messageActionError = ""
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty ? "Could not send the guest request." : error.localizedDescription
        }
    }

    @MainActor
    private func respondToGuestRequest(approve: Bool) async {
        isUpdatingGuestRequest = true
        defer { isUpdatingGuestRequest = false }

        do {
            currentChat = try await environment.chatRepository.respondToGuestRequest(
                in: currentChat.id,
                approve: approve,
                responderID: appState.currentUser.id
            )
            viewModel.messageActionError = ""
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty
                ? "Could not update the guest request."
                : error.localizedDescription
        }
    }

    @MainActor
    private func continueOfflineSend(as mode: ChatMode) async {
        guard let draft = pendingOnlinePreviewDraft else { return }

        do {
            let targetChat: Chat
            switch mode {
            case .smart:
                targetChat = smartContinuationChat()
            case .offline:
                targetChat = try await environment.offlineTransport.importHistory(
                    viewModel.messages,
                    into: currentChat,
                    currentUser: appState.currentUser
                )
            case .online:
                pendingOnlinePreviewDraft = nil
                return
            }

            _ = try await viewModel.submitComposer(
                draft,
                chat: targetChat,
                senderID: appState.currentUser.id,
                repository: environment.chatRepository
            )
            appState.updateSelectedMode(mode)
            currentChat = targetChat
            replyingToMessage = nil
            viewModel.messageActionError = ""
        } catch {
            pendingAutoScrollAfterOutgoingMessage = false
            viewModel.messageActionError = error.localizedDescription.isEmpty
                ? "Could not continue this message."
                : error.localizedDescription
        }

        pendingOnlinePreviewDraft = nil
    }

    private func smartContinuationChat() -> Chat {
        let smartChatID = SmartChatSupport.smartChatID(for: currentChat, currentUserID: appState.currentUser.id)
        return Chat(
            id: smartChatID,
            mode: .smart,
            type: currentChat.type,
            title: currentChat.title,
            subtitle: currentChat.subtitle,
            participantIDs: currentChat.participantIDs,
            participants: currentChat.participants,
            group: currentChat.group,
            lastMessagePreview: currentChat.lastMessagePreview,
            lastActivityAt: currentChat.lastActivityAt,
            unreadCount: currentChat.unreadCount,
            isPinned: currentChat.isPinned,
            draft: currentChat.draft,
            disappearingPolicy: currentChat.disappearingPolicy,
            notificationPreferences: currentChat.notificationPreferences,
            guestRequest: currentChat.guestRequest
        )
    }

    private var chatHeader: some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                    Circle()
                        .fill(PrimeTheme.Colors.glassTint)
                        .frame(width: 44, height: 44)
                    Circle()
                        .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                        .frame(width: 44, height: 44)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                }
                .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                openHeaderDestination()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Text(currentChat.displayTitle(for: appState.currentUser.id))
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.84)
                            .allowsTightening(true)

                        if currentChat.communityDetails?.isOfficial == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.accent)
                        }
                    }
                    .frame(maxWidth: 220)
                    if headerStatusText.isEmpty == false {
                        Text(headerStatusText)
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .fill(headerTitleGlassTint)
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(headerTitleGlassStroke, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(currentChat.type == .selfChat ? 0.18 : 0.1), radius: 16, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(!(currentChat.type == .group && supportsServerBackedFeatures) && currentChat.type != .direct)

            Spacer(minLength: 0)

            Button {
                openHeaderDestination()
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                    Circle()
                        .fill(PrimeTheme.Colors.glassTint)
                        .frame(width: 44, height: 44)
                    Circle()
                        .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                        .frame(width: 44, height: 44)
                    if currentChat.type == .selfChat {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    } else if let groupPhotoURL = currentChat.group?.photoURL {
                        CachedRemoteImage(url: groupPhotoURL) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            headerBadgePlaceholder
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    } else {
                        headerBadgePlaceholder
                    }
                }
                .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!(currentChat.type == .group && supportsServerBackedFeatures) && currentChat.type != .direct && currentChat.type != .selfChat)
        }
    }

    private var smartDeliveryBanner: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            Image(systemName: smartDeliveryBannerIconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(smartDeliveryBannerTint)

            VStack(alignment: .leading, spacing: 2) {
                Text(smartDeliveryBannerTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(smartDeliveryBannerSubtitle)
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(smartConfidenceLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(smartDeliveryBannerTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(smartDeliveryBannerTint.opacity(0.12))
                )
        }
        .padding(.horizontal, PrimeTheme.Spacing.medium)
        .padding(.vertical, 12)
        .chatGlassCard(cornerRadius: PrimeTheme.Radius.card)
    }

    private var smartDeliveryBannerTitle: String {
        switch smartTransportState {
        case .nearby:
            return smartPreferredOfflinePath == .localNetwork ? "Nearby route ready" : "Bluetooth route ready"
        case .relay:
            return "Relay route available"
        case .online:
            return smartShouldPreferOnline ? "Online fallback active" : "Online route ready"
        case .waiting:
            return "Looking for the best route"
        case .unknown:
            return "Smart delivery"
        }
    }

    private var smartDeliveryBannerSubtitle: String {
        let queuedSuffix: String
        if smartQueuedMessageCount > 0 {
            queuedSuffix = smartQueuedMessageCount == 1
                ? " 1 queued message will continue automatically."
                : " \(smartQueuedMessageCount) queued messages will continue automatically."
        } else {
            queuedSuffix = ""
        }

        switch smartTransportState {
        case .nearby:
            switch smartDeliveryConfidence {
            case .high:
                return "Prime can deliver directly nearby right now.\(queuedSuffix)"
            case .medium:
                return "Nearby delivery looks stable, but Prime is still watching the route.\(queuedSuffix)"
            case .low:
                return "Nearby is reachable, but Prime may switch online if it slows down.\(queuedSuffix)"
            case .waiting:
                return "Prime is checking the nearby route before the next send.\(queuedSuffix)"
            }
        case .relay:
            return "Direct nearby is unavailable, but a relay device can help carry messages.\(queuedSuffix)"
        case .online:
            return smartShouldPreferOnline
                ? "Nearby became unreliable, so Prime is preferring internet delivery for now.\(queuedSuffix)"
                : "No strong nearby route right now. Prime will use internet delivery.\(queuedSuffix)"
        case .waiting:
            return "Prime is waiting for either a nearby path or a usable network route.\(queuedSuffix)"
        case .unknown:
            return "Smart will automatically choose the best delivery path.\(queuedSuffix)"
        }
    }

    private var smartDeliveryBannerIconName: String {
        switch smartTransportState {
        case .nearby:
            return smartPreferredOfflinePath == .localNetwork ? "wifi" : "dot.radiowaves.left.and.right"
        case .relay:
            return "point.3.filled.connected.trianglepath.dotted"
        case .online:
            return "network"
        case .waiting, .unknown:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    private var smartDeliveryBannerTint: Color {
        switch smartTransportState {
        case .nearby:
            return smartDeliveryConfidence == .low ? PrimeTheme.Colors.warning : PrimeTheme.Colors.success
        case .relay:
            return PrimeTheme.Colors.smartAccent
        case .online:
            return smartShouldPreferOnline ? PrimeTheme.Colors.warning : PrimeTheme.Colors.accent
        case .waiting, .unknown:
            return PrimeTheme.Colors.textSecondary
        }
    }

    private var smartConfidenceLabel: String {
        switch smartDeliveryConfidence {
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        case .waiting:
            return "Waiting"
        }
    }

    private var headerBadgeText: String {
        let title = currentChat.displayTitle(for: appState.currentUser.id)
        let initials = title
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()

        return initials.isEmpty ? String(title.prefix(2)).uppercased() : initials.uppercased()
    }

    private var headerBadgePlaceholder: some View {
        Text(headerBadgeText)
            .font(.system(.footnote, design: .rounded).weight(.bold))
            .foregroundStyle(PrimeTheme.Colors.textPrimary)
    }

    private var headerTitleGlassTint: Color {
        currentChat.type == .selfChat
            ? PrimeTheme.Colors.elevated.opacity(0.84)
            : PrimeTheme.Colors.glassTint
    }

    private var headerTitleGlassStroke: Color {
        currentChat.type == .selfChat
            ? PrimeTheme.Colors.glassStroke.opacity(1)
            : PrimeTheme.Colors.glassStroke
    }

    private func openHeaderDestination() {
        if currentChat.type == .group, supportsServerBackedFeatures {
            isShowingGroupInfo = true
        } else if currentChat.type == .direct {
            Task {
                await openContactProfile()
            }
        } else if currentChat.type == .selfChat {
            isShowingChatSearch = true
        }
    }

    private func filteredCommunityMessages(from messages: [Message]) -> [Message] {
        var filtered = messages

        if let selectedCommunityTopicID {
            filtered = filtered.filter { $0.communityTopicID == selectedCommunityTopicID }
        }

        guard currentChat.communityDetails?.kind == .channel else {
            return filtered
        }

        if let selectedCommentPostID {
            return filtered.filter { $0.communityParentPostID == selectedCommentPostID }
        }

        return filtered.filter { $0.communityParentPostID == nil }
    }

    private func commentCount(for post: Message) -> Int {
        viewModel.messages.filter { message in
            hiddenMessageIDs.contains(message.id) == false &&
            message.communityParentPostID == post.id
        }.count
    }

    @MainActor
    private func openComments(for post: Message) {
        replyingToMessage = nil
        selectedCommentPostID = post.id
        if selectedCommunityTopicID == nil {
            selectedCommunityTopicID = post.communityTopicID
        }
        localFocusedMessageID = nil
    }

    @MainActor
    private func closeCommentsThread() {
        selectedCommentPostID = nil
    }

    @MainActor
    private func clearCommunityComposeContext() {
        if selectedCommentPostID != nil {
            closeCommentsThread()
        } else {
            selectedCommunityTopicID = nil
        }
    }

    @MainActor
    private func syncChatPresentationAndReadState() async {
        currentChat = await ContactAliasStore.shared.applyAlias(
            to: currentChat,
            currentUserID: appState.currentUser.id,
            messages: viewModel.messages
        )
        await ChatReadStateStore.shared.markChatRead(
            chatID: currentChat.id,
            mode: currentChat.mode,
            userID: appState.currentUser.id,
            messages: viewModel.messages
        )
        if supportsServerBackedFeatures,
           currentChat.type != .selfChat,
           currentChat.mode == .online {
            let now = Date()
            if let lastServerReadMarkAttemptAt,
               now.timeIntervalSince(lastServerReadMarkAttemptAt) < 1.0 {
                return
            }
            lastServerReadMarkAttemptAt = now
            try? await environment.chatRepository.markChatRead(
                chatID: currentChat.id,
                mode: currentChat.mode,
                readerID: appState.currentUser.id
            )
        }
    }

    @MainActor
    private func refreshCurrentChatMetadataIfNeeded() async {
        guard supportsServerBackedFeatures, currentChat.type == .direct else { return }
        guard currentChat.guestRequest != nil || appState.currentUser.isGuest else { return }

        guard let refreshedChat = try? await environment.chatRepository
            .fetchChats(mode: currentChat.mode, for: appState.currentUser.id)
            .first(where: { $0.id == currentChat.id })
        else {
            return
        }

        currentChat = refreshedChat
    }

    @MainActor
    private func scheduleDraftPersistence() {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard Task.isCancelled == false else { return }
            await persistDraftImmediately()
        }
    }

    @MainActor
    private func persistDraftImmediately() async {
        guard viewModel.editingMessage == nil else { return }

        let trimmedText = viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDraft: Draft?
        if trimmedText.isEmpty {
            nextDraft = nil
            await environment.localStore.removeDraft(chatID: currentChat.id, mode: currentChat.mode)
        } else {
            let draft = Draft(
                id: currentChat.draft?.id ?? UUID(),
                chatID: currentChat.id,
                mode: currentChat.mode,
                text: viewModel.draftText,
                updatedAt: .now
            )
            nextDraft = draft
            await environment.localStore.saveDraft(draft)
        }

        currentChat.draft = nextDraft
        await ChatSnapshotStore.shared.updateDraft(
            nextDraft,
            chatID: currentChat.id,
            userID: appState.currentUser.id,
            mode: currentChat.mode
        )
        NotificationCenter.default.post(name: .primeMessagingDraftsChanged, object: nil)
    }

    @MainActor
    private func persistReadingAnchorImmediately() async {
        let anchorMessageID = isNearBottom ? nil : (topVisibleMessageID ?? visibleMessages.first?.id)
        await ChatNavigationStateStore.shared.saveReadingAnchorMessageID(
            anchorMessageID,
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id,
            mode: currentChat.mode
        )
    }

    @MainActor
    private func refreshPresenceIfNeeded() async {
        guard supportsServerBackedFeatures, currentChat.type == .direct else {
            currentPresence = nil
            return
        }

        if currentChat.mode == .smart, NetworkUsagePolicy.canUseChatSyncNetwork() == false {
            currentPresence = nil
            return
        }

        guard let otherUserID = currentChat.participantIDs.first(where: { $0 != appState.currentUser.id }) else {
            currentPresence = nil
            return
        }

        do {
            currentPresence = try await environment.presenceRepository.fetchPresence(for: otherUserID)
        } catch {
            if currentPresence?.userID != otherUserID {
                currentPresence = nil
            }
        }
    }

    @MainActor
    private func refreshSmartTransportState(forceStartScanning: Bool) async {
        guard isSmartDirectChat else {
            smartTransportState = .unknown
            smartDeliveryConfidence = .waiting
            smartPreferredOfflinePath = nil
            smartShouldPreferOnline = false
            return
        }

        guard let otherUserID = currentChat.participantIDs.first(where: { $0 != appState.currentUser.id }) else {
            smartTransportState = .unknown
            smartDeliveryConfidence = .waiting
            smartPreferredOfflinePath = nil
            smartShouldPreferOnline = false
            return
        }

        await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        if forceStartScanning || appState.selectedMode == .smart {
            await environment.offlineTransport.startScanning()
        }

        let discoveredPeers = await environment.offlineTransport.discoveredPeers()
        let directPeer = discoveredPeers.first(where: { $0.id == otherUserID })
        var availablePaths = directPeer?.availablePaths ?? []
        if discoveredPeers.contains(where: { $0.id != otherUserID && $0.relayCapable }) {
            availablePaths.append(.meshRelay)
        }
        availablePaths = Array(Set(availablePaths)).sorted { $0.priority < $1.priority }

        let networkAllowed = NetworkUsagePolicy.canUseChatSyncNetwork()
        smartPreferredOfflinePath = await SmartDeliveryPolicyStore.shared.preferredOfflinePath(
            for: otherUserID,
            availablePaths: availablePaths
        )
        smartShouldPreferOnline = await SmartDeliveryPolicyStore.shared.shouldPreferOnline(
            for: otherUserID,
            availablePaths: availablePaths,
            networkAllowed: networkAllowed
        )
        smartDeliveryConfidence = await SmartDeliveryPolicyStore.shared.deliveryConfidence(
            for: otherUserID,
            availablePaths: availablePaths,
            networkAllowed: networkAllowed
        )

        let hasDirectNearbyPath = directPeer?.availablePaths.contains(where: { $0 == .bluetooth || $0 == .localNetwork }) == true
        let hasRelayPath = availablePaths.contains(.meshRelay)

        if hasDirectNearbyPath, smartShouldPreferOnline == false {
            smartTransportState = .nearby
        } else if hasRelayPath, (smartShouldPreferOnline == false || networkAllowed == false) {
            smartTransportState = .relay
        } else if networkAllowed {
            smartTransportState = .online
        } else if hasRelayPath {
            smartTransportState = .relay
        } else {
            smartTransportState = .waiting
        }
    }

    @MainActor
    private func openContactProfile() async {
        let resolvedChat = await ContactAliasStore.shared.applyAlias(
            to: currentChat,
            currentUserID: appState.currentUser.id,
            messages: viewModel.messages
        )
        currentChat = resolvedChat
        let otherUserID = resolvedChat.participantIDs.first(where: { $0 != appState.currentUser.id })
        let fallbackParticipant = resolvedChat.directParticipant(for: appState.currentUser.id)
        let participantUsername = fallbackParticipant?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackUsername = participantUsername.isEmpty == false ? participantUsername : subtitleUsername(from: resolvedChat.subtitle)
        let fallbackProfile: User?

        if let otherUserID {
            fallbackProfile = fallbackUser(
                userID: otherUserID,
                displayName: resolvedChat.displayTitle(for: appState.currentUser.id),
                username: fallbackUsername
            )
        } else if let fallbackParticipant {
            fallbackProfile = fallbackUser(from: fallbackParticipant)
        } else {
            let displayName = resolvedChat.displayTitle(for: appState.currentUser.id)
            fallbackProfile = displayName.caseInsensitiveCompare("Missing User") == .orderedSame
                ? nil
                : fallbackUser(userID: UUID(), displayName: displayName, username: fallbackUsername)
        }

        contactProfile = fallbackProfile
        if fallbackProfile != nil {
            isShowingContactProfile = true
        }

        guard let otherUserID else { return }

        do {
            let remoteProfile = try await environment.authRepository.userProfile(userID: otherUserID)
            guard isShowingContactProfile, contactProfile?.id == otherUserID else { return }
            contactProfile = remoteProfile
        } catch { }
    }

    private func fallbackUser(from participant: ChatParticipant) -> User {
        fallbackUser(
            userID: participant.id,
            displayName: participant.displayName?.isEmpty == false ? (participant.displayName ?? participant.username) : participant.username,
            username: participant.username
        )
    }

    private func fallbackUser(userID: UUID, displayName: String, username: String?) -> User {
        let resolvedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (username ?? "primecontact")
            : normalizedUsername(from: displayName)

        return User(
            id: userID,
            profile: Profile(
                displayName: displayName,
                username: resolvedUsername,
                bio: "",
                status: "Last seen recently",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: nil,
                socialLink: nil
            ),
            identityMethods: [
                IdentityMethod(type: .username, value: "@\(resolvedUsername)", isVerified: true, isPubliclyDiscoverable: true)
            ],
            privacySettings: .defaultEmailOnly
        )
    }

    private func subtitleUsername(from subtitle: String) -> String? {
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSubtitle.hasPrefix("@") else { return nil }
        let username = String(trimmedSubtitle.dropFirst())
        return username.isEmpty ? nil : username
    }

    private func normalizedUsername(from value: String) -> String {
        let candidate = value
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return candidate.isEmpty ? "primecontact" : String(candidate.prefix(13))
    }

    private var headerStatusText: String {
        if currentChat.type == .selfChat {
            return ""
        }

        if currentChat.type == .group {
            if let selectedCommentPost {
                let count = commentCount(for: selectedCommentPost)
                return count == 1 ? "Comments thread · 1 reply" : "Comments thread · \(count) replies"
            }
            if let selectedCommunityTopic {
                return "Topic · \(selectedCommunityTopic.title)"
            }
            let memberCount = currentChat.group?.members.count ?? max(currentChat.participantIDs.count, 1)
            if currentChat.communityDetails?.kind == .channel {
                var fragments = [memberCount == 1 ? "1 subscriber" : "\(memberCount) subscribers"]
                if currentChat.communityDetails?.isPublic == true {
                    fragments.append("Public")
                }
                if currentChat.communityDetails?.commentsEnabled == true {
                    fragments.append("Comments")
                }
                return fragments.joined(separator: " · ")
            }
            if let communityStatus = currentChat.communityStatusText() {
                return communityStatus
            }
            return memberCount == 1 ? "1 member" : "\(memberCount) members"
        }

        if isSmartDirectChat {
            switch smartTransportState {
            case .nearby:
                let routeTitle = smartPreferredOfflinePath == .localNetwork ? "Nearby" : "Bluetooth"
                switch smartDeliveryConfidence {
                case .high:
                    return "\(routeTitle) · High confidence"
                case .medium:
                    return "\(routeTitle) · Ready"
                case .low:
                    return "\(routeTitle) · Unstable"
                case .waiting:
                    return routeTitle
                }
            case .relay:
                return smartQueuedMessageCount > 0 ? "Relay · \(smartQueuedMessageCount) queued" : "Relay route"
            case .online:
                return smartShouldPreferOnline ? "Online fallback" : (currentPresence == nil ? "Online" : formattedPresenceText)
            case .waiting, .unknown:
                return smartQueuedMessageCount > 0 ? "\(smartQueuedMessageCount) queued locally" : "mode.smart".localized
            }
        }

        if supportsServerBackedFeatures, currentChat.type == .direct {
            return formattedPresenceText
        }

        if currentChat.mode == .smart {
            return "mode.smart".localized
        }

        return currentChat.mode == .online ? "presence.online".localized : "Nearby"
    }

    private var formattedPresenceText: String {
        guard let currentPresence else {
            return "presence.recently".localized
        }

        switch currentPresence.state {
        case .online:
            return "presence.online".localized
        case .recently:
            return "presence.recently".localized
        case .lastSeen, .offline:
            guard let lastSeenAt = currentPresence.lastSeenAt else {
                return "presence.recently".localized
            }
            let formattedDate = lastSeenAt.formatted(date: .abbreviated, time: .shortened)
            return String(format: "presence.last_seen".localized, formattedDate)
        }
    }

    private func updateKeyboardHeight(from notification: Notification) {
        #if os(tvOS)
        keyboardHeight = 0
        return
        #else
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        let overlap = max(UIScreen.main.bounds.height - frame.minY, 0)
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.22

        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = overlap
        }
        #endif
    }
}

struct OfflineSessionBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(PrimeTheme.Colors.accent)
            Text("offline.banner".localized)
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.elevated.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(PrimeTheme.Spacing.medium)
        .chatGlassCard(cornerRadius: PrimeTheme.Radius.card)
    }
}

private struct ChatMessageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ChatMessageMenuFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ChatBottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ChatTopOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatBottomOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatFloatingDayChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PrimeTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.glassTint)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
    }
}

private struct ChatPinnedMessageBanner: View {
    let message: Message
    let previewText: String
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            Button(action: onTap) {
                HStack(spacing: PrimeTheme.Spacing.small) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pinned message")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        Text(previewText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.background.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .chatGlassCard(cornerRadius: PrimeTheme.Radius.card)
    }
}

private struct ChatDayDivider: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(PrimeTheme.Colors.elevated)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(PrimeTheme.Colors.separator.opacity(0.18), lineWidth: 1)
                )
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct ChatForwardSheet: View {
    let currentUserID: UUID
    let sourceChatID: UUID
    let currentMode: ChatMode
    let message: Message
    let onSelectChat: (Chat) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var environment
    @State private var onlineChats: [Chat] = []
    @State private var offlineChats: [Chat] = []
    @State private var query = ""
    @State private var statusMessage = ""

    var body: some View {
        List {
            Section {
                TextField("Search chats", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            if filteredOnlineChats.isEmpty == false {
                Section("Online") {
                    ForEach(filteredOnlineChats) { chat in
                        forwardRow(for: chat)
                    }
                }
            }

            if filteredOfflineChats.isEmpty == false {
                Section("Offline") {
                    ForEach(filteredOfflineChats) { chat in
                        forwardRow(for: chat)
                    }
                }
            }

            if filteredOnlineChats.isEmpty && filteredOfflineChats.isEmpty && statusMessage.isEmpty == false {
                Section {
                    Text("No chats available.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("Forward")
        .task {
            await loadChats()
        }
    }

    private var filteredOnlineChats: [Chat] {
        filter(onlineChats)
    }

    private var filteredOfflineChats: [Chat] {
        filter(offlineChats)
    }

    @ViewBuilder
    private func forwardRow(for chat: Chat) -> some View {
        Button {
            onSelectChat(chat)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.displayTitle(for: currentUserID))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text(forwardSubtitle(for: chat))
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadChats() async {
        do {
            async let fetchedOnlineChats = environment.chatRepository.fetchChats(mode: .online, for: currentUserID)
            async let fetchedOfflineChats = environment.chatRepository.fetchChats(mode: .offline, for: currentUserID)

            onlineChats = try await fetchedOnlineChats
            offlineChats = try await fetchedOfflineChats
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not load chats." : error.localizedDescription
        }
    }

    private func filter(_ chats: [Chat]) -> [Chat] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return chats
            .filter { chat in
                if chat.id == sourceChatID && chat.mode == currentMode {
                    return false
                }

                guard normalizedQuery.isEmpty == false else { return true }
                return chat.displayTitle(for: currentUserID).localizedCaseInsensitiveContains(normalizedQuery)
                    || forwardSubtitle(for: chat).localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
    }

    private func forwardSubtitle(for chat: Chat) -> String {
        if chat.type == .selfChat {
            return "@saved"
        }

        if chat.type == .direct,
           let participant = chat.directParticipant(for: currentUserID) {
            return "@\(resolvedForwardHandle(for: participant, titleFallback: chat.displayTitle(for: currentUserID)))"
        }

        if chat.type == .group {
            let count = chat.group?.members.count ?? max(chat.participantIDs.count, 1)
            if chat.communityDetails?.kind == .channel {
                return count == 1 ? "1 subscriber" : "\(count) subscribers"
            }
            return "\(count) members"
        }

        return "@\(normalizedForwardHandle(from: chat.displayTitle(for: currentUserID), fallback: "primeuser"))"
    }

    private func resolvedForwardHandle(for participant: ChatParticipant, titleFallback: String) -> String {
        let trimmedUsername = participant.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUsername.isEmpty == false {
            return trimmedUsername
        }

        let trimmedDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedDisplayName.isEmpty == false {
            return normalizedForwardHandle(from: trimmedDisplayName, fallback: "primeuser")
        }

        return normalizedForwardHandle(from: titleFallback, fallback: "primeuser")
    }

    private func normalizedForwardHandle(from value: String, fallback: String) -> String {
        let normalized = value
            .lowercased()
            .map { character -> Character? in
                if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                    return character
                }
                if character == " " || character == "-" {
                    return "_"
                }
                return nil
            }
            .compactMap { $0 }

        let handle = String(normalized.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return handle.isEmpty ? fallback : handle
    }
}

private struct ChatMessageSearchSheet: View {
    let title: String
    let messages: [Message]
    let currentUserID: UUID
    let chatID: UUID
    let mode: ChatMode
    let onSelect: (UUID) -> Void

    @State private var query = ""
    @State private var recentSearches: [String] = []

    var body: some View {
        List {
            Section {
                TextField("Search messages", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            await persistQueryIfNeeded()
                        }
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
            } else if filteredMessages.isEmpty {
                Section {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Start typing to search this chat." : "No matching messages.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section {
                    ForEach(filteredMessages) { message in
                        Button {
                            Task {
                                await persistQueryIfNeeded()
                            }
                            onSelect(message.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(searchPreview(for: message))
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)

                                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(title)
        .task(id: "\(currentUserID.uuidString)-\(chatID.uuidString)-\(mode.rawValue)") {
            recentSearches = await ChatNavigationStateStore.shared.recentMessageSearches(
                ownerUserID: currentUserID,
                chatID: chatID,
                mode: mode
            )
        }
    }

    private var filteredMessages: [Message] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return [] }

        return messages
            .filter { message in
                searchPreview(for: message).localizedCaseInsensitiveContains(trimmedQuery)
            }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }

    private func searchPreview(for message: Message) -> String {
        if let structuredContent = StructuredChatMessageContent.parse(message.text) {
            return structuredContent.previewText
        }

        if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false {
            return text
        }

        if message.voiceMessage != nil {
            return "Voice message"
        }

        if let attachment = message.attachments.first {
            return attachment.fileName
        }

        return "Message"
    }

    private func persistQueryIfNeeded() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }
        await ChatNavigationStateStore.shared.saveMessageSearch(
            trimmedQuery,
            ownerUserID: currentUserID,
            chatID: chatID,
            mode: mode
        )
        recentSearches = await ChatNavigationStateStore.shared.recentMessageSearches(
            ownerUserID: currentUserID,
            chatID: chatID,
            mode: mode
        )
    }
}

private struct MessageActionMenuOverlay: View {
    let chat: Chat
    let message: Message
    let replyMessage: Message?
    let currentUserID: UUID
    let showsIncomingSenderName: Bool
    let showsTail: Bool
    let frame: CGRect
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let isOutgoing: Bool
    let isPinned: Bool
    let canEdit: Bool
    let canDelete: Bool
    let showsUndoAction: Bool
    let canReport: Bool
    let showsCommentsButton: Bool
    let commentCount: Int
    let onDismiss: () -> Void
    let onOpenExpandedPicker: () -> Void
    let onSelectReaction: (String) -> Void
    let onEdit: () -> Void
    let onReply: () -> Void
    let onForward: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onReport: () -> Void
    let onUndo: () -> Void
    let onDelete: () -> Void

    @State private var hasAnimatedIn = false

    private let primaryReactions = ["❤️", "👎", "👍", "🔥", "🥰", "👏", "😁", "😮", "😢", "🙏"]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(
                    Color.black.opacity(hasAnimatedIn ? 0.38 : 0)
                        .ignoresSafeArea()
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissAnimated)

            centeredPreviewBubble
                .frame(width: previewBubbleWidth)
                .position(x: animatedMessageCenter.x, y: animatedMessageCenter.y)
                .scaleEffect(hasAnimatedIn ? 1 : 0.98, anchor: .center)
                .opacity(hasAnimatedIn ? 1 : 0.86)
                .allowsHitTesting(false)
                .zIndex(2)

            reactionBar(primaryReactions)
                .frame(width: reactionBarWidth)
                .position(x: targetMessageCenterX, y: reactionBarCenterY)
                .offset(y: hasAnimatedIn ? 0 : 18)
                .opacity(hasAnimatedIn ? 1 : 0)
                .zIndex(3)

            actionCard(items: primaryActionItems)
                .frame(width: actionCardWidth)
                .position(x: targetMessageCenterX, y: actionCardCenterY)
                .offset(y: hasAnimatedIn ? 0 : 20)
                .opacity(hasAnimatedIn ? 1 : 0)
                .zIndex(3)
        }
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    hasAnimatedIn = true
                }
            }
        }
    }

    private func reactionBar(_ emojis: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onSelectReaction(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onOpenExpandedPicker) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.12))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: reactionBarHeight)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(menuTint)
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(menuStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
    }

    private func actionCard(items: [MessageActionMenuRowItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    item.action()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: item.systemName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(item.tint)

                        Text(item.title)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(item.textTint)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: actionRowHeight)
                }
                .buttonStyle(.plain)

                if index != items.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.06))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(menuTint)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(menuStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 18, y: 10)
    }

    private var centeredPreviewBubble: some View {
        MessageBubbleView(
            chat: chat,
            message: message,
            replyMessage: replyMessage,
            rowWidth: previewBubbleWidth,
            currentUserID: currentUserID,
            showsIncomingSenderName: showsIncomingSenderName,
            showsIncomingAvatar: false,
            showsTail: showsTail,
            isActionMenuPresented: false,
            isPressingActionMenu: false,
            isPinned: isPinned,
            isOutgoing: isOutgoing,
            canEdit: canEdit,
            canDelete: canDelete,
            showsCommentsButton: showsCommentsButton,
            commentCount: commentCount,
            onEdit: {},
            onReply: {},
            onOpenReplyTarget: {},
            onCopy: {},
            onOpenActionMenu: {},
            onActionMenuPressingChanged: { _ in },
            onToggleReaction: { _ in },
            onOpenComments: {},
            onPin: {},
            onForward: {},
            onRequestDeleteOptions: {},
            onDelete: {},
            isFloatingPreview: true
        )
        .frame(width: previewBubbleWidth)
        .shadow(color: Color.black.opacity(0.24), radius: 28, y: 16)
    }

    private var primaryActionItems: [MessageActionMenuRowItem] {
        var items: [MessageActionMenuRowItem] = []

        if message.isDeleted == false {
            items.append(
                MessageActionMenuRowItem(title: "Reply", systemName: "arrowshape.turn.up.left", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onReply)
            )
        }

        items.append(
            MessageActionMenuRowItem(title: "Copy", systemName: "doc.on.doc", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onCopy)
        )

        items.append(
            MessageActionMenuRowItem(title: isPinned ? "Unpin" : "Pin", systemName: isPinned ? "pin.slash" : "pin", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onPin)
        )

        if message.isDeleted == false {
            items.append(
                MessageActionMenuRowItem(title: "Forward", systemName: "arrowshape.turn.up.right", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onForward)
            )
        }

        if canEdit {
            items.append(
                MessageActionMenuRowItem(title: "Edit", systemName: "pencil", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onEdit)
            )
        }

        if canReport {
            items.append(
                MessageActionMenuRowItem(title: "Report", systemName: "exclamationmark.bubble", tint: PrimeTheme.Colors.warning, textTint: PrimeTheme.Colors.warning, action: onReport)
            )
        }

        if showsUndoAction {
            items.append(
                MessageActionMenuRowItem(title: "Undo", systemName: "arrow.uturn.backward", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onUndo)
            )
        } else if canDelete || message.isDeleted == false {
            items.append(
                MessageActionMenuRowItem(title: "Delete", systemName: "trash", tint: Color(red: 1, green: 0.45, blue: 0.53), textTint: Color(red: 1, green: 0.45, blue: 0.53), action: onDelete)
            )
        }

        return items
    }

    private var menuTint: Color {
        Color.black.opacity(0.56)
    }

    private var menuStroke: Color {
        Color.white.opacity(0.08)
    }

    private var actionRowHeight: CGFloat {
        56
    }

    private var reactionBarHeight: CGFloat {
        64
    }

    private var actionCardHeight: CGFloat {
        CGFloat(primaryActionItems.count) * actionRowHeight
    }

    private var previewBubbleWidth: CGFloat {
        min(max(frame.width, 96), containerSize.width - 28)
    }

    private var previewBubbleHeight: CGFloat {
        frame.height
    }

    private var reactionBarWidth: CGFloat {
        min(containerSize.width - 28, max(228, previewBubbleWidth + 28))
    }

    private var actionCardWidth: CGFloat {
        min(containerSize.width - 44, 300)
    }

    private var targetMessageCenterX: CGFloat {
        containerSize.width / 2
    }

    private var sourceMessageCenter: CGPoint {
        CGPoint(
            x: min(max(frame.midX, previewBubbleWidth / 2 + 14), containerSize.width - previewBubbleWidth / 2 - 14),
            y: frame.midY
        )
    }

    private var targetMessageCenterY: CGFloat {
        let desired = containerSize.height / 2
        let minimum = safeAreaInsets.top + 18 + reactionBarHeight + stackSpacing + previewBubbleHeight / 2
        let maximum = containerSize.height - safeAreaInsets.bottom - 18 - actionCardHeight - stackSpacing - previewBubbleHeight / 2
        let resolvedMaximum = max(maximum, minimum)
        return min(max(desired, minimum), resolvedMaximum)
    }

    private var animatedMessageCenter: CGPoint {
        CGPoint(
            x: hasAnimatedIn ? targetMessageCenterX : sourceMessageCenter.x,
            y: hasAnimatedIn ? targetMessageCenterY : sourceMessageCenter.y
        )
    }

    private var reactionBarCenterY: CGFloat {
        targetMessageCenterY - previewBubbleHeight / 2 - stackSpacing - reactionBarHeight / 2
    }

    private var actionCardCenterY: CGFloat {
        targetMessageCenterY + previewBubbleHeight / 2 + stackSpacing + actionCardHeight / 2
    }

    private var stackSpacing: CGFloat {
        16
    }

    private func dismissAnimated() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            hasAnimatedIn = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onDismiss)
    }
}

private struct MessageActionMenuRowItem: Identifiable {
    let id = UUID()
    let title: String
    let systemName: String
    let tint: Color
    let textTint: Color
    let action: () -> Void
}

private struct AttachmentOpenTransitionOverlay: View {
    let attachment: Attachment
    let sourceFrame: CGRect
    let containerSize: CGSize

    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.22 * progress)
                .ignoresSafeArea()

            AttachmentTransitionPreviewCard(attachment: attachment)
                .frame(width: interpolatedRect.width, height: interpolatedRect.height)
                .position(x: interpolatedRect.midX, y: interpolatedRect.midY)
                .clipShape(RoundedRectangle(cornerRadius: 26 * (1 - progress), style: .continuous))
                .shadow(color: Color.black.opacity(0.18 * progress), radius: 24, y: 12)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                progress = 1
            }
        }
    }

    private var targetRect: CGRect {
        CGRect(origin: .zero, size: containerSize)
    }

    private var clampedSourceRect: CGRect {
        guard sourceFrame.equalTo(.zero) == false else {
            return CGRect(x: containerSize.width * 0.25, y: containerSize.height * 0.35, width: containerSize.width * 0.5, height: containerSize.height * 0.3)
        }
        return sourceFrame
    }

    private var interpolatedRect: CGRect {
        lerp(from: clampedSourceRect, to: targetRect, progress: progress)
    }

    private func lerp(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * progress,
            y: from.origin.y + (to.origin.y - from.origin.y) * progress,
            width: from.size.width + (to.size.width - from.size.width) * progress,
            height: from.size.height + (to.size.height - from.size.height) * progress
        )
    }
}

private struct AttachmentCloseTransitionOverlay: View {
    let attachment: Attachment
    let targetFrame: CGRect
    let containerSize: CGSize
    let onComplete: () -> Void

    @State private var progress: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.22 * progress)
                .ignoresSafeArea()

            AttachmentTransitionPreviewCard(attachment: attachment)
                .frame(width: interpolatedRect.width, height: interpolatedRect.height)
                .position(x: interpolatedRect.midX, y: interpolatedRect.midY)
                .clipShape(RoundedRectangle(cornerRadius: 26 * (1 - progress), style: .continuous))
                .shadow(color: Color.black.opacity(0.18 * progress), radius: 24, y: 12)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                progress = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(230))
                onComplete()
            }
        }
    }

    private var startRect: CGRect {
        CGRect(origin: .zero, size: containerSize)
    }

    private var resolvedTargetRect: CGRect {
        guard targetFrame.equalTo(.zero) == false else {
            return CGRect(x: containerSize.width * 0.25, y: containerSize.height * 0.35, width: containerSize.width * 0.5, height: containerSize.height * 0.3)
        }
        return targetFrame
    }

    private var interpolatedRect: CGRect {
        CGRect(
            x: resolvedTargetRect.origin.x + (startRect.origin.x - resolvedTargetRect.origin.x) * progress,
            y: resolvedTargetRect.origin.y + (startRect.origin.y - resolvedTargetRect.origin.y) * progress,
            width: resolvedTargetRect.size.width + (startRect.size.width - resolvedTargetRect.size.width) * progress,
            height: resolvedTargetRect.size.height + (startRect.size.height - resolvedTargetRect.size.height) * progress
        )
    }
}

private struct AttachmentTransitionPreviewCard: View {
    let attachment: Attachment

    var body: some View {
        ZStack {
            switch attachment.type {
            case .photo:
                if let localURL = attachment.localURL,
                   let uiImage = UIImage(contentsOfFile: localURL.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                } else if let remoteURL = attachment.remoteURL {
                    CachedRemoteImage(url: remoteURL) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        transitionPlaceholder
                    }
                } else {
                    transitionPlaceholder
                }
            case .video:
                ZStack {
                    transitionPlaceholder
                    Image(systemName: "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            default:
                transitionPlaceholder
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var transitionPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: attachment.type == .video ? "video.fill" : "photo.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
        }
    }
}

private struct EmojiReactionPickerSheet: View {
    private struct SectionModel: Identifiable {
        let id = UUID()
        let title: String
        let emojis: [String]
    }

    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(minimum: 42, maximum: 52), spacing: 10), count: 6)
    private let sections: [SectionModel] = [
        SectionModel(title: "Popular", emojis: ["👍", "❤️", "😂", "🔥", "🙏", "😮", "😢", "👎", "👏", "😍", "🤝", "💯"]),
        SectionModel(title: "Faces", emojis: ["😀", "😁", "😅", "🤣", "😊", "🙂", "😉", "😎", "🤩", "🥹", "😴", "🤯", "🥳", "😇", "😡", "🤔", "🫡", "🥲"]),
        SectionModel(title: "Love", emojis: ["❤️", "💛", "💚", "🩵", "💙", "💜", "🤍", "🖤", "🤎", "💔", "❤️‍🔥", "💘", "💝", "💞", "💕", "💓"]),
        SectionModel(title: "Gestures", emojis: ["👍", "👎", "👌", "✌️", "🤞", "🤟", "🤝", "👏", "🙌", "🙏", "💪", "👋", "🫶", "✍️", "☝️", "👀"]),
        SectionModel(title: "Objects", emojis: ["🔥", "⭐️", "✨", "⚡️", "💯", "🎉", "🎯", "🚀", "📌", "🎵", "📷", "🎬", "🧠", "💎", "🕊️", "🏆"]),
        SectionModel(title: "Nature", emojis: ["🌹", "🌸", "🌼", "🌿", "🍀", "🌍", "🌙", "☀️", "🌈", "🌊", "❄️", "☁️"])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                sectionsBody
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(PrimeTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Add Reaction")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sectionsBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections) { section in
                sectionView(section)
            }
        }
    }

    private func sectionView(_ section: SectionModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(section.emojis, id: \.self) { emoji in
                    emojiButton(emoji)
                }
            }
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button {
            dismiss()
            onSelect(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(PrimeTheme.Colors.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.65), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct MessageBubbleView: View {
    let chat: Chat
    let message: Message
    let replyMessage: Message?
    let rowWidth: CGFloat
    let currentUserID: UUID
    let showsIncomingSenderName: Bool
    let showsIncomingAvatar: Bool
    let showsTail: Bool
    let isActionMenuPresented: Bool
    let isPressingActionMenu: Bool
    let isPinned: Bool
    let isOutgoing: Bool
    let canEdit: Bool
    let canDelete: Bool
    let showsCommentsButton: Bool
    let commentCount: Int
    let onEdit: () -> Void
    let onReply: () -> Void
    let onOpenReplyTarget: () -> Void
    let onCopy: () -> Void
    let onOpenActionMenu: () -> Void
    let onActionMenuPressingChanged: (Bool) -> Void
    let onToggleReaction: (String) -> Void
    let onOpenComments: () -> Void
    let onPin: () -> Void
    let onForward: () -> Void
    let onRequestDeleteOptions: () -> Void
    let onDelete: () -> Void
    let isFloatingPreview: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var swipeOffset: CGFloat = 0
    @State private var bubbleWidth: CGFloat = 0
    @State private var isTrackingReplySwipe = false

    private enum BubbleBodyStyle {
        case standard
        case attachmentOnly
        case voiceOnly
    }

    var body: some View {
        rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
        MessageBubbleRowLayout(
            isOutgoing: isOutgoing,
            rowWidth: effectiveRowWidth,
            contentMaxWidth: rowContentMaxWidth
        ) {
            rowBubbleContent
        }
        .padding(.leading, isOutgoing ? rowOppositeSideInset : 0)
        .padding(.trailing, isOutgoing ? 0 : rowOppositeSideInset)
        .frame(width: rowWidth, alignment: .leading)
    }

    @ViewBuilder
    private var rowBubbleContent: some View {
        if isOutgoing || usesIncomingAvatarColumn == false {
            bubbleBody
        } else {
            HStack(alignment: .bottom, spacing: incomingAvatarSpacing) {
                incomingAvatarSlot
                bubbleBody
            }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        switch bubbleBodyStyle {
        case .standard:
            bubbleShell {
                standardBubble
            }
        case .attachmentOnly:
            bubbleShell {
                attachmentBubble
            }
        case .voiceOnly:
            bubbleShell {
                voiceBubble
            }
        }
    }

    @ViewBuilder
    private func bubbleShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shell = content()
            .frame(minWidth: bubbleMinimumFrameWidth, alignment: .leading)
            .offset(x: swipeOffset)
            .opacity(isActionMenuPresented && isFloatingPreview == false ? 0 : 1)
            .scaleEffect(isActionMenuPresented ? 0.948 : (isPressingActionMenu ? 0.972 : 1), anchor: isOutgoing ? .trailing : .leading)
            .offset(y: isActionMenuPresented ? -8 : (isPressingActionMenu ? -3 : 0))
            .brightness(isActionMenuPresented ? -0.02 : 0)
            .saturation(isActionMenuPresented ? 0.96 : 1)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            bubbleWidth = geometry.size.width
                        }
                        .onChange(of: geometry.size.width) { newValue in
                            bubbleWidth = newValue
                        }
                        .preference(
                            key: ChatMessageMenuFramePreferenceKey.self,
                            value: isFloatingPreview ? [:] : [message.id: geometry.frame(in: .named("chat-root"))]
                        )
                }
            )
            .overlay(alignment: isOutgoing ? .leading : .trailing) {
                if isFloatingPreview == false {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(replyAccentColor.opacity(Double(replyIndicatorOpacity)))
                        .padding(isOutgoing ? .leading : .trailing, 10)
                }
            }
            .shadow(
                color: isOutgoing ? Color.clear : Color.black.opacity(0.06),
                radius: 10,
                y: 4
            )
            .contentShape(Rectangle())
            .animation(.spring(response: 0.26, dampingFraction: 0.84), value: isActionMenuPresented)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isPressingActionMenu)

        if isFloatingPreview {
            shell
        } else {
            #if os(tvOS)
            shell
                .simultaneousGesture(replySwipeGesture)
            #else
            shell
                .simultaneousGesture(replySwipeGesture)
                .onLongPressGesture(
                    minimumDuration: 0.34,
                    maximumDistance: 12,
                    perform: {
                        guard isTrackingReplySwipe == false else { return }
                        onOpenActionMenu()
                    },
                    onPressingChanged: { isPressing in
                        if isTrackingReplySwipe {
                            onActionMenuPressingChanged(false)
                        } else {
                            onActionMenuPressingChanged(isPressing)
                        }
                    }
                )
            #endif
        }
    }

    private var replySwipeGesture: some Gesture {
        #if os(tvOS)
        TapGesture()
        #else
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if isTrackingReplySwipe == false {
                    guard shouldBeginReplySwipe(translation: value.translation) else { return }
                    isTrackingReplySwipe = true
                    onActionMenuPressingChanged(false)
                }

                if isOutgoing {
                    guard value.translation.width < 0 else { return }
                    swipeOffset = max(value.translation.width * 0.26, -26)
                } else {
                    guard value.translation.width > 0 else { return }
                    swipeOffset = min(value.translation.width * 0.26, 26)
                }
            }
            .onEnded { value in
                defer {
                    isTrackingReplySwipe = false
                    onActionMenuPressingChanged(false)
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        swipeOffset = 0
                    }
                }

                guard isTrackingReplySwipe else { return }
                if isOutgoing {
                    guard value.translation.width < -42 else { return }
                } else {
                    guard value.translation.width > 42 else { return }
                }
                onReply()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        #endif
    }

    private var standardBubble: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            senderNameInsideBubble
            replyPreviewView
            deliveryOptionBadges

            if message.isDeleted {
                Text("Message deleted")
                    .font(.system(size: 13.5, weight: .regular))
                    .italic()
                    .foregroundStyle(secondaryBubbleTextColor)
            } else if let structuredContent {
                StructuredMessageCard(
                    messageID: message.id,
                    content: structuredContent,
                    usesLightForeground: usesLightBubbleForeground
                )
            } else if let messageText {
                if usesInlineMetadata {
                    inlineTextMessageBody(messageText)
                } else {
                    Text(messageText)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(primaryBubbleTextColor)
                        .layoutPriority(1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if message.isDeleted == false && message.attachments.isEmpty == false {
                MessageAttachmentGallery(
                    attachments: message.attachments,
                    alignment: mediaHorizontalAlignment,
                    presentationContext: attachmentPresentationContext,
                    isInteractionEnabled: attachmentInteractionsEnabled
                )
                .frame(maxWidth: .infinity, alignment: mediaFrameAlignment)
            }

            if message.isDeleted == false, let voiceMessage = message.voiceMessage {
                VoiceMessagePlayerView(voiceMessage: voiceMessage, style: .bubble(usesLightForeground: usesLightBubbleForeground))
            }

            if usesInlineMetadata == false {
                messageMetadata
            }

            communityFooterActions

            reactionBadges
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            bubbleSurface(cornerRadius: 24, includeTail: true)
        )
    }

    private var attachmentBubble: some View {
        VStack(alignment: mediaHorizontalAlignment, spacing: 6) {
            senderNameInsideBubble
            replyPreviewView

            attachmentSupplementalBadges

            if message.isDeleted == false && message.attachments.isEmpty == false {
                MessageAttachmentGallery(
                    attachments: message.attachments,
                    alignment: mediaHorizontalAlignment,
                    presentationContext: attachmentPresentationContext,
                    isInteractionEnabled: attachmentInteractionsEnabled
                )
                .frame(maxWidth: .infinity, alignment: mediaFrameAlignment)
            }

            standaloneMetadata

            communityFooterActions

            reactionBadges
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            bubbleSurface(cornerRadius: 22, includeTail: true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var voiceBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            senderNameInsideBubble
            replyPreviewView
            deliveryOptionBadges

            if let voiceMessage = message.voiceMessage {
                VoiceMessagePlayerView(
                    voiceMessage: voiceMessage,
                    style: isOutgoing
                        ? .standaloneOutgoing(deliveryState: message.deliveryState)
                        : .standaloneIncoming,
                    footerTimestampText: message.createdAt.formatted(date: .omitted, time: .shortened),
                    footerShowsEdited: message.editedAt != nil && message.isDeleted == false,
                    footerStatus: isOutgoing ? message.status : nil,
                    footerShowsSyncing: message.deliveryState == .syncing
                )
            }

            communityFooterActions

            reactionBadges
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 5)
        .background(
            bubbleSurface(cornerRadius: 24, includeTail: true)
        )
        .frame(maxWidth: maximumVoiceBubbleWidth, alignment: .leading)
    }

    @ViewBuilder
    private var replyPreviewView: some View {
        if message.isDeleted == false, let replyPreviewText {
            Button(action: onOpenReplyTarget) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(replyPreviewTitle)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(replyAccentColor)

                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(replyAccentColor)
                            .frame(width: 3)

                        Text(replyPreviewText)
                            .font(.caption)
                            .foregroundStyle(secondaryBubbleTextColor)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(replyNestedBubbleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(replyNestedBubbleStroke, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(replyContainerFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(replyContainerStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var messageMetadata: some View {
        metadataContent
            .foregroundStyle(secondaryBubbleTextColor)
    }

    @ViewBuilder
    private var standaloneMetadata: some View {
        if bubbleBodyStyle == .voiceOnly {
            metadataContent
                .foregroundStyle(secondaryBubbleTextColor)
        } else {
            HStack(spacing: 8) {
                if let deliveryRouteBadge {
                    deliveryOptionBadge(title: deliveryRouteBadge.title, systemName: deliveryRouteBadge.systemName)
                }

                Spacer(minLength: 0)

                metadataContent
                    .foregroundStyle(secondaryBubbleTextColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(standaloneMetadataFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(standaloneMetadataStroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var attachmentSupplementalBadges: some View {
        if message.isDeleted == false,
           message.isSilentDelivery || message.scheduledAt != nil || mediaTransferBadge != nil {
            HStack(spacing: 6) {
                if let mediaTransferBadge {
                    deliveryOptionBadge(title: mediaTransferBadge.title, systemName: mediaTransferBadge.systemName)
                }

                if message.isSilentDelivery {
                    deliveryOptionBadge(title: "Silent", systemName: "bell.slash.fill")
                }

                if let scheduledAt = message.scheduledAt {
                    let title = message.status == .localPending && scheduledAt > .now
                        ? "Scheduled \(scheduledAt.formatted(date: .omitted, time: .shortened))"
                        : "Sent later"
                    deliveryOptionBadge(title: title, systemName: "clock.fill")
                }
            }
        }
    }

    private var mediaTransferBadge: (title: String, systemName: String)? {
        guard isOutgoing else { return nil }
        guard message.attachments.isEmpty == false || message.voiceMessage != nil else { return nil }

        switch message.status {
        case .sending:
            return ("Uploading…", "arrow.up.circle.fill")
        case .localPending:
            return ("Queued", "clock.fill")
        case .failed:
            return ("Upload failed", "exclamationmark.triangle.fill")
        case .sent, .delivered, .read:
            return nil
        }
    }

    @ViewBuilder
    private func bubbleSurface(cornerRadius: CGFloat, includeTail: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(bubbleBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(bubbleStroke, lineWidth: 1)
            )
            .overlay(alignment: bubbleTailAlignment) {
                if includeTail && showsTail {
                    ZStack {
                        MessageBubbleTailShape(isOutgoing: isOutgoing)
                            .fill(bubbleBackground)
                        MessageBubbleTailShape(isOutgoing: isOutgoing)
                            .stroke(bubbleStroke, lineWidth: 1)
                    }
                    .frame(width: 15, height: 16)
                    .offset(x: isOutgoing ? 5 : -5, y: 2)
                }
            }
    }

    private var metadataContent: some View {
        HStack(spacing: PrimeTheme.Spacing.xSmall) {
            if message.deliveryState == .syncing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9.5, weight: .medium))
            }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            if message.editedAt != nil && message.isDeleted == false {
                Text("edited")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            if isOutgoing {
                MessageStatusGlyphView(status: message.status)
            }
        }
    }

    @ViewBuilder
    private var reactionBadges: some View {
        if message.isDeleted == false, message.reactions.isEmpty == false {
            HStack(spacing: 8) {
                ForEach(sortedReactions) { reaction in
                    Button {
                        onToggleReaction(reaction.emoji)
                    } label: {
                        HStack(spacing: 5) {
                            Text(reaction.emoji)
                            Text("\(reaction.userIDs.count)")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(reaction.userIDs.contains(currentUserID) ? reactionAccentColor : reactionTextColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(reaction.userIDs.contains(currentUserID) ? reactionHighlightFill : reactionNeutralFill)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(reaction.userIDs.contains(currentUserID) ? reactionAccentColor.opacity(0.28) : reactionNeutralStroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var communityFooterActions: some View {
        if showsCommentsButton {
            Button(action: onOpenComments) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(commentCount == 0 ? "Open comments" : "\(commentCount) comment\(commentCount == 1 ? "" : "s")")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(replyAccentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(replyContainerFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(replyContainerStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var deliveryOptionBadges: some View {
        if message.isDeleted == false, message.deliveryOptions.hasAdvancedBehavior || deliveryRouteBadge != nil || mediaTransferBadge != nil {
            HStack(spacing: 6) {
                if let mediaTransferBadge {
                    deliveryOptionBadge(title: mediaTransferBadge.title, systemName: mediaTransferBadge.systemName)
                }

                if let deliveryRouteBadge {
                    deliveryOptionBadge(title: deliveryRouteBadge.title, systemName: deliveryRouteBadge.systemName)
                }

                if message.isSilentDelivery {
                    deliveryOptionBadge(title: "Silent", systemName: "bell.slash.fill")
                }

                if let scheduledAt = message.scheduledAt {
                    let title = message.status == .localPending && scheduledAt > .now
                        ? "Scheduled \(scheduledAt.formatted(date: .omitted, time: .shortened))"
                        : "Sent later"
                    deliveryOptionBadge(title: title, systemName: "clock.fill")
                }
            }
        }
    }

    private var deliveryRouteBadge: (title: String, systemName: String)? {
        switch message.deliveryRoute {
        case .online:
            return ("Online", "network")
        case .bluetooth:
            return ("Bluetooth", "dot.radiowaves.left.and.right")
        case .localNetwork:
            return ("Nearby", "wifi")
        case .meshRelay:
            return (message.status == .localPending ? "Relay queued" : "Relay", "point.3.filled.connected.trianglepath.dotted")
        case .queued:
            return (message.status == .sending ? "Retrying" : "Queued", "clock.arrow.circlepath")
        case nil:
            return nil
        }
    }

    private func deliveryOptionBadge(title: String, systemName: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func inlineTextMessageBody(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(primaryBubbleTextColor)
            .layoutPriority(1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, inlineMetadataReservedWidth)
            .overlay(alignment: .bottomTrailing) {
                metadataContent
                    .foregroundStyle(secondaryBubbleTextColor)
                    .padding(.leading, 7)
                    .padding(.trailing, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(bubbleBackground.opacity(0.94))
                    )
            }
    }

    private var bubbleBodyStyle: BubbleBodyStyle {
        guard message.isDeleted == false else { return .standard }

        if message.voiceMessage != nil,
           message.attachments.isEmpty,
           messageText == nil,
           structuredContent == nil {
            return .voiceOnly
        }

        if message.voiceMessage == nil,
           message.attachments.isEmpty == false,
           messageText == nil,
           structuredContent == nil {
            return .attachmentOnly
        }

        return .standard
    }

    private var shouldUseAttachmentBubbleSurface: Bool {
        bubbleBodyStyle == .attachmentOnly
    }

    private var usesInlineMetadata: Bool {
        message.isDeleted == false
            && structuredContent == nil
            && messageText != nil
            && message.attachments.isEmpty
            && message.voiceMessage == nil
            && prefersSeparatedMetadata == false
    }

    private var messageText: String? {
        guard structuredContent == nil else { return nil }
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return nil
        }
        return text
    }

    @ViewBuilder
    private var senderNameInsideBubble: some View {
        if usesIncomingSenderMetadata, showsIncomingSenderName, let senderDisplayNameForBubble {
            Text(senderDisplayNameForBubble)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(senderMetadataColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var senderAvatar: some View {
        ZStack {
            Circle()
                .fill(PrimeTheme.Colors.elevated.opacity(0.96))
            Circle()
                .stroke(PrimeTheme.Colors.bubbleIncomingBorder, lineWidth: 1)
            Text(senderAvatarInitials)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .frame(width: incomingAvatarSize, height: incomingAvatarSize)
    }

    @ViewBuilder
    private var incomingAvatarSlot: some View {
        if usesIncomingAvatarColumn == false {
            EmptyView()
        } else if showsIncomingAvatar {
            senderAvatar
        } else {
            Color.clear
                .frame(width: incomingAvatarSize, height: incomingAvatarSize)
        }
    }

    private var rowOppositeSideInset: CGFloat {
        isFloatingPreview ? 0 : 52
    }

    private var effectiveRowWidth: CGFloat {
        max(rowWidth - rowOppositeSideInset, 0)
    }

    private var constrainedBubbleWidth: CGFloat {
        min(maximumBubbleWidth, max(effectiveRowWidth - avatarAllowance, 0))
    }

    private var rowContentMaxWidth: CGFloat {
        min(effectiveRowWidth, constrainedBubbleWidth + avatarAllowance)
    }

    private var maximumBubbleWidth: CGFloat {
        switch bubbleBodyStyle {
        case .standard:
            return maximumTextBubbleWidth
        case .attachmentOnly, .voiceOnly:
            return maximumMediaBubbleWidth
        }
    }

    private var maximumTextBubbleWidth: CGFloat {
        min(effectiveRowWidth, UIScreen.main.bounds.width * (prefersSeparatedMetadata ? 0.88 : 0.82))
    }

    private var bubbleMinimumFrameWidth: CGFloat? {
        switch bubbleBodyStyle {
        case .standard:
            return minimumTextBubbleWidth > 0 ? minimumTextBubbleWidth : nil
        case .attachmentOnly, .voiceOnly:
            return nil
        }
    }

    private var minimumTextBubbleWidth: CGFloat {
        guard bubbleBodyStyle == .standard, let messageText else { return 0 }
        guard messageText.contains(" ") else { return 0 }
        guard prefersSeparatedMetadata else { return 0 }

        let wordCount = messageText.split(whereSeparator: \.isWhitespace).count
        switch wordCount {
        case 0...2:
            return 0
        case 3...4:
            return min(maximumTextBubbleWidth, 170)
        case 5...6:
            return min(maximumTextBubbleWidth, 210)
        default:
            return min(maximumTextBubbleWidth, 246)
        }
    }

    private var maximumMediaBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.8, 308)
    }

    private var maximumVoiceBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.68, 262)
    }

    private var incomingAvatarSize: CGFloat {
        34
    }

    private var incomingAvatarSpacing: CGFloat {
        8
    }

    private var avatarAllowance: CGFloat {
        usesIncomingAvatarColumn ? incomingAvatarSize + incomingAvatarSpacing : 0
    }

    private var inlineMetadataReservedWidth: CGFloat {
        if isOutgoing {
            let baseWidth = message.editedAt != nil && message.isDeleted == false ? 118.0 : 82.0
            return message.deliveryState == .syncing ? baseWidth + 14 : baseWidth
        }
        let baseWidth = message.editedAt != nil && message.isDeleted == false ? 94.0 : 64.0
        return message.deliveryState == .syncing ? baseWidth + 14 : baseWidth
    }

    private var prefersSeparatedMetadata: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var bubbleBackground: Color {
        if bubbleBodyStyle == .voiceOnly {
            if isOutgoing {
                switch message.deliveryState {
                case .offline:
                    return PrimeTheme.Colors.bubbleSmartOffline
                case .online:
                    return PrimeTheme.Colors.bubbleOutgoing
                case .syncing:
                    return PrimeTheme.Colors.bubbleSmartSyncing
                case .migrated:
                    return PrimeTheme.Colors.bubbleSmartMigrated
                }
            }
            return PrimeTheme.Colors.voiceIncomingSurface
        }

        guard isOutgoing else {
            return PrimeTheme.Colors.bubbleIncoming
        }

        switch message.deliveryState {
        case .offline:
            return PrimeTheme.Colors.bubbleSmartOffline
        case .online:
            return PrimeTheme.Colors.bubbleOutgoing
        case .syncing:
            return PrimeTheme.Colors.bubbleSmartSyncing
        case .migrated:
            return PrimeTheme.Colors.bubbleSmartMigrated
        }
    }

    private var bubbleStroke: Color {
        if bubbleBodyStyle == .voiceOnly {
            if isOutgoing {
                return Color.white.opacity(message.deliveryState == .offline ? 0.06 : 0.1)
            }
            return PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.92)
        }

        return isOutgoing
            ? Color.white.opacity(message.deliveryState == .offline ? 0.06 : 0.1)
            : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.92)
    }

    private var standaloneMetadataFill: Color {
        if bubbleBodyStyle == .voiceOnly, isOutgoing {
            return bubbleBackground.opacity(0.94)
        }
        if bubbleBodyStyle == .voiceOnly {
            return PrimeTheme.Colors.voiceIncomingSurface.opacity(0.96)
        }
        if isOutgoing {
            return bubbleBackground.opacity(0.92)
        }
        return PrimeTheme.Colors.elevated.opacity(0.96)
    }

    private var standaloneMetadataStroke: Color {
        if bubbleBodyStyle == .voiceOnly, isOutgoing {
            return Color.white.opacity(0.08)
        }
        if bubbleBodyStyle == .voiceOnly {
            return PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.92)
        }
        return isOutgoing
            ? Color.white.opacity(0.08)
            : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.92)
    }

    private var bubbleTailAlignment: Alignment {
        isOutgoing ? .bottomTrailing : .bottomLeading
    }

    private var mediaHorizontalAlignment: HorizontalAlignment {
        isOutgoing ? .trailing : .leading
    }

    private var mediaFrameAlignment: Alignment {
        isOutgoing ? .trailing : .leading
    }

    private var attachmentInteractionsEnabled: Bool {
        isFloatingPreview == false
            && isActionMenuPresented == false
            && isPressingActionMenu == false
            && isTrackingReplySwipe == false
    }

    private var attachmentPresentationContext: ChatAttachmentPresentationStore.PresentationContext {
        ChatAttachmentPresentationStore.PresentationContext(
            senderDisplayName: attachmentSenderDisplayName,
            sentAt: message.createdAt
        )
    }

    private var attachmentSenderDisplayName: String {
        if isOutgoing {
            return "You"
        }
        let bubbleName = senderDisplayNameForBubble?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bubbleName.isEmpty == false {
            return bubbleName
        }
        let explicitName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if explicitName.isEmpty == false {
            return explicitName
        }
        return "Sender"
    }

    private var usesLightBubbleForeground: Bool {
        isOutgoing
    }

    private var primaryBubbleTextColor: Color {
        usesLightBubbleForeground ? .white : PrimeTheme.Colors.textPrimary
    }

    private var secondaryBubbleTextColor: Color {
        if bubbleBodyStyle == .voiceOnly, isOutgoing {
            return Color.white.opacity(0.82)
        }
        if bubbleBodyStyle == .voiceOnly {
            return PrimeTheme.Colors.voiceIncomingText
        }
        return usesLightBubbleForeground ? Color.white.opacity(0.82) : PrimeTheme.Colors.textSecondary
    }

    private var senderMetadataColor: Color {
        usesLightBubbleForeground ? Color.white.opacity(0.94) : PrimeTheme.Colors.accent
    }

    private var senderDisplayNameForBubble: String? {
        guard isOutgoing == false else { return nil }

        let explicitName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitName, !explicitName.isEmpty, explicitName.caseInsensitiveCompare("Unknown user") != .orderedSame {
            return explicitName
        }

        if chat.type == .direct {
            if let participant = chat.directParticipant(for: currentUserID) {
                let participantDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if participantDisplayName.isEmpty == false {
                    return participantDisplayName
                }

                let participantUsername = participant.username.trimmingCharacters(in: .whitespacesAndNewlines)
                if participantUsername.isEmpty == false {
                    return participantUsername
                }
            }

            let directTitle = chat.displayTitle(for: currentUserID).trimmingCharacters(in: .whitespacesAndNewlines)
            return directTitle.isEmpty ? explicitName : directTitle
        }

        guard let member = chat.group?.members.first(where: { $0.userID == message.senderID }) else {
            return explicitName
        }

        let memberDisplayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let memberDisplayName, !memberDisplayName.isEmpty {
            return memberDisplayName
        }

        let memberUsername = member.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let memberUsername, !memberUsername.isEmpty {
            return memberUsername
        }

        return explicitName
    }

    private var senderAvatarInitials: String {
        let senderName = senderDisplayNameForBubble?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initials = senderName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()

        if initials.isEmpty == false {
            return initials
        }

        let fallback = senderName.prefix(2).uppercased()
        return fallback.isEmpty ? "?" : fallback
    }

    private var usesIncomingSenderMetadata: Bool {
        isOutgoing == false && chat.type == .group
    }

    private var usesIncomingAvatarColumn: Bool {
        isFloatingPreview == false && isOutgoing == false && chat.type == .group
    }

    private var replyPreviewTitle: String {
        if let replyMessage, replyMessage.senderID == currentUserID {
            return "Reply to You"
        }

        if let senderDisplayName = replyMessage?.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           senderDisplayName.isEmpty == false {
            return "Reply to \(senderDisplayName)"
        }

        if let senderDisplayName = message.replyPreview?.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           senderDisplayName.isEmpty == false {
            return "Reply to \(senderDisplayName)"
        }

        if message.replyPreview?.senderID == currentUserID {
            return "Reply to You"
        }

        return "Reply"
    }

    private var replyPreviewText: String? {
        if let replyMessage {
            if let structuredContent = StructuredChatMessageContent.parse(replyMessage.text) {
                return structuredContent.previewText
            }
            if let text = replyMessage.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false {
                return text
            }
            if replyMessage.voiceMessage != nil {
                return "Voice message"
            }
            if let attachment = replyMessage.attachments.first {
                return attachment.fileName
            }
            if replyMessage.isDeleted {
                return replyMessage.shouldHideDeletedPlaceholder ? "Original message" : "Message deleted"
            }
        }

        if let previewText = message.replyPreview?.previewText.trimmingCharacters(in: .whitespacesAndNewlines),
           previewText.isEmpty == false {
            return previewText
        }

        guard message.replyToMessageID != nil else { return nil }
        return "Original message"
    }

    private var structuredContent: StructuredChatMessageContent? {
        guard message.isDeleted == false else { return nil }
        return StructuredChatMessageContent.parse(message.text)
    }

    private var replyAccentColor: Color {
        usesLightBubbleForeground ? Color.white.opacity(0.94) : PrimeTheme.Colors.accent
    }

    private var replyContainerFill: Color {
        usesLightBubbleForeground ? Color.white.opacity(0.12) : Color.black.opacity(0.04)
    }

    private var replyContainerStroke: Color {
        usesLightBubbleForeground ? Color.white.opacity(0.1) : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.86)
    }

    private var replyNestedBubbleFill: Color {
        usesLightBubbleForeground ? Color.black.opacity(0.16) : Color.white.opacity(0.58)
    }

    private var replyNestedBubbleStroke: Color {
        usesLightBubbleForeground ? Color.white.opacity(0.08) : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.82)
    }

    private var replyIndicatorOpacity: CGFloat {
        min(max(abs(swipeOffset) / 24, 0), 1)
    }

    private func shouldBeginReplySwipe(translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        guard horizontal > 8 else { return false }
        guard horizontal > vertical * 1.05 else { return false }

        if isOutgoing {
            return translation.width < 0
        } else {
            return translation.width > 0
        }
    }

    private var commonReactionEmojis: [String] {
        ["👍", "❤️", "😂", "😮", "😢", "👎"]
    }

    private var sortedReactions: [MessageReaction] {
        message.reactions.sorted { lhs, rhs in
            if lhs.userIDs.count != rhs.userIDs.count {
                return lhs.userIDs.count > rhs.userIDs.count
            }
            return lhs.emoji < rhs.emoji
        }
    }

    private var reactionAccentColor: Color {
        Color.white
    }

    private var reactionTextColor: Color {
        Color.white.opacity(0.92)
    }

    private var reactionHighlightFill: Color {
        Color.white.opacity(0.18)
    }

    private var reactionNeutralFill: Color {
        Color.white.opacity(0.08)
    }

    private var reactionNeutralStroke: Color {
        Color.white.opacity(0.12)
    }
}

@MainActor
private final class StructuredPollSelectionStore: ObservableObject {
    @Published fileprivate private(set) var selectedOptionIndexes: Set<Int> = []

    private let storageKey: String
    private let defaults: UserDefaults

    init(messageID: UUID, defaults: UserDefaults = .standard) {
        self.storageKey = "prime_messaging.poll.selection.\(messageID.uuidString)"
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Int].self, from: data) {
            selectedOptionIndexes = Set(decoded)
        }
    }

    func toggleSelection(at index: Int) {
        if selectedOptionIndexes.contains(index) {
            selectedOptionIndexes.remove(index)
        } else {
            selectedOptionIndexes.insert(index)
        }
        let encoded = try? JSONEncoder().encode(Array(selectedOptionIndexes).sorted())
        defaults.set(encoded, forKey: storageKey)
    }
}

private struct StructuredMessageCard: View {
    let messageID: UUID
    let content: StructuredChatMessageContent
    let usesLightForeground: Bool

    @StateObject private var pollSelectionStore: StructuredPollSelectionStore
    @State private var isShowingPollVotes = false

    init(messageID: UUID, content: StructuredChatMessageContent, usesLightForeground: Bool) {
        self.messageID = messageID
        self.content = content
        self.usesLightForeground = usesLightForeground
        _pollSelectionStore = StateObject(wrappedValue: StructuredPollSelectionStore(messageID: messageID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 14, weight: .semibold))
                Text(headerTitle)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(headerForeground)

            Text(primaryText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryForeground)

            if case .poll = content {
                Text("Select one or more")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(headerForeground.opacity(0.78))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if case .poll = content {
                        Button {
                            pollSelectionStore.toggleSelection(at: index)
                        } label: {
                            structuredRow(for: row, at: index)
                        }
                        .buttonStyle(.plain)
                    } else {
                        structuredRow(for: row, at: index)
                    }
                }
            }

            if case .poll = content {
                Button {
                    isShowingPollVotes = true
                } label: {
                    Text("View votes")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(rowForeground.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(rowBackground)
                )
                .sheet(isPresented: $isShowingPollVotes) {
                    StructuredPollVotesSheet(
                        question: primaryText,
                        options: rows,
                        selectedOptionIndexes: pollSelectionStore.selectedOptionIndexes
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func structuredRow(for row: String, at index: Int) -> some View {
        HStack(spacing: 8) {
            if case .poll = content {
                ZStack {
                    Circle()
                        .stroke(rowForeground.opacity(0.6), lineWidth: 1.2)
                        .frame(width: 18, height: 18)
                    if pollSelectionStore.selectedOptionIndexes.contains(index) {
                        Circle()
                            .fill(headerForeground)
                            .frame(width: 10, height: 10)
                    }
                }
            } else {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .medium))
            }

            Text(row)
                .font(.footnote)
                .foregroundStyle(rowForeground)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(rowTrailingValue(for: index))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(rowForeground.opacity(0.72))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackground)
        )
    }

    private var headerIcon: String {
        switch content {
        case .poll:
            return "chart.bar.doc.horizontal"
        case .list:
            return "checklist"
        }
    }

    private var headerTitle: String {
        switch content {
        case .poll:
            return "Poll"
        case .list:
            return "List"
        }
    }

    private var primaryText: String {
        switch content {
        case let .poll(question, _):
            return question
        case let .list(title, _):
            return title
        }
    }

    private var rows: [String] {
        switch content {
        case let .poll(_, options):
            return options
        case let .list(_, items):
            return items
        }
    }

    private var headerForeground: Color {
        usesLightForeground ? Color.white.opacity(0.8) : PrimeTheme.Colors.accent
    }

    private var primaryForeground: Color {
        usesLightForeground ? Color.white : PrimeTheme.Colors.textPrimary
    }

    private var rowForeground: Color {
        usesLightForeground ? Color.white.opacity(0.96) : PrimeTheme.Colors.textPrimary
    }

    private var rowBackground: Color {
        usesLightForeground ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
    }

    private func rowTrailingValue(for index: Int) -> String {
        if case .poll = content {
            return pollSelectionStore.selectedOptionIndexes.contains(index) ? "1" : "0"
        }
        return "\(index + 1)"
    }
}

private struct StructuredPollVotesSheet: View {
    let question: String
    let options: [String]
    let selectedOptionIndexes: Set<Int>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Question") {
                    Text(question)
                        .font(.body.weight(.semibold))
                }

                Section("Votes") {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        HStack(spacing: 10) {
                            Image(systemName: selectedOptionIndexes.contains(index) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedOptionIndexes.contains(index) ? PrimeTheme.Colors.accent : PrimeTheme.Colors.textSecondary)
                            Text(option)
                            Spacer(minLength: 0)
                            Text("\(selectedOptionIndexes.contains(index) ? 1 : 0)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Votes")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MessageBubbleRowLayout: Layout {
    let isOutgoing: Bool
    let rowWidth: CGFloat
    let contentMaxWidth: CGFloat

    struct Cache {
        var bubbleSize: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.bubbleSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let subview = subviews.first else {
            return CGSize(width: rowWidth, height: 0)
        }

        let measuredSize = subview.sizeThatFits(
            ProposedViewSize(width: contentMaxWidth, height: proposal.height)
        )
        cache.bubbleSize = measuredSize
        return CGSize(width: rowWidth, height: measuredSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let subview = subviews.first else { return }

        let measuredSize = cache.bubbleSize == .zero
            ? subview.sizeThatFits(ProposedViewSize(width: contentMaxWidth, height: proposal.height))
            : cache.bubbleSize

        let originX = isOutgoing
            ? bounds.maxX - measuredSize.width
            : bounds.minX

        subview.place(
            at: CGPoint(x: originX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: measuredSize.width, height: measuredSize.height)
        )
    }
}

private struct MessageStatusGlyphView: View {
    let status: MessageStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .localPending, .sending:
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
        case .delivered:
            DoubleCheckGlyph(color: Color.white.opacity(0.82))
                .font(.system(size: 10, weight: .semibold))
        case .read:
            DoubleCheckGlyph(color: PrimeTheme.Colors.accentSoft)
                .font(.system(size: 10, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.warning)
        }
    }
}

private struct DoubleCheckGlyph: View {
    let color: Color

    var body: some View {
        ZStack {
            Image(systemName: "checkmark")
                .offset(x: -3)
            Image(systemName: "checkmark")
                .offset(x: 3)
        }
        .foregroundStyle(color)
    }
}

private struct GuestRequestStatusCard: View {
    let title: String
    let message: String
    let introText: String?
    let isWarning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            if let introText, introText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(introText)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill((isWarning ? PrimeTheme.Colors.warning : PrimeTheme.Colors.accent).opacity(0.12))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.vertical, 14)
    }
}

private struct GuestRequestIntroComposer: View {
    @Binding var text: String
    let isSubmitting: Bool
    let onSubmit: () async -> Void

    private var trimmedCount: Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            TextField("Introduce yourself", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2 ... 5)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                )

            HStack {
                Text("\(trimmedCount)/150")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                Spacer()

                Button {
                    Task {
                        await onSubmit()
                    }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .tint(Color.white)
                            .frame(width: 22, height: 22)
                    } else {
                        Text("Send Request")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(PrimeTheme.Colors.accent)
                )
                .disabled(isSubmitting)
            }
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}

private struct ChatWallpaperBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PrimeTheme.Colors.chatWallpaperBase

                if let wallpaperImage {
                    Image(uiImage: wallpaperImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    ChatWallpaperPatternLayer(size: geometry.size, isDark: colorScheme == .dark)
                }

                LinearGradient(
                    colors: [
                        PrimeTheme.Colors.chatWallpaperOverlay.opacity(colorScheme == .dark ? 0.86 : 0.5),
                        Color.clear,
                        PrimeTheme.Colors.chatWallpaperOverlay.opacity(colorScheme == .dark ? 0.38 : 0.18)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private var wallpaperImage: UIImage? {
        let assetName = colorScheme == .dark ? "ChatWallpaperDark" : "ChatWallpaperLight"
        return UIImage(named: assetName)
    }
}

private struct ChatWallpaperPatternLayer: View {
    let size: CGSize
    let isDark: Bool

    private let symbols = [
        "paintpalette", "crown", "paperplane", "pencil", "flame", "diamond",
        "leaf", "heart", "star", "cloud", "gift", "moon.stars",
        "sun.max", "gamecontroller", "camera", "globe.europe.africa", "umbrella", "paperclip",
        "bell", "fish", "pawprint", "tortoise", "hare", "ladybug",
        "fork.knife", "cup.and.saucer", "popcorn", "soccerball", "music.note", "bolt",
        "drop", "sparkles", "location", "airplane", "message", "car"
    ]
    private let xOffsets: [CGFloat] = [-0.14, 0.08, -0.05, 0.12, -0.09, 0.05]
    private let yOffsets: [CGFloat] = [-0.16, 0.07, -0.04, 0.14, -0.1, 0.03]
    private let rotations: [Double] = [-18, -10, -4, 8, 14, 20]
    private let scales: [CGFloat] = [0.72, 0.84, 1.0, 0.9, 0.76, 1.08]

    var body: some View {
        let columns = 5
        let rows = max(Int(size.height / 108), 12)
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)

        ZStack {
            ForEach(0..<(rows * columns), id: \.self) { index in
                glyphView(
                    index: index,
                    rows: rows,
                    columns: columns,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight
                )
            }

            ForEach(0..<(rows * columns * 2), id: \.self) { index in
                smallMarkView(index: index, rows: rows, columns: columns)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func glyphView(index: Int, rows: Int, columns: Int, cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        let row = index / columns
        let column = index % columns
        let position = glyphPosition(index: index, row: row, column: column, cellWidth: cellWidth, cellHeight: cellHeight)
        let glyphOpacity = isDark ? 0.72 : 0.62

        if showsPrimeWord(row: row, column: column, rows: rows) {
            Text("PRIME")
                .font(.system(size: min(cellWidth, cellHeight) * 0.28, weight: .medium, design: .rounded))
                .foregroundStyle(PrimeTheme.Colors.chatWallpaperStroke.opacity(glyphOpacity))
                .position(position)
                .rotationEffect(.degrees(rotations[(row + column) % rotations.count] * 0.35))
        } else {
            Image(systemName: symbols[(row * 7 + column * 5) % symbols.count])
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(PrimeTheme.Colors.chatWallpaperStroke.opacity(glyphOpacity))
                .font(.system(size: min(cellWidth, cellHeight) * 0.24 * scales[(row + column) % scales.count], weight: .regular))
                .position(position)
                .rotationEffect(.degrees(rotations[(row + column) % rotations.count]))
        }
    }

    private func smallMarkView(index: Int, rows: Int, columns: Int) -> some View {
        let column = index % (columns * 2)
        let row = index / (columns * 2)
        let x = (CGFloat(column) + 0.45 + xOffsets[(index + row) % xOffsets.count] * 0.45) * (size.width / CGFloat(columns * 2))
        let y = (CGFloat(row) + 0.5 + yOffsets[(index + column) % yOffsets.count] * 0.55) * (size.height / CGFloat(max(rows * 2, 1)))
        let diameter = CGFloat(3 + (index % 3))

        return Circle()
            .stroke(PrimeTheme.Colors.chatWallpaperStroke.opacity(isDark ? 0.5 : 0.38), lineWidth: 1)
            .frame(width: diameter, height: diameter)
            .position(x: x, y: y)
    }

    private func showsPrimeWord(row: Int, column: Int, rows: Int) -> Bool {
        (row == 1 && column == 0) || (row == rows / 2 && column == 0) || (row == rows - 2 && column == 1)
    }

    private func glyphPosition(index: Int, row: Int, column: Int, cellWidth: CGFloat, cellHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: (CGFloat(column) + 0.5 + xOffsets[index % xOffsets.count]) * cellWidth,
            y: (CGFloat(row) + 0.5 + yOffsets[(index + column) % yOffsets.count]) * cellHeight
        )
    }
}

private struct ChatGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(PrimeTheme.Colors.glassTint)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
    }
}

private extension View {
    func chatGlassCard(cornerRadius: CGFloat) -> some View {
        modifier(ChatGlassCardModifier(cornerRadius: cornerRadius))
    }
}

final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draftText = ""
    @Published private(set) var isSending = false
    @Published private(set) var editingMessage: Message?
    @Published var messageActionError = ""
    private var preEditingDraftText = ""
    private var soundCurrentUserID: UUID?

    @MainActor
    func hydrateMessages(chat: Chat, repository: ChatRepository, localStore: LocalStore, currentUserID: UUID) async {
        soundCurrentUserID = currentUserID
        let cachedMessages = await repository.cachedMessages(chatID: chat.id, mode: chat.mode)
        applyFetchedMessages(cachedMessages, preserveExistingWhenEmpty: true)
        if let savedDraft = await localStore.loadDraft(chatID: chat.id, mode: chat.mode) {
            self.draftText = savedDraft.text
        } else {
            self.draftText = ""
        }
    }

    @MainActor
    func refreshMessages(chat: Chat, repository: ChatRepository, currentUserID: UUID) async {
        soundCurrentUserID = currentUserID
        do {
            let fetchedMessages = try await repository.fetchMessages(chatID: chat.id, mode: chat.mode)
            applyFetchedMessages(fetchedMessages, preserveExistingWhenEmpty: true)
        } catch { }
    }

    @MainActor
    func refreshLocalSnapshot(chat: Chat, repository: ChatRepository, currentUserID: UUID) async {
        soundCurrentUserID = currentUserID
        let cachedMessages = await repository.cachedMessages(chatID: chat.id, mode: chat.mode)
        applyFetchedMessages(cachedMessages, preserveExistingWhenEmpty: true)
    }

    @MainActor
    func submitComposer(_ draft: OutgoingMessageDraft, chat: Chat, senderID: UUID, repository: ChatRepository) async throws -> Message? {
        guard draft.hasContent else { return nil }
        guard isSending == false else { return nil }

        isSending = true
        defer { isSending = false }

        if let editingMessage {
            let updated = try await repository.editMessage(
                editingMessage.id,
                text: draft.text,
                in: chat.id,
                mode: chat.mode,
                editorID: senderID
            )
            replaceOrAppend(updated)
            cancelEditing()
            return updated
        }

        let outgoing = try await repository.sendMessage(draft, in: chat, senderID: senderID)
        replaceOrAppend(outgoing)
        if AudioRecorderController.hasActiveRecording() == false {
            MessageSoundEffectPlayer.shared.playSend()
        }
        draftText = ""
        return outgoing
    }

    @MainActor
    func beginEditing(_ message: Message) {
        guard message.canEditText else { return }
        preEditingDraftText = draftText
        editingMessage = message
        draftText = message.text ?? ""
        messageActionError = ""
    }

    @MainActor
    func cancelEditing() {
        editingMessage = nil
        draftText = preEditingDraftText
        preEditingDraftText = ""
    }

    @MainActor
    func deleteMessage(_ messageID: UUID, chat: Chat, requesterID: UUID, repository: ChatRepository) async {
        do {
            let deleted = try await repository.deleteMessage(messageID, in: chat.id, mode: chat.mode, requesterID: requesterID)
            replaceOrAppend(deleted)
            if editingMessage?.id == messageID {
                cancelEditing()
            }
            messageActionError = ""
        } catch {
            messageActionError = error.localizedDescription.isEmpty ? "Could not update the message." : error.localizedDescription
        }
    }

    func canEdit(_ message: Message, currentUserID: UUID) -> Bool {
        message.senderID == currentUserID && message.canEditText
    }

    func canDelete(_ message: Message, currentUserID: UUID) -> Bool {
        message.senderID == currentUserID && message.isDeleted == false
    }

    @MainActor
    func replaceOrAppend(_ message: Message) {
        applyFetchedMessages([message], preserveExistingWhenEmpty: false)
    }

    @MainActor
    private func applyFetchedMessages(_ fetchedMessages: [Message], preserveExistingWhenEmpty: Bool) {
        let normalizedIncoming = fetchedMessages.sorted(by: { $0.createdAt < $1.createdAt })
        let existingClientMessageIDs = Set(messages.map(\.clientMessageID))
        let shouldPlayIncomingSound = messages.isEmpty == false && normalizedIncoming.contains { message in
            guard existingClientMessageIDs.contains(message.clientMessageID) == false else { return false }
            guard let soundCurrentUserID else { return false }
            return message.senderID != soundCurrentUserID && message.isDeleted == false
        }

        guard preserveExistingWhenEmpty == false || normalizedIncoming.isEmpty == false || messages.isEmpty else {
            return
        }

        guard messages.isEmpty == false else {
            messages = normalizedIncoming
            return
        }

        let existingOrder = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.clientMessageID, $0.offset) })
        var mergedByClientMessageID = Dictionary(uniqueKeysWithValues: messages.map { ($0.clientMessageID, $0) })
        for message in normalizedIncoming {
            if let existing = mergedByClientMessageID[message.clientMessageID] {
                mergedByClientMessageID[message.clientMessageID] = message.mergingLocalObjectState(from: existing)
            } else {
                mergedByClientMessageID[message.clientMessageID] = message
            }
        }

        let mergedMessages = mergedByClientMessageID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }

            let lhsExistingIndex = existingOrder[lhs.clientMessageID]
            let rhsExistingIndex = existingOrder[rhs.clientMessageID]
            if let lhsExistingIndex, let rhsExistingIndex, lhsExistingIndex != rhsExistingIndex {
                return lhsExistingIndex < rhsExistingIndex
            }

            if lhs.id != rhs.id {
                return lhs.id.uuidString < rhs.id.uuidString
            }

            return lhs.clientMessageID.uuidString < rhs.clientMessageID.uuidString
        }

        guard mergedMessages != messages else {
            return
        }

        messages = mergedMessages

        if shouldPlayIncomingSound, AudioRecorderController.hasActiveRecording() == false {
            MessageSoundEffectPlayer.shared.playReceive()
        }
    }

    @MainActor
    func removeMessageLocally(clientMessageID: UUID) {
        messages.removeAll(where: { $0.clientMessageID == clientMessageID })
        if editingMessage?.clientMessageID == clientMessageID {
            cancelEditing()
        }
    }
}

private struct MessageBubbleTailShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isOutgoing {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.36),
                control: CGPoint(x: rect.maxX * 0.62, y: rect.minY - rect.height * 0.08)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX * 0.42, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY * 0.94)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.56),
                control: CGPoint(x: rect.maxX * 0.06, y: rect.maxY * 0.98)
            )
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.36),
                control: CGPoint(x: rect.maxX * 0.38, y: rect.minY - rect.height * 0.08)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX * 0.58, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY * 0.94)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.56),
                control: CGPoint(x: rect.maxX * 0.94, y: rect.maxY * 0.98)
            )
        }
        path.closeSubpath()
        return path
    }
}
