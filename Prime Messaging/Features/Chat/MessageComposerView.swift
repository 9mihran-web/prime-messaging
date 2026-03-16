import PhotosUI
import SwiftUI
import UIKit

struct MessageComposerView: View {
    @Binding var draftText: String
    let chatMode: ChatMode
    let isSending: Bool
    let editingMessage: Message?
    let onCancelEditing: () -> Void
    let onSend: (OutgoingMessageDraft) async throws -> Void

    @StateObject private var recorder = AudioRecorderController()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachments: [Attachment] = []
    @State private var voiceMessage: VoiceMessage?
    @State private var composerError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            if let editingMessage {
                HStack(spacing: PrimeTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Editing message")
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.accent)
                        Text(editingMessage.text ?? "")
                            .font(.caption2)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel", action: onCancelEditing)
                        .font(.caption)
                }
                .padding(.horizontal, PrimeTheme.Spacing.large)
            }

            if attachments.isEmpty == false || voiceMessage != nil {
                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                    if attachments.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: PrimeTheme.Spacing.small) {
                                ForEach(attachments) { attachment in
                                    ZStack(alignment: .topTrailing) {
                                        AttachmentPreviewCard(attachment: attachment)

                                        Button {
                                            attachments.removeAll(where: { $0.id == attachment.id })
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(Color.white, PrimeTheme.Colors.warning)
                                        }
                                        .offset(x: 6, y: -6)
                                    }
                                }
                            }
                        }
                    }

                    if let voiceMessage {
                        HStack {
                            VoiceMessagePlayerView(voiceMessage: voiceMessage)
                            Spacer()
                            Button("Remove") {
                                self.voiceMessage = nil
                            }
                            .font(.footnote)
                        }
                    }
                }
                .padding(.horizontal, PrimeTheme.Spacing.large)
            }

            if !composerError.isEmpty {
                Text(composerError)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
                    .padding(.horizontal, PrimeTheme.Spacing.large)
            }

            HStack(alignment: .bottom, spacing: PrimeTheme.Spacing.small) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(editingMessage != nil || isSending)

                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle")
                        .font(.title2)
                        .foregroundStyle(recorder.isRecording ? PrimeTheme.Colors.warning : PrimeTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(editingMessage != nil || isSending)

                TextField("composer.placeholder".localized, text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, PrimeTheme.Spacing.medium)
                    .padding(.vertical, PrimeTheme.Spacing.small)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                Button {
                    Task {
                        await send()
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend && !isSending ? PrimeTheme.Colors.accent : PrimeTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
            }
            .padding(PrimeTheme.Spacing.large)
            .background(PrimeTheme.Colors.background)
        }
        .task(id: selectedPhotoItem) {
            await loadSelectedPhoto()
        }
        .onChange(of: editingMessage?.id) { _, _ in
            attachments = []
            voiceMessage = nil
            composerError = ""
        }
        .onChange(of: chatMode) { _, _ in
            composerError = ""
        }
    }

    private var canSend: Bool {
        OutgoingMessageDraft(text: draftText, attachments: attachments, voiceMessage: voiceMessage).hasContent
    }

    @MainActor
    private func loadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            attachments.append(try ChatMediaDraftBuilder.makePhotoAttachment(from: data))
            composerError = ""
            self.selectedPhotoItem = nil
        } catch {
            composerError = "Could not attach the selected photo."
        }
    }

    private func toggleRecording() {
        do {
            if recorder.isRecording {
                voiceMessage = try recorder.stopRecording()
            } else {
                try recorder.startRecording()
                composerError = ""
            }
        } catch {
            composerError = "Could not access the microphone."
        }
    }

    @MainActor
    private func send() async {
        let draft = OutgoingMessageDraft(text: draftText, attachments: attachments, voiceMessage: voiceMessage)
        guard draft.hasContent else { return }
        guard isSending == false else { return }

        do {
            try await onSend(draft)
            draftText = ""
            attachments = []
            voiceMessage = nil
            composerError = ""
        } catch {
            composerError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
        }
    }
}

private struct AttachmentPreviewCard: View {
    let attachment: Attachment

    var body: some View {
        SwiftUI.Group {
            if attachment.type == .photo,
               let localURL = attachment.localURL,
               let uiImage = UIImage(contentsOfFile: localURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: PrimeTheme.Spacing.xSmall) {
                    Image(systemName: attachment.type == .audio ? "waveform" : "doc")
                    Text(attachment.fileName)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(PrimeTheme.Spacing.medium)
                .frame(width: 92, height: 92)
                .background(PrimeTheme.Colors.elevated)
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
    }
}
