import Combine
import OSLog
import SwiftUI
import UIKit
import UserNotifications

private enum ChatMessageGestureDiagnostics {
    static let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "MessageGesture")
    static let isEnabled = ProcessInfo.processInfo.environment["PRIME_CHAT_GESTURE_DIAGNOSTICS"] == "1"

    static func log(_ event: String, messageID: UUID? = nil, details: String = "") {
        guard isEnabled else { return }
        let suffix = details.isEmpty ? "" : " \(details)"
        let payload = "MessageGesture event=\(event) message=\(messageID?.uuidString ?? "nil") main=\(Thread.isMainThread)\(suffix)"
        logger.notice("\(payload, privacy: .public)")
    }
}

private enum ChatCallSummaryCodec {
    static let prefix = "[prime_call_summary]"

    struct Payload: Equatable {
        var state: InternetCallState
        var direction: InternetCallDirection
        var durationSeconds: Int
    }

    static func encode(_ payload: Payload) -> String {
        "\(prefix)state=\(payload.state.rawValue);direction=\(payload.direction.rawValue);duration=\(payload.durationSeconds)"
    }

    static func decode(_ text: String?) -> Payload? {
        guard let text, text.hasPrefix(prefix) else { return nil }
        let serialized = String(text.dropFirst(prefix.count))
        let parts = serialized.split(separator: ";")
        var state: InternetCallState?
        var direction: InternetCallDirection?
        var durationSeconds = 0

        for part in parts {
            let tokens = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard tokens.count == 2 else { continue }
            switch tokens[0] {
            case "state":
                state = InternetCallState(rawValue: tokens[1])
            case "direction":
                direction = InternetCallDirection(rawValue: tokens[1])
            case "duration":
                durationSeconds = Int(tokens[1]) ?? 0
            default:
                continue
            }
        }

        guard let state, let direction else { return nil }
        return Payload(state: state, direction: direction, durationSeconds: max(durationSeconds, 0))
    }
}

struct ChatView: View {
    private enum SmartTransportState {
        case unknown
        case nearby
        case relay
        case online
        case waiting
    }

    private enum ChatOpenPhase: String {
        case idle
        case opening
        case loadingInitialMessages
        case initialMessagesReady
        case applyingInitialSnapshot
        case initialViewportReady
        case realtimeStarting
        case active
        case failedButRecoverable
        case cancelled
        case closed
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
    @State private var activeHoldMenuMessage: Message?
    @State private var activeInlineReactionMessage: Message?
    @State private var reactionPickerMessage: Message?
    @State private var isChatScrollInteracting = false
    @State private var scrollInteractionGraceUntil: Date = .distantPast
    @State private var scrollIdleFlushTask: Task<Void, Never>?
    @State private var holdGestureSuppressionUntil: Date = .distantPast
    @State private var smartTransportState: SmartTransportState = .unknown
    @State private var smartDeliveryConfidence: SmartDeliveryConfidence = .waiting
    @State private var smartPreferredOfflinePath: OfflineTransportPath?
    @State private var smartShouldPreferOnline = false
    @State private var draftPersistenceTask: Task<Void, Never>?
    @State private var typingStateEvaluationTask: Task<Void, Never>?
    @State private var lastPersistedDraftText = ""
    @State private var incomingSharedDraft: OutgoingMessageDraft?
    @State private var unreadAnchorMessageID: UUID?
    @State private var readingAnchorMessageID: UUID?
    @State private var topVisibleMessageID: UUID?
    @State private var selectedCommunityTopicID: UUID?
    @State private var selectedCommentPostID: UUID?
    @State private var pendingDeferredMessageRefresh = false
    @State private var pendingDeferredSnapshotRefresh = false
    @State private var previousMessageIDs: [UUID] = []
    @State private var lastServerReadMarkAttemptAt: Date?
    @State private var lastPresenceRefreshUserID: UUID?
    @State private var lastPresenceRefreshAt: Date = .distantPast
    @State private var lastCallSummaryRefreshChatID: UUID?
    @State private var lastCallSummaryRefreshAt: Date = .distantPast
    @State private var bottomInsetRealignmentTask: Task<Void, Never>?
    @State private var keyboardOpenRealignmentTask: Task<Void, Never>?
    @State private var foregroundRefreshTask: Task<Void, Never>?
    @State private var foregroundInteractionGraceUntil: Date = .distantPast
    @State private var pendingForegroundRefreshAfterActivation = false
    @State private var selfDestructNow: Date = .now
    @State private var callSummaryMessages: [Message] = []
    @State private var realtimeMessageTask: Task<Void, Never>?
    @State private var remoteTypingResetTask: Task<Void, Never>?
    @State private var localTypingIdleTask: Task<Void, Never>?
    @State private var localTypingHeartbeatTask: Task<Void, Never>?
    @State private var isLocalTypingActive = false
    @State private var lastTypingSignalState = false
    @State private var lastTypingSignalAt: Date = .distantPast
    @State private var hasReportedPremiumChatOpen = false
    @State private var premiumChatOpenedAt: Date?
    @State private var isScreenRecordingActive = false
    @State private var prefersNotificationLaunchScroll = false
    @State private var notificationLaunchAnchorSuppressionUntil: Date = .distantPast
    @State private var isViewportReady = false
    @State private var isCollapsingLoadedHistory = false
    @State private var cachedVisibleMessages: [Message] = []
    @State private var cachedVisibleMessageSignatures: [VisibleMessageSignature] = []
    @State private var cachedVisibleLookup: [UUID: Message] = [:]
    @State private var cachedVisibleMessageIDs: [UUID] = []
    @State private var cachedMergedBaseMessages: [Message] = []
    @State private var cachedMergedBaseSignatures: [MergedMessageSignature] = []
    @State private var cachedMergedCallSummaryMessages: [Message] = []
    @State private var cachedMergedCallSummarySignatures: [MergedMessageSignature] = []
    @State private var cachedMergedDisplayMessages: [Message] = []
    @State private var cachedRenderRowInputs: [MessageRenderRowInput] = []
    @State private var cachedRenderRowSignatures: [MessageRenderRowSignature] = []
    @State private var cachedRenderRows: [MessageRenderRow] = []
    @State private var deferredInitialRefreshTask: Task<Void, Never>?
    @State private var initialChatBootstrapTask: Task<Void, Never>?
    @State private var presentationSyncTask: Task<Void, Never>?
    @State private var initialScrollRecoveryToken = 0
    @State private var isJumpingToLatestWindow = false
    @State private var hasCompletedInitialMessageBootstrap = false
    @State private var viewportScrollCommand: ChatMessageViewportCommand?
    @State private var viewportCommandToken = 0
    @State private var lastViewportTopRowIndex: Int?
    @State private var lastViewportTrimAnchorMessageID: UUID?
    @State private var lastViewportTrimAt: Date = .distantPast
    @State private var editHistoryMessage: Message?
    @State private var reminderMessageIDs = Set<UUID>()
    @State private var followUpMessageIDs = Set<UUID>()
    @State private var chatSessionID = UUID()
    @State private var chatOpenPhase: ChatOpenPhase = .idle
    @State private var chatOpenFailureMessage: String?
    @State private var pendingTimelineRefreshReasons = Set<String>()
    @State private var pendingTimelineRefreshForce = false
    @State private var pendingTimelineRefreshSessionID: UUID?
    @State private var isTimelineRefreshScheduled = false
    @State private var isApplyingTimelineRefresh = false
    @State private var skippedTimelineRefreshCount = 0

    fileprivate static let scrollIdleDebounce: Duration = .milliseconds(220)
    fileprivate static let scrollIdleGraceWindow: TimeInterval = 0.22
    fileprivate static let largeMessageCollapseThreshold = 2200
    fileprivate static let largeAnchorTextThreshold = 2000

    init(chat: Chat) {
        self.chat = chat
        _currentChat = State(initialValue: chat)
    }

    private struct MessageRenderRow: Identifiable {
        let id: UUID
        let messageID: UUID
        let messageCreatedAt: Date
        let replyMessageID: UUID?
        let showsDayDivider: Bool
        let showsIncomingSenderName: Bool
        let showsIncomingAvatar: Bool
        let showsTail: Bool
        let bottomSpacing: CGFloat
    }

    private struct ViewportFrameRowID: Hashable {
        let id: UUID
    }

    private struct MessageRenderRowInput: Equatable {
        let id: UUID
        let senderID: UUID
        let createdAt: TimeInterval
        let replyToMessageID: UUID?
        let editedAt: TimeInterval?
        let textHash: Int
        let isDeleted: Bool
        let reactionFingerprint: Int
    }

    private struct MessageRenderRowSignature: Equatable {
        let id: UUID
        let senderID: UUID
        let createdAt: TimeInterval
        let replyToMessageID: UUID?
        let editedAt: TimeInterval?
        let textHash: Int
        let isDeleted: Bool
        let reactionFingerprint: Int

        nonisolated init(input: MessageRenderRowInput) {
            id = input.id
            senderID = input.senderID
            createdAt = input.createdAt
            replyToMessageID = input.replyToMessageID
            editedAt = input.editedAt
            textHash = input.textHash
            isDeleted = input.isDeleted
            reactionFingerprint = input.reactionFingerprint
        }
    }

    private struct MergedMessageSignature: Equatable {
        let id: UUID
        let clientMessageID: UUID
        let createdAt: TimeInterval
        let senderID: UUID
        let editedAt: TimeInterval?
        let isDeleted: Bool
        let textHash: Int
        let attachmentCount: Int
        let voiceFingerprint: Int
        let reactionFingerprint: Int

        nonisolated init(message: Message) {
            id = message.id
            clientMessageID = message.clientMessageID
            createdAt = message.createdAt.timeIntervalSinceReferenceDate
            senderID = message.senderID
            editedAt = message.editedAt?.timeIntervalSinceReferenceDate
            isDeleted = message.isDeleted
            textHash = message.text?.hashValue ?? 0
            attachmentCount = message.attachments.count
            if let voiceMessage = message.voiceMessage {
                voiceFingerprint = voiceMessage.durationSeconds ^ voiceMessage.waveformSamples.count ^ Int(voiceMessage.byteSize)
            } else {
                voiceFingerprint = 0
            }
            reactionFingerprint = ChatView.makeReactionFingerprint(from: message.reactions)
        }
    }

    private struct VisibleMessageSignature: Equatable {
        let id: UUID
        let createdAt: TimeInterval
        let senderID: UUID
        let isDeleted: Bool
        let hiddenDeletedPlaceholder: Bool
        let expirationBucket: Int
        let editedAt: TimeInterval?
        let textHash: Int
        let attachmentCount: Int
        let reactionFingerprint: Int

        init(message: Message, relativeTo now: Date) {
            id = message.id
            createdAt = message.createdAt.timeIntervalSinceReferenceDate
            senderID = message.senderID
            isDeleted = message.isDeleted
            hiddenDeletedPlaceholder = message.shouldHideDeletedPlaceholder
            editedAt = message.editedAt?.timeIntervalSinceReferenceDate
            textHash = message.text?.hashValue ?? 0
            attachmentCount = message.attachments.count + (message.voiceMessage == nil ? 0 : 1)
            reactionFingerprint = ChatView.makeReactionFingerprint(from: message.reactions)
            if let expiresAt = message.selfDestructAt() {
                expirationBucket = Int(expiresAt.timeIntervalSince1970)
            } else if message.isExpiredForSelfDestruct(relativeTo: now) {
                expirationBucket = -1
            } else {
                expirationBucket = 0
            }
        }
    }

    private var visibleMessages: [Message] {
        cachedVisibleMessages
    }

    private func logSlowChatPhase(_ label: String, startedAt startTime: CFTimeInterval, count: Int) {
        let duration = CACurrentMediaTime() - startTime
        guard duration >= 0.008 else { return }
        guard ProcessInfo.processInfo.environment["PRIME_CHAT_PERF_LOGS"] == "1" else { return }
        print("PUSHTRACE ChatPerf phase=\(label) durationMs=\(Int((duration * 1000).rounded())) count=\(count)")
    }

    private func logChatOpen(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatOpen step=\(step) chat=\(currentChat.id.uuidString) session=\(chatSessionID.uuidString) phase=\(chatOpenPhase.rawValue) main=\(Thread.isMainThread)\(suffix)")
    }

    private func logChatTimeline(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatTimeline step=\(step) chat=\(currentChat.id.uuidString) session=\(chatSessionID.uuidString) main=\(Thread.isMainThread)\(suffix)")
    }

    private func logChatPresence(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatPresence step=\(step) chat=\(currentChat.id.uuidString) session=\(chatSessionID.uuidString) main=\(Thread.isMainThread)\(suffix)")
    }

    private func logChatSend(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatSend step=\(step) chat=\(currentChat.id.uuidString) session=\(chatSessionID.uuidString) main=\(Thread.isMainThread)\(suffix)")
    }

    private var isChatScrollRecentlyActive: Bool {
        isChatScrollInteracting || Date.now < scrollInteractionGraceUntil
    }

    @MainActor
    private func transitionOpenPhase(_ nextPhase: ChatOpenPhase, sessionID: UUID, details: String = "") {
        guard sessionID == chatSessionID else { return }
        guard chatOpenPhase != nextPhase else { return }
        chatOpenPhase = nextPhase
        logChatOpen("phase.\(nextPhase.rawValue)", details: details)
    }

    @MainActor
    private func isActiveSession(_ sessionID: UUID) -> Bool {
        sessionID == chatSessionID
    }

    @MainActor
    private func updateScrollInteractionState(isActive: Bool, source: String) {
        if isActive {
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = nil
            scrollInteractionGraceUntil = .distantPast
            if isChatScrollInteracting == false {
                isChatScrollInteracting = true
                logChatTimeline("scroll.active", details: "source=\(source)")
            }
            return
        }

        if isChatScrollInteracting {
            isChatScrollInteracting = false
            logChatTimeline("scroll.inactive", details: "source=\(source)")
        }
        scrollInteractionGraceUntil = Date.now.addingTimeInterval(Self.scrollIdleGraceWindow)
        scheduleScrollIdleFlush()
    }

    @MainActor
    private func scheduleScrollIdleFlush() {
        scrollIdleFlushTask?.cancel()
        scrollIdleFlushTask = Task { @MainActor in
            logChatTimeline("scroll.idleDebounce.begin", details: "delayMs=220")
            try? await Task.sleep(for: Self.scrollIdleDebounce)
            guard Task.isCancelled == false else { return }
            guard isChatScrollRecentlyActive == false else { return }
            logChatTimeline("scroll.idleDebounce.end")
            drainTimelineProjectionRefreshes()
            await runDeferredRefreshesIfNeeded()
        }
    }

    private func shouldDeferTimelineRefresh(reason: String) -> Bool {
        guard isChatScrollRecentlyActive else { return false }
        switch reason {
        case "remote_refresh", "remote_refresh_forced", "call_summaries_changed", "local_snapshot_refresh":
            return true
        default:
            return false
        }
    }

    private func buildVisibleMessages() -> [Message] {
        let baseMessages = cachedMergedDisplayMessages.filter { message in
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

    private var composerMentionCandidates: [ComposerMentionCandidate] {
        var resolved: [ComposerMentionCandidate] = []
        var seenHandles = Set<String>()

        for participant in currentChat.participants {
            guard participant.id != appState.currentUser.id else { continue }
            let handle = normalizedMentionHandle(
                explicitUsername: participant.username,
                fallbackDisplayName: participant.displayName
            )
            guard let handle, seenHandles.insert(handle).inserted else { continue }
            let trimmedDisplayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedDisplayName.isEmpty ? participant.username : trimmedDisplayName
            resolved.append(
                ComposerMentionCandidate(
                    id: participant.id,
                    handle: handle,
                    displayName: displayName
                )
            )
        }

        for member in currentChat.group?.members ?? [] {
            guard member.userID != appState.currentUser.id else { continue }
            let handle = normalizedMentionHandle(
                explicitUsername: member.username,
                fallbackDisplayName: member.displayName
            )
            guard let handle, seenHandles.insert(handle).inserted else { continue }
            let trimmedDisplayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedDisplayName.isEmpty
                ? (member.username ?? handle)
                : trimmedDisplayName
            resolved.append(
                ComposerMentionCandidate(
                    id: member.userID,
                    handle: handle,
                    displayName: displayName
                )
            )
        }

        return resolved.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
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

    private var chatScrollInteractionGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("chat-scroll"))
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard vertical > 6 else { return }
                guard vertical > horizontal * 1.1 else { return }
                holdGestureSuppressionUntil = Date.now.addingTimeInterval(0.28)
                if isChatScrollInteracting == false {
                    updateScrollInteractionState(isActive: true, source: "gesture")
                    ChatMessageGestureDiagnostics.log(
                        "scroll_begin_drag",
                        details: "dx=\(Int(value.translation.width)) dy=\(Int(value.translation.height))"
                    )
                }
            }
            .onEnded { _ in
                if isChatScrollInteracting {
                    ChatMessageGestureDiagnostics.log("scroll_end_drag")
                }
                holdGestureSuppressionUntil = Date.now.addingTimeInterval(0.16)
            }
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
    private func chatCanvas(geometry: GeometryProxy) -> some View {
        let renderedRows = cachedRenderRows
        let visibleLookup = cachedVisibleLookup
        let messageColumn = messageColumnWidth(containerWidth: geometry.size.width)
        let renderedRowMap = Dictionary(uniqueKeysWithValues: renderedRows.map { ($0.id, $0) })
        let renderedRowOrderMap = Dictionary(uniqueKeysWithValues: renderedRows.enumerated().map { ($0.element.id, $0.offset) })
        let viewportRows = makeViewportRows(from: renderedRows, visibleLookup: visibleLookup, messageColumn: messageColumn)
        let trackedMessageIDs = Set([activeHoldMenuMessage?.id, activeInlineReactionMessage?.id].compactMap { $0 })
        let shouldMountViewport = hasCompletedInitialMessageBootstrap || viewportRows.isEmpty == false

        ZStack {
            if shouldMountViewport {
                ChatMessageViewport(
                    rows: viewportRows,
                    containerWidth: messageColumn,
                    topInset: topContentInset(safeAreaTop: geometry.safeAreaInsets.top),
                    bottomInset: bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom) + 4,
                    nearBottomThreshold: 110,
                    sessionID: chatSessionID,
                    trackedMessageIDs: trackedMessageIDs,
                    command: viewportScrollCommand,
                    onBuildRow: { viewportRow in
                        guard let renderedRow = renderedRowMap[viewportRow.id] else { return AnyView(EmptyView()) }
                        return makeViewportRowView(
                            row: renderedRow,
                            visibleLookup: visibleLookup,
                            messageColumn: messageColumn
                        )
                    },
                    onCommandConsumed: { token in
                        consumeViewportCommandIfNeeded(token: token)
                    },
                    onReachTop: {
                        guard didInitialScrollToBottom else { return }
                        guard isViewportReady else { return }
                        Task { @MainActor in
                            _ = await viewModel.loadOlderMessages(
                                chat: currentChat,
                                currentUserID: appState.currentUser.id,
                                sessionID: chatSessionID
                            )
                        }
                    },
                    onNearBottomChanged: { nextIsNearBottom in
                        updateBottomAnchorVisibility(isVisible: nextIsNearBottom)
                        if nextIsNearBottom {
                            collapseLoadedHistoryNearBottomIfNeeded()
                        }
                    },
                    onTrackedFramesChanged: { frames in
                        if messageMenuFrames != frames {
                            DispatchQueue.main.async {
                                guard messageMenuFrames != frames else { return }
                                messageMenuFrames = frames
                            }
                        }
                    },
                    onTopVisibleRowChanged: { rowID in
                        updateVisibleDayFromViewport(
                            topVisibleRowID: rowID,
                            rowMap: renderedRowMap,
                            rowOrderMap: renderedRowOrderMap
                        )
                    },
                    onScrollInteractionChanged: { isActive, source in
                        updateScrollInteractionState(isActive: isActive, source: source)
                    },
                    onInitialPositioned: {
                        logChatOpen(
                            "viewport.initialPositioned",
                            details: "rows=\(viewportRows.count) visible=\(visibleMessages.count)"
                        )
                        if didInitialScrollToBottom == false {
                            didInitialScrollToBottom = true
                        }
                        transitionOpenPhase(.initialViewportReady, sessionID: chatSessionID, details: "rows=\(viewportRows.count)")
                        if chatOpenPhase == .realtimeStarting || chatOpenPhase == .initialMessagesReady || chatOpenPhase == .applyingInitialSnapshot {
                            transitionOpenPhase(.active, sessionID: chatSessionID, details: "rows=\(viewportRows.count)")
                        }
                        logChatOpen(
                            "viewport.initialReady",
                            details: "rows=\(viewportRows.count) visible=\(visibleMessages.count)"
                        )
                        completeInitialViewportAlignment()
                    }
                )
                .opacity((isViewportReady || viewportRows.isEmpty) ? 1 : 0)
                .allowsHitTesting(isViewportReady || viewportRows.isEmpty)
                .background(Color.clear)
                .simultaneousGesture(chatScrollInteractionGesture)
                .onAppear {
                    logChatOpen("viewport.appear", details: "rows=\(viewportRows.count)")
                    scrollToRelevantMessage(animated: false)
                }
                .onChange(of: initialScrollRecoveryToken) { _ in
                    guard visibleMessages.isEmpty == false else { return }
                    scrollToRelevantMessage(animated: false)
                }
                .onChange(of: viewModel.messageIDs) { newIDs in
                    handleMessageListChange(oldIDs: previousMessageIDs)
                    previousMessageIDs = newIDs
                }
                .onChange(of: keyboardRealignmentRequest) { _ in
                    guard isNearBottom || pendingAutoScrollAfterOutgoingMessage else { return }
                    scrollToBottom(animated: false)
                }
                .onChange(of: localFocusedMessageID) { newValue in
                    guard newValue != nil else { return }
                    _ = scrollToPendingMessageIfNeeded(
                        animated: !prefersNotificationLaunchScroll,
                        preferBottomAnchorForRecentNotificationMessage: prefersNotificationLaunchScroll
                    )
                }
                .onChange(of: bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom)) { _ in
                    guard visibleMessages.isEmpty == false else { return }
                    guard keyboardHeight <= 0 else { return }
                    bottomInsetRealignmentTask?.cancel()
                    bottomInsetRealignmentTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard Task.isCancelled == false else { return }
                        if didInitialScrollToBottom == false {
                            scrollToRelevantMessage(animated: false)
                            return
                        }
                        guard isNearBottom || pendingAutoScrollAfterOutgoingMessage else { return }
                        scrollToBottom(animated: false)
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(PrimeTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .onAppear {
                        logChatOpen("loader.appear")
                    }
            }

            if hasCompletedInitialMessageBootstrap, viewportRows.isEmpty {
                VStack(spacing: 14) {
                    Text(chatOpenFailureMessage ?? "No messages yet.")
                        .font(.body.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)

                    if chatOpenFailureMessage != nil {
                        Button("Retry") {
                            let sessionID = beginChatSession()
                            initialChatBootstrapTask = Task { @MainActor in
                                await runChatOpenSession(sessionID: sessionID)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .chatGlassCard(cornerRadius: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .zIndex(3)
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
                    let nextHeight = max(height, 76)
                    guard abs(topOverlayHeight - nextHeight) > 0.5 else { return }
                    DispatchQueue.main.async {
                        guard abs(topOverlayHeight - nextHeight) > 0.5 else { return }
                        topOverlayHeight = nextHeight
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

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
                    let nextHeight = max(height, 88)
                    guard abs(bottomOverlayHeight - nextHeight) > 0.5 else { return }
                    DispatchQueue.main.async {
                        guard abs(bottomOverlayHeight - nextHeight) > 0.5 else { return }
                        bottomOverlayHeight = nextHeight
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if let activeInlineReactionMessage,
               let messageFrame = messageMenuFrames[activeInlineReactionMessage.id] {
                MessageInlineReactionOverlay(
                    message: activeInlineReactionMessage,
                    frame: messageFrame,
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets,
                    onDismiss: closeInlineReactionPanel,
                    onOpenExpandedPicker: {
                        let message = activeInlineReactionMessage
                        closeInlineReactionPanel()
                        reactionPickerMessage = message
                    },
                    onSelectReaction: { emoji in
                        let message = activeInlineReactionMessage
                        closeInlineReactionPanel()
                        Task {
                            await toggleReaction(emoji, for: message)
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(99)
            }

            if let activeHoldMenuMessage,
               let messageFrame = messageMenuFrames[activeHoldMenuMessage.id],
               let renderedRow = renderedRows.first(where: { $0.id == activeHoldMenuMessage.id }) {
                MessageActionMenuOverlay(
                    chat: currentChat,
                    message: activeHoldMenuMessage,
                    replyMessage: renderedRow.replyMessageID.flatMap { visibleLookup[$0] },
                    currentUserID: appState.currentUser.id,
                    showsIncomingSenderName: renderedRow.showsIncomingSenderName,
                    showsTail: renderedRow.showsTail,
                    frame: messageFrame,
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets,
                    isOutgoing: activeHoldMenuMessage.senderID == appState.currentUser.id,
                    isPinned: pinnedMessageID == activeHoldMenuMessage.id,
                    canEdit: viewModel.canEdit(activeHoldMenuMessage, currentUserID: appState.currentUser.id),
                    canDelete: viewModel.canDelete(activeHoldMenuMessage, currentUserID: appState.currentUser.id),
                    hasReminder: reminderMessageIDs.contains(activeHoldMenuMessage.id),
                    hasFollowUpMark: followUpMessageIDs.contains(activeHoldMenuMessage.id),
                    showsUndoAction: shouldShowUndoAction(for: activeHoldMenuMessage),
                    canReport: activeHoldMenuMessage.senderID != appState.currentUser.id
                        && activeHoldMenuMessage.isDeleted == false
                        && currentChat.mode != .offline,
                    showsCommentsButton: currentChat.communityDetails?.kind == .channel
                        && currentChat.communityDetails?.commentsEnabled == true
                        && activeHoldMenuMessage.communityParentPostID == nil
                        && activeHoldMenuMessage.isDeleted == false,
                    commentCount: commentCount(for: activeHoldMenuMessage),
                    onDismiss: closeHoldMenu,
                    onOpenExpandedPicker: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        reactionPickerMessage = message
                    },
                    onSelectReaction: { emoji in
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        Task {
                            await toggleReaction(emoji, for: message)
                        }
                    },
                    onEdit: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        replyingToMessage = nil
                        viewModel.beginEditing(message)
                    },
                    onReply: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        beginReplying(to: message)
                    },
                    onForward: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        forwardingMessage = message
                        isShowingForwardSheet = true
                    },
                    onCopy: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        copyMessageContents(message)
                    },
                    onPin: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        Task {
                            await togglePin(for: message)
                        }
                    },
                    onReport: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        pendingReportMessage = message
                    },
                    onShowEditHistory: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        editHistoryMessage = message
                    },
                    onRemindLater: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        Task {
                            await scheduleReminder(for: message, after: 60 * 60)
                        }
                    },
                    onToggleFollowUp: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        Task {
                            await toggleReplyFollowUp(for: message)
                        }
                    },
                    onUndo: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
                        Task {
                            await undoMessageFromMenu(message)
                        }
                    },
                    onDelete: {
                        let message = activeHoldMenuMessage
                        closeHoldMenu()
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
                    jumpToLatestWindow()
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
                .disabled(isJumpingToLatestWindow)
                .opacity(isJumpingToLatestWindow ? 0.72 : 1)
                .padding(.trailing, PrimeTheme.Spacing.large)
                .padding(.bottom, bottomContentInset(safeAreaBottom: geometry.safeAreaInsets.bottom) + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if let visibleDayText, isShowingFloatingDayChip {
                ChatFloatingDayChip(text: visibleDayText)
                    .padding(.top, topContentInset(safeAreaTop: geometry.safeAreaInsets.top) + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .zIndex(90)
            }
        }
        .coordinateSpace(name: "chat-root")
    }

    var body: some View {
        GeometryReader { geometry in
            chatCanvas(geometry: geometry)
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
            logChatOpen(
                "view.appear",
                details: "selected=\(appState.selectedChat?.id.uuidString ?? "nil") visible=\(visibleMessages.count)"
            )
            applyNotificationLaunchContextIfNeeded()
            appState.selectedChat = currentChat
            consumeIncomingShareDraftIfNeeded()
            Task { @MainActor in
                await reportPremiumChatOpenIfNeeded()
            }
            refreshVisibleMessages(force: true, reason: "view_appear")
        }
        .onDisappear {
            transitionOpenPhase(.closed, sessionID: chatSessionID)
            logChatOpen("task.cancelled", details: "reason=view_disappear")
            let shouldPreserveSelection =
                appState.hasPendingNotificationLaunchRoute(for: currentChat.id)
                || appState.pendingNotificationRoute?.chatID == currentChat.id
                || appState.pendingResolvedNotificationChat?.id == currentChat.id

            if shouldPreserveSelection == false,
               appState.selectedChat?.id == currentChat.id {
                appState.selectedChat = nil
            }
            isChatScrollInteracting = false
            bottomInsetRealignmentTask?.cancel()
            keyboardOpenRealignmentTask?.cancel()
            foregroundRefreshTask?.cancel()
            presentationSyncTask?.cancel()
            attachmentPresentation.dismissAll()
            VideoPlaybackControllerRegistry.shared.stopAll()
            VoicePlaybackControllerRegistry.shared.stopAll()
            dayChipHideTask?.cancel()
            draftPersistenceTask?.cancel()
            typingStateEvaluationTask?.cancel()
            cancelSessionScopedTasks()
            remoteTypingResetTask?.cancel()
            localTypingIdleTask?.cancel()
            localTypingHeartbeatTask?.cancel()
            localTypingHeartbeatTask = nil
            notificationLaunchAnchorSuppressionUntil = .distantPast
            Task {
                await reportPremiumChatCloseIfNeeded()
                await stopLocalTypingIfNeeded(force: true)
                await ChatRealtimeService.shared.unsubscribe(
                    chatID: currentChat.id,
                    userID: appState.currentUser.id
                )
            }
            Task { @MainActor in
                await persistDraftImmediately()
                await persistReadingAnchorImmediately()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                await reportPremiumChatActivity(kind: "screenshot")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                await handleScreenRecordingStateChange()
            }
        }
        .onChange(of: appState.isSceneActive) { isActive in
            Task { @MainActor in
                if isActive {
                    await reportPremiumChatOpenIfNeeded()
                } else {
                    await reportPremiumChatCloseIfNeeded()
                }
            }
        }
        .onChange(of: currentChat) { newValue in
            appState.selectedChat = newValue
            consumeIncomingShareDraftIfNeeded()
        }
        .onChange(of: appState.incomingShareDraftRevision) { _ in
            consumeIncomingShareDraftIfNeeded()
        }
        .onChange(of: viewModel.draftText) { _ in
            scheduleDraftPersistence()
            scheduleTypingStateEvaluation()
        }
        .onChange(of: viewModel.editingMessage?.id) { _ in
            scheduleDraftPersistence()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingReachabilityChanged).receive(on: RunLoop.main)) { _ in
            if isSmartDirectChat {
                Task { @MainActor in
                    await refreshSmartTransportState(forceStartScanning: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingChatSnapshotsChanged).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                await refreshLocalSnapshotIfAppropriate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingIncomingChatPush).receive(on: RunLoop.main)) { notification in
            guard
                let userInfo = notification.userInfo,
                let route = NotificationChatRoute(userInfo: userInfo),
                route.chatID == currentChat.id,
                route.mode == currentChat.mode
            else {
                return
            }

            Task { @MainActor in
                if await ChatRealtimeService.shared.isLikelyConnected(userID: appState.currentUser.id) {
                    return
                }
                await refreshMessagesIfAppropriate(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                pendingForegroundRefreshAfterActivation = true
                foregroundInteractionGraceUntil = Date().addingTimeInterval(1.35)
                guard appState.isSceneActive else { return }
                pendingForegroundRefreshAfterActivation = false
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1350))
                    guard Task.isCancelled == false else { return }
                    foregroundInteractionGraceUntil = .distantPast
                    await runDeferredRefreshesIfNeeded()
                    await refreshMessagesIfAppropriate(force: true)
                }
            }
        }
        .onChange(of: appState.isSceneActive) { isSceneActive in
            guard isSceneActive, pendingForegroundRefreshAfterActivation else { return }
            Task { @MainActor in
                pendingForegroundRefreshAfterActivation = false
                foregroundInteractionGraceUntil = Date().addingTimeInterval(1.35)
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1350))
                    guard Task.isCancelled == false else { return }
                    foregroundInteractionGraceUntil = .distantPast
                    await runDeferredRefreshesIfNeeded()
                    await refreshMessagesIfAppropriate(force: true)
                }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            guard viewModel.messages.contains(where: { $0.selfDestructSeconds != nil }) else { return }
            selfDestructNow = value
        }
        #if !os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification).receive(on: RunLoop.main)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification).receive(on: RunLoop.main)) { _ in
            let shouldRealignBottom = isNearBottom || pendingAutoScrollAfterOutgoingMessage
            withAnimation(.easeOut(duration: 0.22)) {
                keyboardHeight = 0
            }
            if shouldRealignBottom {
                keyboardRealignmentRequest += 1
            }
            Task { @MainActor in
                await runDeferredRefreshesIfNeeded()
            }
        }
        #endif
        .task(id: currentChat.id) {
            let sessionID = beginChatSession()
            logChatOpen("task.begin")
            initialChatBootstrapTask = Task { @MainActor in
                await runChatOpenSession(sessionID: sessionID)
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
        .sheet(item: $editHistoryMessage) { message in
            NavigationStack {
                List {
                    ForEach(Array(message.editHistory.reversed())) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.text)
                                .font(.body)
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                .textSelection(.enabled)
                            Text(entry.editedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("Edit History")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .environmentObject(attachmentPresentation)
        .onChange(of: mediaPlaybackActivity.isPlaybackActive) { isActive in
            guard isActive == false else { return }
            Task {
                await runDeferredRefreshesIfNeeded()
            }
        }
        .onChange(of: viewModel.messageRevision) { _ in
            refreshVisibleMessages(reason: "message_revision")
            scheduleChatPresentationSync()
            if let activeHoldMenuMessage,
               visibleMessages.contains(where: { $0.id == activeHoldMenuMessage.id }) == false {
                closeHoldMenu()
            }
            if let activeInlineReactionMessage,
               visibleMessages.contains(where: { $0.id == activeInlineReactionMessage.id }) == false {
                closeInlineReactionPanel()
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
        .onChange(of: hiddenMessageIDs) { _ in
            refreshVisibleMessages(reason: "hidden_messages_changed")
        }
        .onChange(of: selfDestructNow) { _ in
            refreshVisibleMessages(reason: "self_destruct_tick")
        }
        .onChange(of: clearedThreadCutoff) { _ in
            refreshVisibleMessages(force: true, reason: "thread_cleared_cutoff_changed")
        }
        .onChange(of: callSummaryMessages) { _ in
            refreshVisibleMessages(force: true, reason: "call_summaries_changed")
        }
        .onChange(of: selectedCommunityTopicID) { _ in
            refreshVisibleMessages(force: true, reason: "community_topic_changed")
        }
        .onChange(of: selectedCommentPostID) { _ in
            refreshVisibleMessages(force: true, reason: "comment_thread_changed")
        }
        .onChange(of: currentChat.type) { _ in
            refreshVisibleMessages(force: true, reason: "chat_type_changed")
        }
        .onChange(of: currentChat.communityDetails?.kind) { _ in
            refreshVisibleMessages(force: true, reason: "community_kind_changed")
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

    private var openChatSafetyRefreshInterval: Duration {
        if AudioRecorderController.hasActiveRecording() {
            return .seconds(24)
        }
        return currentChat.mode == .offline ? .seconds(10) : .seconds(110)
    }

    @MainActor
    private func beginChatSession() -> UUID {
        let sessionID = UUID()
        chatSessionID = sessionID
        chatOpenFailureMessage = nil
        cancelSessionScopedTasks()
        resetChatSessionState()
        viewModel.beginSession(chat: currentChat, currentUserID: appState.currentUser.id, sessionID: sessionID)
        transitionOpenPhase(.opening, sessionID: sessionID, details: "selected=\(appState.selectedChat?.id.uuidString ?? "nil")")
        return sessionID
    }

    @MainActor
    private func cancelSessionScopedTasks() {
        initialChatBootstrapTask?.cancel()
        deferredInitialRefreshTask?.cancel()
        presentationSyncTask?.cancel()
        bottomInsetRealignmentTask?.cancel()
        keyboardOpenRealignmentTask?.cancel()
        foregroundRefreshTask?.cancel()
        draftPersistenceTask?.cancel()
        typingStateEvaluationTask?.cancel()
        dayChipHideTask?.cancel()
        realtimeMessageTask?.cancel()
        remoteTypingResetTask?.cancel()
        localTypingIdleTask?.cancel()
        localTypingHeartbeatTask?.cancel()
        scrollIdleFlushTask?.cancel()
    }

    @MainActor
    private func resetChatSessionState() {
        attachmentPresentation.dismissAll()
        VideoPlaybackControllerRegistry.shared.stopAll()
        VoicePlaybackControllerRegistry.shared.stopAll()
        didInitialScrollToBottom = false
        visibleDayText = nil
        isShowingFloatingDayChip = false
        lastViewportTopRowIndex = nil
        lastViewportTrimAnchorMessageID = nil
        lastViewportTrimAt = .distantPast
        pendingSearchMessageID = nil
        localFocusedMessageID = nil
        unreadAnchorMessageID = nil
        readingAnchorMessageID = nil
        topVisibleMessageID = nil
        isNearBottom = true
        isOfflineBannerVisible = true
        activeHoldMenuMessage = nil
        activeInlineReactionMessage = nil
        reactionPickerMessage = nil
        previousMessageIDs = []
        scrollInteractionGraceUntil = .distantPast
        lastServerReadMarkAttemptAt = nil
        lastPresenceRefreshUserID = nil
        lastPresenceRefreshAt = .distantPast
        lastCallSummaryRefreshChatID = nil
        lastCallSummaryRefreshAt = .distantPast
        foregroundInteractionGraceUntil = .distantPast
        replyingToMessage = nil
        pendingDeleteMessage = nil
        pendingReportMessage = nil
        forwardingMessage = nil
        contactProfile = nil
        isShowingContactProfile = false
        selectedCommunityTopicID = nil
        selectedCommentPostID = nil
        callSummaryMessages = []
        cachedVisibleMessages = []
        cachedVisibleMessageSignatures = []
        cachedVisibleLookup = [:]
        cachedVisibleMessageIDs = []
        cachedMergedBaseMessages = []
        cachedMergedBaseSignatures = []
        cachedMergedCallSummaryMessages = []
        cachedMergedCallSummarySignatures = []
        cachedMergedDisplayMessages = []
        cachedRenderRowInputs = []
        cachedRenderRowSignatures = []
        cachedRenderRows = []
        pendingTimelineRefreshReasons = []
        pendingTimelineRefreshForce = false
        pendingTimelineRefreshSessionID = nil
        isTimelineRefreshScheduled = false
        isApplyingTimelineRefresh = false
        remoteTypingResetTask = nil
        localTypingHeartbeatTask = nil
        scrollIdleFlushTask = nil
        isLocalTypingActive = false
        lastTypingSignalState = false
        lastTypingSignalAt = .distantPast
        prefersNotificationLaunchScroll = false
        notificationLaunchAnchorSuppressionUntil = .distantPast
        pendingDeferredMessageRefresh = false
        pendingDeferredSnapshotRefresh = false
        isViewportReady = false
        hasCompletedInitialMessageBootstrap = false
        viewportScrollCommand = nil
        viewportCommandToken = 0
        if isSmartDirectChat == false {
            smartTransportState = .unknown
            smartDeliveryConfidence = .waiting
            smartPreferredOfflinePath = nil
            smartShouldPreferOnline = false
        }
    }

    @MainActor
    private func runChatOpenSession(sessionID: UUID) async {
        guard isActiveSession(sessionID) else { return }
        await loadLocalPresentationState()
        guard isActiveSession(sessionID) else {
            transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=local_state_cancelled")
            return
        }
        applyNotificationLaunchContextIfNeeded()

        transitionOpenPhase(.loadingInitialMessages, sessionID: sessionID)
        let localStartedAt = CACurrentMediaTime()
        logChatOpen("localLoad.begin")
        let hydrateCompleted = await hydrateInitialMessagesWithTimeout(sessionID: sessionID)
        guard isActiveSession(sessionID) else {
            transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=hydrate_cancelled")
            return
        }
        let localDurationMs = Int(((CACurrentMediaTime() - localStartedAt) * 1000).rounded())
        logChatOpen(
            "localLoad.end",
            details: "completed=\(hydrateCompleted) durationMs=\(localDurationMs) count=\(viewModel.messages.count)"
        )

        unreadAnchorMessageID = await ChatReadStateStore.shared.firstUnreadMessageID(
            for: currentChat,
            messages: viewModel.messages,
            currentUserID: appState.currentUser.id
        )
        guard isActiveSession(sessionID) else {
            transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=unread_anchor_cancelled")
            return
        }
        lastPersistedDraftText = viewModel.draftText
        previousMessageIDs = viewModel.messageIDs
        refreshVisibleMessages(force: true, reason: "bootstrap_local")
        drainTimelineProjectionRefreshes()
        logChatOpen(
            "bootstrap.initialRows.ready",
            details: "source=local count=\(viewModel.messages.count)"
        )

        if viewModel.messages.isEmpty == false, isViewportReady == false {
            hasCompletedInitialMessageBootstrap = true
            transitionOpenPhase(.initialMessagesReady, sessionID: sessionID, details: "source=local count=\(viewModel.messages.count)")
            transitionOpenPhase(.applyingInitialSnapshot, sessionID: sessionID, details: "source=local")
            logChatOpen("viewport.applyInitial.begin", details: "source=local rows=\(cachedRenderRows.count)")
            initialScrollRecoveryToken &+= 1
            scheduleViewportReadyTimeout(sessionID: sessionID)
        }

        if viewModel.messages.isEmpty {
            let remoteStartedAt = CACurrentMediaTime()
            logChatOpen("remoteLoad.begin", details: "reason=no_local_messages")
            await viewModel.refreshMessages(
                chat: currentChat,
                repository: environment.chatRepository,
                currentUserID: appState.currentUser.id,
                sessionID: sessionID
            )
            guard isActiveSession(sessionID) else {
                transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=remote_load_cancelled")
                return
            }
            let remoteDurationMs = Int(((CACurrentMediaTime() - remoteStartedAt) * 1000).rounded())
            logChatOpen(
                "remoteLoad.end",
                details: "durationMs=\(remoteDurationMs) count=\(viewModel.messages.count)"
            )
            refreshVisibleMessages(force: true, reason: "bootstrap_remote")
            drainTimelineProjectionRefreshes()
            logChatOpen(
                "bootstrap.initialRows.ready",
                details: "source=remote count=\(viewModel.messages.count)"
            )
            hasCompletedInitialMessageBootstrap = true
            initialScrollRecoveryToken &+= 1
            scheduleViewportReadyTimeout(sessionID: sessionID)

            if viewModel.messages.isEmpty {
                chatOpenFailureMessage = "This chat is empty right now."
                completeInitialViewportAlignment()
                transitionOpenPhase(.failedButRecoverable, sessionID: sessionID, details: "reason=empty_after_remote")
            } else if isViewportReady == false {
                transitionOpenPhase(.initialMessagesReady, sessionID: sessionID, details: "source=remote count=\(viewModel.messages.count)")
                transitionOpenPhase(.applyingInitialSnapshot, sessionID: sessionID, details: "source=remote")
                logChatOpen("viewport.applyInitial.begin", details: "source=remote rows=\(cachedRenderRows.count)")
            }
        }

        guard isActiveSession(sessionID) else {
            transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=before_realtime")
            return
        }

        transitionOpenPhase(.realtimeStarting, sessionID: sessionID)
        await startRealtimeSubscriptionIfNeeded(sessionID: sessionID)
        guard isActiveSession(sessionID) else {
            transitionOpenPhase(.cancelled, sessionID: sessionID, details: "reason=after_realtime_start")
            return
        }
        logChatOpen("bootstrap.realtime.started")

        deferredInitialRefreshTask = Task { @MainActor in
            await runDeferredBootstrapSession(sessionID: sessionID)
        }

        while Task.isCancelled == false, isActiveSession(sessionID) {
            try? await Task.sleep(for: openChatSafetyRefreshInterval)
            guard isActiveSession(sessionID) else { return }
            await refreshMessagesIfAppropriate(force: false)
            if isSmartDirectChat {
                await refreshSmartTransportState(forceStartScanning: false)
            }
        }
    }

    @MainActor
    private func runDeferredBootstrapSession(sessionID: UUID) async {
        await Task.yield()
        guard isActiveSession(sessionID) else { return }
        logChatOpen("bootstrap.deferred.begin")
        if isSmartDirectChat {
            await refreshSmartTransportState(forceStartScanning: true)
        }
        guard isActiveSession(sessionID) else { return }
        await refreshMessagesIfAppropriate(force: true)
        guard isActiveSession(sessionID) else { return }
        await refreshDirectContactProfileIfNeeded()
        guard isActiveSession(sessionID) else { return }
        await syncChatPresentationAndReadState()
        initialScrollRecoveryToken &+= 1
        if chatOpenPhase != .failedButRecoverable {
            transitionOpenPhase(.active, sessionID: sessionID, details: "messages=\(viewModel.messages.count)")
        }
        logChatOpen(
            "bootstrap.deferred.end",
            details: "messages=\(viewModel.messages.count) visible=\(visibleMessages.count)"
        )
    }

    @MainActor
    private func scheduleViewportReadyTimeout(sessionID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard isActiveSession(sessionID) else { return }
            guard isViewportReady == false else { return }
            logChatOpen("viewport.ready.timeout", details: "forcingTransitionCompletion=true")
            completeInitialViewportAlignment()
        }
    }

    @MainActor
    private func hydrateInitialMessagesWithTimeout(sessionID: UUID) async -> Bool {
        logChatOpen("hydrate.timeout.begin")
        let hydrateTask = Task { @MainActor in
            await viewModel.hydrateMessages(
                chat: currentChat,
                repository: environment.chatRepository,
                localStore: environment.localStore,
                currentUserID: appState.currentUser.id,
                sessionID: sessionID
            )
            return true
        }

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await hydrateTask.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if completed == false {
            hydrateTask.cancel()
        }
        logChatOpen(
            "hydrate.timeout.end",
            details: "completed=\(completed) messages=\(viewModel.messages.count)"
        )
        return completed
    }

    @MainActor
    private func startRealtimeSubscriptionIfNeeded(sessionID: UUID) async {
        realtimeMessageTask?.cancel()
        realtimeMessageTask = nil

        guard currentChat.mode == .online else { return }

        logChatOpen("realtime.start.begin", details: "session=\(sessionID.uuidString)")
        await ChatRealtimeService.shared.subscribe(
            chatID: currentChat.id,
            userID: appState.currentUser.id,
            mode: currentChat.mode
        )
        await ChatRealtimeService.shared.sendPresenceHeartbeat(
            userID: appState.currentUser.id,
            mode: currentChat.mode,
            force: true
        )

        let stream = await ChatRealtimeService.shared.stream(
            for: appState.currentUser.id,
            mode: currentChat.mode
        )
        realtimeMessageTask = Task { @MainActor in
            defer {
                logChatOpen(
                    "realtime.start.end",
                    details: "reason=\(Task.isCancelled ? "cancelled" : "stream_completed")"
                )
            }
            for await event in stream {
                guard Task.isCancelled == false else { return }
                guard isActiveSession(sessionID) else { return }
                await handleRealtimeEvent(event)
            }
        }
    }

    @MainActor
    private func handleRealtimeEvent(_ event: RealtimeChatEvent) async {
        guard currentChat.mode == .online else { return }
        if let eventMode = event.mode, eventMode != .online {
            return
        }
        if let eventChatID = event.chatID, eventChatID != currentChat.id {
            return
        }

        if event.type == "typing.started"
            || event.type == "typing.stopped"
            || event.type == "presence.updated" {
            await applyRealtimePresenceEvent(event)
        }

        if let eventChat = event.chat, eventChat.id == currentChat.id {
            currentChat = eventChat
            await ChatSnapshotStore.shared.upsertChat(
                eventChat,
                userID: appState.currentUser.id,
                mode: eventChat.mode
            )
        }
        if let message = event.message, message.chatID == currentChat.id {
            viewModel.replaceOrAppend(message)
            await ChatSnapshotStore.shared.upsertMessage(
                message,
                in: currentChat,
                userID: appState.currentUser.id,
                mode: currentChat.mode
            )
            await ChatMessagePageStore.shared.upsertMessages(
                [message],
                chatID: currentChat.id,
                userID: appState.currentUser.id,
                mode: currentChat.mode
            )
            scheduleChatPresentationSync(delay: .milliseconds(90))
        }
        if event.type == "chat.resync_required" {
            await refreshMessagesIfAppropriate(force: true)
        }
    }

    @MainActor
    private func refreshLocalSnapshotIfAppropriate() async {
        if AudioRecorderController.hasActiveRecording() {
            pendingDeferredSnapshotRefresh = true
            return
        }
        if isChatScrollRecentlyActive {
            pendingDeferredSnapshotRefresh = true
            return
        }
        if mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 1.5) {
            pendingDeferredSnapshotRefresh = true
            return
        }

        pendingDeferredSnapshotRefresh = false
        let sessionID = chatSessionID
        logChatTimeline("snapshot.refresh.begin", details: "reason=local_snapshot")
        await viewModel.refreshLocalSnapshot(
            chat: currentChat,
            repository: environment.chatRepository,
            currentUserID: appState.currentUser.id,
            sessionID: sessionID
        )
        guard isActiveSession(sessionID) else {
            logChatOpen("task.cancelled", details: "reason=local_snapshot_stale")
            return
        }
        await syncChatPresentationAndReadState()
        refreshVisibleMessages(force: true, reason: "local_snapshot_refresh")
    }

    @MainActor
    private func refreshMessagesIfAppropriate(force: Bool = false) async {
        if AudioRecorderController.hasActiveRecording() {
            pendingDeferredMessageRefresh = true
            return
        }
        if isChatScrollRecentlyActive {
            pendingDeferredMessageRefresh = true
            return
        }
        if keyboardHeight > 0 || Date() < foregroundInteractionGraceUntil {
            pendingDeferredMessageRefresh = true
            return
        }
        if force == false, mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 2.0) {
            pendingDeferredMessageRefresh = true
            return
        }

        pendingDeferredMessageRefresh = false
        logChatOpen("remoteLoad.begin", details: "force=\(force)")
        let sessionID = chatSessionID
        Task { @MainActor in
            guard isActiveSession(sessionID) else { return }
            await refreshPresenceIfNeeded()
        }
        await viewModel.refreshMessages(
            chat: currentChat,
            repository: environment.chatRepository,
            currentUserID: appState.currentUser.id,
            sessionID: sessionID
        )
        guard isActiveSession(sessionID) else {
            logChatOpen("task.cancelled", details: "reason=remote_refresh_stale")
            return
        }
        await refreshCurrentChatMetadataIfNeeded()
        guard isActiveSession(sessionID) else {
            logChatOpen("task.cancelled", details: "reason=metadata_refresh_stale")
            return
        }
        await syncChatPresentationAndReadState()
        guard isActiveSession(sessionID) else {
            logChatOpen("task.cancelled", details: "reason=read_state_refresh_stale")
            return
        }
        await refreshCallSummaries()
        guard isActiveSession(sessionID) else {
            logChatOpen("task.cancelled", details: "reason=call_summary_refresh_stale")
            return
        }
        refreshVisibleMessages(force: true, reason: force ? "remote_refresh_forced" : "remote_refresh")
        logChatOpen("remoteLoad.end", details: "force=\(force) messages=\(viewModel.messages.count)")
    }

    @MainActor
    private func runDeferredRefreshesIfNeeded() async {
        guard mediaPlaybackActivity.shouldDeferChatRefresh(gracePeriod: 1.25) == false else { return }
        guard isChatScrollRecentlyActive == false else { return }

        if pendingDeferredSnapshotRefresh {
            await refreshLocalSnapshotIfAppropriate()
        }

        if pendingDeferredMessageRefresh {
            await refreshMessagesIfAppropriate(force: true)
        }
    }

    @MainActor
    private func refreshCallSummaries() async {
        guard currentChat.mode != .offline else {
            if callSummaryMessages.isEmpty == false {
                callSummaryMessages = []
            }
            return
        }

        guard currentChat.type == .direct || currentChat.type == .group else {
            callSummaryMessages = []
            return
        }

        let now = Date()
        if lastCallSummaryRefreshChatID == currentChat.id,
           now.timeIntervalSince(lastCallSummaryRefreshAt) < 12 {
            return
        }
        lastCallSummaryRefreshChatID = currentChat.id
        lastCallSummaryRefreshAt = now

        guard let callHistory = try? await environment.callRepository.fetchCallHistory(for: appState.currentUser.id) else {
            return
        }

        let relevantCalls = callHistory.filter { call in
            call.chatID == currentChat.id
                && (call.state == .ended || call.state == .cancelled || call.state == .rejected || call.state == .missed)
        }

        let mappedMessages = relevantCalls.map { call in
            makeCallSummaryMessage(from: call)
        }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        if mappedMessages != callSummaryMessages {
            callSummaryMessages = mappedMessages
        }
    }

    private func makeCallSummaryMessage(from call: InternetCall) -> Message {
        let direction = call.direction(for: appState.currentUser.id)
        let effectiveState = call.effectiveState(for: appState.currentUser.id)
        let durationSeconds = resolvedCallDurationSeconds(for: call)
        let payload = ChatCallSummaryCodec.Payload(
            state: effectiveState,
            direction: direction,
            durationSeconds: durationSeconds
        )

        let summaryText = ChatCallSummaryCodec.encode(payload)
        let senderID: UUID
        if call.isGroupCall {
            senderID = call.callerID
        } else {
            senderID = direction == .outgoing
                ? appState.currentUser.id
                : (call.otherParticipant(for: appState.currentUser.id)?.id ?? call.callerID)
        }

        return Message(
            id: call.id,
            chatID: currentChat.id,
            senderID: senderID,
            clientMessageID: call.id,
            senderDisplayName: nil,
            mode: currentChat.mode,
            deliveryState: .online,
            deliveryRoute: .online,
            kind: .system,
            text: summaryText,
            attachments: [],
            replyToMessageID: nil,
            replyPreview: nil,
            communityContext: nil,
            deliveryOptions: MessageDeliveryOptions(),
            status: .sent,
            createdAt: call.activityDate,
            editedAt: nil,
            deletedForEveryoneAt: nil,
            reactions: [],
            voiceMessage: nil,
            liveLocation: nil
        )
    }

    private func resolvedCallDurationSeconds(for call: InternetCall) -> Int {
        guard let answeredAt = call.answeredAt else { return 0 }
        let endDate = call.endedAt ?? Date.now
        return max(Int(endDate.timeIntervalSince(answeredAt)), 0)
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

    @MainActor
    private func applyNotificationLaunchContextIfNeeded() {
        guard let route = appState.consumeNotificationLaunchRoute(for: currentChat.id) else { return }
        prefersNotificationLaunchScroll = true
        notificationLaunchAnchorSuppressionUntil = Date().addingTimeInterval(2.4)
        unreadAnchorMessageID = nil
        readingAnchorMessageID = nil
        localFocusedMessageID = route.messageID
    }

    private func issueViewportCommand(_ action: ChatMessageViewportCommand.Action) {
        viewportCommandToken &+= 1
        viewportScrollCommand = ChatMessageViewportCommand(token: viewportCommandToken, action: action)
    }

    private func consumeViewportCommandIfNeeded(token: Int) {
        guard viewportScrollCommand?.token == token else { return }
        let consumedKind = viewportScrollCommand.map { command in
            switch command.action {
            case .scrollToBottom:
                return "initialScrollToBottom"
            case .scrollToMessage:
                return "scrollToMessage"
            }
        } ?? "none"
        viewportScrollCommand = nil
        print("PUSHTRACE ChatViewport step=command.consumed main=\(Thread.isMainThread) kind=\(consumedKind) token=\(token)")
    }

    private func scrollToRelevantMessage(animated: Bool) {
        if prefersNotificationLaunchScroll {
            if scrollToPendingMessageIfNeeded(
                animated: false,
                preferBottomAnchorForRecentNotificationMessage: true
            ) {
                didInitialScrollToBottom = true
                notificationLaunchAnchorSuppressionUntil = Date().addingTimeInterval(1.2)
                prefersNotificationLaunchScroll = false
                completeInitialViewportAlignment()
                return
            }

            guard visibleMessages.isEmpty == false else { return }
            didInitialScrollToBottom = true
            notificationLaunchAnchorSuppressionUntil = Date().addingTimeInterval(1.2)
            prefersNotificationLaunchScroll = false
            scrollToBottom(animated: false)
            completeInitialViewportAlignment()
            return
        }

        if scrollToUnreadAnchorIfNeeded(animated: false) {
            completeInitialViewportAlignment()
            return
        }

        if scrollToReadingAnchorIfNeeded(animated: false) {
            completeInitialViewportAlignment()
            return
        }

        if scrollToPendingMessageIfNeeded(animated: animated) {
            completeInitialViewportAlignment()
            return
        }

        guard visibleMessages.isEmpty == false else { return }

        guard didInitialScrollToBottom == false else { return }
        didInitialScrollToBottom = true
        scrollToBottom(animated: animated)
        completeInitialViewportAlignment()
    }

    private func completeInitialViewportAlignment() {
        guard isViewportReady == false else { return }
        Task { @MainActor in
            await Task.yield()
            guard isViewportReady == false else { return }
            if isJumpingToLatestWindow {
                isViewportReady = true
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isViewportReady = true
                }
            }
            logChatOpen(
                "bootstrap.visible.ready",
                details: "viewportRows=\(cachedRenderRows.count) visible=\(visibleMessages.count)"
            )
        }
    }

    private func scrollToPendingMessageIfNeeded(
        animated: Bool = true,
        preferBottomAnchorForRecentNotificationMessage: Bool = false
    ) -> Bool {
        if localFocusedMessageID == nil {
            localFocusedMessageID = appState.consumeFocusedMessageID(for: currentChat.id)
        }

        guard let targetMessageID = localFocusedMessageID else {
            return false
        }

        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            return false
        }

        let scrollAnchor: ChatMessageViewportScrollAnchor
        if preferBottomAnchorForRecentNotificationMessage,
           let targetIndex = visibleMessages.firstIndex(where: { $0.id == targetMessageID }),
           targetIndex >= max(0, visibleMessages.count - 8) {
            scrollAnchor = .bottom
        } else {
            scrollAnchor = .center
        }

        issueViewportCommand(.scrollToMessage(targetMessageID, anchor: scrollAnchor, animated: animated))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if localFocusedMessageID == targetMessageID {
                localFocusedMessageID = nil
            }
        }
        return true
    }

    private func scrollToUnreadAnchorIfNeeded(animated: Bool = true) -> Bool {
        if Date() < notificationLaunchAnchorSuppressionUntil {
            return false
        }
        guard let targetMessageID = unreadAnchorMessageID else { return false }
        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            unreadAnchorMessageID = nil
            return false
        }

        didInitialScrollToBottom = true
        issueViewportCommand(.scrollToMessage(targetMessageID, anchor: .top, animated: animated))
        unreadAnchorMessageID = nil
        return true
    }

    private func scrollToReadingAnchorIfNeeded(animated: Bool = true) -> Bool {
        if Date() < notificationLaunchAnchorSuppressionUntil {
            return false
        }
        guard let targetMessageID = readingAnchorMessageID else { return false }
        guard visibleMessages.contains(where: { $0.id == targetMessageID }) else {
            readingAnchorMessageID = nil
            return false
        }

        didInitialScrollToBottom = true
        issueViewportCommand(.scrollToMessage(targetMessageID, anchor: .top, animated: animated))
        readingAnchorMessageID = nil
        return true
    }

    private func scrollToBottom(animated: Bool = true) {
        dayChipHideTask?.cancel()
        isNearBottom = true
        topVisibleMessageID = nil
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingFloatingDayChip = false
        }

        issueViewportCommand(.scrollToBottom(animated: animated))
    }

    private func jumpToLatestWindow() {
        guard isJumpingToLatestWindow == false else { return }
        isJumpingToLatestWindow = true
        dayChipHideTask?.cancel()
        isShowingFloatingDayChip = false
        topVisibleMessageID = nil
        isNearBottom = true
        didInitialScrollToBottom = false
        isViewportReady = false

        Task { @MainActor in
            await viewModel.jumpToLatestWindow(
                chat: currentChat,
                currentUserID: appState.currentUser.id,
                sessionID: chatSessionID
            )
            previousMessageIDs = viewModel.messageIDs
            didInitialScrollToBottom = true
            issueViewportCommand(.scrollToBottom(animated: false))
            completeInitialViewportAlignment()
            isJumpingToLatestWindow = false
        }
    }

    private func collapseLoadedHistoryNearBottomIfNeeded() {
        guard didInitialScrollToBottom else { return }
        guard isJumpingToLatestWindow == false else { return }
        guard isCollapsingLoadedHistory == false else { return }
        guard viewModel.messages.count > ChatViewModel.Paging.autoCollapseWindowThreshold else { return }

        isCollapsingLoadedHistory = true
        Task { @MainActor in
            await viewModel.collapseToLatestWindowIfNeeded(
                chat: currentChat,
                currentUserID: appState.currentUser.id,
                sessionID: chatSessionID
            )
            previousMessageIDs = viewModel.messageIDs
            issueViewportCommand(.scrollToBottom(animated: false))
            isCollapsingLoadedHistory = false
        }
    }

    private func handleMessageListChange(oldIDs: [UUID]) {
        if isJumpingToLatestWindow {
            return
        }
        if scrollToPendingMessageIfNeeded(
            animated: !prefersNotificationLaunchScroll,
            preferBottomAnchorForRecentNotificationMessage: prefersNotificationLaunchScroll
        ) {
            if prefersNotificationLaunchScroll {
                didInitialScrollToBottom = true
                prefersNotificationLaunchScroll = false
            }
            return
        }

        if didInitialScrollToBottom == false {
            scrollToRelevantMessage(animated: false)
            return
        }

        let newIDs = viewModel.messageIDs
        let oldIDSet = Set(oldIDs)
        let hasInsertedMessages = newIDs.contains(where: { oldIDSet.contains($0) == false })

        if pendingAutoScrollAfterOutgoingMessage {
            pendingAutoScrollAfterOutgoingMessage = false
            if hasInsertedMessages || isNearBottom {
                scrollToBottom()
            }
            return
        }

        if hasInsertedMessages, isNearBottom {
            scrollToBottom()
        }
    }

    private func messageRenderRows(from inputs: [MessageRenderRowInput]) -> [MessageRenderRow] {
        guard inputs.isEmpty == false else { return [] }

        return inputs.enumerated().map { index, input in
            let previousInput = index > 0 ? inputs[index - 1] : nil
            let nextInput = index + 1 < inputs.count ? inputs[index + 1] : nil
            let isOutgoing = input.senderID == appState.currentUser.id

            let isGroupedWithPrevious: Bool = {
                guard let previousInput else { return false }
                return isGroupedMessage(input, with: previousInput)
            }()

            let isGroupedWithNext: Bool = {
                guard let nextInput else { return false }
                return isGroupedMessage(input, with: nextInput)
            }()

            let messageDate = Date(timeIntervalSinceReferenceDate: input.createdAt)
            let showsDayDivider: Bool = {
                guard let previousInput else { return true }
                let previousDate = Date(timeIntervalSinceReferenceDate: previousInput.createdAt)
                return Calendar.autoupdatingCurrent.isDate(messageDate, inSameDayAs: previousDate) == false
            }()

            let showsIncomingSenderName = currentChat.type == .group
                && currentChat.communityDetails?.kind != .channel
                && isOutgoing == false
                && isGroupedWithPrevious == false

            let showsIncomingAvatar = currentChat.type == .group
                && currentChat.communityDetails?.kind != .channel
                && isOutgoing == false
                && isGroupedWithNext == false

            return MessageRenderRow(
                id: input.id,
                messageID: input.id,
                messageCreatedAt: messageDate,
                replyMessageID: input.replyToMessageID,
                showsDayDivider: showsDayDivider,
                showsIncomingSenderName: showsIncomingSenderName,
                showsIncomingAvatar: showsIncomingAvatar,
                showsTail: isGroupedWithNext == false,
                bottomSpacing: isGroupedWithNext
                    ? PrimeTheme.Spacing.medium / 4
                    : PrimeTheme.Spacing.medium / 2
            )
        }
    }

    private func messageRenderRowInputs(from messages: [Message]) -> [MessageRenderRowInput] {
        messages.map { message in
            let reactionFingerprint = ChatView.makeReactionFingerprint(from: message.reactions)
            return MessageRenderRowInput(
                id: message.id,
                senderID: message.senderID,
                createdAt: message.createdAt.timeIntervalSinceReferenceDate,
                replyToMessageID: message.replyToMessageID,
                editedAt: message.editedAt?.timeIntervalSinceReferenceDate,
                textHash: message.text?.hashValue ?? 0,
                isDeleted: message.isDeleted,
                reactionFingerprint: reactionFingerprint
            )
        }
    }

    private nonisolated static func makeReactionFingerprint(from reactions: [MessageReaction]) -> Int {
        var hasher = Hasher()
        for reaction in reactions.sorted(by: { lhs, rhs in
            if lhs.emoji != rhs.emoji {
                return lhs.emoji < rhs.emoji
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }) {
            hasher.combine(reaction.id)
            hasher.combine(reaction.emoji)
            hasher.combine(reaction.userIDs.sorted(by: { $0.uuidString < $1.uuidString }))
        }
        return hasher.finalize()
    }

    private func refreshVisibleMessages(force: Bool = false, reason: String = "unspecified") {
        scheduleTimelineProjectionRefresh(force: force, reason: reason)
    }

    private func scheduleTimelineProjectionRefresh(force: Bool, reason: String) {
        let hadPending = pendingTimelineRefreshSessionID != nil
        pendingTimelineRefreshReasons.insert(reason)
        pendingTimelineRefreshForce = pendingTimelineRefreshForce || force
        pendingTimelineRefreshSessionID = chatSessionID
        if shouldDeferTimelineRefresh(reason: reason) {
            logChatTimeline(
                "update.deferred",
                details: "reason=\(reason) force=\(force) because=scrolling pendingReasons=\(pendingTimelineRefreshReasons.count)"
            )
            scheduleScrollIdleFlush()
            return
        }
        logChatTimeline(
            hadPending ? "update.coalesced" : "update.scheduled",
            details: "reason=\(reason) force=\(force) pendingReasons=\(pendingTimelineRefreshReasons.count)"
        )

        guard isTimelineRefreshScheduled == false else { return }
        isTimelineRefreshScheduled = true
        DispatchQueue.main.async {
            isTimelineRefreshScheduled = false
            drainTimelineProjectionRefreshes()
        }
    }

    private func drainTimelineProjectionRefreshes() {
        guard isApplyingTimelineRefresh == false else {
            logChatTimeline("singleFlight.locked", details: "pendingReasons=\(pendingTimelineRefreshReasons.count)")
            return
        }

        isApplyingTimelineRefresh = true
        defer {
            isApplyingTimelineRefresh = false
            logChatTimeline("unlock", details: "pendingReasons=\(pendingTimelineRefreshReasons.count)")
        }

        while let scheduledSessionID = pendingTimelineRefreshSessionID {
            let reasons = pendingTimelineRefreshReasons
            let shouldForce = pendingTimelineRefreshForce
            pendingTimelineRefreshSessionID = nil
            pendingTimelineRefreshReasons = []
            pendingTimelineRefreshForce = false

            guard scheduledSessionID == chatSessionID else {
                logChatTimeline(
                    "update.cancelled",
                    details: "reason=stale_session scheduledSession=\(scheduledSessionID.uuidString)"
                )
                continue
            }

            performVisibleMessagesRefresh(force: shouldForce, reasons: reasons)
        }
    }

    private func performVisibleMessagesRefresh(force: Bool, reasons: Set<String>) {
        let startedAt = CACurrentMediaTime()
        let reasonList = reasons.sorted().joined(separator: ",")
        logChatTimeline(
            "update.begin",
            details: "force=\(force) reasons=\(reasonList) visible=\(cachedVisibleMessages.count) base=\(viewModel.messages.count)"
        )

        refreshMergedDisplayMessages(force: force)
        let nextVisibleMessages = buildVisibleMessages()
        let nextVisibleSignatures = nextVisibleMessages.map {
            VisibleMessageSignature(message: $0, relativeTo: selfDestructNow)
        }

        guard nextVisibleSignatures != cachedVisibleMessageSignatures else {
            skippedTimelineRefreshCount += 1
            logChatTimeline(
                "dedupe.skip",
                details: "reason=sameVisibleSignature rows=\(nextVisibleMessages.count) skipped=\(skippedTimelineRefreshCount)"
            )
            return
        }

        cachedVisibleMessages = nextVisibleMessages
        cachedVisibleMessageSignatures = nextVisibleSignatures
        cachedVisibleLookup = Dictionary(uniqueKeysWithValues: nextVisibleMessages.map { ($0.id, $0) })
        cachedVisibleMessageIDs = nextVisibleMessages.map(\.id)
        refreshCachedRenderRows()

        let durationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
        logChatTimeline(
            "update.completed",
            details: "rows=\(nextVisibleMessages.count) durationMs=\(durationMs) reasons=\(reasonList)"
        )
        logSlowChatPhase("refreshVisibleMessages", startedAt: startedAt, count: nextVisibleMessages.count)
    }

    private func refreshMergedDisplayMessages(force: Bool = false) {
        let startTime = CACurrentMediaTime()
        let baseMessages = viewModel.messages
        let summaryMessages = callSummaryMessages
        let baseSignatures = baseMessages.map(MergedMessageSignature.init)
        let summarySignatures = summaryMessages.map(MergedMessageSignature.init)
        guard force || baseSignatures != cachedMergedBaseSignatures || summarySignatures != cachedMergedCallSummarySignatures else {
            return
        }

        cachedMergedBaseMessages = baseMessages
        cachedMergedBaseSignatures = baseSignatures
        cachedMergedCallSummaryMessages = summaryMessages
        cachedMergedCallSummarySignatures = summarySignatures

        guard summaryMessages.isEmpty == false else {
            cachedMergedDisplayMessages = baseMessages
            logSlowChatPhase("refreshMergedDisplayMessages", startedAt: startTime, count: baseMessages.count)
            return
        }

        var byClientMessageID = Dictionary(uniqueKeysWithValues: baseMessages.map { ($0.clientMessageID, $0) })
        for callSummary in summaryMessages {
            byClientMessageID[callSummary.clientMessageID] = callSummary
        }

        cachedMergedDisplayMessages = byClientMessageID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            if lhs.id != rhs.id {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.clientMessageID.uuidString < rhs.clientMessageID.uuidString
        }
        logSlowChatPhase("refreshMergedDisplayMessages", startedAt: startTime, count: cachedMergedDisplayMessages.count)
    }

    private func refreshCachedRenderRows(force: Bool = false) {
        let startTime = CACurrentMediaTime()
        let inputs = messageRenderRowInputs(from: visibleMessages)
        let signatures = inputs.map(MessageRenderRowSignature.init)
        guard force || signatures != cachedRenderRowSignatures else { return }
        cachedRenderRowInputs = inputs
        cachedRenderRowSignatures = signatures
        cachedRenderRows = messageRenderRows(from: inputs)
        logSlowChatPhase("refreshCachedRenderRows", startedAt: startTime, count: inputs.count)
    }

    private func isGroupedMessage(_ lhs: MessageRenderRowInput, with rhs: MessageRenderRowInput) -> Bool {
        lhs.senderID == rhs.senderID
            && Calendar.autoupdatingCurrent.isDate(
                Date(timeIntervalSinceReferenceDate: lhs.createdAt),
                inSameDayAs: Date(timeIntervalSinceReferenceDate: rhs.createdAt)
            )
    }

    private func updateBottomAnchorVisibility(isVisible: Bool) {
        if isVisible, isNearBottom == false {
            isNearBottom = true
        }
    }

    private func updateVisibleDayFromViewport(
        topVisibleRowID: UUID?,
        rowMap: [UUID: MessageRenderRow],
        rowOrderMap: [UUID: Int]
    ) {
        guard let topVisibleRowID, let visibleRow = rowMap[topVisibleRowID] else {
            if visibleDayText != nil {
                visibleDayText = nil
            }
            if topVisibleMessageID != nil {
                topVisibleMessageID = nil
            }
            lastViewportTopRowIndex = nil
            dayChipHideTask?.cancel()
            if isShowingFloatingDayChip {
                isShowingFloatingDayChip = false
            }
            return
        }

        let topVisibleChanged = topVisibleMessageID != visibleRow.id
        let previousTopRowIndex = lastViewportTopRowIndex
        let nextTopRowIndex = rowOrderMap[visibleRow.id]
        if topVisibleChanged {
            topVisibleMessageID = visibleRow.id
        }
        lastViewportTopRowIndex = nextTopRowIndex

        let nextVisibleDayText = contextualDayText(for: visibleRow.messageCreatedAt)
        if visibleDayText != nextVisibleDayText {
            visibleDayText = nextVisibleDayText
        }

        if let previousTopRowIndex,
           let nextTopRowIndex,
           nextTopRowIndex > previousTopRowIndex {
            trimLoadedHistoryWhileScrollingDownIfNeeded(anchorMessageID: visibleRow.id)
        }

        guard isNearBottom == false else {
            dayChipHideTask?.cancel()
            if isShowingFloatingDayChip {
                withAnimation(.easeOut(duration: 0.18)) {
                    isShowingFloatingDayChip = false
                }
            }
            return
        }

        if isShowingFloatingDayChip == false || topVisibleChanged {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingFloatingDayChip = true
            }
            scheduleDayChipHide()
        }
    }

    private func updateVisibleDay(
        from frames: [UUID: CGRect],
        rows: [MessageRenderRow],
        viewportHeight: CGFloat,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) {
        let visibleTop = max(topContentInset(safeAreaTop: safeAreaTop) - 8, 0)
        let visibleBottom = max(
            viewportHeight - bottomContentInset(safeAreaBottom: safeAreaBottom) + 18,
            visibleTop + 1
        )

        guard let visibleRow = rows.first(where: { row in
            guard let frame = frames[row.id] else { return false }
            return frame.maxY >= visibleTop && frame.minY <= visibleBottom
        }) else {
            if visibleDayText != nil {
                visibleDayText = nil
            }
            if topVisibleMessageID != nil {
                topVisibleMessageID = nil
            }
            dayChipHideTask?.cancel()
            if isShowingFloatingDayChip {
                isShowingFloatingDayChip = false
            }
            return
        }

        let topVisibleChanged = topVisibleMessageID != visibleRow.id
        if topVisibleChanged {
            topVisibleMessageID = visibleRow.id
        }

        let nextVisibleDayText = contextualDayText(for: visibleRow.messageCreatedAt)
        if visibleDayText != nextVisibleDayText {
            visibleDayText = nextVisibleDayText
        }

        guard isNearBottom == false else {
            dayChipHideTask?.cancel()
            if isShowingFloatingDayChip {
                withAnimation(.easeOut(duration: 0.18)) {
                    isShowingFloatingDayChip = false
                }
            }
            return
        }

        if isShowingFloatingDayChip == false || topVisibleChanged {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingFloatingDayChip = true
            }
            scheduleDayChipHide()
        }
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
        ChatDayTextFormatter.string(for: date)
    }

    private func trimLoadedHistoryWhileScrollingDownIfNeeded(anchorMessageID: UUID) {
        guard isViewportReady else { return }
        guard didInitialScrollToBottom else { return }
        guard isNearBottom == false else { return }
        guard isJumpingToLatestWindow == false else { return }
        guard isCollapsingLoadedHistory == false else { return }
        guard viewModel.isLoadingOlderMessages == false else { return }
        guard lastViewportTrimAnchorMessageID != anchorMessageID else { return }

        let now = Date()
        guard now.timeIntervalSince(lastViewportTrimAt) >= 0.35 else { return }

        lastViewportTrimAnchorMessageID = anchorMessageID
        lastViewportTrimAt = now

        Task { @MainActor in
            let trimmed = viewModel.trimLoadedHistoryBefore(anchorMessageID: anchorMessageID)
            guard trimmed else { return }
            previousMessageIDs = viewModel.messageIDs
        }
    }

    private func makeViewportRows(
        from renderedRows: [MessageRenderRow],
        visibleLookup: [UUID: Message],
        messageColumn: CGFloat
    ) -> [ChatMessageViewportRow] {
        renderedRows.compactMap { row in
            guard let message = visibleLookup[row.messageID] else { return nil }
            let replyMessage = row.replyMessageID.flatMap { visibleLookup[$0] }
            let heightVersion = viewportRowHeightVersion(
                row: row,
                message: message,
                replyMessage: replyMessage
            )
            let estimatedHeight = viewportRowEstimatedHeight(
                row: row,
                message: message,
                replyMessage: replyMessage,
                messageColumn: messageColumn
            )
            return ChatMessageViewportRow(
                id: row.id,
                messageID: row.messageID,
                contentVersion: viewportRowContentVersion(
                    message: message,
                    replyMessage: replyMessage
                ),
                layoutVersion: viewportRowLayoutVersion(
                    row: row,
                    message: message
                ),
                heightVersion: heightVersion,
                estimatedHeight: estimatedHeight,
                shouldAvoidAnchor: shouldAvoidViewportAnchor(
                    message: message,
                    estimatedHeight: estimatedHeight
                )
            )
        }
    }

    private func viewportRowContentVersion(message: Message, replyMessage: Message?) -> Int {
        var hasher = Hasher()
        hasher.combine(message.id)
        hasher.combine(message.clientMessageID)
        hasher.combine(message.senderID)
        hasher.combine(message.createdAt.timeIntervalSinceReferenceDate)
        hasher.combine(message.editedAt?.timeIntervalSinceReferenceDate)
        hasher.combine(message.text?.hashValue ?? 0)
        hasher.combine(message.attachments.count)
        hasher.combine(message.voiceMessage?.durationSeconds ?? 0)
        hasher.combine(message.reactions.count)
        hasher.combine(message.isDeleted)
        hasher.combine(message.status.rawValue)
        if let replyMessage {
            hasher.combine(replyMessage.id)
            hasher.combine(replyMessage.text?.hashValue ?? 0)
            hasher.combine(replyMessage.editedAt?.timeIntervalSinceReferenceDate)
        }
        return hasher.finalize()
    }

    private func viewportRowLayoutVersion(row: MessageRenderRow, message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(row.id)
        hasher.combine(row.messageID)
        hasher.combine(row.messageCreatedAt.timeIntervalSinceReferenceDate)
        hasher.combine(row.replyMessageID)
        hasher.combine(row.showsDayDivider)
        hasher.combine(row.showsIncomingSenderName)
        hasher.combine(row.showsIncomingAvatar)
        hasher.combine(row.showsTail)
        hasher.combine(row.bottomSpacing)
        hasher.combine(activeHoldMenuMessage?.id == message.id)
        hasher.combine(activeInlineReactionMessage?.id == message.id)
        hasher.combine(pinnedMessageID == message.id)
        return hasher.finalize()
    }

    private func viewportRowHeightVersion(row: MessageRenderRow, message: Message, replyMessage: Message?) -> Int {
        var hasher = Hasher()
        hasher.combine(row.id)
        hasher.combine(row.showsDayDivider)
        hasher.combine(row.showsIncomingSenderName)
        hasher.combine(row.showsIncomingAvatar)
        hasher.combine(row.showsTail)
        hasher.combine(message.isDeleted)
        hasher.combine(message.text ?? "")
        hasher.combine(message.attachments.count)
        hasher.combine(message.linkPreview?.selectedURL)
        hasher.combine(message.linkPreview?.isDisabled ?? false)
        hasher.combine(message.voiceMessage?.durationSeconds ?? 0)
        hasher.combine(message.reactions.count)
        hasher.combine(message.communityParentPostID != nil)
        hasher.combine(message.communityTopicID)
        hasher.combine(replyMessage?.id)
        hasher.combine(replyMessage?.text ?? "")
        hasher.combine(ChatCallSummaryCodec.decode(message.text)?.durationSeconds ?? 0)
        return hasher.finalize()
    }

    private func viewportRowEstimatedHeight(
        row: MessageRenderRow,
        message: Message,
        replyMessage: Message?,
        messageColumn: CGFloat
    ) -> CGFloat {
        let isOutgoing = message.senderID == appState.currentUser.id
        let rowWidth = max(messageColumn - (PrimeTheme.Spacing.large * 0), 0)
        let rowOppositeSideInset: CGFloat = 52
        let effectiveRowWidth = max(rowWidth - rowOppositeSideInset, 0)
        let maximumTextBubbleWidth = min(effectiveRowWidth, UIScreen.main.bounds.width * 0.82)
        let maximumMediaBubbleWidth = min(UIScreen.main.bounds.width * 0.8, 308)
        let maximumVoiceBubbleWidth = min(UIScreen.main.bounds.width * 0.68, 262)
        let bubbleWidth: CGFloat
        if ChatCallSummaryCodec.decode(message.text) != nil {
            bubbleWidth = min(effectiveRowWidth, 290)
        } else if message.voiceMessage != nil, message.attachments.isEmpty, trimmedMessageText(for: message) == nil {
            bubbleWidth = maximumVoiceBubbleWidth
        } else if message.voiceMessage == nil, message.attachments.isEmpty == false, trimmedMessageText(for: message) == nil {
            bubbleWidth = maximumMediaBubbleWidth
        } else {
            bubbleWidth = maximumTextBubbleWidth
        }

        let textWidth = max(bubbleWidth - 24, 140)
        var totalHeight: CGFloat = row.showsDayDivider ? 34 : 0
        totalHeight += row.bottomSpacing

        var bubbleHeight: CGFloat = 16
        if row.showsIncomingSenderName, isOutgoing == false {
            bubbleHeight += 18
        }
        if replyMessage != nil {
            bubbleHeight += 72
        }

        if message.isDeleted {
            bubbleHeight += 28
        } else if ChatCallSummaryCodec.decode(message.text) != nil {
            bubbleHeight += 68
        } else {
            if let text = trimmedMessageText(for: message) {
                let measuredHeight = measuredTextHeight(text, width: textWidth)
                if text.count > Self.largeMessageCollapseThreshold {
                    let collapsedHeight = ceil(min(measuredHeight, 18 * 18))
                    bubbleHeight += max(collapsedHeight, 220)
                    bubbleHeight += 28
                } else {
                    bubbleHeight += measuredHeight
                }
            } else if message.attachments.isEmpty && message.voiceMessage == nil {
                bubbleHeight += 22
            }

            if message.linkPreview?.resolvedURL(in: message.text) != nil, message.isDeleted == false {
                bubbleHeight += 112
            }

            if message.attachments.isEmpty == false, message.isDeleted == false {
                bubbleHeight += estimatedAttachmentGalleryHeight(
                    attachments: message.attachments,
                    maximumWidth: maximumMediaBubbleWidth
                )
            }

            if message.voiceMessage != nil, message.isDeleted == false {
                bubbleHeight += 58
            }

            if currentChat.communityDetails?.kind == .channel,
               currentChat.communityDetails?.commentsEnabled == true,
               message.communityParentPostID == nil,
               message.isDeleted == false {
                bubbleHeight += 38
            }

            if message.reactions.isEmpty == false, message.isDeleted == false {
                bubbleHeight += 30
            }
        }

        bubbleHeight += 18
        totalHeight += bubbleHeight

        if totalHeight > 1600 {
            print(
                "PUSHTRACE ChatViewport step=row.height.large main=\(Thread.isMainThread) rowId=\(row.id.uuidString) messageId=\(message.id.uuidString) estimated=\(Int(totalHeight.rounded())) textCount=\((message.text ?? "").count) attachments=\(message.attachments.count) voice=\(message.voiceMessage != nil) callSummary=\(ChatCallSummaryCodec.decode(message.text) != nil)"
            )
        }

        return ceil(max(totalHeight, 52))
    }

    private func shouldAvoidViewportAnchor(message: Message, estimatedHeight: CGFloat) -> Bool {
        if estimatedHeight > 800 {
            return true
        }
        if (message.text?.count ?? 0) > Self.largeAnchorTextThreshold {
            return true
        }
        if ChatCallSummaryCodec.decode(message.text) != nil {
            return true
        }
        return false
    }

    private func measuredTextHeight(_ text: String, width: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 13.5, weight: .regular)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 80), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }

    private func estimatedAttachmentGalleryHeight(attachments: [Attachment], maximumWidth: CGFloat) -> CGFloat {
        let clampedWidth = max(min(maximumWidth, 308), 180)
        if attachments.count == 1 {
            return clampedWidth * 0.72
        }
        if attachments.count == 2 {
            return clampedWidth * 0.82
        }
        return clampedWidth
    }

    private func trimmedMessageText(for message: Message) -> String? {
        let trimmed = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    private func makeViewportRowView(
        row: MessageRenderRow,
        visibleLookup: [UUID: Message],
        messageColumn: CGFloat
    ) -> AnyView {
        guard let message = visibleLookup[row.messageID] else {
            return AnyView(EmptyView())
        }

        let replyMessage = row.replyMessageID.flatMap { visibleLookup[$0] }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                if row.showsDayDivider {
                    ChatDayDivider(text: contextualDayText(for: row.messageCreatedAt))
                }

                MessageBubbleView(
                    chat: currentChat,
                    message: message,
                    replyMessage: replyMessage,
                    rowWidth: messageColumn,
                    currentUserID: appState.currentUser.id,
                    showsIncomingSenderName: row.showsIncomingSenderName,
                    showsIncomingAvatar: row.showsIncomingAvatar,
                    showsTail: row.showsTail,
                    isActionMenuPresented: activeHoldMenuMessage?.id == message.id,
                    isReactionPanelPresented: activeInlineReactionMessage?.id == message.id,
                    isPressingActionMenu: false,
                    isPinned: pinnedMessageID == message.id,
                    isOutgoing: message.senderID == appState.currentUser.id,
                    canEdit: viewModel.canEdit(message, currentUserID: appState.currentUser.id),
                    canDelete: viewModel.canDelete(message, currentUserID: appState.currentUser.id),
                    isListInteracting: isChatScrollInteracting,
                    shouldAllowActionMenuPressing: {
                        isChatScrollInteracting == false && Date.now >= holdGestureSuppressionUntil
                    },
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
                        if let resolvedReplyMessageID = row.replyMessageID,
                           visibleLookup[resolvedReplyMessageID] != nil {
                            localFocusedMessageID = resolvedReplyMessageID
                        } else if let replyTargetID = message.replyToMessageID {
                            localFocusedMessageID = replyTargetID
                        }
                    },
                    onCopy: {
                        copyMessageContents(message)
                    },
                    onOpenActionMenu: {
                        openHoldMenu(for: message)
                    },
                    onOpenReactionPanelOnly: {
                        ChatMessageGestureDiagnostics.log("double_tap_reaction_panel", messageID: message.id)
                        openInlineReactionPanel(for: message)
                    },
                    onActionMenuPressingChanged: { _ in },
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
                .equatable()
                .padding(.bottom, row.bottomSpacing)
            }
            .frame(width: messageColumn, alignment: .leading)
            .padding(.horizontal, PrimeTheme.Spacing.large)
        )
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
        reminderMessageIDs = Set(ChatReminderStore.shared.reminderMessageIDs(chatID: currentChat.id))
        followUpMessageIDs = Set(ChatReplyFollowUpStore.shared.messageIDs(chatID: currentChat.id))
        readingAnchorMessageID = await ChatNavigationStateStore.shared.readingAnchorMessageID(
            ownerUserID: appState.currentUser.id,
            chatID: currentChat.id,
            mode: currentChat.mode
        )
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

    private func openHoldMenu(for message: Message) {
        guard activeHoldMenuMessage?.id != message.id else { return }
        activeInlineReactionMessage = nil
        ChatMessageGestureDiagnostics.log(
            "hold_activated",
            messageID: message.id,
            details: "menu=hold"
        )
        #if !os(tvOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            activeHoldMenuMessage = message
        }
        #if !os(tvOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func openInlineReactionPanel(for message: Message) {
        guard activeInlineReactionMessage?.id != message.id else { return }
        activeHoldMenuMessage = nil
        ChatMessageGestureDiagnostics.log(
            "inline_reaction_panel_opened",
            messageID: message.id
        )
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            activeInlineReactionMessage = message
        }
        #if !os(tvOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func closeHoldMenu() {
        if let activeHoldMenuMessage {
            ChatMessageGestureDiagnostics.log(
                "message_menu_closed",
                messageID: activeHoldMenuMessage.id,
                details: "menu=hold"
            )
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            activeHoldMenuMessage = nil
        }
    }

    private func closeInlineReactionPanel() {
        if let activeInlineReactionMessage {
            ChatMessageGestureDiagnostics.log(
                "message_menu_closed",
                messageID: activeInlineReactionMessage.id,
                details: "menu=inline_reactions"
            )
        }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.92)) {
            activeInlineReactionMessage = nil
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
    private func scheduleReminder(for message: Message, after interval: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = currentChat.displayTitle(for: appState.currentUser.id)
        content.body = "Reminder: \(messagePreviewText(for: message))"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: false)
        let request = UNNotificationRequest(
            identifier: ChatReminderStore.notificationIdentifier(chatID: currentChat.id, messageID: message.id),
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            ChatReminderStore.shared.saveReminder(messageID: message.id, chatID: currentChat.id)
            reminderMessageIDs.insert(message.id)
            viewModel.messageActionError = ""
        } catch {
            viewModel.messageActionError = error.localizedDescription.isEmpty ? "Could not schedule the reminder." : error.localizedDescription
        }
    }

    @MainActor
    private func toggleReplyFollowUp(for message: Message) async {
        if followUpMessageIDs.contains(message.id) {
            ChatReplyFollowUpStore.shared.remove(messageID: message.id, chatID: currentChat.id)
            followUpMessageIDs.remove(message.id)
        } else {
            ChatReplyFollowUpStore.shared.save(messageID: message.id, chatID: currentChat.id)
            followUpMessageIDs.insert(message.id)
        }
        viewModel.messageActionError = ""
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
                currentUserID: appState.currentUser.id,
                sessionID: chatSessionID
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

    private func normalizedMentionHandle(explicitUsername: String?, fallbackDisplayName: String?) -> String? {
        let username = explicitUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if username.isEmpty == false {
            return username
                .replacingOccurrences(of: "@", with: "")
                .lowercased()
        }

        let displayName = fallbackDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokens = displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
        guard tokens.isEmpty == false else { return nil }
        return tokens.joined()
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
                    mentionCandidates: composerMentionCandidates,
                    isSending: viewModel.isSending,
                    editingMessage: viewModel.editingMessage,
                    replyMessage: replyingToMessage,
                    communityContextTitle: communityComposeContextTitle,
                    communityContext: communityComposeContext,
                    incomingSharedDraft: incomingSharedDraft,
                    onCancelEditing: {
                        viewModel.cancelEditing()
                    },
                    onCancelReply: {
                        replyingToMessage = nil
                    },
                    onCancelCommunityContext: communityComposeContextTitle == nil ? nil : {
                        clearCommunityComposeContext()
                    },
                    onConsumeIncomingSharedDraft: {
                        incomingSharedDraft = nil
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
                    } else if let headerAvatarURL {
                        CachedRemoteImage(url: headerAvatarURL, maxPixelSize: 256) { image in
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

    private var headerAvatarURL: URL? {
        if currentChat.type == .group {
            return currentChat.group?.photoURL
        }

        guard currentChat.type == .direct else { return nil }
        if let contactProfileURL = contactProfile?.profile.profilePhotoURL {
            return contactProfileURL
        }
        if let directParticipant = currentChat.directParticipant(for: appState.currentUser.id),
           let directPhotoURL = directParticipant.photoURL {
            return directPhotoURL
        }
        return currentChat.participants.first(where: { $0.id != appState.currentUser.id })?.photoURL
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
    private func scheduleChatPresentationSync(delay: Duration = .milliseconds(140)) {
        presentationSyncTask?.cancel()
        presentationSyncTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard Task.isCancelled == false else { return }
            await syncChatPresentationAndReadState()
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
            try? await Task.sleep(for: .milliseconds(820))
            guard Task.isCancelled == false else { return }
            await persistDraftImmediately()
        }
    }

    @MainActor
    private func scheduleTypingStateEvaluation() {
        typingStateEvaluationTask?.cancel()
        let snapshot = viewModel.draftText
        typingStateEvaluationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard Task.isCancelled == false else { return }
            guard snapshot == viewModel.draftText else { return }
            await handleDraftTypingStateChange()
        }
    }

    @MainActor
    private func consumeIncomingShareDraftIfNeeded() {
        guard incomingSharedDraft == nil else { return }
        incomingSharedDraft = appState.consumeIncomingShareDraft(for: currentChat.id)
    }

    @MainActor
    private func persistDraftImmediately() async {
        guard viewModel.editingMessage == nil else { return }
        guard viewModel.draftText != lastPersistedDraftText else { return }

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

        lastPersistedDraftText = viewModel.draftText
        currentChat.draft = nextDraft
        await ChatSnapshotStore.shared.updateDraft(
            nextDraft,
            chatID: currentChat.id,
            userID: appState.currentUser.id,
            mode: currentChat.mode
        )

        // Avoid expensive chat-feed hydration churn while user is actively typing in this chat.
        if appState.selectedChat?.id != currentChat.id {
            NotificationCenter.default.post(name: .primeMessagingDraftsChanged, object: nil)
        }
    }

    @MainActor
    private func persistReadingAnchorImmediately() async {
        await ChatNavigationStateStore.shared.saveReadingAnchorMessageID(
            isNearBottom ? nil : topVisibleMessageID,
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

        let now = Date()
        if lastPresenceRefreshUserID == otherUserID,
           now.timeIntervalSince(lastPresenceRefreshAt) < 6 {
            return
        }
        lastPresenceRefreshUserID = otherUserID
        lastPresenceRefreshAt = now

        do {
            logChatPresence("presence.load.begin", details: "user=\(otherUserID.uuidString)")
            var fetchedPresence = try await environment.presenceRepository.fetchPresence(for: otherUserID)
            if currentPresence?.userID == fetchedPresence.userID, currentPresence?.isTyping == true {
                fetchedPresence.isTyping = true
            }
            currentPresence = fetchedPresence
            logChatPresence("presence.updated", details: "state=\(fetchedPresence.state.rawValue) typing=\(fetchedPresence.isTyping)")
        } catch {
            if currentPresence?.userID != otherUserID {
                currentPresence = nil
            }
            logChatPresence("presence.failed", details: error.localizedDescription)
        }
    }

    @MainActor
    private func handleDraftTypingStateChange() async {
        guard currentChat.mode == .online, currentChat.type == .direct else {
            await stopLocalTypingIfNeeded(force: true)
            return
        }
        guard appState.currentUser.privacySettings.shareTypingStatus else {
            await stopLocalTypingIfNeeded(force: true)
            return
        }

        let hasMeaningfulText = viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasMeaningfulText {
            await sendTypingState(true, force: false)
            scheduleLocalTypingHeartbeat()
            scheduleLocalTypingIdleStop()
        } else {
            await stopLocalTypingIfNeeded(force: false)
        }
    }

    @MainActor
    private func scheduleLocalTypingIdleStop() {
        localTypingIdleTask?.cancel()
        localTypingIdleTask = Task {
            try? await Task.sleep(for: .seconds(4.2))
            guard Task.isCancelled == false else { return }
            await stopLocalTypingIfNeeded(force: false)
        }
    }

    @MainActor
    private func stopLocalTypingIfNeeded(force: Bool) async {
        localTypingIdleTask?.cancel()
        localTypingIdleTask = nil
        localTypingHeartbeatTask?.cancel()
        localTypingHeartbeatTask = nil

        guard currentChat.mode == .online, currentChat.type == .direct else {
            isLocalTypingActive = false
            lastTypingSignalState = false
            return
        }

        if force == false, isLocalTypingActive == false {
            return
        }
        await sendTypingState(false, force: true)
    }

    @MainActor
    private func scheduleLocalTypingHeartbeat() {
        guard localTypingHeartbeatTask == nil else { return }
        localTypingHeartbeatTask = Task { @MainActor in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(2.4))
                guard Task.isCancelled == false else { return }

                let hasMeaningfulText = viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                guard hasMeaningfulText, currentChat.mode == .online, currentChat.type == .direct else {
                    localTypingHeartbeatTask = nil
                    return
                }

                await sendTypingState(true, force: true)
            }
        }
    }

    @MainActor
    private func sendTypingState(_ isTyping: Bool, force: Bool) async {
        guard currentChat.mode == .online, currentChat.type == .direct else { return }
        if appState.currentUser.privacySettings.shareTypingStatus == false {
            lastTypingSignalState = false
            isLocalTypingActive = false
            return
        }

        let now = Date()
        let minRepeatInterval: TimeInterval = isTyping ? 1.0 : 0.2
        if force == false,
           lastTypingSignalState == isTyping,
           now.timeIntervalSince(lastTypingSignalAt) < minRepeatInterval {
            return
        }

        lastTypingSignalState = isTyping
        lastTypingSignalAt = now
        isLocalTypingActive = isTyping

        await ChatRealtimeService.shared.sendTyping(
            chatID: currentChat.id,
            userID: appState.currentUser.id,
            mode: currentChat.mode,
            isTyping: isTyping
        )
    }

    @MainActor
    private func reportPremiumChatOpenIfNeeded() async {
        guard supportsServerBackedFeatures, currentChat.mode == .online, currentChat.type == .direct else { return }
        guard appState.isSceneActive else { return }
        guard hasReportedPremiumChatOpen == false else { return }
        hasReportedPremiumChatOpen = true
        premiumChatOpenedAt = Date()
        await reportPremiumChatActivity(kind: "opened")
    }

    @MainActor
    private func reportPremiumChatCloseIfNeeded() async {
        guard supportsServerBackedFeatures, currentChat.mode == .online, currentChat.type == .direct else { return }
        guard hasReportedPremiumChatOpen else { return }
        hasReportedPremiumChatOpen = false
        premiumChatOpenedAt = nil
        isScreenRecordingActive = false
        await reportPremiumChatActivity(kind: "closed")
    }

    @MainActor
    private func handleScreenRecordingStateChange() async {
        guard supportsServerBackedFeatures, currentChat.mode == .online, currentChat.type == .direct else { return }
        let nextState = UIScreen.main.isCaptured
        guard nextState != isScreenRecordingActive else { return }
        isScreenRecordingActive = nextState
        await reportPremiumChatActivity(kind: "screen_recording", isActive: nextState)
    }

    @MainActor
    private func reportPremiumChatActivity(kind: String, isActive: Bool? = nil) async {
        guard supportsServerBackedFeatures, currentChat.mode == .online, currentChat.type == .direct else { return }
        await ChatRealtimeService.shared.sendChatActivity(
            chatID: currentChat.id,
            userID: appState.currentUser.id,
            mode: currentChat.mode,
            kind: kind,
            isActive: isActive
        )
    }

    @MainActor
    private func applyRealtimePresenceEvent(_ event: RealtimeChatEvent) async {
        guard currentChat.type == .direct else { return }
        guard let otherUserID = currentChat.participantIDs.first(where: { $0 != appState.currentUser.id }) else { return }

        if let actorUserID = event.actorUserID, actorUserID != otherUserID {
            return
        }

        switch event.type {
        case "typing.started":
            var nextPresence = event.presence ?? currentPresence ?? Presence(
                userID: otherUserID,
                state: .online,
                lastSeenAt: .now,
                isTyping: false
            )
            guard nextPresence.userID == otherUserID else { return }
            nextPresence.isTyping = true
            if nextPresence.state == .offline || nextPresence.state == .recently || nextPresence.state == .lastSeen {
                nextPresence.state = .online
            }
            if nextPresence.lastSeenAt == nil {
                nextPresence.lastSeenAt = .now
            }
            currentPresence = nextPresence
            scheduleRemoteTypingReset(userID: otherUserID)
        case "typing.stopped":
            var nextPresence = event.presence ?? currentPresence ?? Presence(
                userID: otherUserID,
                state: .recently,
                lastSeenAt: .now,
                isTyping: false
            )
            guard nextPresence.userID == otherUserID else { return }
            nextPresence.isTyping = false
            currentPresence = nextPresence
            remoteTypingResetTask?.cancel()
        case "presence.updated":
            guard let nextPresence = event.presence else { return }
            guard nextPresence.userID == otherUserID else { return }
            currentPresence = nextPresence
            if nextPresence.isTyping {
                scheduleRemoteTypingReset(userID: otherUserID)
            } else {
                remoteTypingResetTask?.cancel()
            }
        default:
            return
        }
    }

    @MainActor
    private func scheduleRemoteTypingReset(userID: UUID) {
        remoteTypingResetTask?.cancel()
        remoteTypingResetTask = Task {
            try? await Task.sleep(for: .seconds(5.2))
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                guard currentPresence?.userID == userID else { return }
                guard currentPresence?.isTyping == true else { return }
                currentPresence?.isTyping = false
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
    private func refreshDirectContactProfileIfNeeded() async {
        guard currentChat.type == .direct else { return }
        guard let otherUserID = currentChat.participantIDs.first(where: { $0 != appState.currentUser.id }) else { return }

        do {
            let remoteProfile = try await environment.authRepository.userProfile(userID: otherUserID)
            guard currentChat.type == .direct else { return }
            contactProfile = remoteProfile
            if let participantIndex = currentChat.participants.firstIndex(where: { $0.id == otherUserID }) {
                currentChat.participants[participantIndex].displayName = remoteProfile.profile.displayName
                currentChat.participants[participantIndex].username = remoteProfile.profile.username
                currentChat.participants[participantIndex].photoURL = remoteProfile.profile.profilePhotoURL
            }
        } catch { }
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

        if currentPresence.isTyping {
            return "Typing…"
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

    @MainActor
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
        let previousKeyboardHeight = keyboardHeight

        if overlap > 0, Date() < foregroundInteractionGraceUntil {
            foregroundInteractionGraceUntil = Date().addingTimeInterval(1.1)
        }

        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = overlap
        }
        if previousKeyboardHeight <= 0, overlap > 0, (isNearBottom || pendingAutoScrollAfterOutgoingMessage) {
            keyboardOpenRealignmentTask?.cancel()
            keyboardOpenRealignmentTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard Task.isCancelled == false else { return }
                keyboardRealignmentRequest += 1
            }
        } else if overlap <= 0 {
            keyboardOpenRealignmentTask?.cancel()
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

private enum ChatDayTextFormatter {
    private static let relativeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter
    }()

    static func string(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return relativeFormatter.string(from: date)
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: .now), currentWeek.contains(date) {
            return weekdayFormatter.string(from: date).capitalized
        }

        return fullDateFormatter.string(from: date)
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

private extension View {
    @ViewBuilder
    func chatMessageFrameReporter(rowID: UUID, isEnabled: Bool) -> some View {
        if isEnabled {
            background(
                GeometryReader { frameReader in
                    Color.clear.preference(
                        key: ChatMessageFramePreferenceKey.self,
                        value: [rowID: frameReader.frame(in: .named("chat-scroll"))]
                    )
                }
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func chatMessageMenuFrameReporter(messageID: UUID, isEnabled: Bool) -> some View {
        if isEnabled {
            background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatMessageMenuFramePreferenceKey.self,
                        value: [messageID: geometry.frame(in: .named("chat-root"))]
                    )
                }
            )
        } else {
            self
        }
    }
}

private enum ChatMessageViewportScrollAnchor: Equatable {
    case top
    case center
    case bottom
}

private struct ChatMessageViewportCommand: Equatable {
    enum Action: Equatable {
        case scrollToBottom(animated: Bool)
        case scrollToMessage(UUID, anchor: ChatMessageViewportScrollAnchor, animated: Bool)
    }

    let token: Int
    let action: Action
}

private struct ChatMessageViewportRow: Identifiable, Hashable {
    let id: UUID
    let messageID: UUID
    let contentVersion: Int
    let layoutVersion: Int
    let heightVersion: Int
    let estimatedHeight: CGFloat
    let shouldAvoidAnchor: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ChatMessageViewportRow, rhs: ChatMessageViewportRow) -> Bool {
        lhs.id == rhs.id
    }
}

private struct ChatMessageViewport: UIViewRepresentable {
    private static func log(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatViewport step=\(step) main=\(Thread.isMainThread)\(suffix)")
    }

    final class ViewportTableView: UITableView {
        var onDidMoveToWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            ChatMessageViewport.log("table.didMoveToWindow")
            onDidMoveToWindow?()
        }
    }

    final class ViewportCell: UITableViewCell {
        var trackedRowID: UUID?
        var configuredMessageID: UUID?
        var configuredContentVersion: Int?
        var configuredLayoutVersion: Int?

        override func prepareForReuse() {
            ChatMessageViewport.log("prepareForReuse.begin", details: "rowId=\(trackedRowID?.uuidString ?? "nil")")
            super.prepareForReuse()
            trackedRowID = nil
            configuredMessageID = nil
            configuredContentVersion = nil
            configuredLayoutVersion = nil
            contentConfiguration = nil
            ChatMessageViewport.log("prepareForReuse.end")
        }

        override func layoutSubviews() {
            let startedAt = CACurrentMediaTime()
            ChatMessageViewport.log("layoutSubviews.begin", details: "rowId=\(trackedRowID?.uuidString ?? "nil")")
            super.layoutSubviews()
            let durationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
            ChatMessageViewport.log("layoutSubviews.end", details: "rowId=\(trackedRowID?.uuidString ?? "nil") durationMs=\(durationMs)")
            if durationMs > 4 {
                ChatMessageViewport.log("layoutSubviews.slow", details: "rowId=\(trackedRowID?.uuidString ?? "nil") durationMs=\(durationMs)")
            }
        }
    }

    let rows: [ChatMessageViewportRow]
    let containerWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let nearBottomThreshold: CGFloat
    let sessionID: UUID
    let trackedMessageIDs: Set<UUID>
    let command: ChatMessageViewportCommand?
    let onBuildRow: (ChatMessageViewportRow) -> AnyView
    let onCommandConsumed: (Int) -> Void
    let onReachTop: () -> Void
    let onNearBottomChanged: (Bool) -> Void
    let onTrackedFramesChanged: ([UUID: CGRect]) -> Void
    let onTopVisibleRowChanged: (UUID?) -> Void
    let onScrollInteractionChanged: (Bool, String) -> Void
    let onInitialPositioned: () -> Void

    private enum AnchorMode: String, Equatable {
        case idle
        case initialBottom
        case preserveVisible
        case prependRestore
        case trimRestore
        case stickToBottom
        case explicitCommand
    }

    private struct ViewportSnapshotSignature: Equatable {
        let itemIDs: [UUID]
        let contentVersions: [Int]
        let layoutVersions: [Int]
        let commandToken: Int?
        let containerWidthBucket: Int
        let anchorMode: AnchorMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = ViewportTableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = true
        tableView.estimatedRowHeight = 120
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = true
        tableView.isPrefetchingEnabled = true
        tableView.delegate = context.coordinator
        tableView.prefetchDataSource = context.coordinator
        tableView.register(ViewportCell.self, forCellReuseIdentifier: Coordinator.cellReuseIdentifier)
        context.coordinator.attach(tableView: tableView)
        tableView.onDidMoveToWindow = { [weak coordinator = context.coordinator, weak tableView] in
            guard let coordinator, let tableView else { return }
            coordinator.handleTableViewDidMoveToWindow(tableView)
        }
        return tableView
    }

    func updateUIView(_ uiView: UITableView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(tableView: uiView)
    }

    final class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSourcePrefetching {
        static let cellReuseIdentifier = "ChatViewportCell"

        final class InstrumentedDataSource: UITableViewDiffableDataSource<Int, UUID> {
            override func numberOfSections(in tableView: UITableView) -> Int {
                ChatMessageViewport.log("numberOfSections.begin")
                let count = super.numberOfSections(in: tableView)
                ChatMessageViewport.log("numberOfSections.end", details: "count=\(count)")
                return count
            }

            override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
                ChatMessageViewport.log("numberOfRows.begin", details: "section=\(section)")
                let count = super.tableView(tableView, numberOfRowsInSection: section)
                ChatMessageViewport.log("numberOfRows.end", details: "section=\(section) count=\(count)")
                return count
            }
        }

        struct AnchorSnapshot {
            let rowID: UUID
            let deltaFromContentOffset: CGFloat
        }

        private struct HeightCacheKey: Hashable {
            let messageID: UUID
            let heightVersion: Int
            let containerWidthBucket: Int
            let contentSizeCategory: String
        }

        private struct PendingViewportUpdate {
            let sessionID: UUID
            let rows: [ChatMessageViewportRow]
            let rowOrder: [UUID]
            let rowsByID: [UUID: ChatMessageViewportRow]
            let contentVersions: [UUID: Int]
            let layoutVersions: [UUID: Int]
            let changedIDs: [UUID]
            let removedIDs: Set<UUID>
            let dataChanged: Bool
            let isPrepend: Bool
            let isLeadingTrim: Bool
            let preserveVisibleAnchor: Bool
            let shouldStickToBottom: Bool
            let anchorMode: AnchorMode
            let anchorSnapshot: AnchorSnapshot?
            let signature: ViewportSnapshotSignature
            let createdAt: CFTimeInterval
            let insertedCount: Int
            let deletedCount: Int
            let reconfiguredCount: Int
            let wasDragging: Bool
            let wasDecelerating: Bool
            let isInitialSnapshot: Bool
        }

        var parent: ChatMessageViewport
        private var dataSource: InstrumentedDataSource?

        private weak var attachedTableView: UITableView?
        private var currentSessionID: UUID?
        private var rowOrder: [UUID] = []
        private var rowContentVersions: [UUID: Int] = [:]
        private var rowLayoutVersions: [UUID: Int] = [:]
        private var rowsByID: [UUID: ChatMessageViewportRow] = [:]
        private var cachedRowHeights: [HeightCacheKey: CGFloat] = [:]
        private var didApplyInitialPosition = false
        private var hasAppliedInitialSnapshot = false
        private var lastExecutedCommandToken: Int?
        private var lastNearBottomState = true
        private var lastTriggeredTopRowID: UUID?
        private var lastReportedTopVisibleRowID: UUID?
        private var lastTopVisibleEmitAt: CFTimeInterval = 0
        private var hasPendingPostApplyWork = false
        private var pendingPostApplyUpdate: PendingViewportUpdate?
        private var pendingViewportUpdate: PendingViewportUpdate?
        private var deferredViewportUpdateWhileScrolling: PendingViewportUpdate?
        private var isViewportUpdateScheduled = false
        private var isApplyingViewportUpdate = false
        private var lastAppliedSignature: ViewportSnapshotSignature?
        private var skippedDuplicateUpdatesCount = 0
        private var heightCacheHitCount = 0
        private var heightCacheMissCount = 0
        private var lastLoggedHeightCacheHits = 0
        private var lastLoggedHeightCacheMisses = 0
        private var lastContainerWidthBucket: Int?
        private var lastAppliedInsets: UIEdgeInsets = .zero
        private var needsFullSnapshotApply = false
        private var activeApplyID: UUID?
        private var activeApplyTimeoutTask: Task<Void, Never>?
        private var isPerformingInitialReload = false
        private var lastViewportScheduleReason = "unknown"
        private var scrollRecentlyActiveUntil: CFTimeInterval = 0
        private var scrollIdleFlushTask: Task<Void, Never>?

        init(parent: ChatMessageViewport) {
            self.parent = parent
        }

        func attach(tableView: UITableView) {
            if attachedTableView !== tableView {
                dataSource = makeDataSource(for: tableView)
                tableView.dataSource = dataSource
            }
            attachedTableView = tableView
            resetViewportState(for: parent.sessionID, on: tableView)
        }

        private func makeDataSource(for tableView: UITableView) -> InstrumentedDataSource {
            let dataSource = InstrumentedDataSource(tableView: tableView) { [weak self] tableView, indexPath, itemID in
                let startedAt = CACurrentMediaTime()
                ChatMessageViewport.log(
                    "cellForRow.begin",
                    details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(itemID.uuidString)"
                )
                guard let self, let row = self.rowsByID[itemID] else {
                    ChatMessageViewport.log("cellForRow.end", details: "indexPath=\(indexPath.section):\(indexPath.row) missing=true")
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath) as? ViewportCell ?? ViewportCell(style: .default, reuseIdentifier: Self.cellReuseIdentifier)
                cell.trackedRowID = row.id
                cell.selectionStyle = .none
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                ChatMessageViewport.log("cellForRow.configure.begin", details: "rowId=\(row.id.uuidString) messageId=\(row.messageID.uuidString) initialReload=\(self.isPerformingInitialReload)")
                if cell.configuredMessageID == row.messageID,
                   cell.configuredContentVersion == row.contentVersion,
                   cell.configuredLayoutVersion == row.layoutVersion,
                   self.isPerformingInitialReload == false {
                    let configureDurationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
                    ChatMessageViewport.log("cellForRow.configure.end", details: "rowId=\(row.id.uuidString) durationMs=\(configureDurationMs) skipped=true")
                    ChatMessageViewport.log("cellForRow.end", details: "indexPath=\(indexPath.section):\(indexPath.row) durationMs=\(configureDurationMs)")
                    return cell
                }
                if self.isPerformingInitialReload {
                    var content = UIListContentConfiguration.cell()
                    content.text = "Loading message"
                    content.secondaryText = String(row.messageID.uuidString.prefix(8))
                    content.textProperties.numberOfLines = 1
                    cell.contentConfiguration = content
                } else {
                    cell.contentConfiguration = UIHostingConfiguration {
                        self.parent.onBuildRow(row)
                    }
                    .margins(.all, 0)
                }
                cell.configuredMessageID = row.messageID
                cell.configuredContentVersion = row.contentVersion
                cell.configuredLayoutVersion = row.layoutVersion
                let configureDurationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
                ChatMessageViewport.log("cellForRow.configure.end", details: "rowId=\(row.id.uuidString) durationMs=\(configureDurationMs)")
                if configureDurationMs > 4 {
                    ChatMessageViewport.log("cell.configure.slow", details: "rowId=\(row.id.uuidString) durationMs=\(configureDurationMs)")
                }
                ChatMessageViewport.log("cellForRow.end", details: "indexPath=\(indexPath.section):\(indexPath.row) durationMs=\(configureDurationMs)")
                return cell
            }
            dataSource.defaultRowAnimation = .none
            return dataSource
        }

        func update(tableView: UITableView) {
            if currentSessionID != parent.sessionID {
                resetViewportState(for: parent.sessionID, on: tableView)
            }
            let effectiveCommand = parent.command.flatMap { command in
                command.token == lastExecutedCommandToken ? nil : command
            }
            ChatMessageViewport.log(
                "update.begin",
                details: "rows=\(parent.rows.count) session=\(parent.sessionID.uuidString) command=\(commandKind(effectiveCommand))"
            )
            let nextInsets = UIEdgeInsets(top: parent.topInset, left: 0, bottom: parent.bottomInset, right: 0)
            if tableView.contentInset != nextInsets {
                tableView.contentInset = nextInsets
            }
            if tableView.scrollIndicatorInsets != nextInsets {
                tableView.scrollIndicatorInsets = nextInsets
            }

            let containerWidthBucket = Int((parent.containerWidth * 10).rounded())
            if lastContainerWidthBucket != containerWidthBucket {
                cachedRowHeights.removeAll()
                lastContainerWidthBucket = containerWidthBucket
            }

            let newRows = parent.rows
            let newIDs = newRows.map(\.id)
            let oldIDs = rowOrder
            let oldIDSet = Set(oldIDs)
            let newContentVersions = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0.contentVersion) })
            let newLayoutVersions = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0.layoutVersion) })
            let changedIDs = newIDs.filter { id in
                guard oldIDSet.contains(id) else { return false }
                let previousContent = rowContentVersions[id]
                let nextContent = newContentVersions[id]
                let previousLayout = rowLayoutVersions[id]
                let nextLayout = newLayoutVersions[id]
                return previousContent != nextContent || previousLayout != nextLayout
            }
            let removedIDs = oldIDs.isEmpty ? Set<UUID>() : Set(oldIDs).subtracting(newIDs)
            let dataChanged = oldIDs != newIDs || changedIDs.isEmpty == false
            let isPrepend = oldIDs.isEmpty == false
                && newIDs.count > oldIDs.count
                && Array(newIDs.suffix(oldIDs.count)) == oldIDs
            let isLeadingTrim = oldIDs.isEmpty == false
                && oldIDs.count > newIDs.count
                && Array(oldIDs.suffix(newIDs.count)) == newIDs
            let wasNearBottom = distanceFromBottom(in: tableView) < parent.nearBottomThreshold
            let preserveVisibleAnchor = didApplyInitialPosition
                && dataChanged
                && wasNearBottom == false
                && isPrepend == false
                && isLeadingTrim == false
            let shouldStickToBottom = didApplyInitialPosition
                && dataChanged
                && wasNearBottom
                && isPrepend == false
                && isLeadingTrim == false
                && effectiveCommand == nil

            let anchorMode: AnchorMode = {
                if didApplyInitialPosition == false, newIDs.isEmpty == false {
                    return .initialBottom
                }
                if isPrepend { return .prependRestore }
                if isLeadingTrim { return .trimRestore }
                if preserveVisibleAnchor { return .preserveVisible }
                if shouldStickToBottom { return .stickToBottom }
                if effectiveCommand != nil { return .explicitCommand }
                return .idle
            }()

            let anchorSnapshot: AnchorSnapshot? = {
                guard anchorMode == .prependRestore || anchorMode == .trimRestore || anchorMode == .preserveVisible else {
                    return nil
                }
                return captureAnchorSnapshot(in: tableView)
            }()
            let isInitialSnapshot = hasAppliedInitialSnapshot == false && newIDs.isEmpty == false

            let request = PendingViewportUpdate(
                sessionID: parent.sessionID,
                rows: newRows,
                rowOrder: newIDs,
                rowsByID: Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) }),
                contentVersions: newContentVersions,
                layoutVersions: newLayoutVersions,
                changedIDs: changedIDs,
                removedIDs: removedIDs,
                dataChanged: dataChanged,
                isPrepend: isPrepend,
                isLeadingTrim: isLeadingTrim,
                preserveVisibleAnchor: preserveVisibleAnchor,
                shouldStickToBottom: shouldStickToBottom,
                anchorMode: anchorMode,
                anchorSnapshot: anchorSnapshot,
                signature: ViewportSnapshotSignature(
                    itemIDs: newRows.map(\.messageID),
                    contentVersions: newRows.map(\.contentVersion),
                    layoutVersions: newRows.map(\.layoutVersion),
                    commandToken: effectiveCommand?.token,
                    containerWidthBucket: containerWidthBucket,
                    anchorMode: anchorMode
                ),
                createdAt: CACurrentMediaTime(),
                insertedCount: max(newIDs.count - oldIDs.count, 0),
                deletedCount: removedIDs.count,
                reconfiguredCount: changedIDs.count,
                wasDragging: tableView.isDragging,
                wasDecelerating: tableView.isDecelerating,
                isInitialSnapshot: isInitialSnapshot
            )

            pendingViewportUpdate = request
            if isApplyingViewportUpdate {
                ChatMessageViewport.log(
                    "update.coalesced",
                    details: "reason=apply_in_flight rows=\(newRows.count) pending=1"
                )
                return
            }
            scheduleViewportUpdateIfNeeded(
                in: tableView,
                reason: "swiftui_update dataChanged=\(dataChanged) anchor=\(anchorMode.rawValue)"
            )
        }

        func handleTableViewDidMoveToWindow(_ tableView: UITableView) {
            if let pendingPostApplyUpdate {
                runPostApplyWorkIfPossible(
                    in: tableView,
                    update: pendingPostApplyUpdate
                )
            } else {
                scheduleViewportUpdateIfNeeded(in: tableView, reason: "didMoveToWindow")
            }
        }

        private func scheduleViewportUpdateIfNeeded(in tableView: UITableView, reason: String) {
            lastViewportScheduleReason = reason
            ChatMessageViewport.log("update.scheduled", details: "reason=\(reason)")
            guard isPerformingInitialReload == false else {
                ChatMessageViewport.log("update.deferred", details: "reason=initial_reload source=\(reason) rows=\(pendingViewportUpdate?.rows.count ?? 0)")
                return
            }
            guard isViewportUpdateScheduled == false else { return }
            isViewportUpdateScheduled = true
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                self.isViewportUpdateScheduled = false
                self.performScheduledViewportUpdate(in: tableView)
            }
        }

        private func performScheduledViewportUpdate(in tableView: UITableView) {
            guard let request = pendingViewportUpdate else { return }
            pendingViewportUpdate = nil
            guard request.sessionID == currentSessionID else {
                ChatMessageViewport.log(
                    "apply.cancelled",
                    details: "reason=stale_session scheduledSession=\(request.sessionID.uuidString) currentSession=\(currentSessionID?.uuidString ?? "nil")"
                )
                return
            }

            let now = CACurrentMediaTime()
            let isUserInteracting = tableView.isDragging || tableView.isDecelerating
            let isScrollRecentlyActive = now < scrollRecentlyActiveUntil
            let shouldDeferDuringScroll = request.isInitialSnapshot == false
                && request.dataChanged
                && request.shouldStickToBottom == false
                && request.anchorMode != .explicitCommand
            if (isUserInteracting || isScrollRecentlyActive) && shouldDeferDuringScroll {
                deferredViewportUpdateWhileScrolling = request
                ChatMessageViewport.log(
                    "update.deferred",
                    details: "reason=user_interacting rows=\(request.rows.count) source=\(lastViewportScheduleReason) dragging=\(tableView.isDragging) decelerating=\(tableView.isDecelerating) recentlyActive=\(isScrollRecentlyActive)"
                )
                return
            }

            let commandAlreadyHandled = parent.command.map { $0.token == lastExecutedCommandToken } ?? true
            let signatureUnchanged = request.signature == lastAppliedSignature
            ChatMessageViewport.log(
                "dedupe.check",
                details: "rows=\(request.rows.count) initial=\(request.isInitialSnapshot) dataChanged=\(request.dataChanged) commandHandled=\(commandAlreadyHandled) signatureUnchanged=\(signatureUnchanged)"
            )
            if request.isInitialSnapshot == false
                && signatureUnchanged
                && commandAlreadyHandled
                && request.dataChanged == false
                && needsFullSnapshotApply == false {
                skippedDuplicateUpdatesCount += 1
                ChatMessageViewport.log(
                    "update.skipped",
                    details: "reason=duplicate rows=\(request.rows.count) skipped=\(skippedDuplicateUpdatesCount)"
                )
                reportNearBottomState(in: tableView)
                reportTrackedFrames(in: tableView)
                reportTopVisibleRow(in: tableView)
                return
            }

            if request.removedIDs.isEmpty == false || request.changedIDs.isEmpty == false {
                pruneHeightCache(
                    removedIDs: request.removedIDs,
                    changedRows: request.rows.filter { request.changedIDs.contains($0.id) }
                )
            }

            if request.isInitialSnapshot {
                ChatMessageViewport.log("initialReloadData.setRows.begin", details: "rows=\(request.rows.count)")
            }
            rowsByID = request.rowsByID
            rowOrder = request.rowOrder
            rowContentVersions = request.contentVersions
            rowLayoutVersions = request.layoutVersions
            if request.isInitialSnapshot {
                ChatMessageViewport.log("initialReloadData.setRows.end", details: "rows=\(request.rows.count)")
            }
            primeHeightCache(for: request.rows, in: tableView)

            guard request.dataChanged || needsFullSnapshotApply else {
                lastAppliedSignature = request.signature
                pendingPostApplyUpdate = request
                executePendingCommandIfNeeded(in: tableView, reason: "command_only")
                if lastExecutedCommandToken == request.signature.commandToken {
                    pendingPostApplyUpdate = nil
                }
                reportNearBottomState(in: tableView)
                reportTrackedFrames(in: tableView)
                reportTopVisibleRow(in: tableView)
                flushPendingViewportUpdateIfNeeded(in: tableView)
                return
            }

            isApplyingViewportUpdate = true
            let applyStartedAt = CACurrentMediaTime()
            let applyID = UUID()
            activeApplyID = applyID
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(request.rowOrder)
            if request.isInitialSnapshot == false, request.changedIDs.isEmpty == false {
                snapshot.reconfigureItems(request.changedIDs)
            }

            let hasDataSource = dataSource != nil
            ChatMessageViewport.log(
                "apply.enter",
                details: "session=\(request.sessionID.uuidString)"
            )
            ChatMessageViewport.log(
                "apply.datasource.exists",
                details: "value=\(hasDataSource)"
            )
            ChatMessageViewport.log(
                "apply.viewLoaded",
                details: "value=\(tableView.superview != nil)"
            )
            ChatMessageViewport.log(
                "apply.window.exists",
                details: "value=\(tableView.window != nil)"
            )

            guard let dataSource else {
                finishFailedApply(
                    applyID: applyID,
                    reason: "missing_data_source",
                    request: request,
                    tableView: tableView
                )
                return
            }

            let currentSnapshotCount = dataSource.snapshot().numberOfItems
            let newSnapshotCount = snapshot.numberOfItems
            ChatMessageViewport.log(
                "apply.currentSnapshot.count",
                details: "value=\(currentSnapshotCount)"
            )
            ChatMessageViewport.log(
                "apply.newSnapshot.count",
                details: "value=\(newSnapshotCount)"
            )

            let effectiveReconfiguredCount = request.isInitialSnapshot ? 0 : request.reconfiguredCount
            if request.isInitialSnapshot {
                ChatMessageViewport.log(
                    "initialApply.begin",
                    details: "rows=\(request.rows.count) inserted=\(request.insertedCount) deleted=\(request.deletedCount) reconfigured=0 session=\(request.sessionID.uuidString)"
                )
            }
            ChatMessageViewport.log(
                "apply.begin",
                details: "rows=\(request.rows.count) inserted=\(request.insertedCount) deleted=\(request.deletedCount) reconfigured=\(effectiveReconfiguredCount) session=\(request.sessionID.uuidString) dragging=\(tableView.isDragging) decelerating=\(tableView.isDecelerating) recentlyActive=\(CACurrentMediaTime() < scrollRecentlyActiveUntil)"
            )
            scheduleApplyTimeout(applyID: applyID, request: request, snapshot: snapshot, tableView: tableView)
            if request.isInitialSnapshot {
                isPerformingInitialReload = true
                ChatMessageViewport.log("initialReloadData.enter", details: "rows=\(request.rows.count)")
                ChatMessageViewport.log(
                    "apply.call.begin",
                    details: "method=initialReloadData animated=false"
                )
                ChatMessageViewport.log("initialReloadData.reloadData.begin", details: "rows=\(request.rows.count)")
                dataSource.applySnapshotUsingReloadData(snapshot) { [weak self, weak tableView] in
                    ChatMessageViewport.log("apply.completion.called", details: "finished=true method=initialReloadData")
                    guard let self, let tableView else { return }
                    ChatMessageViewport.log("initialReloadData.reloadData.end", details: "rows=\(request.rows.count)")
                    ChatMessageViewport.log("initialReloadData.visibleCells.begin")
                    ChatMessageViewport.log("initialReloadData.visibleCells.end", details: "count=\(tableView.visibleCells.count)")
                    guard self.currentSessionID == request.sessionID else {
                        self.isPerformingInitialReload = false
                        self.finishCancelledApplyIfNeeded(applyID: applyID, reason: "initial_apply_stale_session")
                        return
                    }
                    self.isPerformingInitialReload = false
                    ChatMessageViewport.log("initialReloadData.exit", details: "rows=\(request.rows.count)")
                    self.completeSuccessfulApply(
                        applyID: applyID,
                        request: request,
                        tableView: tableView,
                        applyStartedAt: applyStartedAt,
                        method: "initialReloadData",
                        reconfiguredCount: 0,
                        forceLayoutBeforePostApply: false
                    )
                }
                ChatMessageViewport.log("apply.call.returned", details: "method=initialReloadData")
                return
            }
            ChatMessageViewport.log(
                "apply.call.begin",
                details: "method=diffableApply animated=false"
            )
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak tableView] in
                ChatMessageViewport.log("apply.completion.called", details: "finished=true method=diffableApply")
                guard let self, let tableView else { return }
                guard self.currentSessionID == request.sessionID else {
                    self.finishCancelledApplyIfNeeded(applyID: applyID, reason: "completion_stale_session")
                    return
                }
                self.completeSuccessfulApply(
                    applyID: applyID,
                    request: request,
                    tableView: tableView,
                    applyStartedAt: applyStartedAt,
                    method: "diffableApply",
                    reconfiguredCount: effectiveReconfiguredCount,
                    forceLayoutBeforePostApply: false
                )
            }
            ChatMessageViewport.log("apply.call.returned", details: "method=diffableApply")
        }

        private func runPostApplyWorkIfPossible(
            in tableView: UITableView,
            update: PendingViewportUpdate
        ) {
            guard hasPendingPostApplyWork else { return }
            guard tableView.window != nil else { return }

            hasPendingPostApplyWork = false
            pendingPostApplyUpdate = nil
            let startedAt = CACurrentMediaTime()
            let offsetBefore = tableView.contentOffset.y
            var offsetChangeReason = "none"
            ChatMessageViewport.log(
                "postApply.begin",
                details: "rows=\(update.rows.count) contentSize=\(Int(tableView.contentSize.height.rounded()))"
            )

            if didApplyInitialPosition == false, update.rowOrder.isEmpty == false {
                scrollToBottom(in: tableView, animated: false)
                didApplyInitialPosition = true
                offsetChangeReason = "initial_bottom"
                ChatMessageViewport.log("initial.ready", details: "rows=\(update.rows.count) session=\(update.sessionID.uuidString)")
                emitAsync {
                    self.parent.onInitialPositioned()
                }
            } else if let anchorSnapshot = update.anchorSnapshot {
                restoreAnchorSnapshot(anchorSnapshot, in: tableView)
                offsetChangeReason = update.anchorMode.rawValue
            } else if update.shouldStickToBottom, tableView.isDragging == false, tableView.isDecelerating == false {
                scrollToBottom(in: tableView, animated: false)
                offsetChangeReason = "stick_to_bottom"
            }

            executePendingCommandIfNeeded(in: tableView, reason: offsetChangeReason)
            reportNearBottomState(in: tableView)
            reportTrackedFrames(in: tableView)
            reportTopVisibleRow(in: tableView)
            let offsetAfter = tableView.contentOffset.y
            let postApplyDurationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
            let totalDurationMs = Int(((CACurrentMediaTime() - update.createdAt) * 1000).rounded())
            let heightHits = heightCacheHitCount - lastLoggedHeightCacheHits
            let heightMisses = heightCacheMissCount - lastLoggedHeightCacheMisses
            lastLoggedHeightCacheHits = heightCacheHitCount
            lastLoggedHeightCacheMisses = heightCacheMissCount
            ChatMessageViewport.log(
                "postApply.end",
                details: "offsetY=\(Int(offsetAfter.rounded())) offsetChanged=\(abs(offsetAfter - offsetBefore) > 0.5) reason=\(offsetChangeReason) postMs=\(postApplyDurationMs) totalMs=\(totalDurationMs) dragging=\(tableView.isDragging) decelerating=\(tableView.isDecelerating) heightHits=\(heightHits) heightMisses=\(heightMisses) skipped=\(skippedDuplicateUpdatesCount)"
            )
            isApplyingViewportUpdate = false
            flushPendingViewportUpdateIfNeeded(in: tableView)
        }

        private func completeSuccessfulApply(
            applyID: UUID,
            request: PendingViewportUpdate,
            tableView: UITableView,
            applyStartedAt: CFTimeInterval,
            method: String,
            reconfiguredCount: Int,
            forceLayoutBeforePostApply: Bool
        ) {
            guard activeApplyID == applyID else { return }
            activeApplyTimeoutTask?.cancel()
            activeApplyTimeoutTask = nil
            hasPendingPostApplyWork = true
            pendingPostApplyUpdate = request
            lastAppliedSignature = request.signature
            needsFullSnapshotApply = false
            if request.isInitialSnapshot {
                hasAppliedInitialSnapshot = true
            }
            if forceLayoutBeforePostApply {
                tableView.layoutIfNeeded()
            }
            let applyDurationMs = Int(((CACurrentMediaTime() - applyStartedAt) * 1000).rounded())
            ChatMessageViewport.log(
                "apply.completed",
                details: "rows=\(request.rows.count) inserted=\(request.insertedCount) deleted=\(request.deletedCount) reconfigured=\(reconfiguredCount) durationMs=\(applyDurationMs) session=\(request.sessionID.uuidString)"
            )
            activeApplyID = nil
            runPostApplyWorkIfPossible(
                in: tableView,
                update: request
            )
            ChatMessageViewport.log("apply.exit", details: "method=\(method)")
        }

        private func finishFailedApply(
            applyID: UUID,
            reason: String,
            request: PendingViewportUpdate,
            tableView: UITableView?
        ) {
            guard activeApplyID == applyID else { return }
            isPerformingInitialReload = false
            activeApplyTimeoutTask?.cancel()
            activeApplyTimeoutTask = nil
            activeApplyID = nil
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = nil
            scrollRecentlyActiveUntil = 0
            isApplyingViewportUpdate = false
            ChatMessageViewport.log(
                "apply.failed",
                details: "reason=\(reason) rows=\(request.rows.count) session=\(request.sessionID.uuidString)"
            )
            ChatMessageViewport.log("apply.exit", details: "method=failed")
            if let tableView {
                flushPendingViewportUpdateIfNeeded(in: tableView)
            }
        }

        private func emitAsync(_ action: @escaping () -> Void) {
            DispatchQueue.main.async(execute: action)
        }

        private func captureAnchorSnapshot(in tableView: UITableView) -> AnchorSnapshot? {
            guard let visibleIndexPaths = tableView.indexPathsForVisibleRows?.sorted() else { return nil }
            let visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
            let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom

            let preferredIndexPath = visibleIndexPaths.first(where: { indexPath in
                guard indexPath.row < rowOrder.count else { return false }
                let rowID = rowOrder[indexPath.row]
                guard let row = rowsByID[rowID] else { return false }
                let cachedHeight = cachedRowHeights[heightCacheKey(for: row, in: tableView)] ?? row.estimatedHeight
                guard row.shouldAvoidAnchor == false else { return false }
                guard cachedHeight <= max(800, tableView.bounds.height * 1.5) else { return false }
                let rowRect = tableView.rectForRow(at: indexPath)
                let visibleHeight = min(rowRect.maxY, visibleBottom) - max(rowRect.minY, visibleTop)
                return visibleHeight >= min(max(cachedHeight * 0.4, 28), cachedHeight)
            })

            guard let preferredIndexPath, preferredIndexPath.row < rowOrder.count else {
                ChatMessageViewport.log("anchor.capture.skipped", details: "reason=no_stable_candidate")
                return nil
            }
            let rowID = rowOrder[preferredIndexPath.row]
            let rowRect = tableView.rectForRow(at: preferredIndexPath)
            let cachedHeight = rowsByID[rowID].map { cachedRowHeights[heightCacheKey(for: $0, in: tableView)] ?? $0.estimatedHeight } ?? rowRect.height
            ChatMessageViewport.log(
                "anchor.capture",
                details: "rowId=\(rowID.uuidString) delta=\(Int((rowRect.minY - tableView.contentOffset.y).rounded())) height=\(Int(cachedHeight.rounded())) avoided=\(rowsByID[rowID]?.shouldAvoidAnchor == true)"
            )
            return AnchorSnapshot(
                rowID: rowID,
                deltaFromContentOffset: rowRect.minY - tableView.contentOffset.y
            )
        }

        private func restoreAnchorSnapshot(_ snapshot: AnchorSnapshot, in tableView: UITableView) {
            guard let newIndex = rowOrder.firstIndex(of: snapshot.rowID) else { return }
            let indexPath = IndexPath(row: newIndex, section: 0)
            tableView.scrollToRow(at: indexPath, at: .top, animated: false)
            let rect = tableView.rectForRow(at: indexPath)
            tableView.contentOffset.y = rect.minY - snapshot.deltaFromContentOffset
            ChatMessageViewport.log(
                "anchor.restore",
                details: "rowId=\(snapshot.rowID.uuidString) delta=\(Int(snapshot.deltaFromContentOffset.rounded()))"
            )
        }

        private func flushPendingViewportUpdateIfNeeded(in tableView: UITableView) {
            if let pendingPostApplyUpdate,
               hasPendingPostApplyWork,
               tableView.isDragging == false,
               tableView.isDecelerating == false,
               CACurrentMediaTime() >= scrollRecentlyActiveUntil {
                ChatMessageViewport.log("pending.flush", details: "kind=post_apply rows=\(pendingPostApplyUpdate.rows.count)")
                runPostApplyWorkIfPossible(in: tableView, update: pendingPostApplyUpdate)
                return
            }
            if let deferredViewportUpdateWhileScrolling,
               tableView.isDragging == false,
               tableView.isDecelerating == false,
               CACurrentMediaTime() >= scrollRecentlyActiveUntil {
                ChatMessageViewport.log("pending.flush", details: "kind=deferred_scroll rows=\(deferredViewportUpdateWhileScrolling.rows.count)")
                pendingViewportUpdate = deferredViewportUpdateWhileScrolling
                self.deferredViewportUpdateWhileScrolling = nil
            }
            guard pendingViewportUpdate != nil else { return }
            scheduleViewportUpdateIfNeeded(in: tableView, reason: "pending_flush")
        }

        private func scheduleScrollIdleFlush(in tableView: UITableView) {
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = Task { @MainActor in
                ChatMessageViewport.log("scroll.idleDebounce.begin", details: "delayMs=220")
                try? await Task.sleep(for: .milliseconds(220))
                guard Task.isCancelled == false else { return }
                guard tableView.isDragging == false, tableView.isDecelerating == false else { return }
                guard CACurrentMediaTime() >= scrollRecentlyActiveUntil else { return }
                ChatMessageViewport.log("scroll.idleDebounce.end", details: "offsetY=\(Int(tableView.contentOffset.y.rounded()))")
                self.flushPendingViewportUpdateIfNeeded(in: tableView)
            }
        }

        private func resetViewportState(for sessionID: UUID, on tableView: UITableView?) {
            currentSessionID = sessionID
            rowOrder = []
            rowContentVersions = [:]
            rowLayoutVersions = [:]
            rowsByID = [:]
            cachedRowHeights.removeAll()
            didApplyInitialPosition = false
            hasAppliedInitialSnapshot = false
            lastExecutedCommandToken = nil
            lastNearBottomState = true
            lastTriggeredTopRowID = nil
            lastReportedTopVisibleRowID = nil
            lastTopVisibleEmitAt = 0
            hasPendingPostApplyWork = false
            pendingPostApplyUpdate = nil
            pendingViewportUpdate = nil
            deferredViewportUpdateWhileScrolling = nil
            isViewportUpdateScheduled = false
            isApplyingViewportUpdate = false
            lastAppliedSignature = nil
            needsFullSnapshotApply = true
            activeApplyID = nil
            activeApplyTimeoutTask?.cancel()
            activeApplyTimeoutTask = nil
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = nil
            scrollRecentlyActiveUntil = 0
            if let tableView {
                dataSource = makeDataSource(for: tableView)
                tableView.dataSource = dataSource
            }
        }

        private func scheduleApplyTimeout(
            applyID: UUID,
            request: PendingViewportUpdate,
            snapshot: NSDiffableDataSourceSnapshot<Int, UUID>,
            tableView: UITableView
        ) {
            activeApplyTimeoutTask?.cancel()
            activeApplyTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard self.activeApplyID == applyID else { return }
                guard self.currentSessionID == request.sessionID else {
                    self.finishCancelledApplyIfNeeded(applyID: applyID, reason: "timeout_stale_session")
                    return
                }
                ChatMessageViewport.log(
                    "apply.timedOut",
                    details: "rows=\(request.rows.count) session=\(request.sessionID.uuidString) window=\(tableView.window != nil) currentSnapshot=\(self.dataSource?.snapshot().numberOfItems ?? -1) newSnapshot=\(snapshot.numberOfItems)"
                )
                self.isPerformingInitialReload = false
                self.dataSource?.applySnapshotUsingReloadData(snapshot, completion: nil)
                tableView.reloadData()
                self.completeSuccessfulApply(
                    applyID: applyID,
                    request: request,
                    tableView: tableView,
                    applyStartedAt: request.createdAt,
                    method: "timeoutRecoveryReloadData",
                    reconfiguredCount: request.isInitialSnapshot ? 0 : request.reconfiguredCount,
                    forceLayoutBeforePostApply: true
                )
            }
        }

        private func finishCancelledApplyIfNeeded(applyID: UUID, reason: String) {
            guard activeApplyID == applyID else { return }
            isPerformingInitialReload = false
            activeApplyTimeoutTask?.cancel()
            activeApplyTimeoutTask = nil
            activeApplyID = nil
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = nil
            scrollRecentlyActiveUntil = 0
            isApplyingViewportUpdate = false
            ChatMessageViewport.log("apply.cancelled", details: "reason=\(reason)")
            ChatMessageViewport.log("apply.exit", details: "method=cancelled")
            if let tableView = attachedTableView {
                flushPendingViewportUpdateIfNeeded(in: tableView)
            }
        }

        private func commandKind(_ command: ChatMessageViewportCommand?) -> String {
            guard let command else { return "none" }
            switch command.action {
            case .scrollToBottom:
                return "initialScrollToBottom"
            case .scrollToMessage:
                return "scrollToMessage"
            }
        }

        private func executePendingCommandIfNeeded(in tableView: UITableView, reason: String) {
            guard isPerformingInitialReload == false else {
                ChatMessageViewport.log("command.skipped", details: "reason=initial_reload")
                return
            }
            guard let command = parent.command else { return }
            guard lastExecutedCommandToken != command.token else { return }
            guard tableView.window != nil else {
                hasPendingPostApplyWork = true
                return
            }
            guard didApplyInitialPosition == false || (tableView.isDragging == false && tableView.isDecelerating == false) else {
                hasPendingPostApplyWork = true
                pendingPostApplyUpdate = pendingPostApplyUpdate ?? pendingViewportUpdate
                return
            }
            lastExecutedCommandToken = command.token
            ChatMessageViewport.log("command.execute", details: "kind=\(commandKind(command)) token=\(command.token) reason=\(reason)")

            switch command.action {
            case let .scrollToBottom(animated):
                scrollToBottom(in: tableView, animated: animated)
            case let .scrollToMessage(id, anchor, animated):
                scrollToMessage(id: id, anchor: anchor, in: tableView, animated: animated)
            }
            emitAsync { [parent] in
                parent.onCommandConsumed(command.token)
            }
        }

        private func distanceFromBottom(in tableView: UITableView) -> CGFloat {
            (tableView.contentSize.height + tableView.adjustedContentInset.bottom) - (tableView.contentOffset.y + tableView.bounds.height)
        }

        private func pruneHeightCache(removedIDs: Set<UUID>, changedRows: [ChatMessageViewportRow]) {
            if removedIDs.isEmpty == false {
                cachedRowHeights = cachedRowHeights.filter { removedIDs.contains($0.key.messageID) == false }
            }
            if changedRows.isEmpty == false {
                let changedMessageIDs = Set(changedRows.map(\.messageID))
                cachedRowHeights = cachedRowHeights.filter { changedMessageIDs.contains($0.key.messageID) == false }
            }
        }

        private func primeHeightCache(for rows: [ChatMessageViewportRow], in tableView: UITableView) {
            for row in rows {
                let cacheKey = heightCacheKey(for: row, in: tableView)
                if cachedRowHeights[cacheKey] == nil {
                    cachedRowHeights[cacheKey] = row.estimatedHeight
                }
            }
        }

        private func scrollToBottom(in tableView: UITableView, animated: Bool) {
            let targetY = max(-tableView.adjustedContentInset.top, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        }

        private func scrollToMessage(id: UUID, anchor: ChatMessageViewportScrollAnchor, in tableView: UITableView, animated: Bool) {
            guard let index = rowOrder.firstIndex(of: id) else { return }
            let indexPath = IndexPath(row: index, section: 0)
            let rect = tableView.rectForRow(at: indexPath)

            let targetY: CGFloat
            switch anchor {
            case .top:
                targetY = rect.minY - tableView.adjustedContentInset.top
            case .center:
                targetY = rect.midY - (tableView.bounds.height / 2)
            case .bottom:
                targetY = rect.maxY - tableView.bounds.height + tableView.adjustedContentInset.bottom
            }

            let clampedY = max(-tableView.adjustedContentInset.top, min(targetY, max(-tableView.adjustedContentInset.top, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)))
            tableView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        }

        private func reportNearBottomState(in tableView: UITableView) {
            guard isPerformingInitialReload == false else { return }
            let distanceFromBottom = (tableView.contentSize.height + tableView.adjustedContentInset.bottom) - (tableView.contentOffset.y + tableView.bounds.height)
            let isNearBottom = distanceFromBottom < parent.nearBottomThreshold
            guard isNearBottom != lastNearBottomState else { return }
            lastNearBottomState = isNearBottom
            ChatMessageViewport.log(
                "nearBottom.changed",
                details: "value=\(isNearBottom) distance=\(Int(distanceFromBottom.rounded()))"
            )
            emitAsync { [parent] in
                parent.onNearBottomChanged(isNearBottom)
            }
        }

        private func reportTrackedFrames(in tableView: UITableView) {
            guard isPerformingInitialReload == false else { return }
            guard parent.trackedMessageIDs.isEmpty == false else {
                emitAsync { [parent] in
                    parent.onTrackedFramesChanged([:])
                }
                return
            }

            var frames: [UUID: CGRect] = [:]
            for id in parent.trackedMessageIDs {
                guard let index = rowOrder.firstIndex(of: id) else { continue }
                let indexPath = IndexPath(row: index, section: 0)
                guard let cell = tableView.cellForRow(at: indexPath) else { continue }
                frames[id] = cell.frame
            }
            emitAsync { [parent] in
                parent.onTrackedFramesChanged(frames)
            }
        }

        private func reportTopVisibleRow(in tableView: UITableView) {
            guard isPerformingInitialReload == false else { return }
            let topInset = tableView.adjustedContentInset.top
            let probeY = tableView.contentOffset.y + topInset + 12
            let probePoint = CGPoint(x: max(tableView.bounds.midX, 1), y: probeY)
            let visibleRowID: UUID?
            if let indexPath = tableView.indexPathForRow(at: probePoint), indexPath.row < rowOrder.count {
                visibleRowID = rowOrder[indexPath.row]
            } else if let firstVisibleIndexPath = tableView.indexPathsForVisibleRows?.min(), firstVisibleIndexPath.row < rowOrder.count {
                visibleRowID = rowOrder[firstVisibleIndexPath.row]
            } else {
                visibleRowID = nil
            }

            guard visibleRowID != lastReportedTopVisibleRowID else { return }
            let now = CACurrentMediaTime()
            if (tableView.isDragging || tableView.isDecelerating || now < scrollRecentlyActiveUntil),
               now - lastTopVisibleEmitAt < 0.12 {
                return
            }
            lastReportedTopVisibleRowID = visibleRowID
            lastTopVisibleEmitAt = now
            emitAsync { [parent] in
                parent.onTopVisibleRowChanged(visibleRowID)
            }
        }

        private func triggerTopReachIfNeeded(in tableView: UITableView) {
            guard isPerformingInitialReload == false else {
                ChatMessageViewport.log("pagination.skip", details: "reason=initial_reload")
                return
            }
            guard tableView.contentOffset.y <= 120 else { return }
            guard let firstRowID = rowOrder.first else {
                ChatMessageViewport.log("pagination.skip", details: "reason=no_rows")
                return
            }
            guard lastTriggeredTopRowID != firstRowID else {
                ChatMessageViewport.log("pagination.skip", details: "reason=duplicate_anchor rowId=\(firstRowID.uuidString)")
                return
            }
            lastTriggeredTopRowID = firstRowID
            ChatMessageViewport.log("pagination.trigger", details: "rowId=\(firstRowID.uuidString) offsetY=\(Int(tableView.contentOffset.y.rounded()))")
            emitAsync { [parent] in
                parent.onReachTop()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isPerformingInitialReload == false else { return }
            guard let tableView = attachedTableView else { return }
            reportNearBottomState(in: tableView)
            reportTrackedFrames(in: tableView)
            reportTopVisibleRow(in: tableView)
            triggerTopReachIfNeeded(in: tableView)
        }

        func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
            guard isPerformingInitialReload == false else { return }
            guard indexPaths.contains(where: { $0.row < 8 }) else { return }
            triggerTopReachIfNeeded(in: tableView)
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            let probeRowID = indexPath.row < rowOrder.count ? rowOrder[indexPath.row] : nil
            ChatMessageViewport.log("estimatedHeight.begin", details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(probeRowID?.uuidString ?? "nil")")
            if isPerformingInitialReload {
                ChatMessageViewport.log("estimatedHeight.end", details: "indexPath=\(indexPath.section):\(indexPath.row) height=72 durationMs=0")
                return 72
            }
            guard indexPath.row < rowOrder.count else { return 120 }
            let rowID = rowOrder[indexPath.row]
            guard let row = rowsByID[rowID] else { return 120 }
            let cacheKey = heightCacheKey(for: row, in: tableView)
            if let height = cachedRowHeights[cacheKey] {
                heightCacheHitCount += 1
                ChatMessageViewport.log("estimatedHeight.end", details: "indexPath=\(indexPath.section):\(indexPath.row) height=\(Int(height.rounded())) durationMs=0 cache=hit")
                return height
            }
            heightCacheMissCount += 1
            let fallbackHeight = row.estimatedHeight
            cachedRowHeights[cacheKey] = fallbackHeight
            ChatMessageViewport.log("estimatedHeight.end", details: "indexPath=\(indexPath.section):\(indexPath.row) height=\(Int(fallbackHeight.rounded())) durationMs=0 cache=miss")
            return fallbackHeight
        }

        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            let startedAt = CACurrentMediaTime()
            let rowID = indexPath.row < rowOrder.count ? rowOrder[indexPath.row] : nil
            ChatMessageViewport.log("heightForRow.begin", details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(rowID?.uuidString ?? "nil")")
            let height: CGFloat
            if isPerformingInitialReload {
                height = 72
            } else if let rowID, let row = rowsByID[rowID] {
                let cacheKey = heightCacheKey(for: row, in: tableView)
                let cachedHeight = cachedRowHeights[cacheKey] ?? row.estimatedHeight
                cachedRowHeights[cacheKey] = cachedHeight
                height = cachedHeight
            } else {
                height = 120
            }
            let durationMs = Int(((CACurrentMediaTime() - startedAt) * 1000).rounded())
            let heightText = String(Int(height.rounded()))
            ChatMessageViewport.log("heightForRow.end", details: "indexPath=\(indexPath.section):\(indexPath.row) height=\(heightText) durationMs=\(durationMs)")
            return height
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            let probeRowID = indexPath.row < rowOrder.count ? rowOrder[indexPath.row] : nil
            ChatMessageViewport.log("willDisplay.begin", details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(probeRowID?.uuidString ?? "nil")")
            guard indexPath.row < rowOrder.count else { return }
            let rowID = rowOrder[indexPath.row]
            guard let row = rowsByID[rowID] else { return }
            guard isPerformingInitialReload == false else {
                ChatMessageViewport.log("willDisplay.end", details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(rowID.uuidString) initialReload=true")
                return
            }
            let cacheKey = heightCacheKey(for: row, in: tableView)
            let measuredHeight = max(cell.bounds.height, 1)
            let cachedHeight = cachedRowHeights[cacheKey] ?? 0
            guard abs(cachedHeight - measuredHeight) > 0.5 else { return }
            cachedRowHeights[cacheKey] = measuredHeight
            ChatMessageViewport.log("willDisplay.end", details: "indexPath=\(indexPath.section):\(indexPath.row) rowId=\(rowID.uuidString) height=\(Int(measuredHeight.rounded()))")
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            deferredViewportUpdateWhileScrolling = nil
            scrollIdleFlushTask?.cancel()
            scrollIdleFlushTask = nil
            scrollRecentlyActiveUntil = .greatestFiniteMagnitude
            ChatMessageViewport.log("scroll.beginDragging", details: "offsetY=\(Int(scrollView.contentOffset.y.rounded()))")
            emitAsync { [parent] in
                parent.onScrollInteractionChanged(true, "viewport_drag_begin")
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            ChatMessageViewport.log("scroll.endDragging", details: "offsetY=\(Int(scrollView.contentOffset.y.rounded())) decelerate=\(decelerate)")
            guard let tableView = attachedTableView else { return }
            guard decelerate == false else { return }
            scrollRecentlyActiveUntil = CACurrentMediaTime() + 0.22
            emitAsync { [parent] in
                parent.onScrollInteractionChanged(false, "viewport_drag_end")
            }
            scheduleScrollIdleFlush(in: tableView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            ChatMessageViewport.log("scroll.endDecelerating", details: "offsetY=\(Int(scrollView.contentOffset.y.rounded()))")
            guard let tableView = attachedTableView else { return }
            scrollRecentlyActiveUntil = CACurrentMediaTime() + 0.22
            emitAsync { [parent] in
                parent.onScrollInteractionChanged(false, "viewport_deceleration_end")
            }
            scheduleScrollIdleFlush(in: tableView)
        }

        private func heightCacheKey(for row: ChatMessageViewportRow, in tableView: UITableView) -> HeightCacheKey {
            HeightCacheKey(
                messageID: row.messageID,
                heightVersion: row.heightVersion,
                containerWidthBucket: Int((parent.containerWidth * 10).rounded()),
                contentSizeCategory: tableView.traitCollection.preferredContentSizeCategory.rawValue
            )
        }
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

private struct MessageInlineReactionOverlay: View {
    let message: Message
    let frame: CGRect
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let onDismiss: () -> Void
    let onOpenExpandedPicker: () -> Void
    let onSelectReaction: (String) -> Void

    @State private var hasAnimatedIn = false

    private let primaryReactions = ["❤️", "👎", "👍", "🔥", "🥰", "👏", "😁", "😮", "😢", "🙏"]

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: dismissAnimated)

            reactionBar(primaryReactions)
                .frame(width: reactionBarWidth)
                .position(x: reactionBarCenterX, y: reactionBarCenterY)
                .offset(y: hasAnimatedIn ? 0 : 10)
                .opacity(hasAnimatedIn ? 1 : 0)
                .zIndex(2)
        }
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
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
                        .fill(Color.black.opacity(0.42))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 8)
    }

    private var reactionBarHeight: CGFloat {
        64
    }

    private var reactionBarWidth: CGFloat {
        min(containerSize.width - 28, max(228, frame.width + 28))
    }

    private var reactionBarCenterX: CGFloat {
        min(max(frame.midX, reactionBarWidth / 2 + 14), containerSize.width - reactionBarWidth / 2 - 14)
    }

    private var reactionBarCenterY: CGFloat {
        let desired = frame.minY - 12 - reactionBarHeight / 2
        let minimum = safeAreaInsets.top + 10 + reactionBarHeight / 2
        return max(desired, minimum)
    }

    private func dismissAnimated() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.94)) {
            hasAnimatedIn = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: onDismiss)
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
    let hasReminder: Bool
    let hasFollowUpMark: Bool
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
    let onShowEditHistory: () -> Void
    let onRemindLater: () -> Void
    let onToggleFollowUp: () -> Void
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
            isReactionPanelPresented: false,
            isPressingActionMenu: false,
            isPinned: isPinned,
            isOutgoing: isOutgoing,
            canEdit: canEdit,
            canDelete: canDelete,
            isListInteracting: false,
            shouldAllowActionMenuPressing: { false },
            showsCommentsButton: showsCommentsButton,
            commentCount: commentCount,
            onEdit: {},
            onReply: {},
            onOpenReplyTarget: {},
            onCopy: {},
            onOpenActionMenu: {},
            onOpenReactionPanelOnly: {},
            onActionMenuPressingChanged: { _ in },
            onToggleReaction: { _ in },
            onOpenComments: {},
            onPin: {},
            onForward: {},
            onRequestDeleteOptions: {},
            onDelete: {},
            isFloatingPreview: true
        )
        .equatable()
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: previewBubbleWidth, alignment: isOutgoing ? .trailing : .leading)
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

        if message.editHistory.isEmpty == false {
            items.append(
                MessageActionMenuRowItem(title: "Edit History", systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onShowEditHistory)
            )
        }

        if message.isDeleted == false {
            items.append(
                MessageActionMenuRowItem(title: hasReminder ? "Reminder set" : "Remind in 1 hour", systemName: "bell.badge", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onRemindLater)
            )
            items.append(
                MessageActionMenuRowItem(title: hasFollowUpMark ? "Clear reply reminder" : "Don't forget reply", systemName: "arrowshape.turn.up.left.badge.clock", tint: PrimeTheme.Colors.accentSoft, textTint: .white, action: onToggleFollowUp)
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

private struct ChatReminderStore {
    static let shared = ChatReminderStore()

    private let defaults: UserDefaults
    private let storageKey = "chat.message_reminders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func reminderMessageIDs(chatID: UUID) -> [UUID] {
        let payload = storedPayload()
        return payload[chatID.uuidString, default: []].compactMap(UUID.init(uuidString:))
    }

    func saveReminder(messageID: UUID, chatID: UUID) {
        var payload = storedPayload()
        let chatKey = chatID.uuidString
        var ids = payload[chatKey, default: []]
        if ids.contains(messageID.uuidString) == false {
            ids.append(messageID.uuidString)
        }
        payload[chatKey] = ids
        persistPayload(payload)
    }

    static func notificationIdentifier(chatID: UUID, messageID: UUID) -> String {
        "prime.chat.reminder.\(chatID.uuidString).\(messageID.uuidString)"
    }

    private func storedPayload() -> [String: [String]] {
        defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
    }

    private func persistPayload(_ payload: [String: [String]]) {
        defaults.set(payload, forKey: storageKey)
    }
}

private struct ChatReplyFollowUpStore {
    static let shared = ChatReplyFollowUpStore()

    private let defaults: UserDefaults
    private let storageKey = "chat.reply_follow_up_marks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func messageIDs(chatID: UUID) -> [UUID] {
        let payload = defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        return payload[chatID.uuidString, default: []].compactMap(UUID.init(uuidString:))
    }

    func save(messageID: UUID, chatID: UUID) {
        var payload = defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        let key = chatID.uuidString
        var ids = payload[key, default: []]
        if ids.contains(messageID.uuidString) == false {
            ids.append(messageID.uuidString)
        }
        payload[key] = ids
        defaults.set(payload, forKey: storageKey)
    }

    func remove(messageID: UUID, chatID: UUID) {
        var payload = defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        let key = chatID.uuidString
        payload[key] = payload[key, default: []].filter { $0 != messageID.uuidString }
        defaults.set(payload, forKey: storageKey)
    }
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
                if let localURL = attachment.localURL {
                    LocalAttachmentImage(url: localURL, maxPixelSize: 1600) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        transitionPlaceholder
                    }
                } else if let remoteURL = attachment.remoteURL {
                    CachedRemoteImage(url: remoteURL, maxPixelSize: 1600) { image in
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
    let isReactionPanelPresented: Bool
    let isPressingActionMenu: Bool
    let isPinned: Bool
    let isOutgoing: Bool
    let canEdit: Bool
    let canDelete: Bool
    let isListInteracting: Bool
    let shouldAllowActionMenuPressing: () -> Bool
    let showsCommentsButton: Bool
    let commentCount: Int
    let onEdit: () -> Void
    let onReply: () -> Void
    let onOpenReplyTarget: () -> Void
    let onCopy: () -> Void
    let onOpenActionMenu: () -> Void
    let onOpenReactionPanelOnly: () -> Void
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
    @State private var isTrackingReplySwipe = false

    private enum BubbleBodyStyle {
        case standard
        case attachmentOnly
        case voiceOnly
        case callSummary
    }

    var body: some View {
        rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
        MessageBubbleRowLayout(
            isOutgoing: isOutgoing,
            rowWidth: effectiveRowWidth,
            contentMaxWidth: rowContentMaxWidth,
            usesFixedRowWidth: isFloatingPreview == false
        ) {
            rowBubbleContent
        }
        .padding(.leading, isFloatingPreview ? 0 : (isOutgoing ? rowOppositeSideInset : 0))
        .padding(.trailing, isFloatingPreview ? 0 : (isOutgoing ? 0 : rowOppositeSideInset))
        .frame(
            width: isFloatingPreview ? nil : rowWidth,
            alignment: .leading
        )
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
        case .callSummary:
            bubbleShell {
                callSummaryBubble
            }
        }
    }

    @ViewBuilder
    private func bubbleShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shell = content()
            .fixedSize(horizontal: isFloatingPreview, vertical: isFloatingPreview)
            .offset(x: swipeOffset)
            .opacity(isActionMenuPresented && isFloatingPreview == false ? 0 : 1)
            .scaleEffect(isActionMenuPresented ? 0.948 : 1, anchor: isOutgoing ? .trailing : .leading)
            .offset(y: isActionMenuPresented ? -8 : 0)
            .brightness(isActionMenuPresented ? -0.02 : 0)
            .saturation(isActionMenuPresented ? 0.96 : 1)
            .chatMessageMenuFrameReporter(
                messageID: message.id,
                isEnabled: shouldReportMenuFrame
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
                color: isOutgoing || isListInteracting ? Color.clear : Color.black.opacity(0.06),
                radius: isListInteracting ? 0 : 10,
                y: isListInteracting ? 0 : 4
            )
            .contentShape(Rectangle())
            .animation(.spring(response: 0.26, dampingFraction: 0.84), value: isActionMenuPresented)

        if isFloatingPreview {
            shell
        } else {
            #if os(tvOS)
            shell
            #elseif targetEnvironment(macCatalyst)
            shell
                .simultaneousGesture(replySwipeGesture)
                .contextMenu {
                    Button("Reply", action: onReply)
                    Button("Copy", action: onCopy)
                    Button("Forward", action: onForward)
                    if canEdit {
                        Button("Edit", action: onEdit)
                    }
                    if canDelete {
                        Button("Delete", role: .destructive, action: onRequestDeleteOptions)
                    }
                }
            #else
            shell
                .simultaneousGesture(replySwipeGesture)
                .simultaneousGesture(actionMenuHoldGesture)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            guard isTrackingReplySwipe == false else { return }
                            guard isListInteracting == false else { return }
                            guard abs(swipeOffset) < 2 else { return }
                            onOpenReactionPanelOnly()
                        }
                )
            #endif
        }
    }

    private var actionMenuHoldGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .onEnded { _ in
                guard isFloatingPreview == false else { return }
                guard isActionMenuPresented == false else { return }
                guard isReactionPanelPresented == false else { return }
                guard isTrackingReplySwipe == false else { return }
                guard abs(swipeOffset) < 2 else { return }
                guard isListInteracting == false else { return }
                guard shouldAllowActionMenuPressing() else { return }
                ChatMessageGestureDiagnostics.log("hold_activated", messageID: message.id, details: "menu=hold")
                onOpenActionMenu()
            }
    }

    private var replySwipeGesture: some Gesture {
        #if os(tvOS)
        TapGesture()
        #else
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                if isTrackingReplySwipe == false {
                    guard shouldBeginReplySwipe(translation: value.translation) else { return }
                    isTrackingReplySwipe = true
                    ChatMessageGestureDiagnostics.log(
                        "pan_swipe_start",
                        messageID: message.id,
                        details: "dx=\(Int(value.translation.width)) dy=\(Int(value.translation.height))"
                    )
                }

                if abs(value.translation.height) > 18 {
                    isTrackingReplySwipe = false
                    swipeOffset = 0
                    return
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
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        swipeOffset = 0
                    }
                }

                guard isTrackingReplySwipe else { return }
                if isOutgoing {
                    guard value.translation.width < -54 else { return }
                } else {
                    guard value.translation.width > 54 else { return }
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
                    bubbleTextBody(messageText)
                }
            }

            if let linkPreviewURL, message.isDeleted == false {
                RichLinkPreviewCard(url: linkPreviewURL, usesLightForeground: usesLightBubbleForeground)
            }

            if message.isDeleted == false && message.attachments.isEmpty == false {
                MessageAttachmentGallery(
                    attachments: message.attachments,
                    alignment: mediaHorizontalAlignment,
                    presentationContext: attachmentPresentationContext,
                    isInteractionEnabled: attachmentInteractionsEnabled,
                    defersHeavyMediaLoading: isListInteracting
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
                    isInteractionEnabled: attachmentInteractionsEnabled,
                    defersHeavyMediaLoading: isListInteracting
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
    private var callSummaryBubble: some View {
        if let payload = callSummaryPayload {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(callSummaryAccentColor(for: payload).opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: callSummaryIconName(for: payload))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(callSummaryAccentColor(for: payload))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(callSummaryTitle(for: payload))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(primaryBubbleTextColor)
                            .lineLimit(1)
                        Text(callSummarySubtitle(for: payload))
                            .font(.caption)
                            .foregroundStyle(secondaryBubbleTextColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if payload.durationSeconds > 0 {
                        Text(formattedCallDuration(payload.durationSeconds))
                            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(secondaryBubbleTextColor)
                    }
                }

                messageMetadata
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                bubbleSurface(cornerRadius: 20, includeTail: true)
            )
            .frame(maxWidth: maximumCallSummaryBubbleWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var replyPreviewView: some View {
        if message.isDeleted == false, let replyPreviewText {
            if isFloatingPreview {
                replyPreviewCard(replyPreviewText, expandsToAvailableWidth: false)
            } else {
                Button(action: onOpenReplyTarget) {
                    replyPreviewCard(replyPreviewText, expandsToAvailableWidth: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func replyPreviewCard(_ replyPreviewText: String, expandsToAvailableWidth: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(replyPreviewTitle)
                    .font(.caption.weight(.semibold))
                if expandsToAvailableWidth {
                    Spacer(minLength: 0)
                }
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
        .fixedSize(horizontal: expandsToAvailableWidth == false, vertical: false)
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
            if chat.type == .group, isOutgoing, let viewCount = message.viewCount, viewCount > 0 {
                Image(systemName: "eye")
                    .font(.system(size: 9.5, weight: .medium))
                Text("\(viewCount)")
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
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
        bubbleTextBody(text)
            .layoutPriority(1)
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

    @ViewBuilder
    private func bubbleTextBody(_ text: String) -> some View {
        let shouldUseCollapsedPreview = shouldUseCollapsedLongTextPreview(for: text)

        if RichMessageText.containsExplicitMarkup(text) {
            if RichMessageText.containsSpoilerMarkup(text) {
                RichBubbleTextView(
                    rawText: text,
                    fontSize: 13.5,
                    textColor: primaryBubbleTextColor
                )
            } else {
                Text(
                    RichMessageText.makeSwiftUIAttributedString(
                        from: text,
                        baseFontSize: 13.5,
                        textColor: primaryBubbleTextColor
                    )
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if RichMessageText.containsSmartDetections(text) {
            VStack(alignment: .leading, spacing: shouldUseCollapsedPreview ? 8 : 0) {
                Text(
                    RichMessageText.makeSmartDetectionSwiftUIAttributedString(
                        from: text,
                        baseFontSize: 13.5,
                        textColor: primaryBubbleTextColor
                    )
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(shouldUseCollapsedPreview ? 18 : nil)

                if shouldUseCollapsedPreview {
                    longTextPreviewFooter
                }
            }
        } else {
            VStack(alignment: .leading, spacing: shouldUseCollapsedPreview ? 8 : 0) {
                Text(text)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(primaryBubbleTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(shouldUseCollapsedPreview ? 18 : nil)

                if shouldUseCollapsedPreview {
                    longTextPreviewFooter
                }
            }
        }
    }

    @ViewBuilder
    private var longTextPreviewFooter: some View {
        Label("Long message preview", systemImage: "text.justify.leading")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(secondaryBubbleTextColor)
    }

    private var bubbleBodyStyle: BubbleBodyStyle {
        guard message.isDeleted == false else { return .standard }

        if callSummaryPayload != nil {
            return .callSummary
        }

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

    private func shouldUseCollapsedLongTextPreview(for text: String) -> Bool {
        text.count > ChatView.largeMessageCollapseThreshold
            && RichMessageText.containsExplicitMarkup(text) == false
    }

    private var linkPreviewURL: URL? {
        guard message.isDeleted == false else { return nil }
        guard message.attachments.isEmpty, message.voiceMessage == nil else { return nil }
        guard message.linkPreview?.isDisabled != true else { return nil }
        return message.linkPreview?.resolvedURL(in: message.text)
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
        case .callSummary:
            return maximumCallSummaryBubbleWidth
        }
    }

    private var maximumTextBubbleWidth: CGFloat {
        min(effectiveRowWidth, UIScreen.main.bounds.width * (prefersSeparatedMetadata ? 0.88 : 0.82))
    }

    private var maximumMediaBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.8, 308)
    }

    private var maximumVoiceBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.68, 262)
    }

    private var maximumCallSummaryBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.72, 276)
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

    private var callSummaryPayload: ChatCallSummaryCodec.Payload? {
        guard message.kind == .system else { return nil }
        return ChatCallSummaryCodec.decode(message.text)
    }

    private func callSummaryTitle(for payload: ChatCallSummaryCodec.Payload) -> String {
        switch payload.state {
        case .ended:
            return "Call ended"
        case .cancelled:
            return "Call canceled"
        case .rejected:
            return "Call rejected"
        case .missed:
            return "Missed call"
        case .ringing:
            return payload.direction == .incoming ? "Incoming call" : "Outgoing call"
        case .active:
            return "Call in progress"
        }
    }

    private func callSummarySubtitle(for payload: ChatCallSummaryCodec.Payload) -> String {
        if payload.durationSeconds > 0 {
            return payload.direction == .incoming ? "Incoming audio call" : "Outgoing audio call"
        }
        return payload.direction == .incoming ? "Incoming call" : "Outgoing call"
    }

    private func callSummaryIconName(for payload: ChatCallSummaryCodec.Payload) -> String {
        switch payload.state {
        case .missed:
            return "phone.badge.xmark.fill"
        case .rejected, .cancelled:
            return "phone.down.fill"
        case .ended:
            return payload.direction == .incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"
        case .ringing:
            return payload.direction == .incoming ? "phone.badge.plus.fill" : "phone.fill"
        case .active:
            return "phone.connection.fill"
        }
    }

    private func callSummaryAccentColor(for payload: ChatCallSummaryCodec.Payload) -> Color {
        switch payload.state {
        case .missed, .rejected:
            return PrimeTheme.Colors.warning
        case .cancelled, .ended:
            return PrimeTheme.Colors.accent
        case .ringing, .active:
            return PrimeTheme.Colors.smartAccent
        }
    }

    private func formattedCallDuration(_ duration: Int) -> String {
        let safeDuration = max(duration, 0)
        let hours = safeDuration / 3600
        let minutes = (safeDuration % 3600) / 60
        let seconds = safeDuration % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return "\(minutes):" + String(format: "%02d", seconds)
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
            let text = RichMessageText.plainText(from: replyMessage.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
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

    private var shouldReportMenuFrame: Bool {
        isFloatingPreview == false && (isActionMenuPresented || isReactionPanelPresented || isPressingActionMenu)
    }

    private func shouldBeginReplySwipe(translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        guard horizontal > 16 else { return false }
        guard horizontal > vertical * 1.45 else { return false }
        guard vertical < 14 else { return false }

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

extension MessageBubbleView: Equatable {
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.chat == rhs.chat
            && lhs.message == rhs.message
            && lhs.replyMessage == rhs.replyMessage
            && lhs.rowWidth == rhs.rowWidth
            && lhs.currentUserID == rhs.currentUserID
            && lhs.showsIncomingSenderName == rhs.showsIncomingSenderName
            && lhs.showsIncomingAvatar == rhs.showsIncomingAvatar
            && lhs.showsTail == rhs.showsTail
            && lhs.isActionMenuPresented == rhs.isActionMenuPresented
            && lhs.isReactionPanelPresented == rhs.isReactionPanelPresented
            && lhs.isPressingActionMenu == rhs.isPressingActionMenu
            && lhs.isPinned == rhs.isPinned
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.canEdit == rhs.canEdit
            && lhs.canDelete == rhs.canDelete
            && lhs.isListInteracting == rhs.isListInteracting
            && lhs.showsCommentsButton == rhs.showsCommentsButton
            && lhs.commentCount == rhs.commentCount
            && lhs.isFloatingPreview == rhs.isFloatingPreview
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
    let usesFixedRowWidth: Bool

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
            return CGSize(width: usesFixedRowWidth ? rowWidth : 0, height: 0)
        }

        let measuredSize = subview.sizeThatFits(
            ProposedViewSize(width: contentMaxWidth, height: proposal.height)
        )
        cache.bubbleSize = measuredSize
        return CGSize(
            width: usesFixedRowWidth ? rowWidth : measuredSize.width,
            height: measuredSize.height
        )
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
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                PrimeTheme.Colors.chatWallpaperBase,
                                PrimeTheme.Colors.chatWallpaperBase.opacity(0.92),
                                PrimeTheme.Colors.chatWallpaperOverlay.opacity(0.38)
                            ]
                            : [
                                PrimeTheme.Colors.chatWallpaperBase,
                                PrimeTheme.Colors.chatWallpaperBase.opacity(0.97),
                                PrimeTheme.Colors.chatWallpaperOverlay.opacity(0.18)
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
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

@MainActor
final class ChatViewModel: ObservableObject {
    enum Paging {
        static let initialPageSize = 50
        static let olderPageSize = 60
        static let refreshWindowLimit = 160
        static let collapsedBottomWindowSize = 80
        static let autoCollapseWindowThreshold = 140
        static let dynamicTrimHeadroom = 24
        static let dynamicTrimTriggerCount = 40
    }

    static let maximumEditWindow: TimeInterval = 48 * 60 * 60
    private let heavyChatFetchTimeout: Duration = .seconds(5)

    @Published private(set) var messages: [Message] = []
    @Published private(set) var messageIDs: [UUID] = []
    @Published private(set) var messageRevision: Int = 0
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlderMessages = false
    @Published var draftText = ""
    @Published private(set) var isSending = false
    @Published private(set) var editingMessage: Message?
    @Published var messageActionError = ""
    private var preEditingDraftText = ""
    private var soundCurrentUserID: UUID?
    private var activeSessionID = UUID()
    private var activeChatID: UUID?
    private var activeMode: ChatMode?

    @MainActor
    func beginSession(chat: Chat, currentUserID: UUID, sessionID: UUID) {
        activeSessionID = sessionID
        activeChatID = chat.id
        activeMode = chat.mode
        soundCurrentUserID = currentUserID
        editingMessage = nil
        messageActionError = ""
        hasOlderMessages = false
        isLoadingOlderMessages = false
        commitMessages([])
    }

    @MainActor
    func isActiveSession(_ sessionID: UUID, chat: Chat) -> Bool {
        activeSessionID == sessionID && activeChatID == chat.id && activeMode == chat.mode
    }

    @MainActor
    func hydrateMessages(chat: Chat, repository: ChatRepository, localStore: LocalStore, currentUserID: UUID, sessionID: UUID) async {
        soundCurrentUserID = currentUserID
        let initialMessages = await preferredLocalMessages(
            chat: chat,
            repository: repository,
            currentUserID: currentUserID,
            limit: Paging.initialPageSize
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        replaceMessageWindow(with: initialMessages, preserveExistingWhenEmpty: true)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
        guard isActiveSession(sessionID, chat: chat) else { return }
        if let savedDraft = await localStore.loadDraft(chatID: chat.id, mode: chat.mode) {
            guard isActiveSession(sessionID, chat: chat) else { return }
            self.draftText = savedDraft.text
        } else {
            guard isActiveSession(sessionID, chat: chat) else { return }
            self.draftText = ""
        }
    }

    @MainActor
    func refreshMessages(chat: Chat, repository: ChatRepository, currentUserID: UUID, sessionID: UUID) async {
        soundCurrentUserID = currentUserID
        let localWindowLimit = min(max(Paging.initialPageSize, messages.count), Paging.refreshWindowLimit)
        let immediateMessages = await preferredLocalMessages(
            chat: chat,
            repository: repository,
            currentUserID: currentUserID,
            limit: localWindowLimit
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        if messages.isEmpty, immediateMessages.isEmpty == false {
            replaceMessageWindow(with: immediateMessages, preserveExistingWhenEmpty: true)
            await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
            guard isActiveSession(sessionID, chat: chat) else { return }
        }

        guard await fetchRemoteMessagesWithTimeout(chat: chat, repository: repository) else {
            let fallbackMessages = await preferredLocalMessages(
                chat: chat,
                repository: repository,
                currentUserID: currentUserID,
                limit: localWindowLimit
            )
            guard isActiveSession(sessionID, chat: chat) else { return }
            replaceMessageWindow(with: fallbackMessages, preserveExistingWhenEmpty: true)
            await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
            return
        }

        let latestMessages = await preferredLocalMessages(
            chat: chat,
            repository: repository,
            currentUserID: currentUserID,
            limit: localWindowLimit
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        replaceMessageWindow(with: latestMessages, preserveExistingWhenEmpty: true)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
    }

    @MainActor
    func refreshLocalSnapshot(chat: Chat, repository: ChatRepository, currentUserID: UUID, sessionID: UUID) async {
        soundCurrentUserID = currentUserID
        let latestMessages = await preferredLocalMessages(
            chat: chat,
            repository: repository,
            currentUserID: currentUserID,
            limit: min(max(Paging.initialPageSize, messages.count), Paging.refreshWindowLimit)
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        replaceMessageWindow(with: latestMessages, preserveExistingWhenEmpty: true)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
    }

    @MainActor
    func loadOlderMessages(chat: Chat, currentUserID: UUID, sessionID: UUID) async -> UUID? {
        guard isLoadingOlderMessages == false else { return nil }
        guard let anchorMessage = messages.first else { return nil }
        guard hasOlderMessages else { return nil }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        let olderMessages = await ChatMessagePageStore.shared.page(
            before: anchorMessage,
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode,
            limit: Paging.olderPageSize
        )
        guard isActiveSession(sessionID, chat: chat) else { return nil }
        guard olderMessages.isEmpty == false else {
            hasOlderMessages = false
            return nil
        }

        let anchorMessageID = anchorMessage.id
        replaceMessageWindow(with: olderMessages + messages, preserveExistingWhenEmpty: false)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
        return anchorMessageID
    }

    @MainActor
    func jumpToLatestWindow(chat: Chat, currentUserID: UUID, sessionID: UUID) async {
        soundCurrentUserID = currentUserID
        let latestMessages = await ChatMessagePageStore.shared.latestPage(
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode,
            limit: Paging.collapsedBottomWindowSize
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        replaceMessageWindow(with: latestMessages, preserveExistingWhenEmpty: true)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
    }

    @MainActor
    func collapseToLatestWindowIfNeeded(chat: Chat, currentUserID: UUID, sessionID: UUID) async {
        guard messages.count > Paging.autoCollapseWindowThreshold else { return }
        soundCurrentUserID = currentUserID
        let latestMessages = await ChatMessagePageStore.shared.latestPage(
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode,
            limit: Paging.collapsedBottomWindowSize
        )
        guard isActiveSession(sessionID, chat: chat) else { return }
        replaceMessageWindow(with: latestMessages, preserveExistingWhenEmpty: true)
        await refreshOlderAvailability(chat: chat, currentUserID: currentUserID)
    }

    @MainActor
    func trimLoadedHistoryBefore(anchorMessageID: UUID) -> Bool {
        guard messages.count > Paging.refreshWindowLimit else { return false }
        guard let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID }) else { return false }

        let trimPrefixCount = max(anchorIndex - Paging.dynamicTrimHeadroom, 0)
        guard trimPrefixCount >= Paging.dynamicTrimTriggerCount else { return false }

        let nextMessages = Array(messages.dropFirst(trimPrefixCount))
        guard nextMessages.count < messages.count else { return false }

        commitMessages(nextMessages)
        return true
    }

    @MainActor
    func submitComposer(_ draft: OutgoingMessageDraft, chat: Chat, senderID: UUID, repository: ChatRepository) async throws -> Message? {
        guard draft.hasContent else { return nil }

        if let editingMessage {
            guard isSending == false else { return nil }
            isSending = true
            defer { isSending = false }
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

        let preparedDraft = preparedOutgoingDraft(from: draft)
        let optimisticMessage = makeOptimisticMessage(from: preparedDraft, chat: chat, senderID: senderID)
        logSendEvent("optimistic.inserted", clientMessageID: optimisticMessage.clientMessageID, details: "text=\((optimisticMessage.text ?? "").count) attachments=\(optimisticMessage.attachments.count)")
        replaceOrAppend(optimisticMessage)
        draftText = ""
        messageActionError = ""
        if AudioRecorderController.hasActiveRecording() == false {
            MessageSoundEffectPlayer.shared.playSend()
        }
        Task { @MainActor in
            await sendOptimisticMessage(
                preparedDraft,
                optimisticMessage: optimisticMessage,
                in: chat,
                senderID: senderID,
                repository: repository
            )
        }
        return optimisticMessage
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
        guard message.kind != .system else { return false }
        guard message.senderID == currentUserID && message.canEditText else { return false }
        return Date.now.timeIntervalSince(message.createdAt) <= Self.maximumEditWindow
    }

    func canDelete(_ message: Message, currentUserID: UUID) -> Bool {
        guard message.kind != .system else { return false }
        return message.senderID == currentUserID && message.isDeleted == false
    }

    @MainActor
    func replaceOrAppend(_ message: Message) {
        mergeIncomingMessages([message])
    }

    @MainActor
    private func preparedOutgoingDraft(from draft: OutgoingMessageDraft) -> OutgoingMessageDraft {
        var nextDraft = draft
        if nextDraft.clientMessageID == nil {
            nextDraft.clientMessageID = UUID()
        }
        if nextDraft.createdAt == nil {
            nextDraft.createdAt = .now
        }
        return nextDraft
    }

    @MainActor
    private func makeOptimisticMessage(from draft: OutgoingMessageDraft, chat: Chat, senderID: UUID) -> Message {
        let createdAt = draft.createdAt ?? .now
        let clientMessageID = draft.clientMessageID ?? UUID()
        let messageID = clientMessageID
        return Message(
            id: messageID,
            chatID: chat.id,
            senderID: senderID,
            clientMessageID: clientMessageID,
            senderDisplayName: nil,
            mode: chat.mode,
            deliveryState: draft.deliveryStateOverride ?? (chat.mode == .offline ? .offline : .online),
            deliveryRoute: draft.deliveryStateOverride == .offline ? .queued : nil,
            kind: draft.voiceMessage != nil ? .voice : (draft.attachments.first.map { attachment in
                switch attachment.type {
                case .photo: return MessageKind.photo
                case .video: return MessageKind.video
                case .document: return MessageKind.document
                case .audio: return MessageKind.audio
                case .contact: return MessageKind.contact
                case .location: return MessageKind.location
                }
            } ?? .text),
            text: draft.normalizedText,
            attachments: draft.attachments,
            linkPreview: draft.linkPreview,
            replyToMessageID: draft.replyToMessageID,
            replyPreview: draft.replyPreview,
            communityContext: draft.communityContext,
            deliveryOptions: draft.deliveryOptions,
            status: .sending,
            createdAt: createdAt,
            editedAt: nil,
            editHistory: [],
            deletedForEveryoneAt: nil,
            reactions: [],
            mentions: draft.mentions,
            viewCount: nil,
            voiceMessage: draft.voiceMessage,
            liveLocation: nil
        )
    }

    @MainActor
    private func sendOptimisticMessage(
        _ draft: OutgoingMessageDraft,
        optimisticMessage: Message,
        in chat: Chat,
        senderID: UUID,
        repository: ChatRepository
    ) async {
        logSendEvent("send.begin", clientMessageID: optimisticMessage.clientMessageID)
        do {
            let outgoing = try await repository.sendMessage(draft, in: chat, senderID: senderID)
            guard activeChatID == chat.id else { return }
            let reconciled = outgoing
                .mergingLocalObjectState(from: optimisticMessage)
                .applyingDraftObjectState(from: draft)
            logSendEvent("server.ack", clientMessageID: optimisticMessage.clientMessageID, details: "serverMessageID=\(reconciled.id.uuidString)")
            replaceOrAppend(reconciled)
            logSendEvent("reconcile.success", clientMessageID: optimisticMessage.clientMessageID)
        } catch {
            guard activeChatID == chat.id else { return }
            markOutgoingMessageFailed(
                clientMessageID: optimisticMessage.clientMessageID,
                fallbackText: optimisticMessage.text,
                error: error
            )
            logSendEvent(
                "send.failed",
                clientMessageID: optimisticMessage.clientMessageID,
                details: error.localizedDescription
            )
        }
    }

    @MainActor
    private func markOutgoingMessageFailed(clientMessageID: UUID, fallbackText: String?, error: Error) {
        guard let index = messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) else {
            messageActionError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
            return
        }

        var nextMessages = messages
        nextMessages[index].status = .failed
        if let fallbackText, (nextMessages[index].text?.isEmpty ?? true) {
            nextMessages[index].text = fallbackText
        }
        commitMessages(nextMessages)
        messageActionError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
    }

    @MainActor
    private func logSendEvent(_ step: String, clientMessageID: UUID, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        print("PUSHTRACE ChatSend step=\(step) clientMessageId=\(clientMessageID.uuidString) chat=\(activeChatID?.uuidString ?? "nil") session=\(activeSessionID.uuidString) main=\(Thread.isMainThread)\(suffix)")
    }

    @MainActor
    private func preferredLocalMessages(
        chat: Chat,
        repository: ChatRepository,
        currentUserID: UUID,
        limit: Int
    ) async -> [Message] {
        let pageStoreMessages = await ChatMessagePageStore.shared.latestPage(
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode,
            limit: limit
        )
        if pageStoreMessages.isEmpty == false {
            return pageStoreMessages
        }

        let cachedMessages = await repository.cachedMessages(chatID: chat.id, mode: chat.mode)
        if cachedMessages.isEmpty == false {
            await ChatMessagePageStore.shared.replaceMessages(
                cachedMessages,
                chatID: chat.id,
                userID: currentUserID,
                mode: chat.mode
            )
            return Array(cachedMessages.suffix(limit))
        }

        let snapshotMessages = await ChatSnapshotStore.shared.loadMessages(
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode
        )
        if snapshotMessages.isEmpty == false {
            await ChatMessagePageStore.shared.replaceMessages(
                snapshotMessages,
                chatID: chat.id,
                userID: currentUserID,
                mode: chat.mode
            )
            return Array(snapshotMessages.suffix(limit))
        }

        let sharedSnapshotMessages = await ChatSnapshotStore.shared.loadSharedMessages(
            chatID: chat.id,
            userID: currentUserID
        )
        if sharedSnapshotMessages.isEmpty == false {
            await ChatMessagePageStore.shared.replaceMessages(
                sharedSnapshotMessages,
                chatID: chat.id,
                userID: currentUserID,
                mode: chat.mode
            )
            return Array(sharedSnapshotMessages.suffix(limit))
        }

        return []
    }

    @MainActor
    private func fetchRemoteMessagesWithTimeout(chat: Chat, repository: ChatRepository) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await repository.fetchMessages(chatID: chat.id, mode: chat.mode)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: self.heavyChatFetchTimeout)
                return false
            }

            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
    }

    @MainActor
    private func refreshOlderAvailability(chat: Chat, currentUserID: UUID) async {
        guard let oldestMessage = messages.first else {
            hasOlderMessages = false
            return
        }
        hasOlderMessages = await ChatMessagePageStore.shared.hasMessages(
            before: oldestMessage,
            chatID: chat.id,
            userID: currentUserID,
            mode: chat.mode
        )
    }

    @MainActor
    private func commitMessages(_ nextMessages: [Message]) {
        guard nextMessages != messages else {
            return
        }

        messages = nextMessages
        messageIDs = nextMessages.map(\.id)
        messageRevision &+= 1
    }

    @MainActor
    private func mergeSingleMessage(_ message: Message) -> Bool {
        if let existingIndex = messages.firstIndex(where: { $0.clientMessageID == message.clientMessageID }) {
            let existing = messages[existingIndex]
            let merged = message.mergingLocalObjectState(from: existing)

            guard merged != existing else {
                return true
            }

            if merged.createdAt == existing.createdAt {
                var nextMessages = messages
                nextMessages[existingIndex] = merged
                commitMessages(nextMessages)
                return true
            }

            return false
        }

        guard let lastMessage = messages.last else {
            commitMessages([message])
            return true
        }

        let shouldAppendAtEnd = message.createdAt > lastMessage.createdAt
            || (message.createdAt == lastMessage.createdAt && message.id.uuidString >= lastMessage.id.uuidString)

        guard shouldAppendAtEnd else {
            return false
        }

        var nextMessages = messages
        nextMessages.append(message)
        commitMessages(nextMessages)
        return true
    }

    @MainActor
    private func replaceMessageWindow(with fetchedMessages: [Message], preserveExistingWhenEmpty: Bool) {
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

        let existingByClientMessageID = Dictionary(uniqueKeysWithValues: messages.map { ($0.clientMessageID, $0) })
        var normalizedByClientMessageID: [UUID: Message] = [:]
        normalizedByClientMessageID.reserveCapacity(normalizedIncoming.count)
        for message in normalizedIncoming {
            if let existing = existingByClientMessageID[message.clientMessageID] {
                normalizedByClientMessageID[message.clientMessageID] = message.mergingLocalObjectState(from: existing)
            } else {
                normalizedByClientMessageID[message.clientMessageID] = message
            }
        }
        for existing in messages where isPendingLocalMessage(existing) {
            guard normalizedByClientMessageID[existing.clientMessageID] == nil else { continue }
            normalizedByClientMessageID[existing.clientMessageID] = existing
        }

        let nextMessages = normalizedByClientMessageID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            if lhs.id != rhs.id {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.clientMessageID.uuidString < rhs.clientMessageID.uuidString
        }

        guard messages.isEmpty == false else {
            commitMessages(nextMessages)
            return
        }

        guard nextMessages != messages else {
            return
        }

        commitMessages(nextMessages)

        if shouldPlayIncomingSound, AudioRecorderController.hasActiveRecording() == false {
            MessageSoundEffectPlayer.shared.playReceive()
        }
    }

    @MainActor
    private func mergeIncomingMessages(_ fetchedMessages: [Message]) {
        let normalizedIncoming = fetchedMessages.sorted(by: { $0.createdAt < $1.createdAt })
        let existingClientMessageIDs = Set(messages.map(\.clientMessageID))
        let shouldPlayIncomingSound = messages.isEmpty == false && normalizedIncoming.contains { message in
            guard existingClientMessageIDs.contains(message.clientMessageID) == false else { return false }
            guard let soundCurrentUserID else { return false }
            return message.senderID != soundCurrentUserID && message.isDeleted == false
        }

        guard messages.isEmpty == false else {
            commitMessages(normalizedIncoming)
            return
        }

        if normalizedIncoming.count == 1, let singleMessage = normalizedIncoming.first,
           mergeSingleMessage(singleMessage) {
            if shouldPlayIncomingSound, AudioRecorderController.hasActiveRecording() == false {
                MessageSoundEffectPlayer.shared.playReceive()
            }
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

        commitMessages(mergedMessages)

        if shouldPlayIncomingSound, AudioRecorderController.hasActiveRecording() == false {
            MessageSoundEffectPlayer.shared.playReceive()
        }
    }

    private func isPendingLocalMessage(_ message: Message) -> Bool {
        switch message.status {
        case .localPending, .sending, .failed:
            return true
        default:
            return false
        }
    }

    @MainActor
    func removeMessageLocally(clientMessageID: UUID) {
        var nextMessages = messages
        nextMessages.removeAll(where: { $0.clientMessageID == clientMessageID })
        commitMessages(nextMessages)
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
