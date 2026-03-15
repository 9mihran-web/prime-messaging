import Combine
import SwiftUI

struct ChatListView: View {
    let mode: ChatMode

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ChatListViewModel()

    var body: some View {
        List(viewModel.chats) { chat in
            NavigationLink(value: chat) {
                ChatRowView(chat: chat)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PrimeTheme.Colors.background)
        .navigationDestination(for: Chat.self) { chat in
            ChatView(chat: chat)
        }
        .task(id: refreshTaskID) {
            while !Task.isCancelled {
                await viewModel.loadChats(mode: mode, repository: environment.chatRepository, userID: appState.currentUser.id)
                try? await Task.sleep(for: .seconds(mode == .offline ? 1 : 3))
            }
        }
        .onChange(of: mode) { _, newValue in
            Task {
                await viewModel.loadChats(mode: newValue, repository: environment.chatRepository, userID: appState.currentUser.id)
            }
        }
    }

    private var refreshTaskID: String {
        "\(mode.rawValue)-\(appState.currentUser.id.uuidString)"
    }
}

struct ChatRowView: View {
    let chat: Chat

    var body: some View {
        HStack(alignment: .top, spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(chat.mode == .online ? PrimeTheme.Colors.accent.opacity(0.85) : PrimeTheme.Colors.offlineAccent.opacity(0.9))
                .frame(width: 52, height: 52)
                .overlay(
                    Text(String(chat.resolvedDisplayTitle.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(Color.white)
                )

            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                HStack {
                    Text(chat.resolvedDisplayTitle)
                        .font(.headline)
                    Spacer()
                    Text(chat.lastActivityAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Text(chat.lastMessagePreview ?? chat.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(2)

                if let draft = chat.draft {
                    Text("Draft: \(draft.text)")
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.accentSoft)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, PrimeTheme.Spacing.small)
    }
}

final class ChatListViewModel: ObservableObject {
    @Published private(set) var chats: [Chat] = []

    @MainActor
    func loadChats(mode: ChatMode, repository: ChatRepository, userID: UUID) async {
        do {
            chats = try await repository.fetchChats(mode: mode, for: userID)
                .sorted(by: { lhs, rhs in
                    if lhs.isPinned != rhs.isPinned {
                        return lhs.isPinned && !rhs.isPinned
                    }
                    return lhs.lastActivityAt > rhs.lastActivityAt
                })
        } catch {
            chats = []
        }
    }
}
