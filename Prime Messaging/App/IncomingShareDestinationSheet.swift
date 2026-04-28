import SwiftUI

struct IncomingShareDestinationSheet: View {
    let payload: IncomingSharedPayload
    let chats: [Chat]
    let onSelect: (Chat) -> Void
    let onCancel: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Share to Prime Messaging")
                        .font(.headline)
                    if payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Text(payload.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    if payload.files.isEmpty == false {
                        Text(payload.files.count == 1 ? "1 attachment" : "\(payload.files.count) attachments")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PrimeTheme.Colors.accent)
                    }
                }
                .padding(.vertical, 4)
            }

            if chats.isEmpty {
                Section {
                    Text("Open Prime Messaging and start at least one chat first. Then sharing will have destinations to pick from.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Choose chat") {
                    ForEach(chats, id: \.id) { chat in
                        Button {
                            onSelect(chat)
                        } label: {
                            HStack(spacing: 12) {
                                IncomingShareChatAvatar(title: chat.title)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    if chat.subtitle.isEmpty == false {
                                        Text(chat.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Share")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    onCancel()
                }
            }
        }
    }
}

private struct IncomingShareChatAvatar: View {
    let title: String

    var body: some View {
        ZStack {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.18))
            Text(initials)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(PrimeTheme.Colors.accent)
        }
        .frame(width: 42, height: 42)
    }

    private var initials: String {
        let components = title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(2)
        let joined = components.compactMap { $0.first }.map(String.init).joined()
        return joined.isEmpty ? "PM" : joined.uppercased()
    }
}
