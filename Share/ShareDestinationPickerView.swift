import SwiftUI

struct ShareDestinationPickerView: View {
    enum Mode {
        case share
        case importHistory
    }

    struct PreviewItem: Hashable {
        let text: String
        let attachmentCount: Int
    }

    struct SubmissionProgress: Hashable, Sendable {
        let title: String
        let detail: String?
        let fractionCompleted: Double?
    }

    let mode: Mode
    let preview: PreviewItem
    let chats: [ShareChatDestination]
    let selectedChatID: UUID?
    let isLoading: Bool
    let isSubmitting: Bool
    let submissionProgress: SubmissionProgress?
    let errorMessage: String?
    let onCancel: () -> Void
    let onSelectChat: (UUID) -> Void
    let onSend: () -> Void

    @State private var searchText = ""

    private struct ChatSection: Identifiable {
        let mode: ShareChatDestination.Mode
        let chats: [ShareChatDestination]

        var id: ShareChatDestination.Mode { mode }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView("Preparing share…")
                        .progressViewStyle(.circular)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                previewCard

                                if let errorMessage, errorMessage.isEmpty == false {
                                    Text(errorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }

                                searchField

                                if filteredChats.isEmpty {
                                    emptyState
                                } else {
                                    chatsList
                                }
                            }
                            .padding(16)
                            .padding(.bottom, 100)
                        }

                        sendBar
                    }
                }

                if let submissionProgress, isSubmitting {
                    submissionOverlay(submissionProgress)
                }
            }
            .navigationTitle(mode == .importHistory ? "Import to Prime Messaging" : "Share to Prime Messaging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: previewIconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to send")
                        .font(.headline)
                    if mode == .importHistory {
                        Text("WhatsApp chat export detected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    if preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Text(preview.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    } else {
                        Text(preview.attachmentCount == 1 ? "1 attachment" : "\(preview.attachmentCount) attachments")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if preview.attachmentCount > 0 {
                HStack(spacing: 8) {
                    Label(
                        preview.attachmentCount == 1 ? "1 attachment" : "\(preview.attachmentCount) attachments",
                        systemImage: "paperclip"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search chats", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var chatsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(chatSections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(sectionTitle(for: section.mode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        ForEach(section.chats) { chat in
                            chatRow(chat)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No chats available")
                .font(.headline)
            Text("Open Prime Messaging first so recent chats can be prepared for fast sharing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var sendBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    onSend()
                } label: {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }

                        Text(mode == .importHistory ? "Import" : "Send")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selectedChatID == nil || isSubmitting ? Color.gray.opacity(0.35) : Color.accentColor)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(selectedChatID == nil || isSubmitting)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
    }

    private func submissionOverlay(_ progress: SubmissionProgress) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if let fractionCompleted = progress.fractionCompleted {
                    ProgressView(value: min(max(fractionCompleted, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                }

                Text(progress.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let detail = progress.detail, detail.isEmpty == false {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .shadow(color: .black.opacity(0.12), radius: 22, y: 12)
            .padding(24)
        }
        .transition(.opacity)
    }

    private var filteredChats: [ShareChatDestination] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return chats }
        return chats.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query) ||
            $0.previewText.localizedCaseInsensitiveContains(query)
        }
    }

    private var chatSections: [ChatSection] {
        let grouped = Dictionary(grouping: filteredChats, by: \.mode)
        let orderedModes: [ShareChatDestination.Mode] = [.online, .offline, .smart]
        return orderedModes.compactMap { mode in
            guard let chats = grouped[mode], chats.isEmpty == false else { return nil }
            return ChatSection(mode: mode, chats: chats)
        }
    }

    private var previewIconName: String {
        if mode == .importHistory {
            return "tray.and.arrow.down.fill"
        }
        if preview.attachmentCount > 0 {
            return preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "photo.on.rectangle.angled" : "square.and.arrow.up"
        }
        return "text.alignleft"
    }

    private func chatRow(_ chat: ShareChatDestination) -> some View {
        Button {
            onSelectChat(chat.id)
        } label: {
            HStack(spacing: 12) {
                avatar(for: chat)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(chat.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if chat.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if chat.subtitle.isEmpty == false {
                        Text(chat.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if chat.previewText.isEmpty == false {
                        Text(chat.previewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }

                Image(systemName: selectedChatID == chat.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selectedChatID == chat.id ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(for mode: ShareChatDestination.Mode) -> String {
        switch mode {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .smart:
            return "Smart"
        }
    }

    @ViewBuilder
    private func avatar(for chat: ShareChatDestination) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
            if chat.kind == .saved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(initials(for: chat.title))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 46, height: 46)
    }

    private func initials(for title: String) -> String {
        let parts = title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(2)
        let value = parts.compactMap { $0.first }.map(String.init).joined()
        return value.isEmpty ? "PM" : value.uppercased()
    }
}
