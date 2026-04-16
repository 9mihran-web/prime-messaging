import AVFoundation
import AVKit
import Combine
import CoreTransferable
import CoreLocation
import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit
import Photos
#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
typealias ComposerPhotoPickerItem = PhotosPickerItem
#else
struct ComposerPhotoPickerItem: Hashable {}
#endif
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MessageComposerView: View {
    @Binding var draftText: String
    let chatTitle: String
    let chatMode: ChatMode
    let isSending: Bool
    let editingMessage: Message?
    let replyMessage: Message?
    let communityContextTitle: String?
    let communityContext: CommunityMessageContext?
    let onCancelEditing: () -> Void
    let onCancelReply: () -> Void
    let onCancelCommunityContext: (() -> Void)?
    let onSend: (OutgoingMessageDraft) async throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = AudioRecorderController()
    @StateObject private var locationProvider = ComposerLocationProvider()
    @State private var selectedGalleryItems: [ComposerPhotoPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var voiceMessage: VoiceMessage?
    @State private var composerError = ""
    @State private var isHoldRecording = false
    @State private var isShowingAttachmentMenu = false
    @State private var attachmentButtonFrame: CGRect = .zero
    @State private var isShowingGalleryPicker = false
    @State private var isShowingFileImporter = false
    @State private var cameraMode: ComposerCameraCaptureMode?
    @State private var isShowingCameraModeMenu = false
    @State private var isShowingPollComposer = false
    @State private var isShowingListComposer = false
    @State private var isResolvingLocation = false
    @State private var pendingLocationSelection: ComposerLocationSelection?
    @State private var pendingMediaEditor: ComposerPendingMedia?
    @State private var deliveryOptions = MessageDeliveryOptions()
    @State private var isShowingDeliveryOptionsMenu = false
    @State private var micTouchBeganAt: Date?
    @State private var isHoldActivationPending = false
    @State private var holdRecordingStartedFromGesture = false

    private let composerControlSize: CGFloat = 50
    private let holdRecordingActivationDelay: TimeInterval = 0.14

    @ViewBuilder
    private func platformGalleryPicker<Content: View>(_ content: Content) -> some View {
        #if canImport(PhotosUI) && !os(tvOS)
        content.photosPicker(
            isPresented: $isShowingGalleryPicker,
            selection: $selectedGalleryItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos])
        )
        #else
        content
        #endif
    }

    @ViewBuilder
    private func platformFileImporter<Content: View>(_ content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImportedFile(result)
        }
        #endif
    }

    var body: some View {
        platformFileImporter(
            platformGalleryPicker(
                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            if let editingMessage {
                composerContextBanner(
                    title: "Editing message",
                    preview: editPreviewText(for: editingMessage),
                    onCancel: onCancelEditing
                )
            }

            if let replyMessage {
                composerContextBanner(
                    title: replyBannerTitle(for: replyMessage),
                    preview: replyPreviewText(for: replyMessage),
                    onCancel: onCancelReply
                )
            }

            if let communityContextTitle, let onCancelCommunityContext {
                composerContextBanner(
                    title: communityContextTitle,
                    preview: communityContextPreviewText,
                    onCancel: onCancelCommunityContext
                )
            }

            if deliveryOptions.hasAdvancedBehavior, editingMessage == nil, canSend {
                deliveryOptionsBanner
            }

            if attachments.isEmpty == false {
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

                }
                .padding(.horizontal, PrimeTheme.Spacing.large)
            }

            if !composerError.isEmpty {
                Text(composerError)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
                    .padding(.horizontal, PrimeTheme.Spacing.large)
            }

            if isShowingAttachmentMenu {
                ComposerAttachmentMenuOverlay(
                    containerSize: UIScreen.main.bounds.size,
                    onDismiss: {
                        isShowingAttachmentMenu = false
                    },
                    onPreviewAsset: { asset in
                        Task {
                            await previewLibraryAsset(asset)
                        }
                    },
                    onSendSelectedAssets: { assets in
                        Task {
                            await attachLibraryAssets(assets)
                        }
                    },
                    onOpenCamera: {
                        cameraMode = .photo
                    },
                    onOpenFiles: {
                        isShowingFileImporter = true
                    },
                    onOpenLocation: {
                        Task {
                            await attachCurrentLocation()
                        }
                    },
                    onOpenPoll: {
                        isShowingPollComposer = true
                    },
                    onOpenList: {
                        isShowingListComposer = true
                    }
                )
                .padding(.horizontal, PrimeTheme.Spacing.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isShowingAttachmentMenu == false {
                HStack(alignment: .center, spacing: 8) {
                    if recorder.isRecording == false {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                isShowingAttachmentMenu.toggle()
                            }
                        } label: {
                            composerCircleButton(
                                systemName: "plus",
                                foregroundColor: PrimeTheme.Colors.accent
                            )
                        }
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear {
                                        attachmentButtonFrame = geometry.frame(in: .global)
                                    }
                                    .onChange(of: geometry.frame(in: .global)) { newValue in
                                        attachmentButtonFrame = newValue
                                    }
                            }
                        )
                        .buttonStyle(.plain)
                        .disabled(editingMessage != nil || isSending || recorder.isRecording)
                    }

                    composerInputCapsule
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.38))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(PrimeTheme.Colors.accentSoft.opacity(0.84), lineWidth: 1.35)
                )
                .shadow(color: PrimeTheme.Colors.accent.opacity(0.28), radius: 14, y: 0)
                .shadow(color: PrimeTheme.Colors.accentSoft.opacity(0.18), radius: 28, y: 0)
                .padding(.horizontal, PrimeTheme.Spacing.large)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.86, anchor: .leading).combined(with: .opacity)
                    )
                )
            }
        }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        .coordinateSpace(name: "composer-root")
        .sheet(item: $cameraMode) { mode in
            ComposerCameraPicker(mode: mode) { result in
                Task {
                    await handleCameraResult(result)
                }
            }
        }
        .sheet(item: $pendingLocationSelection) { selection in
            if #available(iOS 17.0, *) {
                ComposerLocationPickerSheet(
                    initialSelection: selection,
                    locationProvider: locationProvider
                ) { updatedSelection in
                    Task {
                        await sendLocationSelection(updatedSelection)
                    }
                }
            } else {
                ComposerLegacyLocationPickerSheet(initialSelection: selection) { updatedSelection in
                    Task {
                        await sendLocationSelection(updatedSelection)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingPollComposer) {
            NavigationStack {
                PollComposerSheet { pollText in
                    await sendStructuredMessageText(pollText)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingListComposer) {
            NavigationStack {
                ListComposerSheet { listText in
                    await sendStructuredMessageText(listText)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $pendingMediaEditor) { item in
            ComposerMediaEditorSheet(
                chatTitle: chatTitle,
                media: item,
                initialCaption: draftText,
                initialQualityPreset: item.defaultQualityPreset,
                onSend: { submission in
                    try await sendPendingMedia(submission)
                },
                onClose: {
                    pendingMediaEditor = nil
                }
            )
        }
        .confirmationDialog("Camera", isPresented: $isShowingCameraModeMenu, titleVisibility: .visible) {
            Button("Take Photo") {
                cameraMode = .photo
            }
            Button("Record Video") {
                cameraMode = .video
            }
            Button("common.cancel".localized, role: .cancel) { }
        }
        .confirmationDialog("Message options", isPresented: $isShowingDeliveryOptionsMenu, titleVisibility: .visible) {
            Button(deliveryOptions.isSilent ? "Deliver with sound" : "Send silently") {
                deliveryOptions.isSilent.toggle()
            }
            Button("Send in 30 minutes") {
                deliveryOptions.scheduledAt = Date().addingTimeInterval(30 * 60)
            }
            Button("Send in 2 hours") {
                deliveryOptions.scheduledAt = Date().addingTimeInterval(2 * 60 * 60)
            }
            Button("Send tomorrow morning") {
                deliveryOptions.scheduledAt = nextMorningDeliveryDate()
            }
            Button("Auto-delete in 10 seconds") {
                deliveryOptions.selfDestructSeconds = 10
            }
            Button("Auto-delete in 1 minute") {
                deliveryOptions.selfDestructSeconds = 60
            }
            Button("Auto-delete in 1 hour") {
                deliveryOptions.selfDestructSeconds = 60 * 60
            }
            if deliveryOptions.hasAdvancedBehavior {
                Button("Clear delivery options", role: .destructive) {
                    deliveryOptions = MessageDeliveryOptions()
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        }
        .task(id: selectedGalleryItems.count) {
            await loadSelectedGalleryItems()
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .background else { return }
            if recorder.isRecording {
                recorder.cancelRecording()
            }
            isHoldRecording = false
            micTouchBeganAt = nil
            isHoldActivationPending = false
            holdRecordingStartedFromGesture = false
        }
        .onChange(of: editingMessage?.id) { _ in
            attachments = []
            voiceMessage = nil
            composerError = ""
            deliveryOptions = MessageDeliveryOptions()
        }
        .onChange(of: chatMode) { _ in
            composerError = ""
        }
    }

    private var canSend: Bool {
        OutgoingMessageDraft(
            text: draftText,
            attachments: attachments,
            voiceMessage: voiceMessage,
            replyToMessageID: replyMessage?.id,
            replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
            communityContext: communityContext,
            deliveryOptions: deliveryOptions
        ).hasContent
    }

    private var hasTypedText: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private var composerInputCapsule: some View {
        SwiftUI.Group {
            if recorder.isRecording {
                recordingTimelineCapsule
                    .transition(.scale(scale: 0.94, anchor: .center).combined(with: .opacity))
            } else if let voiceMessage {
                HStack(spacing: 8) {
                    VoiceMessagePlayerView(
                        voiceMessage: voiceMessage,
                        style: .composer
                    )
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()

                    Button {
                        self.voiceMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await send()
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(PrimeTheme.Colors.accent)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .transition(.scale(scale: 0.96, anchor: .center).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    TextField("composer.placeholder".localized, text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 5)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    trailingComposerControl
                }
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .transition(.scale(scale: 0.96, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(height: composerControlSize, alignment: .center)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: recorder.isRecording)
    }

    @ViewBuilder
    private var recordingTimelineCapsule: some View {
        ViewThatFits(in: .horizontal) {
            recordingTimelineContent(isCompact: false)
            recordingTimelineContent(isCompact: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func recordingTimelineContent(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 10) {
            HStack(spacing: isCompact ? 0 : 8) {
                Circle()
                    .fill(PrimeTheme.Colors.accent)
                    .frame(width: isCompact ? 7 : 8, height: isCompact ? 7 : 8)
                    .opacity(recorder.isPaused ? 0.5 : 1)

                if !isCompact {
                    Text(recorder.isPaused ? "Paused" : "Recording")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, isCompact ? 5 : 6)
            .background(
                Capsule(style: .continuous)
                    .fill(PrimeTheme.Colors.accent.opacity(0.14))
            )

            ComposerRecordingEqualizerView(
                samples: isCompact ? compactRecordingEqualizerSamples : recordingEqualizerSamples,
                tint: PrimeTheme.Colors.accent,
                dimTint: PrimeTheme.Colors.accent.opacity(0.28),
                barWidth: isCompact ? 2 : 3,
                barSpacing: isCompact ? 1.4 : 2,
                minBarHeight: isCompact ? 4 : 6,
                maxBarHeight: isCompact ? 18 : 22
            )
            .frame(maxWidth: .infinity)

            Text(recordingDurationLabel)
                .font((isCompact ? Font.caption2 : Font.footnote).monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)

            Button {
                if recorder.isPaused {
                    recorder.resumeRecording()
                } else {
                    recorder.pauseRecording()
                }
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: isCompact ? 13 : 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: isCompact ? 24 : 28, height: isCompact ? 24 : 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)

            Button {
                stopTapRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: isCompact ? 12 : 13, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
                    .frame(width: isCompact ? 24 : 28, height: isCompact ? 24 : 28)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.accent.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailingComposerControl: some View {
        HStack(spacing: 8) {
            if hasTypedText == false {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isHoldRecording ? PrimeTheme.Colors.warning : microphoneTintColor)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                handleMicrophoneTouchChanged()
                            }
                            .onEnded { _ in
                                handleMicrophoneTouchEnded()
                            }
                    )
                .opacity(isSending || editingMessage != nil ? 0.45 : 1)
                .allowsHitTesting(!(isSending || editingMessage != nil))
            }

            Button {
                if canSend {
                    Task {
                        await send()
                    }
                } else if recorder.isRecording {
                    stopTapRecording()
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "arrow.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(canSend || recorder.isRecording ? PrimeTheme.Colors.accent : sendControlTintColor)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isSending || (canSend == false && recorder.isRecording == false))
        }
    }

    private var microphoneTintColor: Color {
        colorScheme == .light ? Color.white.opacity(0.96) : PrimeTheme.Colors.textSecondary
    }

    private var sendControlTintColor: Color {
        colorScheme == .light ? Color.white.opacity(0.82) : PrimeTheme.Colors.textSecondary.opacity(0.62)
    }

    private var recordingEqualizerSamples: [CGFloat] {
        let sampleCount = 26
        let time = recorder.recordingDuration
        return (0 ..< sampleCount).map { index in
            if recorder.isPaused {
                return 0.2
            }
            let phase = time * 4.8 + (Double(index) * 0.42)
            let envelope = 0.25 + (sin(time * 1.7) * 0.1)
            let value = abs(sin(phase)) * 0.72 + envelope
            return CGFloat(max(0.14, min(value, 1)))
        }
    }

    private var compactRecordingEqualizerSamples: [CGFloat] {
        let samples = recordingEqualizerSamples
        guard samples.count > 14 else { return samples }
        let sampleStride = max(samples.count / 14, 1)
        let reduced = stride(from: 0, to: samples.count, by: sampleStride).map { samples[$0] }
        return Array(reduced.prefix(14))
    }

    private var recordingDurationLabel: String {
        let totalSeconds = max(Int(recorder.recordingDuration.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @MainActor
    private func loadSelectedGalleryItems() async {
        #if canImport(PhotosUI) && !os(tvOS)
        guard selectedGalleryItems.isEmpty == false else { return }

        let items = selectedGalleryItems
        selectedGalleryItems = []

        if items.count == 1 {
            do {
                if let pendingMedia = try await makePendingMedia(from: items[0]) {
                    pendingMediaEditor = pendingMedia
                    composerError = ""
                    return
                }
            } catch {
                composerError = "Could not prepare the selected media."
                return
            }
        }

        for item in items {
            do {
                guard let attachment = try await makeGalleryAttachment(from: item) else { continue }
                attachments.append(attachment)
                composerError = ""
            } catch {
                composerError = "Could not attach the selected item."
            }
        }
        #else
        selectedGalleryItems = []
        #endif
    }

    @MainActor
    private func previewLibraryAsset(_ asset: PHAsset) async {
        do {
            guard let pendingMedia = try await makePendingMedia(from: asset) else { return }
            pendingMediaEditor = pendingMedia
            composerError = ""
            isShowingAttachmentMenu = false
        } catch {
            composerError = "Could not prepare the selected media."
        }
    }

    @MainActor
    private func attachLibraryAssets(_ assets: [PHAsset]) async {
        guard assets.isEmpty == false else { return }

        if assets.count == 1 {
            await previewLibraryAsset(assets[0])
            return
        }

        var importedAny = false
        for asset in assets {
            do {
                guard let attachment = try await makeLibraryAttachment(from: asset) else { continue }
                attachments.append(attachment)
                importedAny = true
            } catch {
                composerError = "Could not attach one or more selected items."
            }
        }

        if importedAny {
            composerError = ""
            isShowingAttachmentMenu = false
        }
    }

    private func toggleTapRecording() async {
        do {
            if recorder.isRecording {
                let recordedVoiceMessage = try recorder.stopRecording()
                voiceMessage = recordedVoiceMessage
                composerError = recordedVoiceMessage == nil ? "Voice recording was interrupted. Please record again." : ""
            } else {
                try await recorder.startRecording()
                composerError = ""
            }
        } catch {
            composerError = "Could not access the microphone."
        }
    }

    private func stopTapRecording() {
        do {
            let recordedVoiceMessage = try recorder.stopRecording()
            voiceMessage = recordedVoiceMessage
            composerError = recordedVoiceMessage == nil ? "Voice recording was interrupted. Please record again." : ""
        } catch {
            composerError = "Could not access the microphone."
        }
    }

    private func handleMicrophoneTouchChanged() {
        guard isSending == false, editingMessage == nil, hasTypedText == false else {
            return
        }

        let now = Date()
        if micTouchBeganAt == nil {
            micTouchBeganAt = now
            isHoldActivationPending = true
            holdRecordingStartedFromGesture = false
            return
        }

        guard isHoldActivationPending, holdRecordingStartedFromGesture == false else {
            return
        }

        guard let beganAt = micTouchBeganAt,
              now.timeIntervalSince(beganAt) >= holdRecordingActivationDelay else {
            return
        }

        isHoldActivationPending = false
        holdRecordingStartedFromGesture = true

        Task { @MainActor in
            do {
                if recorder.isRecording == false {
                    try await recorder.startRecording()
                }
                isHoldRecording = true
                composerError = ""
            } catch {
                holdRecordingStartedFromGesture = false
                isHoldRecording = false
                composerError = "Could not access the microphone."
            }
        }
    }

    private func handleMicrophoneTouchEnded() {
        let shouldHandleAsTap = isHoldActivationPending
        let shouldHandleAsHold = holdRecordingStartedFromGesture

        micTouchBeganAt = nil
        isHoldActivationPending = false
        holdRecordingStartedFromGesture = false

        if shouldHandleAsHold {
            Task { @MainActor in
                await finishHoldRecordingAndSend()
            }
            return
        }

        guard shouldHandleAsTap else { return }
        Task {
            await toggleTapRecording()
        }
    }

    @MainActor
    private func finishHoldRecordingAndSend() async {
        guard recorder.isRecording else {
            isHoldRecording = false
            return
        }

        do {
            guard let recordedVoiceMessage = try recorder.stopRecording() else {
                isHoldRecording = false
                composerError = "Voice recording was interrupted. Please record again."
                return
            }

            let draft = OutgoingMessageDraft(
                text: "",
                attachments: [],
                voiceMessage: recordedVoiceMessage,
                replyToMessageID: replyMessage?.id,
                replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
                communityContext: communityContext,
                deliveryOptions: editingMessage == nil ? deliveryOptions : MessageDeliveryOptions()
            )

            guard isSending == false else {
                isHoldRecording = false
                voiceMessage = recordedVoiceMessage
                return
            }

            try await onSend(draft)
            isHoldRecording = false
            composerError = ""
            voiceMessage = nil
            deliveryOptions = MessageDeliveryOptions()
        } catch {
            isHoldRecording = false
            composerError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
        }
    }

    

    @MainActor
    private func send() async {
        let draft = OutgoingMessageDraft(
            text: draftText,
            attachments: attachments,
            voiceMessage: voiceMessage,
            replyToMessageID: replyMessage?.id,
            replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
            communityContext: communityContext,
            deliveryOptions: editingMessage == nil ? deliveryOptions : MessageDeliveryOptions()
        )
        guard draft.hasContent else { return }
        guard isSending == false else { return }

        do {
            try await onSend(draft)
            draftText = ""
            attachments = []
            voiceMessage = nil
            deliveryOptions = MessageDeliveryOptions()
            composerError = ""
        } catch {
            composerError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
        }
    }

    @MainActor
    private func sendLocationSelection(_ selection: ComposerLocationSelection) async {
        guard isSending == false else { return }

        do {
            let attachment = try ChatMediaDraftBuilder.makeLocationAttachment(
                latitude: selection.coordinate.latitude,
                longitude: selection.coordinate.longitude,
                accuracyMeters: selection.accuracyMeters
            )

            let draft = OutgoingMessageDraft(
                text: "",
                attachments: [attachment],
                voiceMessage: nil,
                replyToMessageID: replyMessage?.id,
                replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
                communityContext: communityContext,
                deliveryOptions: editingMessage == nil ? deliveryOptions : MessageDeliveryOptions()
            )

            try await onSend(draft)
            pendingLocationSelection = nil
            composerError = ""
        } catch {
            composerError = error.localizedDescription.isEmpty ? "Could not send the selected location." : error.localizedDescription
        }
    }

    @MainActor
    private func sendPendingMedia(_ submission: ComposerMediaEditorSubmission) async throws {
        guard isSending == false else { return }

        let attachment = try await submission.media.makeAttachment(qualityPreset: submission.qualityPreset)
        let draft = OutgoingMessageDraft(
            text: submission.caption,
            attachments: [attachment],
            voiceMessage: nil,
            replyToMessageID: replyMessage?.id,
            replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
            communityContext: communityContext,
            deliveryOptions: editingMessage == nil ? deliveryOptions : MessageDeliveryOptions()
        )

        try await onSend(draft)
        draftText = ""
        composerError = ""
    }

    private var deliveryOptionsBanner: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            if deliveryOptions.isSilent {
                deliveryOptionChip(systemName: "bell.slash.fill", title: "Silent")
            }

            if let scheduledAt = deliveryOptions.scheduledAt {
                deliveryOptionChip(
                    systemName: "clock.fill",
                    title: "Send \(scheduledAt.formatted(date: .omitted, time: .shortened))"
                )
            }

            if let selfDestructSeconds = deliveryOptions.selfDestructSeconds {
                deliveryOptionChip(
                    systemName: "timer",
                    title: "Auto-delete \(selfDestructLabel(for: selfDestructSeconds))"
                )
            }

            Spacer(minLength: 0)

            Button {
                deliveryOptions = MessageDeliveryOptions()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.background.opacity(0.58))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.background.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
        )
        .padding(.horizontal, PrimeTheme.Spacing.large)
    }

    private var communityContextPreviewText: String {
        if let communityContext, communityContext.parentPostID != nil {
            return "Replies will stay inside this post thread."
        }
        if let communityContext, communityContext.topicID != nil {
            return "New messages will go to this topic."
        }
        return "Messages will follow the current community timeline."
    }

    private func deliveryOptionChip(systemName: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(PrimeTheme.Colors.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(PrimeTheme.Colors.warning.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(PrimeTheme.Colors.warning.opacity(0.18), lineWidth: 1)
        )
    }

    private func selfDestructLabel(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        return "\(seconds / 3600)h"
    }

    private func nextMorningDeliveryDate(now: Date = .now) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 60 * 60)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func replyPreviewText(for message: Message) -> String {
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

    private func makeReplyPreviewSnapshot(for message: Message) -> ReplyPreviewSnapshot {
        ReplyPreviewSnapshot(
            senderID: message.senderID,
            senderDisplayName: resolvedReplySenderDisplayName(for: message),
            previewText: replyPreviewText(for: message)
        )
    }

    private func resolvedReplySenderDisplayName(for message: Message) -> String? {
        let trimmedDisplayName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDisplayName, trimmedDisplayName.isEmpty == false {
            return trimmedDisplayName
        }

        return nil
    }

    private func editPreviewText(for message: Message) -> String {
        replyPreviewText(for: message)
    }

    private func replyBannerTitle(for message: Message) -> String {
        if let displayName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           displayName.isEmpty == false {
            return "Reply to \(displayName)"
        }
        return "Reply to message"
    }

    @ViewBuilder
    private func composerContextBanner(title: String, preview: String, onCancel: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: PrimeTheme.Spacing.small) {
            ZStack {
                Circle()
                    .fill(PrimeTheme.Colors.accent.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(PrimeTheme.Colors.background.opacity(0.58))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.background.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
        )
        .padding(.horizontal, PrimeTheme.Spacing.large)
    }

    private var recordingBanner: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            ZStack {
                Circle()
                    .fill(PrimeTheme.Colors.warning.opacity(0.18))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(PrimeTheme.Colors.warning)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.isPaused ? "Paused \(formattedRecordingDuration)" : "Recording \(formattedRecordingDuration)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(recordingHelpText)
                    .font(.caption2)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if isHoldRecording == false {
                Button {
                    if recorder.isPaused {
                        recorder.resumeRecording()
                    } else {
                        recorder.pauseRecording()
                    }
                } label: {
                    Text(recorder.isPaused ? "Resume" : "Pause")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeTheme.Colors.background.opacity(0.68))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    stopTapRecording()
                } label: {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeTheme.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
            }

            Button("Cancel") {
                recorder.cancelRecording()
                isHoldRecording = false
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.background.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PrimeTheme.Spacing.large)
    }

    @MainActor
    private func makeGalleryAttachment(from item: ComposerPhotoPickerItem) async throws -> Attachment? {
        #if canImport(PhotosUI) && !os(tvOS)
        let contentType = item.supportedContentTypes.first ?? .data
        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) || contentType.conforms(to: .audiovisualContent) {
            guard let importedVideo = try await item.loadTransferable(type: GalleryVideoImport.self) else {
                throw ComposerGalleryImportError.videoUnavailable
            }
            let videoURL = importedVideo.url
            return try await ChatMediaDraftBuilder.makeVideoAttachment(
                copying: videoURL,
                fileExtension: videoURL.pathExtension.isEmpty ? contentType.preferredFilenameExtension : videoURL.pathExtension,
                mimeType: contentType.preferredMIMEType ?? UTType(filenameExtension: videoURL.pathExtension)?.preferredMIMEType ?? "video/quicktime",
                qualityPreset: NetworkUsagePolicy.preferredUploadQuality(for: .videos)
            )
        }

        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }

        return try ChatMediaDraftBuilder.makePhotoAttachment(
            from: data,
            qualityPreset: NetworkUsagePolicy.preferredUploadQuality(for: .photos)
        )
        #else
        return nil
        #endif
    }

    @MainActor
    private func makeLibraryAttachment(from asset: PHAsset) async throws -> Attachment? {
        if asset.mediaType == .video {
            guard let videoInfo = try await loadVideoInfo(from: asset) else {
                throw ComposerGalleryImportError.videoUnavailable
            }
            return try await ChatMediaDraftBuilder.makeVideoAttachment(
                copying: videoInfo.url,
                fileExtension: videoInfo.fileExtension,
                mimeType: videoInfo.mimeType,
                qualityPreset: NetworkUsagePolicy.preferredUploadQuality(for: .videos)
            )
        }

        guard let data = try await loadImageData(from: asset) else {
            return nil
        }
        return try ChatMediaDraftBuilder.makePhotoAttachment(
            from: data,
            qualityPreset: NetworkUsagePolicy.preferredUploadQuality(for: .photos)
        )
    }

    @MainActor
    private func makePendingMedia(from item: ComposerPhotoPickerItem) async throws -> ComposerPendingMedia? {
        #if canImport(PhotosUI) && !os(tvOS)
        let contentType = item.supportedContentTypes.first ?? .data
        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) || contentType.conforms(to: .audiovisualContent) {
            guard let importedVideo = try await item.loadTransferable(type: GalleryVideoImport.self) else {
                throw ComposerGalleryImportError.videoUnavailable
            }
            let videoURL = importedVideo.url
            return ComposerPendingMedia(
                source: .video(
                    url: videoURL,
                    fileExtension: videoURL.pathExtension.isEmpty ? contentType.preferredFilenameExtension : videoURL.pathExtension,
                    mimeType: contentType.preferredMIMEType ?? UTType(filenameExtension: videoURL.pathExtension)?.preferredMIMEType ?? "video/quicktime"
                )
            )
        }

        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }

        return ComposerPendingMedia(source: .photo(data: data))
        #else
        return nil
        #endif
    }

    @MainActor
    private func makePendingMedia(from asset: PHAsset) async throws -> ComposerPendingMedia? {
        if asset.mediaType == .video {
            guard let videoInfo = try await loadVideoInfo(from: asset) else {
                throw ComposerGalleryImportError.videoUnavailable
            }
            return ComposerPendingMedia(
                source: .video(
                    url: videoInfo.url,
                    fileExtension: videoInfo.fileExtension,
                    mimeType: videoInfo.mimeType
                )
            )
        }

        guard let data = try await loadImageData(from: asset) else {
            return nil
        }
        return ComposerPendingMedia(source: .photo(data: data))
    }

    private func loadImageData(from asset: PHAsset) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                lock.lock()
                defer { lock.unlock() }
                guard didResume == false else { return }

                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if isCancelled {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                didResume = true
                continuation.resume(returning: data)
            }
        }
    }

    private func loadVideoInfo(from asset: PHAsset) async throws -> ComposerLibraryVideoInfo? {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                lock.lock()
                defer { lock.unlock() }
                guard didResume == false else { return }

                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if isCancelled {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let urlAsset = avAsset as? AVURLAsset else {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                let url = urlAsset.url
                let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "video/quicktime"
                didResume = true
                continuation.resume(returning: ComposerLibraryVideoInfo(url: url, fileExtension: fileExtension, mimeType: mimeType))
            }
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard urls.isEmpty == false else { return }

            var importedAnyFile = false
            for url in urls {
                let canAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if canAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    attachments.append(try ChatMediaDraftBuilder.makeDocumentAttachment(copying: url))
                    importedAnyFile = true
                } catch {
                    composerError = "Could not attach one or more selected files."
                }
            }

            if importedAnyFile {
                composerError = ""
            }
        case .failure:
            composerError = "Could not open the selected file."
        }
    }

    @MainActor
    private func attachCurrentLocation() async {
        guard isResolvingLocation == false else { return }
        isResolvingLocation = true
        defer { isResolvingLocation = false }

        do {
            let location = try await locationProvider.requestCurrentLocation()
            pendingLocationSelection = ComposerLocationSelection(location: location)
            composerError = ""
        } catch {
            composerError = error.localizedDescription.isEmpty ? "Could not get your current location." : error.localizedDescription
        }
    }

    @MainActor
    private func handleCameraResult(_ result: Result<ComposerCameraCaptureResult, Error>) async {
        switch result {
        case let .success(capture):
            do {
                switch capture {
                case let .photo(data):
                    pendingMediaEditor = ComposerPendingMedia(source: .photo(data: data))
                case let .video(url, fileExtension, mimeType):
                    pendingMediaEditor = ComposerPendingMedia(
                        source: .video(
                            url: url,
                            fileExtension: fileExtension,
                            mimeType: mimeType
                        )
                    )
                }
                composerError = ""
            } catch {
                composerError = "Could not attach the captured media."
            }
        case .failure:
            composerError = "Could not open the camera."
        }
    }

    private func composedText(appending newBlock: String) -> String {
        let trimmedExisting = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedExisting.isEmpty == false else { return newBlock }
        return "\(trimmedExisting)\n\n\(newBlock)"
    }

    @MainActor
    private func sendStructuredMessageText(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return false }
        guard isSending == false else { return false }

        let draft = OutgoingMessageDraft(
            text: trimmedText,
            attachments: [],
            voiceMessage: nil,
            replyToMessageID: replyMessage?.id,
            replyPreview: replyMessage.map(makeReplyPreviewSnapshot(for:)),
            communityContext: communityContext,
            deliveryOptions: editingMessage == nil ? deliveryOptions : MessageDeliveryOptions()
        )

        do {
            try await onSend(draft)
            composerError = ""
            return true
        } catch {
            composerError = error.localizedDescription.isEmpty ? "Could not send the message." : error.localizedDescription
            return false
        }
    }

    @ViewBuilder
    private func composerCircleButton(systemName: String, foregroundColor: Color) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: composerControlSize, height: composerControlSize)
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                .frame(width: composerControlSize, height: composerControlSize)
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var trailingButtonSymbol: String {
        if recorder.isRecording {
            return "stop.fill"
        }

        return canSend ? "arrow.up" : "mic.fill"
    }

    private var trailingButtonColor: Color {
        if recorder.isRecording {
            return PrimeTheme.Colors.warning
        }

        return canSend ? PrimeTheme.Colors.accent : PrimeTheme.Colors.textSecondary
    }

    private var formattedRecordingDuration: String {
        let seconds = Int(recorder.recordingDuration.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }

    private var recordingHelpText: String {
        if recorder.isPaused {
            return "Resume to continue, preview to listen, or cancel to discard"
        }

        if isHoldRecording {
            return "Release to stop and preview the voice message"
        }

        return "Pause, preview before sending, or cancel to discard"
    }
}

private struct AttachmentPreviewCard: View {
    let attachment: Attachment

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewBody

            if attachment.type != .photo {
                VStack(alignment: .leading, spacing: 4) {
                    Label(typeTitle, systemImage: systemImageName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(attachment.fileName)
                        .font(.caption2)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.72), Color.black.opacity(0.18)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewBody: some View {
        if attachment.type == .photo,
           let localURL = attachment.localURL,
           let uiImage = UIImage(contentsOfFile: localURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        PrimeTheme.Colors.elevated,
                        PrimeTheme.Colors.background.opacity(0.92),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: systemImageName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
            }
        }
    }

    private var systemImageName: String {
        switch attachment.type {
        case .photo:
            return "photo"
        case .video:
            return "video.fill"
        case .document:
            return "doc.fill"
        case .audio:
            return "waveform"
        case .contact:
            return "person.crop.circle"
        case .location:
            return "mappin.and.ellipse"
        }
    }

    private var typeTitle: String {
        switch attachment.type {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .document:
            return "File"
        case .audio:
            return "Audio"
        case .contact:
            return "Contact"
        case .location:
            return "Location"
        }
    }
}

private struct ComposerAttachmentMenuOverlay: View {
    let containerSize: CGSize
    let onDismiss: () -> Void
    let onPreviewAsset: (PHAsset) -> Void
    let onSendSelectedAssets: ([PHAsset]) -> Void
    let onOpenCamera: () -> Void
    let onOpenFiles: () -> Void
    let onOpenLocation: () -> Void
    let onOpenPoll: () -> Void
    let onOpenList: () -> Void

    @State private var isVisible = false
    @StateObject private var library = ComposerMediaLibraryController()
    @State private var selectedTab: AttachmentLauncherTab = .gallery

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    private enum AttachmentLauncherTab: CaseIterable, Identifiable {
        case gallery
        case file
        case geolocation
        case poll
        case list

        var id: Self { self }

        var title: String {
            switch self {
            case .gallery:
                return "Gallery"
            case .file:
                return "File"
            case .geolocation:
                return "Geolocation"
            case .poll:
                return "Poll"
            case .list:
                return "List"
            }
        }

        var systemImage: String {
            switch self {
            case .gallery:
                return "photo.on.rectangle.angled"
            case .file:
                return "doc"
            case .geolocation:
                return "location"
            case .poll:
                return "chart.bar.xaxis"
            case .list:
                return "list.bullet"
            }
        }
    }

    var body: some View {
        bottomLauncher
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    isVisible = true
                }
                Task {
                    await library.loadIfNeeded()
                }
            }
    }

    private var bottomLauncher: some View {
        VStack(alignment: .leading, spacing: 14) {
            mediaGridCard
            bottomActionBar
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: isVisible ? 0 : 40)
        .opacity(isVisible ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isVisible)
    }

    private var mediaGridCard: some View {
        VStack(spacing: 0) {
            if library.isAuthorized {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        cameraTile
                        ForEach(library.assets, id: \.localIdentifier) { asset in
                            ComposerAttachmentAssetTile(
                                asset: asset,
                                imageManager: library.imageManager,
                                selectionIndex: library.selectionIndex(for: asset),
                                onTap: {
                                    onPreviewAsset(asset)
                                },
                                onToggleSelection: {
                                    library.toggleSelection(for: asset)
                                }
                            )
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 210)
            } else {
                permissionCard
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.06),
                                    PrimeTheme.Colors.glassTint.opacity(0.54),
                                    Color.black.opacity(0.24)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke.opacity(0.92), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 26, y: 14)
    }

    private var cameraTile: some View {
        Button {
            dismissAnimated {
                onOpenCamera()
            }
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 20, weight: .semibold))
                        Text("CAMERA")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                )
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow photo access")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("To show your recent photos here and let you send several at once.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.7))
            Button {
                Task {
                    await library.requestAccess()
                }
            } label: {
                Text("Open Library")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.accent.opacity(0.85))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Button {
                dismissAnimated()
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.08),
                                            PrimeTheme.Colors.glassTint.opacity(0.62),
                                            Color.black.opacity(0.28)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                    Circle()
                        .stroke(PrimeTheme.Colors.glassStroke.opacity(0.9), lineWidth: 1)
                    Circle()
                        .inset(by: 6)
                        .fill(Color.black.opacity(0.56))
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            attachmentTabBar

            if library.selectedAssets.isEmpty == false {
                Button {
                    let assets = library.selectedAssets
                    dismissAnimated {
                        onSendSelectedAssets(assets)
                    }
                } label: {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.accent)
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                            Text("\(library.selectedAssets.count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 48)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: library.selectedAssets.count)
    }

    private var attachmentTabBar: some View {
        HStack(spacing: 4) {
            ForEach(AttachmentLauncherTab.allCases) { tab in
                Button {
                    handleTabSelection(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(tab == selectedTab ? .white : Color.white.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                tab == selectedTab
                                    ? PrimeTheme.Colors.accent.opacity(0.92)
                                    : Color.white.opacity(0.04)
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                tab == selectedTab
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    PrimeTheme.Colors.glassTint.opacity(0.58),
                                    Color.black.opacity(0.24)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 16, y: 8)
    }

    private func dismissAnimated(after completion: (() -> Void)? = nil) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            isVisible = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            onDismiss()
            completion?()
        }
    }

    private func handleTabSelection(_ tab: AttachmentLauncherTab) {
        selectedTab = tab
        switch tab {
        case .gallery:
            break
        case .file:
            dismissAnimated {
                onOpenFiles()
            }
        case .geolocation:
            dismissAnimated {
                onOpenLocation()
            }
        case .poll:
            dismissAnimated {
                onOpenPoll()
            }
        case .list:
            dismissAnimated {
                onOpenList()
            }
        }
    }
}

@MainActor
private final class ComposerMediaLibraryController: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var selectedIDs: [String] = []
    @Published var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    let imageManager = PHCachingImageManager()
    private var hasLoaded = false

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var selectedAssets: [PHAsset] {
        let selected = Set(selectedIDs)
        return assets.filter { selected.contains($0.localIdentifier) }
    }

    func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        hasLoaded = true
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard isAuthorized else {
            assets = []
            selectedIDs = []
            return
        }
        reloadAssets()
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        guard isAuthorized else {
            assets = []
            selectedIDs = []
            return
        }
        reloadAssets()
    }

    func toggleSelection(for asset: PHAsset) {
        if let index = selectedIDs.firstIndex(of: asset.localIdentifier) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(asset.localIdentifier)
        }
    }

    func selectionIndex(for asset: PHAsset) -> Int? {
        selectedIDs.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    private func reloadAssets() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: fetchOptions)
        var loadedAssets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            loadedAssets.append(asset)
        }
        assets = loadedAssets
        selectedIDs = selectedIDs.filter { id in loadedAssets.contains(where: { $0.localIdentifier == id }) }
    }
}

private struct ComposerAttachmentAssetTile: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let selectionIndex: Int?
    let onTap: () -> Void
    let onToggleSelection: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(alignment: .center) {
                        ZStack {
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                ProgressView()
                                    .tint(.white.opacity(0.8))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if asset.mediaType == .video {
                            HStack(spacing: 4) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(asset.composerDurationLabel)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.45), in: Capsule(style: .continuous))
                            .padding(6)
                        }
                    }

                Button(action: onToggleSelection) {
                    ZStack {
                        Circle()
                            .fill(selectionIndex == nil ? Color.black.opacity(0.34) : PrimeTheme.Colors.accent)
                            .frame(width: 22, height: 22)
                        Circle()
                            .stroke(Color.white.opacity(0.92), lineWidth: 2)
                            .frame(width: 22, height: 22)
                        if let selectionIndex {
                            Text("\(selectionIndex)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                }
                .buttonStyle(.plain)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        if thumbnail != nil { return }
        let targetSize = CGSize(width: 260, height: 260)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        thumbnail = await withCheckedContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                lock.lock()
                defer { lock.unlock() }
                guard didResume == false else { return }

                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if isCancelled {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                if info?[PHImageErrorKey] != nil {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded {
                    return
                }

                didResume = true
                continuation.resume(returning: image)
            }
        }
    }
}

private struct ComposerPendingMedia: Identifiable {
    enum Source {
        case photo(data: Data)
        case preparedPhoto(data: Data)
        case video(url: URL, fileExtension: String?, mimeType: String)
    }

    let id = UUID()
    let source: Source

    var defaultQualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset {
        switch source {
        case .photo, .preparedPhoto:
            return NetworkUsagePolicy.preferredUploadQuality(for: .photos)
        case .video:
            return NetworkUsagePolicy.preferredUploadQuality(for: .videos)
        }
    }

    func makeAttachment(
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset
    ) async throws -> Attachment {
        switch source {
        case let .photo(data):
            return try ChatMediaDraftBuilder.makePhotoAttachment(
                from: data,
                qualityPreset: qualityPreset
            )
        case let .preparedPhoto(data):
            return try ChatMediaDraftBuilder.makePreparedPhotoAttachment(jpegData: data)
        case let .video(url, fileExtension, mimeType):
            return try await ChatMediaDraftBuilder.makeVideoAttachment(
                copying: url,
                fileExtension: fileExtension,
                mimeType: mimeType,
                qualityPreset: qualityPreset
            )
        }
    }
}

private struct ComposerMediaEditorSubmission {
    let caption: String
    let qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset
    let media: ComposerPendingMedia
}

private enum ComposerMediaEditorTool: String, Identifiable {
    case crop
    case draw
    case adjust

    var id: String { rawValue }
}

private enum ComposerPhotoCropPreset: String, CaseIterable, Identifiable {
    case original
    case square
    case portrait
    case story

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            return "Original"
        case .square:
            return "Square"
        case .portrait:
            return "4:5"
        case .story:
            return "9:16"
        }
    }

    var aspectRatio: CGFloat? {
        switch self {
        case .original:
            return nil
        case .square:
            return 1
        case .portrait:
            return 4.0 / 5.0
        case .story:
            return 9.0 / 16.0
        }
    }
}

private struct ComposerPhotoAdjustmentValues {
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
}

private struct ComposerPhotoStroke: Identifiable, Hashable {
    struct Point: Hashable {
        var x: CGFloat
        var y: CGFloat
    }

    let id = UUID()
    var colorHex: String
    var lineWidth: CGFloat
    var points: [Point]

    var color: Color {
        Color(hex: colorHex)
    }
}

private struct ComposerMediaEditorSheet: View {
    let chatTitle: String
    let media: ComposerPendingMedia
    let initialCaption: String
    let initialQualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset
    let onSend: (ComposerMediaEditorSubmission) async throws -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var captionText: String
    @State private var selectedQualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset
    @State private var usesFillPreview = false
    @State private var isMuted = false
    @State private var isSending = false
    @State private var errorText = ""
    @State private var activeTool: ComposerMediaEditorTool?
    @State private var photoCropPreset: ComposerPhotoCropPreset = .original
    @State private var photoCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var photoAdjustments = ComposerPhotoAdjustmentValues()
    @State private var photoStrokes: [ComposerPhotoStroke] = []
    @State private var selectedDrawColor = Color.white
    @State private var videoTrimStart: Double = 0
    @State private var videoTrimEnd: Double = 1

    init(
        chatTitle: String,
        media: ComposerPendingMedia,
        initialCaption: String,
        initialQualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset,
        onSend: @escaping (ComposerMediaEditorSubmission) async throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.chatTitle = chatTitle
        self.media = media
        self.initialCaption = initialCaption
        self.initialQualityPreset = initialQualityPreset
        self.onSend = onSend
        self.onClose = onClose
        _captionText = State(initialValue: initialCaption)
        _selectedQualityPreset = State(initialValue: initialQualityPreset)
    }

    var body: some View {
        platformStatusBarBehavior(
            GeometryReader { geometry in
                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        topChrome(topInset: geometry.safeAreaInsets.top)

                        Spacer(minLength: 0)

                        mediaCanvas
                            .padding(.horizontal, 10)
                            .padding(.top, 14)

                        Spacer(minLength: 0)

                        if let videoURL {
                            ComposerVideoTrimEditor(
                                url: videoURL,
                                startProgress: $videoTrimStart,
                                endProgress: $videoTrimEnd
                            )
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                        }

                        if isPhoto, let activeTool {
                            toolPanel(for: activeTool)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if errorText.isEmpty == false {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.86))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22)
                                .padding(.bottom, 10)
                        }

                        bottomComposerPanel(bottomInset: geometry.safeAreaInsets.bottom)
                    }
                }
            }
        )
        .interactiveDismissDisabled(isSending)
    }

    @ViewBuilder
    private func platformStatusBarBehavior<Content: View>(_ content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.statusBarHidden(false)
        #endif
    }

    @ViewBuilder
    private var mediaCanvas: some View {
        switch media.source {
        case let .photo(data):
            ComposerPhotoCanvas(
                data: data,
                usesFillPreview: usesFillPreview,
                cropPreset: photoCropPreset,
                cropRect: $photoCropRect,
                adjustments: photoAdjustments,
                strokes: $photoStrokes,
                selectedDrawColor: selectedDrawColor,
                allowsDrawing: activeTool == .draw,
                isCropping: activeTool == .crop
            )
        case let .preparedPhoto(data):
            ComposerPhotoCanvas(
                data: data,
                usesFillPreview: usesFillPreview,
                cropPreset: photoCropPreset,
                cropRect: $photoCropRect,
                adjustments: photoAdjustments,
                strokes: $photoStrokes,
                selectedDrawColor: selectedDrawColor,
                allowsDrawing: activeTool == .draw,
                isCropping: activeTool == .crop
            )
        case let .video(url, _, _):
            ComposerVideoCanvas(
                url: url,
                usesFillPreview: usesFillPreview,
                isMuted: $isMuted
            )
        }
    }

    private var videoURL: URL? {
        guard case let .video(url, _, _) = media.source else { return nil }
        return url
    }

    private var isPhoto: Bool {
        if case .photo = media.source {
            return true
        }
        if case .preparedPhoto = media.source {
            return true
        }
        return false
    }

    private func topChrome(topInset: CGFloat) -> some View {
        HStack(spacing: 14) {
            Button {
                closeEditor()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(chatTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(videoURL == nil ? "Photo preview" : "Video preview")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.88), lineWidth: 2)
                    .frame(width: 30, height: 30)
                Text(chatAvatarInitial)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, topInset + 8)
    }

    private func bottomComposerPanel(bottomInset: CGFloat) -> some View {
        VStack(spacing: 14) {
            captionBar
            toolbarRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, max(bottomInset, 8))
    }

    private var captionBar: some View {
        HStack(spacing: 12) {
            TextField("Add caption...", text: $captionText, axis: .vertical)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1 ... 4)

            Image(systemName: "info.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            if isPhoto {
                toolbarButton(
                    systemName: "crop",
                    title: "Crop",
                    isSelected: activeTool == .crop
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        activeTool = activeTool == .crop ? nil : .crop
                    }
                }

                toolbarButton(
                    systemName: "pencil.tip.crop.circle",
                    title: "Draw",
                    isSelected: activeTool == .draw
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        activeTool = activeTool == .draw ? nil : .draw
                    }
                }

                toolbarButton(
                    systemName: "slider.horizontal.3",
                    title: "Adjust",
                    isSelected: activeTool == .adjust
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        activeTool = activeTool == .adjust ? nil : .adjust
                    }
                }
            } else {
                toolbarButton(
                    systemName: usesFillPreview ? "rectangle.compress.vertical" : "crop.rotate",
                    title: usesFillPreview ? "Fit" : "Fill",
                    isSelected: usesFillPreview
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        usesFillPreview.toggle()
                    }
                }

                if videoURL != nil {
                    toolbarButton(
                        systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        title: isMuted ? "Muted" : "Audio",
                        isSelected: isMuted
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isMuted.toggle()
                        }
                    }
                }
            }

            Menu {
                ForEach(NetworkUsagePolicy.MediaUploadQualityPreset.allCases) { preset in
                    Button {
                        selectedQualityPreset = preset
                    } label: {
                        if preset == selectedQualityPreset {
                            Label(preset.composerShortLabel, systemImage: "checkmark")
                        } else {
                            Text(preset.composerShortLabel)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedQualityPreset.composerShortLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 62, minHeight: 52)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                Task {
                    await performSend()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(PrimeTheme.Colors.accent)
                        .frame(width: 56, height: 56)
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSending)
        }
    }

    private func toolbarButton(systemName: String, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? PrimeTheme.Colors.accent.opacity(0.24) : Color.white.opacity(0.08))
                        .frame(width: 52, height: 52)
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toolPanel(for tool: ComposerMediaEditorTool) -> some View {
        switch tool {
        case .crop:
            cropPanel
        case .draw:
            drawPanel
        case .adjust:
            adjustPanel
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                ForEach(ComposerPhotoCropPreset.allCases) { preset in
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            photoCropPreset = preset
                            photoCropRect = ComposerCropMath.fittedRect(
                                for: preset.aspectRatio,
                                currentRect: photoCropRect
                            )
                        }
                    } label: {
                        Text(preset.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(photoCropPreset == preset ? PrimeTheme.Colors.accent.opacity(0.32) : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var drawPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Draw")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button("Clear") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        photoStrokes.removeAll()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.76))
            }

            HStack(spacing: 12) {
                ForEach(ComposerMediaEditorPaletteColor.allCases, id: \.rawValue) { paletteColor in
                    Button {
                        selectedDrawColor = paletteColor.color
                    } label: {
                        ZStack {
                            Circle()
                                .fill(paletteColor.color)
                                .frame(width: 28, height: 28)
                            if selectedDrawColor.matches(paletteColor.color) {
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                                    .frame(width: 36, height: 36)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Drag directly on the photo to draw.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.64))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var adjustPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)

            adjustmentSlider(title: "Brightness", value: $photoAdjustments.brightness, range: -0.35 ... 0.35)
            adjustmentSlider(title: "Contrast", value: $photoAdjustments.contrast, range: 0.7 ... 1.5)
            adjustmentSlider(title: "Saturation", value: $photoAdjustments.saturation, range: 0.4 ... 1.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func adjustmentSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.8))

            #if os(tvOS)
            HStack(spacing: 10) {
                Button {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - sliderStepSize(for: range))
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.accentSoft)
                            .frame(width: adjustmentFillWidth(for: value.wrappedValue, range: range))
                    }

                Button {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + sliderStepSize(for: range))
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            #else
            Slider(value: value, in: range)
                .tint(PrimeTheme.Colors.accentSoft)
            #endif
        }
    }

    private func sliderStepSize(for range: ClosedRange<Double>) -> Double {
        max((range.upperBound - range.lowerBound) / 20, 0.01)
    }

    private func adjustmentFillWidth(for currentValue: Double, range: ClosedRange<Double>) -> CGFloat {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let progress = max(0, min((currentValue - range.lowerBound) / span, 1))
        return CGFloat(progress) * 160
    }

    @MainActor
    private func performSend() async {
        guard isSending == false else { return }
        isSending = true

        do {
            let submission = await buildSubmission()
            let sendAction = onSend
            closeEditor()
            Task {
                try? await sendAction(submission)
            }
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not send this media." : error.localizedDescription
        }

        if isSending {
            isSending = false
        }
    }

    @MainActor
    private func buildSubmission() async -> ComposerMediaEditorSubmission {
        let caption = captionText
        let qualityPreset = selectedQualityPreset
        let media = media
        let cropPreset = photoCropPreset
        let cropRect = photoCropRect
        let adjustments = photoAdjustments
        let strokes = photoStrokes
        let videoTrimStart = videoTrimStart
        let videoTrimEnd = videoTrimEnd

        let resolvedMedia: ComposerPendingMedia
        if case let .photo(data) = media.source {
            let editedPhotoData = await Task.detached(priority: .userInitiated) {
                renderEditedPhotoData(
                    from: data,
                    cropPreset: cropPreset,
                    cropRect: cropRect,
                    adjustments: adjustments,
                    strokes: strokes
                )
            }.value
            if let editedPhotoData {
                resolvedMedia = ComposerPendingMedia(source: .preparedPhoto(data: editedPhotoData))
            } else {
                resolvedMedia = media
            }
        } else if case let .preparedPhoto(data) = media.source {
            let editedPhotoData = await Task.detached(priority: .userInitiated) {
                renderEditedPhotoData(
                    from: data,
                    cropPreset: cropPreset,
                    cropRect: cropRect,
                    adjustments: adjustments,
                    strokes: strokes
                )
            }.value
            if let editedPhotoData {
                resolvedMedia = ComposerPendingMedia(source: .preparedPhoto(data: editedPhotoData))
            } else {
                resolvedMedia = media
            }
        } else if case let .video(url, fileExtension, mimeType) = media.source,
                  abs(videoTrimStart) > 0.0001 || abs(videoTrimEnd - 1) > 0.0001 {
            if let trimmedMedia = await renderTrimmedVideoSource(
                url: url,
                fileExtension: fileExtension,
                mimeType: mimeType,
                startProgress: videoTrimStart,
                endProgress: videoTrimEnd
            ) {
                resolvedMedia = trimmedMedia
            } else {
                resolvedMedia = media
            }
        } else {
            resolvedMedia = media
        }

        return ComposerMediaEditorSubmission(
            caption: caption,
            qualityPreset: qualityPreset,
            media: resolvedMedia
        )
    }

    private var chatAvatarInitial: String {
        let trimmed = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.first ?? "•")
    }

    @MainActor
    private func closeEditor() {
        dismiss()
        Task { @MainActor in
            onClose()
        }
    }
}

private struct ComposerPhotoCanvas: View {
    let data: Data
    let usesFillPreview: Bool
    let cropPreset: ComposerPhotoCropPreset
    @Binding var cropRect: CGRect
    let adjustments: ComposerPhotoAdjustmentValues
    @Binding var strokes: [ComposerPhotoStroke]
    let selectedDrawColor: Color
    let allowsDrawing: Bool
    let isCropping: Bool

    @State private var currentStroke: ComposerPhotoStroke?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                if let uiImage = UIImage(data: data) {
                    let imageRect = ComposerCropMath.imageRect(
                        imageSize: uiImage.size,
                        containerSize: geometry.size
                    )

                    Image(uiImage: uiImage)
                        .resizable()
                        .saturation(adjustments.saturation)
                        .contrast(adjustments.contrast)
                        .brightness(adjustments.brightness)
                        .aspectRatio(contentMode: usesFillPreview ? .fill : .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

                    ComposerDrawingOverlay(
                        strokes: strokes,
                        currentStroke: currentStroke,
                        isEnabled: allowsDrawing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    #if !os(tvOS)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard allowsDrawing, imageRect.contains(value.location) else { return }
                                let point = ComposerPhotoStroke.Point(
                                    x: min(max((value.location.x - imageRect.minX) / max(imageRect.width, 1), 0), 1),
                                    y: min(max((value.location.y - imageRect.minY) / max(imageRect.height, 1), 0), 1)
                                )

                                if currentStroke == nil {
                                    currentStroke = ComposerPhotoStroke(
                                        colorHex: selectedDrawColor.hexString,
                                        lineWidth: 7,
                                        points: [point]
                                    )
                                } else {
                                    currentStroke?.points.append(point)
                                }
                            }
                            .onEnded { _ in
                                guard let currentStroke, currentStroke.points.isEmpty == false else {
                                    self.currentStroke = nil
                                    return
                                }
                                strokes.append(currentStroke)
                                self.currentStroke = nil
                            }
                    )
                    #endif

                    if isCropping {
                        ComposerCropOverlay(
                            imageRect: imageRect,
                            cropRect: $cropRect,
                            aspectRatio: cropPreset.aspectRatio
                        )
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        Text("Could not preview this photo")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }
}

private func renderEditedPhotoData(
    from data: Data,
    cropPreset: ComposerPhotoCropPreset,
    cropRect: CGRect,
    adjustments: ComposerPhotoAdjustmentValues,
    strokes: [ComposerPhotoStroke]
) -> Data? {
    ComposerMediaEditorRenderer.renderEditedPhotoData(
        from: data,
        cropPreset: cropPreset,
        cropRect: cropRect,
        adjustments: adjustments,
        strokes: strokes
    )
}

private func renderTrimmedVideoSource(
    url: URL,
    fileExtension: String?,
    mimeType: String,
    startProgress: Double,
    endProgress: Double
) async -> ComposerPendingMedia? {
    let startProgress = max(0, min(startProgress, 1))
    let endProgress = max(startProgress + 0.01, min(endProgress, 1))
    guard endProgress - startProgress < 0.999 else {
        return ComposerPendingMedia(source: .video(url: url, fileExtension: fileExtension, mimeType: mimeType))
    }

    return await Task.detached(priority: .userInitiated) { () async -> ComposerPendingMedia? in
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = max(CMTimeGetSeconds(duration), 0)
        guard durationSeconds > 0 else { return nil }

        let trimmedStart = durationSeconds * startProgress
        let trimmedEnd = durationSeconds * endProgress
        let exportStart = CMTime(seconds: trimmedStart, preferredTimescale: 600)
        let exportDuration = CMTime(seconds: max(trimmedEnd - trimmedStart, 0.1), preferredTimescale: 600)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }

        let extensionCandidate = (fileExtension?.isEmpty == false ? fileExtension! : url.pathExtension)
        let outputExtension = extensionCandidate.isEmpty ? "mov" : extensionCandidate
        let outputURL = ComposerMediaEditorRenderer.stagedMediaDirectory.appendingPathComponent("trimmed-\(UUID().uuidString).\(outputExtension)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputExtension.lowercased() == "mp4" ? .mp4 : .mov
        exportSession.timeRange = CMTimeRange(start: exportStart, duration: exportDuration)
        exportSession.shouldOptimizeForNetworkUse = true

        return await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(
                        returning: ComposerPendingMedia(
                            source: .video(
                                url: outputURL,
                                fileExtension: outputExtension,
                                mimeType: mimeType
                            )
                        )
                    )
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }.value
}

private enum ComposerMediaEditorRenderer {
    nonisolated(unsafe) static let fileManager = FileManager.default

    nonisolated static var stagedMediaDirectory: URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = baseDirectory
            .appendingPathComponent("PrimeMessagingMedia", isDirectory: true)
            .appendingPathComponent("Staged", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func renderEditedPhotoData(
        from data: Data,
        cropPreset: ComposerPhotoCropPreset,
        cropRect: CGRect,
        adjustments: ComposerPhotoAdjustmentValues,
        strokes: [ComposerPhotoStroke]
    ) -> Data? {
        autoreleasepool {
            guard let image = UIImage(data: data) else {
                return nil
            }

            let croppedImage = image.cropped(using: cropPreset, normalizedRect: cropRect)
            let adjustedImage = croppedImage.applyingAdjustments(adjustments)
            let compositedImage = adjustedImage.rendering(strokes: strokes)
            return compositedImage.jpegData(compressionQuality: 0.98)
        }
    }
}

private struct ComposerVideoCanvas: View {
    let url: URL
    let usesFillPreview: Bool
    @Binding var isMuted: Bool

    @StateObject private var playbackModel: ComposerVideoPreviewModel

    init(url: URL, usesFillPreview: Bool, isMuted: Binding<Bool>) {
        self.url = url
        self.usesFillPreview = usesFillPreview
        _isMuted = isMuted
        _playbackModel = StateObject(wrappedValue: ComposerVideoPreviewModel(url: url))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                ComposerAVPlayerSurface(
                    player: playbackModel.player,
                    videoGravity: usesFillPreview ? .resizeAspectFill : .resizeAspect
                )
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

                if playbackModel.isPlaying == false {
                    Button {
                        playbackModel.togglePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.36))
                                .frame(width: 92, height: 92)
                            Image(systemName: "play.fill")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }

                VStack {
                    Spacer()

                    HStack {
                        Button {
                            playbackModel.toggleMute()
                            isMuted = playbackModel.isMuted
                        } label: {
                            Image(systemName: playbackModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.36))
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
            .onChange(of: isMuted) { newValue in
                playbackModel.setMuted(newValue)
            }
            .onAppear {
                playbackModel.setMuted(isMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }
}

@MainActor
private final class ComposerVideoPreviewModel: ObservableObject {
    let player: AVPlayer
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false

    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .pause
        self.player = player

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = observedPlayer.timeControlStatus == .playing
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            self.player.pause()
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    deinit {
        timeControlObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }
}

private struct ComposerAVPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> ComposerPlayerContainerView {
        let view = ComposerPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: ComposerPlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

private final class ComposerPlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            fatalError("Expected AVPlayerLayer")
        }
        return layer
    }
}

private struct ComposerVideoTrimEditor: View {
    let url: URL
    @Binding var startProgress: Double
    @Binding var endProgress: Double

    @StateObject private var loader: ComposerVideoThumbnailStripLoader
    @State private var leadingHandleStart: Double?
    @State private var trailingHandleStart: Double?

    init(url: URL, startProgress: Binding<Double>, endProgress: Binding<Double>) {
        self.url = url
        _startProgress = startProgress
        _endProgress = endProgress
        _loader = StateObject(wrappedValue: ComposerVideoThumbnailStripLoader(url: url))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.06))

                    if loader.images.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            ProgressView()
                                .tint(.white)
                            Spacer(minLength: 0)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ForEach(Array(loader.images.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                    }

                    let selectionX = CGFloat(startProgress) * geometry.size.width
                    let selectionWidth = max(CGFloat(endProgress - startProgress) * geometry.size.width, 48)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(PrimeTheme.Colors.accent, lineWidth: 2)
                        .frame(width: selectionWidth, height: 62)
                        .offset(x: selectionX)
                        .overlay(alignment: .leading) {
                            #if os(tvOS)
                            trimHandle
                                .offset(x: selectionX - 9)
                            #else
                            trimHandle
                                .offset(x: selectionX - 9)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if leadingHandleStart == nil {
                                                leadingHandleStart = startProgress
                                            }
                                            let delta = value.translation.width / max(geometry.size.width, 1)
                                            startProgress = max(0, min((leadingHandleStart ?? startProgress) + delta, endProgress - 0.05))
                                        }
                                        .onEnded { _ in
                                            leadingHandleStart = nil
                                        }
                                )
                            #endif
                        }
                        .overlay(alignment: .trailing) {
                            #if os(tvOS)
                            trimHandle
                                .offset(x: selectionX + selectionWidth - 9)
                            #else
                            trimHandle
                                .offset(x: selectionX + selectionWidth - 9)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if trailingHandleStart == nil {
                                                trailingHandleStart = endProgress
                                            }
                                            let delta = value.translation.width / max(geometry.size.width, 1)
                                            endProgress = min(1, max((trailingHandleStart ?? endProgress) + delta, startProgress + 0.05))
                                        }
                                        .onEnded { _ in
                                            trailingHandleStart = nil
                                        }
                                )
                            #endif
                        }

                    Rectangle()
                        .fill(Color.black.opacity(0.34))
                        .frame(width: selectionX, height: 62)
                        .offset(x: 0, y: 0)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color.black.opacity(0.34))
                        .frame(width: max(0, geometry.size.width - selectionX - selectionWidth), height: 62)
                        .offset(x: selectionX + selectionWidth, y: 0)
                        .allowsHitTesting(false)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .frame(height: 76)

            HStack {
                Text(trimmedStartLabel)
                Spacer()
                Text(trimmedDurationLabel)
                Spacer()
                Text(trimmedEndLabel)
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.74))
            .padding(.horizontal, 6)
        }
    }

    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(PrimeTheme.Colors.accent)
            .frame(width: 18, height: 62)
            .overlay(
                VStack(spacing: 4) {
                    Capsule().fill(Color.white.opacity(0.92)).frame(width: 3, height: 16)
                    Capsule().fill(Color.white.opacity(0.92)).frame(width: 3, height: 16)
                }
            )
    }

    private var totalDuration: Double {
        loader.durationSeconds
    }

    private var trimmedStartLabel: String {
        format(duration: totalDuration * startProgress)
    }

    private var trimmedEndLabel: String {
        format(duration: totalDuration * endProgress)
    }

    private var trimmedDurationLabel: String {
        format(duration: totalDuration * max(endProgress - startProgress, 0))
    }

    private func format(duration: Double) -> String {
        let seconds = max(Int(duration.rounded(.down)), 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }
}

@MainActor
private final class ComposerVideoThumbnailStripLoader: ObservableObject {
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var durationSeconds: Double = 0

    private let url: URL

    init(url: URL) {
        self.url = url
        Task {
            await load()
        }
    }

    private func load() async {
        let url = self.url
        let generatedImages = await Task.detached(priority: .userInitiated) { () async -> [UIImage] in
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)) ?? .zero
            let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
            let frameCount = 6
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 220, height: 220)
            generator.appliesPreferredTrackTransform = true

            var result: [UIImage] = []
            for index in 0..<frameCount {
                let progress = Double(index) / Double(max(frameCount - 1, 1))
                let requestedTime = CMTime(seconds: durationSeconds * progress, preferredTimescale: 600)
                if let image = try? generator.copyCGImage(at: requestedTime, actualTime: nil) {
                    result.append(UIImage(cgImage: image))
                }
            }
            return result
        }.value

        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        durationSeconds = max(CMTimeGetSeconds(duration), 0)
        images = generatedImages
    }
}

private struct ComposerDrawingOverlay: View {
    let strokes: [ComposerPhotoStroke]
    let currentStroke: ComposerPhotoStroke?
    let isEnabled: Bool

    var body: some View {
        Canvas { context, size in
            for stroke in strokes + (currentStroke.map { [$0] } ?? []) {
                guard stroke.points.count >= 2 else { continue }
                var path = Path()
                let first = CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height)
                path.move(to: first)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.stroke(
                    path,
                    with: .color(stroke.color),
                    style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(isEnabled)
    }
}

private enum ComposerCropHandle {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

private struct ComposerCropOverlay: View {
    let imageRect: CGRect
    @Binding var cropRect: CGRect
    let aspectRatio: CGFloat?

    @State private var dragStartRect: CGRect?
    @State private var resizeStartRect: CGRect?

    var body: some View {
        ZStack {
            cropDimmingOverlay

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .overlay(alignment: .topLeading) { handle(.topLeading) }
                .overlay(alignment: .topTrailing) { handle(.topTrailing) }
                .overlay(alignment: .bottomLeading) { handle(.bottomLeading) }
                .overlay(alignment: .bottomTrailing) { handle(.bottomTrailing) }
                #if !os(tvOS)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartRect == nil {
                                dragStartRect = cropRect
                            }
                            guard let dragStartRect else { return }
                            cropRect = ComposerCropMath.movedRect(
                                dragStartRect,
                                translation: CGSize(
                                    width: value.translation.width / max(imageRect.width, 1),
                                    height: value.translation.height / max(imageRect.height, 1)
                                )
                            )
                        }
                        .onEnded { _ in
                            dragStartRect = nil
                        }
                )
                #endif

            gridOverlay
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .allowsHitTesting(false)
        }
    }

    private var cropFrame: CGRect {
        ComposerCropMath.absoluteFrame(for: cropRect, in: imageRect)
    }

    private var cropDimmingOverlay: some View {
        let topHeight = max(0, cropFrame.minY - imageRect.minY)
        let bottomHeight = max(0, imageRect.maxY - cropFrame.maxY)
        let leftWidth = max(0, cropFrame.minX - imageRect.minX)
        let rightWidth = max(0, imageRect.maxX - cropFrame.maxX)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: imageRect.width, height: topHeight)
                .offset(x: imageRect.minX, y: imageRect.minY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: imageRect.width, height: bottomHeight)
                .offset(x: imageRect.minX, y: cropFrame.maxY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: leftWidth, height: cropFrame.height)
                .offset(x: imageRect.minX, y: cropFrame.minY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: rightWidth, height: cropFrame.height)
                .offset(x: cropFrame.maxX, y: cropFrame.minY)
        }
        .allowsHitTesting(false)
    }

    private var gridOverlay: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            Path { path in
                let vertical1 = width / 3
                let vertical2 = width * 2 / 3
                let horizontal1 = height / 3
                let horizontal2 = height * 2 / 3
                path.move(to: CGPoint(x: vertical1, y: 0))
                path.addLine(to: CGPoint(x: vertical1, y: height))
                path.move(to: CGPoint(x: vertical2, y: 0))
                path.addLine(to: CGPoint(x: vertical2, y: height))
                path.move(to: CGPoint(x: 0, y: horizontal1))
                path.addLine(to: CGPoint(x: width, y: horizontal1))
                path.move(to: CGPoint(x: 0, y: horizontal2))
                path.addLine(to: CGPoint(x: width, y: horizontal2))
            }
            .stroke(Color.white.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
    }

    @ViewBuilder
    private func handle(_ handle: ComposerCropHandle) -> some View {
        Circle()
            .fill(PrimeTheme.Colors.accent)
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.92), lineWidth: 2)
            )
            .offset(handleOffset(for: handle))
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizeStartRect == nil {
                            resizeStartRect = cropRect
                        }
                        guard let resizeStartRect else { return }
                        cropRect = ComposerCropMath.resizedRect(
                            resizeStartRect,
                            handle: handle,
                            translation: CGSize(
                                width: value.translation.width / max(imageRect.width, 1),
                                height: value.translation.height / max(imageRect.height, 1)
                            ),
                            aspectRatio: aspectRatio
                        )
                    }
                    .onEnded { _ in
                        resizeStartRect = nil
                    }
            )
            #endif
    }

    private func handleOffset(for handle: ComposerCropHandle) -> CGSize {
        switch handle {
        case .topLeading:
            return CGSize(width: -10, height: -10)
        case .topTrailing:
            return CGSize(width: 10, height: -10)
        case .bottomLeading:
            return CGSize(width: -10, height: 10)
        case .bottomTrailing:
            return CGSize(width: 10, height: 10)
        }
    }
}

private enum ComposerCropMath {
    static func imageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: containerSize))
    }

    static func absoluteFrame(for normalizedRect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        )
    }

    static func fittedRect(for aspectRatio: CGFloat?, currentRect: CGRect) -> CGRect {
        guard let aspectRatio else {
            return currentRect
        }

        let sourceRect = currentRect.equalTo(CGRect(x: 0, y: 0, width: 1, height: 1)) ? CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92) : currentRect
        let center = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let maxWidth = min(0.92, aspectRatio > 1 ? 0.92 : 0.82)
        var width = maxWidth
        var height = width / aspectRatio
        if height > 0.92 {
            height = 0.92
            width = height * aspectRatio
        }

        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return clamped(rect)
    }

    static func movedRect(_ rect: CGRect, translation: CGSize) -> CGRect {
        let moved = CGRect(
            x: rect.origin.x + translation.width,
            y: rect.origin.y + translation.height,
            width: rect.width,
            height: rect.height
        )
        return clamped(moved)
    }

    static func resizedRect(
        _ rect: CGRect,
        handle: ComposerCropHandle,
        translation: CGSize,
        aspectRatio: CGFloat?
    ) -> CGRect {
        let minimumSide: CGFloat = 0.18

        if let aspectRatio {
            switch handle {
            case .topLeading:
                let anchoredX = rect.maxX
                let anchoredY = rect.maxY
                var width = max(minimumSide, rect.width - translation.width)
                var height = width / aspectRatio
                if height > anchoredY {
                    height = anchoredY
                    width = height * aspectRatio
                }
                let newRect = CGRect(x: anchoredX - width, y: anchoredY - height, width: width, height: height)
                return clamped(newRect)
            case .topTrailing:
                let anchoredX = rect.minX
                let anchoredY = rect.maxY
                var width = max(minimumSide, rect.width + translation.width)
                var height = width / aspectRatio
                if height > anchoredY {
                    height = anchoredY
                    width = height * aspectRatio
                }
                let newRect = CGRect(x: anchoredX, y: anchoredY - height, width: width, height: height)
                return clamped(newRect)
            case .bottomLeading:
                let anchoredX = rect.maxX
                let anchoredY = rect.minY
                var width = max(minimumSide, rect.width - translation.width)
                var height = width / aspectRatio
                if anchoredY + height > 1 {
                    height = 1 - anchoredY
                    width = height * aspectRatio
                }
                let newRect = CGRect(x: anchoredX - width, y: anchoredY, width: width, height: height)
                return clamped(newRect)
            case .bottomTrailing:
                let anchoredX = rect.minX
                let anchoredY = rect.minY
                var width = max(minimumSide, rect.width + translation.width)
                var height = width / aspectRatio
                if anchoredY + height > 1 {
                    height = 1 - anchoredY
                    width = height * aspectRatio
                }
                let newRect = CGRect(x: anchoredX, y: anchoredY, width: width, height: height)
                return clamped(newRect)
            }
        }

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeading:
            minX += translation.width
            minY += translation.height
        case .topTrailing:
            maxX += translation.width
            minY += translation.height
        case .bottomLeading:
            minX += translation.width
            maxY += translation.height
        case .bottomTrailing:
            maxX += translation.width
            maxY += translation.height
        }

        if maxX - minX < minimumSide {
            if handle == .topLeading || handle == .bottomLeading {
                minX = maxX - minimumSide
            } else {
                maxX = minX + minimumSide
            }
        }

        if maxY - minY < minimumSide {
            if handle == .topLeading || handle == .topTrailing {
                minY = maxY - minimumSide
            } else {
                maxY = minY + minimumSide
            }
        }

        return clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    static func clamped(_ rect: CGRect) -> CGRect {
        let minWidth: CGFloat = 0.18
        let minHeight: CGFloat = 0.18
        var rect = rect
        rect.origin.x = max(0, min(rect.origin.x, 1 - minWidth))
        rect.origin.y = max(0, min(rect.origin.y, 1 - minHeight))
        rect.size.width = max(minWidth, min(rect.size.width, 1 - rect.origin.x))
        rect.size.height = max(minHeight, min(rect.size.height, 1 - rect.origin.y))
        return rect
    }
}

private enum ComposerMediaEditorPaletteColor: String, CaseIterable {
    case white
    case red
    case orange
    case green
    case blue
    case purple

    var color: Color {
        switch self {
        case .white:
            return .white
        case .red:
            return Color(red: 0.96, green: 0.29, blue: 0.31)
        case .orange:
            return Color(red: 0.98, green: 0.66, blue: 0.18)
        case .green:
            return Color(red: 0.35, green: 0.88, blue: 0.46)
        case .blue:
            return Color(red: 0.32, green: 0.58, blue: 0.97)
        case .purple:
            return Color(red: 0.72, green: 0.42, blue: 0.94)
        }
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&int)
        let red = Double((int >> 16) & 0xFF) / 255
        let green = Double((int >> 8) & 0xFF) / 255
        let blue = Double(int & 0xFF) / 255
        self = Color(red: red, green: green, blue: blue)
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }

    func matches(_ other: Color) -> Bool {
        UIColor(self).cgColor.components == UIColor(other).cgColor.components
    }
}

private extension UIImage {
    func cropped(using preset: ComposerPhotoCropPreset, normalizedRect: CGRect) -> UIImage {
        let imageSize = size
        let adjustedRect = CGRect(
            x: normalizedRect.minX * imageSize.width,
            y: normalizedRect.minY * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )

        guard let cgImage,
              let croppedCGImage = cgImage.cropping(to: adjustedRect.integral) else {
            return self
        }
        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: imageOrientation)
    }

    func applyingAdjustments(_ adjustments: ComposerPhotoAdjustmentValues) -> UIImage {
        guard let ciImage = CIImage(image: self) else { return self }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.brightness = Float(adjustments.brightness)
        filter.contrast = Float(adjustments.contrast)
        filter.saturation = Float(adjustments.saturation)

        let context = CIContext(options: nil)
        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return self
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
    }

    func rendering(strokes: [ComposerPhotoStroke]) -> UIImage {
        guard strokes.isEmpty == false else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            draw(in: CGRect(origin: .zero, size: size))
            for stroke in strokes {
                guard stroke.points.count >= 2 else { continue }
                let bezier = UIBezierPath()
                bezier.lineCapStyle = .round
                bezier.lineJoinStyle = .round
                bezier.lineWidth = stroke.lineWidth * max(size.width, size.height) / 420
                UIColor(stroke.color).setStroke()
                let first = CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height)
                bezier.move(to: first)
                for point in stroke.points.dropFirst() {
                    bezier.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                bezier.stroke()
            }
        }
    }
}

private extension NetworkUsagePolicy.MediaUploadQualityPreset {
    var composerShortLabel: String {
        switch self {
        case .original:
            return "HD"
        case .balanced:
            return "720"
        case .dataSaver:
            return "SD"
        }
    }

    var nextPreset: Self {
        switch self {
        case .original:
            return .balanced
        case .balanced:
            return .dataSaver
        case .dataSaver:
            return .original
        }
    }
}

private enum ComposerCameraCaptureMode: String, Identifiable {
    case photo
    case video

    var id: String { rawValue }
}

private enum ComposerCameraCaptureResult {
    case photo(Data)
    case video(URL, fileExtension: String?, mimeType: String)
}

#if !os(tvOS)
private struct ComposerCameraPicker: UIViewControllerRepresentable {
    let mode: ComposerCameraCaptureMode
    let onCapture: (Result<ComposerCameraCaptureResult, Error>) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.mediaTypes = mediaTypes
        picker.allowsEditing = false
        picker.videoQuality = NetworkUsagePolicy.preferredUploadQuality(for: .videos).cameraVideoQuality
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary

        if picker.sourceType == .camera {
            picker.cameraCaptureMode = mode == .photo ? .photo : .video
        }

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    private var mediaTypes: [String] {
        switch mode {
        case .photo:
            return [UTType.image.identifier]
        case .video:
            return [UTType.movie.identifier]
        }
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ComposerCameraPicker

        init(parent: ComposerCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            defer {
                parent.dismiss()
            }

            let mediaType = (info[.mediaType] as? String) ?? ""

            if mediaType == UTType.movie.identifier,
               let mediaURL = info[.mediaURL] as? URL {
                parent.onCapture(
                    .success(
                        .video(
                            mediaURL,
                            fileExtension: mediaURL.pathExtension.isEmpty ? nil : mediaURL.pathExtension,
                            mimeType: UTType(filenameExtension: mediaURL.pathExtension)?.preferredMIMEType ?? "video/quicktime"
                        )
                    )
                )
                return
            }

            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1) {
                parent.onCapture(.success(.photo(data)))
                return
            }

            parent.onCapture(.failure(ComposerCameraError.captureUnavailable))
        }
    }
}
#else
private struct ComposerCameraPicker: View {
    let mode: ComposerCameraCaptureMode
    let onCapture: (Result<ComposerCameraCaptureResult, Error>) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                Text("Camera capture is unavailable on Apple TV.")
                    .font(.headline)
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
        }
    }
}
#endif

private enum ComposerCameraError: LocalizedError {
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            return "Could not capture photo or video."
        }
    }
}

private struct ComposerRecordingEqualizerView: View {
    let samples: [CGFloat]
    let tint: Color
    let dimTint: Color
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    var minBarHeight: CGFloat = 6
    var maxBarHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                Capsule(style: .continuous)
                    .fill(index.isMultiple(of: 3) ? tint : dimTint)
                    .frame(width: barWidth, height: max(minBarHeight, min(maxBarHeight, sample * maxBarHeight)))
            }
        }
        .frame(height: 24, alignment: .center)
    }
}

private enum ComposerGalleryImportError: LocalizedError {
    case videoUnavailable

    var errorDescription: String? {
        switch self {
        case .videoUnavailable:
            return "Could not load the selected video."
        }
    }
}

private struct GalleryVideoImport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let sourceURL = received.file
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let extensionCandidate = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let targetURL = directory.appendingPathComponent("gallery-video-\(UUID().uuidString).\(extensionCandidate)")
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try? FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            return Self(url: targetURL)
        }
    }
}

private struct ComposerLibraryVideoInfo {
    let url: URL
    let fileExtension: String
    let mimeType: String
}

private extension PHAsset {
    var composerDurationLabel: String {
        guard mediaType == .video else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}

@MainActor
private final class ComposerLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    let objectWillChange = ObservableObjectPublisher()
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestCurrentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw ComposerLocationError.servicesDisabled
        }

        let status = manager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            try await requestAuthorization()
        case .restricted, .denied:
            throw ComposerLocationError.permissionDenied
        @unknown default:
            throw ComposerLocationError.permissionDenied
        }

        if let cachedLocation = manager.location,
           abs(cachedLocation.timestamp.timeIntervalSinceNow) < 20 {
            return cachedLocation
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let authorizationContinuation else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            self.authorizationContinuation = nil
            authorizationContinuation.resume()
        case .restricted, .denied:
            self.authorizationContinuation = nil
            authorizationContinuation.resume(throwing: ComposerLocationError.permissionDenied)
        case .notDetermined:
            break
        @unknown default:
            self.authorizationContinuation = nil
            authorizationContinuation.resume(throwing: ComposerLocationError.permissionDenied)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let locationContinuation else { return }
        self.locationContinuation = nil

        if let location = locations.last {
            locationContinuation.resume(returning: location)
        } else {
            locationContinuation.resume(throwing: ComposerLocationError.locationUnavailable)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard let locationContinuation else { return }
        self.locationContinuation = nil
        locationContinuation.resume(throwing: error)
    }
}

private enum ComposerLocationError: LocalizedError {
    case servicesDisabled
    case permissionDenied
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            return "Location services are turned off."
        case .permissionDenied:
            return "Location access is not allowed for Prime Messaging."
        case .locationUnavailable:
            return "Could not get your current location."
        }
    }
}

private struct ComposerLocationSelection: Identifiable, Equatable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var accuracyMeters: CLLocationAccuracy

    init(location: CLLocation) {
        coordinate = location.coordinate
        accuracyMeters = max(location.horizontalAccuracy, 0)
    }

    init(coordinate: CLLocationCoordinate2D, accuracyMeters: CLLocationAccuracy) {
        self.coordinate = coordinate
        self.accuracyMeters = accuracyMeters
    }

    static func == (lhs: ComposerLocationSelection, rhs: ComposerLocationSelection) -> Bool {
        abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 0.000_001 &&
        abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 0.000_001 &&
        abs(lhs.accuracyMeters - rhs.accuracyMeters) < 0.5
    }
}

private struct ComposerLocationPlace: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    init(title: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        self.id = "\(title)|\(subtitle)|\(coordinate.latitude)|\(coordinate.longitude)"
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
    }

    init(mapItem: MKMapItem) {
        let placemark = mapItem.placemark
        let subtitleComponents = [
            placemark.locality,
            placemark.subAdministrativeArea,
            placemark.country,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        self.init(
            title: mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Pinned location",
            subtitle: subtitleComponents.joined(separator: ", "),
            coordinate: placemark.coordinate
        )
    }
}

private struct ComposerLegacyLocationPickerSheet: View {
    let initialSelection: ComposerLocationSelection
    let onSend: (ComposerLocationSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion

    init(
        initialSelection: ComposerLocationSelection,
        onSend: @escaping (ComposerLocationSelection) -> Void
    ) {
        self.initialSelection = initialSelection
        self.onSend = onSend
        _region = State(
            initialValue: MKCoordinateRegion(
                center: initialSelection.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: PrimeTheme.Spacing.large) {
                Map(coordinateRegion: $region)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .frame(height: 280)

                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                    Text("Pinned location")
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(coordinateText)
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    Text("Accuracy ±\(Int(max(initialSelection.accuracyMeters, 0))) m")
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Send Location") {
                    onSend(
                        ComposerLocationSelection(
                            coordinate: region.center,
                            accuracyMeters: initialSelection.accuracyMeters
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimeTheme.Colors.accent)

                Spacer(minLength: 0)
            }
            .padding(PrimeTheme.Spacing.large)
            .navigationTitle("Send Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var coordinateText: String {
        String(format: "%.5f, %.5f", region.center.latitude, region.center.longitude)
    }
}

@available(iOS 17.0, *)
private struct ComposerLocationPickerSheet: View {
    let initialSelection: ComposerLocationSelection
    @ObservedObject var locationProvider: ComposerLocationProvider
    let onSend: (ComposerLocationSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var accuracyMeters: CLLocationAccuracy
    @State private var searchText = ""
    @State private var isRefreshingCurrentLocation = false
    @State private var isSearching = false
    @State private var isResolvingAddress = false
    @State private var addressTitle = "Pinned location"
    @State private var addressSubtitle = "Move the map to choose a different spot."
    @State private var searchResults: [ComposerLocationPlace] = []
    @State private var nearbyPlaces: [ComposerLocationPlace] = []

    init(
        initialSelection: ComposerLocationSelection,
        locationProvider: ComposerLocationProvider,
        onSend: @escaping (ComposerLocationSelection) -> Void
    ) {
        self.initialSelection = initialSelection
        self.locationProvider = locationProvider
        self.onSend = onSend
        _selectedCoordinate = State(initialValue: initialSelection.coordinate)
        _accuracyMeters = State(initialValue: initialSelection.accuracyMeters)
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: initialSelection.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapSection
                    .ignoresSafeArea(edges: .bottom)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.28),
                        Color.clear,
                        Color.black.opacity(0.18)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    floatingLocationHeader
                    Spacer(minLength: 0)
                    bottomLocationPanel
                }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await refreshResolvedAddressAndNearby()
        }
    }

    private var floatingLocationHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.white)

                Spacer(minLength: 0)

                Text("Send Location")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Button("Send") {
                    onSend(
                        ComposerLocationSelection(
                            coordinate: selectedCoordinate,
                            accuracyMeters: accuracyMeters
                        )
                    )
                    dismiss()
                }
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.accentSoft)
            }

            searchBar
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.top, 10)
    }

    private var bottomLocationPanel: some View {
        VStack(spacing: 12) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.24))
                .frame(width: 48, height: 5)
                .padding(.top, 10)

            summaryCard

            placesSection
                .frame(maxHeight: 258)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))

            TextField("Search or enter an address", text: $searchText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .foregroundStyle(.white)
                .onSubmit {
                    Task {
                        await performSearch()
                    }
                }

            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var mapSection: some View {
        ZStack {
            Map(position: $cameraPosition, interactionModes: .all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onMapCameraChange(frequency: .onEnd) { context in
                    selectedCoordinate = context.region.center
                    Task {
                        await refreshResolvedAddressAndNearby()
                    }
                }

            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        mapActionButton(
                            systemName: isRefreshingCurrentLocation ? "location.circle.fill" : "location.fill",
                            isLoading: isRefreshingCurrentLocation
                        ) {
                            Task {
                                await recenterOnCurrentLocation()
                            }
                        }
                    }
                }
                .padding(.top, 116)
                .padding(.horizontal, PrimeTheme.Spacing.large)

                Spacer()
            }

            VStack {
                Spacer()

                VStack(spacing: 0) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                    Circle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 18, height: 6)
                        .blur(radius: 3)
                        .offset(y: -4)
                }
                .allowsHitTesting(false)

                Spacer()
            }
        }
    }

    private func mapActionButton(systemName: String, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .frame(width: 46, height: 46)
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(PrimeTheme.Colors.accent.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(addressTitle)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if isResolvingAddress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(addressSubtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(3)

                    Text(selectedCoordinateText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Spacer(minLength: 0)
            }

            Button {
                onSend(
                    ComposerLocationSelection(
                        coordinate: selectedCoordinate,
                        accuracyMeters: accuracyMeters
                    )
                )
                dismiss()
            } label: {
                HStack {
                    Text("Send this location")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PrimeTheme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Nearby places" : "Search results")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, PrimeTheme.Spacing.large)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visiblePlaces) { place in
                        Button {
                            focus(on: place)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(PrimeTheme.Colors.accent.opacity(0.12))
                                        .frame(width: 42, height: 42)
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.title)
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    Text(place.subtitle.isEmpty ? "Tap to move the map here." : place.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.68))
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.68))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if visiblePlaces.isEmpty, isSearching == false {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Move the map or search for an address to see places here." : "No places matched that search.")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, PrimeTheme.Spacing.small)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var visiblePlaces: [ComposerLocationPlace] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty ? nearbyPlaces : searchResults
    }

    private var selectedCoordinateText: String {
        "\(selectedCoordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(selectedCoordinate.longitude.formatted(.number.precision(.fractionLength(5))))"
    }

    @MainActor
    private func recenterOnCurrentLocation() async {
        guard isRefreshingCurrentLocation == false else { return }
        isRefreshingCurrentLocation = true
        defer { isRefreshingCurrentLocation = false }

        do {
            let location = try await locationProvider.requestCurrentLocation()
            accuracyMeters = max(location.horizontalAccuracy, 0)
            selectedCoordinate = location.coordinate
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            )
            await refreshResolvedAddressAndNearby()
        } catch {
        }
    }

    @MainActor
    private func focus(on place: ComposerLocationPlace) {
        selectedCoordinate = place.coordinate
        cameraPosition = .region(
            MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        )
        addressTitle = place.title
        addressSubtitle = place.subtitle.isEmpty ? selectedCoordinateText : place.subtitle
    }

    @MainActor
    private func refreshResolvedAddressAndNearby() async {
        await resolveAddress(for: selectedCoordinate)
        await loadNearbyPlaces(around: selectedCoordinate)
    }

    @MainActor
    private func resolveAddress(for coordinate: CLLocationCoordinate2D) async {
        isResolvingAddress = true
        defer { isResolvingAddress = false }

        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if let placemark = placemarks.first {
                let titleCandidate = placemark.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                let subtitleComponents = [
                    placemark.locality,
                    placemark.subAdministrativeArea,
                    placemark.country,
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }

                addressTitle = titleCandidate ?? "Pinned location"
                addressSubtitle = subtitleComponents.isEmpty ? selectedCoordinateText : subtitleComponents.joined(separator: ", ")
            } else {
                addressTitle = "Pinned location"
                addressSubtitle = selectedCoordinateText
            }
        } catch {
            addressTitle = "Pinned location"
            addressSubtitle = selectedCoordinateText
        }
    }

    @MainActor
    private func loadNearbyPlaces(around coordinate: CLLocationCoordinate2D) async {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1_000,
            longitudinalMeters: 1_000
        )
        request.resultTypes = .pointOfInterest

        do {
            let response = try await MKLocalSearch(request: request).start()
            nearbyPlaces = response.mapItems.prefix(6).map(ComposerLocationPlace.init(mapItem:))
        } catch {
            nearbyPlaces = []
        }
    }

    @MainActor
    private func performSearch() async {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        request.region = MKCoordinateRegion(
            center: selectedCoordinate,
            latitudinalMeters: 2_000,
            longitudinalMeters: 2_000
        )
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            searchResults = response.mapItems.prefix(10).map(ComposerLocationPlace.init(mapItem:))
        } catch {
            searchResults = []
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PollComposerSheet: View {
    let onCreate: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("Question") {
                TextField("What should we decide?", text: $question, axis: .vertical)
                    .lineLimit(2 ... 4)
            }

            Section("Options") {
                ForEach(options.indices, id: \.self) { index in
                    TextField("Option \(index + 1)", text: Binding(
                        get: { options[index] },
                        set: { options[index] = $0 }
                    ))
                }

                Button("Add Option") {
                    options.append("")
                }
            }
        }
        .navigationTitle("Create Poll")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Send") {
                    let pollText = StructuredChatMessageContent.makePollText(
                        question: question,
                        options: normalizedOptions
                    )
                    Task {
                        guard isSubmitting == false else { return }
                        isSubmitting = true
                        let didSend = await onCreate(pollText)
                        isSubmitting = false
                        if didSend {
                            dismiss()
                        }
                    }
                }
                .disabled(!canCreate || isSubmitting)
            }
        }
    }

    private var normalizedOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var canCreate: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && normalizedOptions.count >= 2
    }
}

private struct ListComposerSheet: View {
    let onCreate: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var items = ["", ""]
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("Title") {
                TextField("List title", text: $title)
            }

            Section("Items") {
                ForEach(items.indices, id: \.self) { index in
                    TextField("Item \(index + 1)", text: Binding(
                        get: { items[index] },
                        set: { items[index] = $0 }
                    ))
                }

                Button("Add Item") {
                    items.append("")
                }
            }
        }
        .navigationTitle("Create List")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Send") {
                    let listText = StructuredChatMessageContent.makeListText(
                        title: title,
                        items: normalizedItems
                    )
                    Task {
                        guard isSubmitting == false else { return }
                        isSubmitting = true
                        let didSend = await onCreate(listText)
                        isSubmitting = false
                        if didSend {
                            dismiss()
                        }
                    }
                }
                .disabled(!canCreate || isSubmitting)
            }
        }
    }

    private var normalizedItems: [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var canCreate: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && normalizedItems.isEmpty == false
    }
}
