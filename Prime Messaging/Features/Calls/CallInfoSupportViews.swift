import SwiftUI

struct CallInfoSheetParticipant: Identifiable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String?
    let photoURL: URL?
}

struct CallInfoSheet: View {
    let title: String
    let subtitle: String
    let duration: String
    let participants: [CallInfoSheetParticipant]
    let statusMessage: String
    let addParticipantTitle: String
    let showsContactInfoAction: Bool
    let onOpenChat: () -> Void
    let onSendMessage: () -> Void
    let onOpenContactInfo: () -> Void
    let onSendEmoji: (String) -> Void
    let onOpenParticipant: (CallInfoSheetParticipant) -> Void
    let onAddParticipant: () -> Void

    private let quickReactionEmojis = ["👍", "❤️", "😂", "🔥", "👏", "🙏"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        Text(subtitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        Label(duration, systemImage: "clock")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    }

                    if statusMessage.isEmpty == false {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(PrimeTheme.Colors.elevated)
                            )
                    }

                    actionSection

                    if participants.isEmpty == false {
                        participantsSection
                    }

                    reactionSection

                    Button(action: onAddParticipant) {
                        Label(addParticipantTitle, systemImage: "person.badge.plus")
                            .font(.headline)
                            .foregroundStyle(PrimeTheme.Colors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(PrimeTheme.Colors.accent.opacity(0.2), lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(PrimeTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Call info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            actionButton(title: "Open chat", systemName: "bubble.left.and.bubble.right") {
                onOpenChat()
            }
            actionButton(title: "Send message", systemName: "paperplane") {
                onSendMessage()
            }
            if showsContactInfoAction {
                actionButton(title: "Contact info", systemName: "person.text.rectangle") {
                    onOpenContactInfo()
                }
            }
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Participants")
                .font(.headline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            ForEach(participants) { participant in
                Button {
                    onOpenParticipant(participant)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay(
                                Text(initials(for: participant.title))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(participant.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            if let subtitle = participant.subtitle, subtitle.isEmpty == false {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(PrimeTheme.Colors.elevated)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send emoji reaction")
                .font(.headline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            HStack(spacing: 10) {
                ForEach(quickReactionEmojis, id: \.self) { emoji in
                    Button {
                        onSendEmoji(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(PrimeTheme.Colors.elevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func actionButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
                    .frame(width: 24)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
        }
        .buttonStyle(.plain)
    }

    private func initials(for label: String) -> String {
        let parts = label.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        if letters.isEmpty {
            return String(label.prefix(2)).uppercased()
        }
        return String(letters.prefix(2)).uppercased()
    }
}

struct CallMessageComposerSheet: View {
    let title: String
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(PrimeTheme.Colors.elevated)
                    )

                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { return }
                    isSending = true
                    onSend(trimmed)
                    dismiss()
                } label: {
                    Text(isSending ? "Sending…" : "Send")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(PrimeTheme.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)

                Spacer()
            }
            .padding(20)
            .background(PrimeTheme.Colors.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct CallParticipantPickerSheet: View {
    let title: String
    let excludedUserIDs: Set<UUID>
    let onSelect: (User) -> Void

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [User] = []
    @State private var isSearching = false
    @State private var errorText = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("Search users", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PrimeTheme.Colors.elevated)
                    )
                    .onChange(of: query) { _ in
                        scheduleSearch()
                    }

                if errorText.isEmpty == false {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 30)
                } else if results.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search for a contact to add." : "No matching users found.")
                            .font(.subheadline)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(results, id: \.id) { user in
                                Button {
                                    onSelect(user)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarBadgeView(profile: user.profile, size: 46)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(user.profile.displayName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                            Text("@\(user.profile.username)")
                                                .font(.caption)
                                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(PrimeTheme.Colors.elevated)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(PrimeTheme.Colors.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            results = []
            errorText = ""
            isSearching = false
            return
        }

        isSearching = true
        errorText = ""
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false else { return }
            do {
                let found = try await environment.authRepository.searchUsers(
                    query: trimmed,
                    excluding: appState.currentUser.id
                )
                guard Task.isCancelled == false else { return }
                results = found.filter { excludedUserIDs.contains($0.id) == false }
                isSearching = false
            } catch {
                guard Task.isCancelled == false else { return }
                results = []
                isSearching = false
                errorText = error.localizedDescription.isEmpty ? "Could not search users." : error.localizedDescription
            }
        }
    }
}
