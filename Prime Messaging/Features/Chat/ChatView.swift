import Combine
import SwiftUI

struct ChatView: View {
    let chat: Chat

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if chat.mode == .offline {
                OfflineSessionBanner()
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.bottom, PrimeTheme.Spacing.small)
            }

            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(spacing: PrimeTheme.Spacing.medium) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(
                                message: message,
                                isOutgoing: message.senderID == appState.currentUser.id
                            )
                        }
                    }
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.vertical, PrimeTheme.Spacing.medium)
                }
                .background(PrimeTheme.Colors.background)
            }

            Divider()
            MessageComposerView(
                draftText: $viewModel.draftText,
                onSend: { text in
                    await viewModel.sendMessage(
                        text,
                        chat: chat,
                        senderID: appState.currentUser.id,
                        repository: environment.chatRepository
                    )
                }
            )
        }
        .navigationTitle(chat.resolvedDisplayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appState.selectedChat = chat
        }
        .onDisappear {
            if appState.selectedChat?.id == chat.id {
                appState.selectedChat = nil
            }
        }
        .task {
            await viewModel.loadMessages(chat: chat, repository: environment.chatRepository)
        }
        .task(id: chat.id) {
            while !Task.isCancelled {
                await viewModel.refreshMessages(chat: chat, repository: environment.chatRepository)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct OfflineSessionBanner: View {
    var body: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("offline.banner".localized)
                .font(.subheadline)
            Spacer()
        }
        .padding(PrimeTheme.Spacing.medium)
        .background(PrimeTheme.Colors.offlineAccent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
    }
}

struct MessageBubbleView: View {
    let message: Message
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                if let text = message.text {
                    Text(text)
                        .foregroundStyle(isOutgoing ? Color.white : PrimeTheme.Colors.textPrimary)
                }

                HStack(spacing: PrimeTheme.Spacing.xSmall) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                    if isOutgoing {
                        Text(message.status.rawValue.capitalized)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(isOutgoing ? Color.white.opacity(0.82) : PrimeTheme.Colors.textSecondary)
            }
            .padding(.horizontal, PrimeTheme.Spacing.medium)
            .padding(.vertical, PrimeTheme.Spacing.small)
            .background(isOutgoing ? PrimeTheme.Colors.bubbleOutgoing : PrimeTheme.Colors.bubbleIncoming)
            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.bubble, style: .continuous))
            if !isOutgoing { Spacer(minLength: 40) }
        }
    }
}

final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draftText = ""

    @MainActor
    func loadMessages(chat: Chat, repository: ChatRepository) async {
        do {
            messages = try await repository.fetchMessages(chatID: chat.id, mode: chat.mode)
            draftText = chat.draft?.text ?? ""
        } catch {
            messages = []
        }
    }

    @MainActor
    func refreshMessages(chat: Chat, repository: ChatRepository) async {
        do {
            messages = try await repository.fetchMessages(chatID: chat.id, mode: chat.mode)
        } catch { }
    }

    @MainActor
    func sendMessage(_ text: String, chat: Chat, senderID: UUID, repository: ChatRepository) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let outgoing = try await repository.sendMessage(trimmed, in: chat.id, mode: chat.mode, senderID: senderID)
            messages.append(outgoing)
            draftText = ""
        } catch { }
    }
}
