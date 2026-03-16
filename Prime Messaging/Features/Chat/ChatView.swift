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
                                chat: chat,
                                message: message,
                                isOutgoing: message.senderID == appState.currentUser.id,
                                canEdit: viewModel.canEdit(message, currentUserID: appState.currentUser.id),
                                canDelete: viewModel.canDelete(message, currentUserID: appState.currentUser.id),
                                onEdit: {
                                    viewModel.beginEditing(message)
                                },
                                onDelete: {
                                    Task {
                                        await viewModel.deleteMessage(
                                            message.id,
                                            chat: chat,
                                            requesterID: appState.currentUser.id,
                                            repository: environment.chatRepository
                                        )
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.vertical, PrimeTheme.Spacing.medium)
                }
                .background(PrimeTheme.Colors.background)
            }

            Divider()
            if !viewModel.messageActionError.isEmpty {
                Text(viewModel.messageActionError)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.top, PrimeTheme.Spacing.small)
            }
            MessageComposerView(
                draftText: $viewModel.draftText,
                chatMode: chat.mode,
                isSending: viewModel.isSending,
                editingMessage: viewModel.editingMessage,
                onCancelEditing: {
                    viewModel.cancelEditing()
                },
                onSend: { draft in
                    try await viewModel.submitComposer(
                        draft,
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
    let chat: Chat
    let message: Message
    let isOutgoing: Bool
    let canEdit: Bool
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                if chat.type == .group,
                   !isOutgoing,
                   let senderDisplayName = message.senderDisplayName,
                   !senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(senderDisplayName)
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.accent)
                }

                if message.isDeleted {
                    Text("Message deleted")
                        .italic()
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.92) : PrimeTheme.Colors.textSecondary)
                } else if let text = message.text {
                    Text(text)
                        .foregroundStyle(isOutgoing ? Color.white : PrimeTheme.Colors.textPrimary)
                }

                if message.isDeleted == false && message.attachments.isEmpty == false {
                    MessageAttachmentGallery(attachments: message.attachments)
                }

                if message.isDeleted == false, let voiceMessage = message.voiceMessage {
                    VoiceMessagePlayerView(voiceMessage: voiceMessage)
                }

                HStack(spacing: PrimeTheme.Spacing.xSmall) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                    if message.editedAt != nil && message.isDeleted == false {
                        Text("edited")
                            .font(.caption2)
                    }
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
            .contextMenu {
                if canEdit {
                    Button("Edit") {
                        onEdit()
                    }
                }

                if canDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
            }
            if !isOutgoing { Spacer(minLength: 40) }
        }
    }
}

final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published var draftText = ""
    @Published private(set) var isSending = false
    @Published private(set) var editingMessage: Message?
    @Published var messageActionError = ""

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
    func submitComposer(_ draft: OutgoingMessageDraft, chat: Chat, senderID: UUID, repository: ChatRepository) async throws {
        guard draft.hasContent else { return }
        guard isSending == false else { return }

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
            return
        }

        let outgoing = try await repository.sendMessage(draft, in: chat.id, mode: chat.mode, senderID: senderID)
        replaceOrAppend(outgoing)
        draftText = ""
    }

    @MainActor
    func beginEditing(_ message: Message) {
        guard message.canEditText else { return }
        editingMessage = message
        draftText = message.text ?? ""
        messageActionError = ""
    }

    @MainActor
    func cancelEditing() {
        editingMessage = nil
        draftText = ""
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

    private func replaceOrAppend(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
            messages.sort(by: { $0.createdAt < $1.createdAt })
        }
    }
}
