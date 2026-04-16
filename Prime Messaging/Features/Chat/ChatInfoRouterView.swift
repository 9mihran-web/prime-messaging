import SwiftUI

struct ChatInfoRouterView: View {
    @Binding var chat: Chat
    var onRequestSearch: (() -> Void)? = nil
    var onGroupDeleted: (() -> Void)? = nil
    var onGroupLeft: (() -> Void)? = nil

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var resolvedKind: CommunityKind?
    @State private var didAttemptResolve = false

    init(
        chat: Binding<Chat>,
        onRequestSearch: (() -> Void)? = nil,
        onGroupDeleted: (() -> Void)? = nil,
        onGroupLeft: (() -> Void)? = nil
    ) {
        _chat = chat
        self.onRequestSearch = onRequestSearch
        self.onGroupDeleted = onGroupDeleted
        self.onGroupLeft = onGroupLeft
        _resolvedKind = State(initialValue: chat.wrappedValue.communityDetails?.kind)
    }

    var body: some View {
        content
            .task {
                await resolveKindIfNeeded()
            }
            .onChange(of: chat.communityDetails?.kind) { newValue in
                if let newValue {
                    resolvedKind = newValue
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch resolvedKind {
        case .channel:
            ChannelInfoView(
                chat: $chat,
                onRequestSearch: onRequestSearch,
                onGroupDeleted: onGroupDeleted,
                onGroupLeft: onGroupLeft
            )
        case .community:
            CommunityInfoView(
                chat: $chat,
                onRequestSearch: onRequestSearch,
                onGroupDeleted: onGroupDeleted,
                onGroupLeft: onGroupLeft
            )
        case .supergroup:
            SupergroupInfoView(
                chat: $chat,
                onRequestSearch: onRequestSearch,
                onGroupDeleted: onGroupDeleted,
                onGroupLeft: onGroupLeft
            )
        case .group:
            GroupInfoView(
                chat: $chat,
                onRequestSearch: onRequestSearch,
                onGroupDeleted: onGroupDeleted,
                onGroupLeft: onGroupLeft
            )
        case nil:
            if didAttemptResolve {
                GroupInfoView(
                    chat: $chat,
                    onRequestSearch: onRequestSearch,
                    onGroupDeleted: onGroupDeleted,
                    onGroupLeft: onGroupLeft
                )
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading chat info...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color.clear)
            }
        }
    }

    @MainActor
    private func resolveKindIfNeeded() async {
        defer { didAttemptResolve = true }

        let normalizedChat = await CommunityChatMetadataStore.shared.normalize(chat, ownerUserID: appState.currentUser.id)
        if normalizedChat.communityDetails != chat.communityDetails {
            chat = normalizedChat
        }

        if let kind = normalizedChat.communityDetails?.kind {
            resolvedKind = kind
            return
        }

        let cachedChats = await environment.chatRepository.cachedChats(mode: chat.mode, for: appState.currentUser.id)
        if let matchedCachedChat = matchingChat(for: chat, in: cachedChats),
           let kind = matchedCachedChat.communityDetails?.kind {
            chat = matchedCachedChat
            resolvedKind = kind
            return
        }

        guard chat.mode != .offline else { return }

        guard let refreshedChat = matchingChat(
            for: chat,
            in: (try? await environment.chatRepository.fetchChats(mode: chat.mode, for: appState.currentUser.id)) ?? []
        )
        else {
            return
        }

        if let kind = refreshedChat.communityDetails?.kind {
            chat = refreshedChat
            resolvedKind = kind
        }
    }

    private func matchingChat(for target: Chat, in chats: [Chat]) -> Chat? {
        if let exactMatch = chats.first(where: { $0.id == target.id }) {
            return exactMatch
        }

        if let targetGroupID = target.group?.id,
           let groupMatch = chats.first(where: { $0.group?.id == targetGroupID }) {
            return groupMatch
        }

        let targetParticipantIDs = Set(target.participantIDs)
        if targetParticipantIDs.isEmpty == false,
           let participantMatch = chats.first(where: { Set($0.participantIDs) == targetParticipantIDs && $0.type == target.type }) {
            return participantMatch
        }

        return nil
    }
}
