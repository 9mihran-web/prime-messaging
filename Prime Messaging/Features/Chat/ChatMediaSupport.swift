import AVFoundation
import AVKit
import Combine
import CryptoKit
import MapKit
import OSLog
#if canImport(PDFKit) && !os(tvOS)
import PDFKit
#endif
import Photos
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif
#if !os(tvOS)
import Speech
#endif
import SwiftUI
import UIKit

private enum ChatMediaStorage {
    private nonisolated(unsafe) static let fileManager = FileManager.default

    nonisolated static var mediaRootDirectory: URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("PrimeMessagingMedia", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static var stagedMediaDirectory: URL {
        let directory = mediaRootDirectory.appendingPathComponent("Staged", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static var downloadedMediaDirectory: URL {
        let directory = mediaRootDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static var playbackMediaDirectory: URL {
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("PrimeMessagingPlaybackMedia", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum ChatMediaPersistentStore {
    private enum Bucket {
        case attachments
        case voices
        case downloads

        nonisolated var directoryURL: URL {
            switch self {
            case .attachments:
                return ChatMediaStorage.stagedMediaDirectory
            case .voices:
                return ChatMediaStorage.stagedMediaDirectory.appendingPathComponent("Voices", isDirectory: true)
            case .downloads:
                return ChatMediaStorage.downloadedMediaDirectory
            }
        }
    }

    private nonisolated(unsafe) static let fileManager = FileManager.default

    nonisolated static func isUsableLocalMediaURL(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    nonisolated static func persist(_ draft: OutgoingMessageDraft) -> OutgoingMessageDraft {
        var stabilized = draft
        stabilized.attachments = draft.attachments.map(persist)
        stabilized.voiceMessage = draft.voiceMessage.map(persist)
        return stabilized
    }

    nonisolated static func persist(_ message: Message) -> Message {
        var stabilized = message
        stabilized.attachments = message.attachments.map(persist)
        stabilized.voiceMessage = message.voiceMessage.map(persist)
        return stabilized
    }

    nonisolated static func persist(_ attachment: Attachment) -> Attachment {
        var stabilized = attachment
        stabilized.localURL = persistentLocalURL(
            from: attachment.localURL,
            preferredFileName: attachment.fileName,
            bucket: .attachments
        )
        if stabilized.byteSize <= 0,
           let localURL = stabilized.localURL,
           let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            stabilized.byteSize = Int64(fileSize)
        }
        return stabilized
    }

    nonisolated static func persist(_ voiceMessage: VoiceMessage) -> VoiceMessage {
        var stabilized = voiceMessage
        stabilized.localFileURL = persistentLocalURL(
            from: voiceMessage.localFileURL,
            preferredFileName: voiceMessage.localFileURL?.lastPathComponent ?? "voice.m4a",
            bucket: .voices
        )
        if stabilized.byteSize <= 0,
           let localURL = stabilized.localFileURL,
           let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            stabilized.byteSize = Int64(fileSize)
        }
        return stabilized
    }

    nonisolated static func persistDownloadedFile(sourceURL: URL, preferredFileName: String) -> URL? {
        persistentLocalURL(from: sourceURL, preferredFileName: preferredFileName, bucket: .downloads)
    }

    private nonisolated static func persistentLocalURL(from sourceURL: URL?, preferredFileName: String, bucket: Bucket) -> URL? {
        guard isUsableLocalMediaURL(sourceURL) else { return nil }
        guard let sourceURL else { return nil }

        let bucketDirectory = bucket.directoryURL
        try? fileManager.createDirectory(at: bucketDirectory, withIntermediateDirectories: true)

        if sourceURL.path.hasPrefix(bucketDirectory.path) {
            return sourceURL
        }

        let sanitizedName = sanitizeFileName(preferredFileName, fallbackExtension: sourceURL.pathExtension)
        let digest = SHA256.hash(data: Data(sourceURL.standardizedFileURL.absoluteString.utf8))
        let stablePrefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let targetURL = bucketDirectory.appendingPathComponent("\(stablePrefix)-\(sanitizedName)")

        if fileManager.fileExists(atPath: targetURL.path) {
            let existingSize = fileSize(at: targetURL)
            let sourceSize = fileSize(at: sourceURL)
            if existingSize > 0, existingSize == sourceSize {
                return targetURL
            }
            try? fileManager.removeItem(at: targetURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch {
            return sourceURL
        }
    }

    private nonisolated static func sanitizeFileName(_ preferredFileName: String, fallbackExtension: String) -> String {
        let trimmed = preferredFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed.replacingOccurrences(of: "/", with: "-")
        }

        let resolvedExtension = fallbackExtension.isEmpty ? "bin" : fallbackExtension
        return "\(UUID().uuidString).\(resolvedExtension)"
    }

    private nonisolated static func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

private enum MediaPipelineDiagnostics {
    static let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "MediaPipeline")

    static func logResolvedFile(_ label: String, url: URL, size: Int64, duration: Double?, details: String = "") {
        let durationText = duration.map { String(format: "%.3f", $0) } ?? "n/a"
        logger.info("\(label, privacy: .public) file=\(url.lastPathComponent, privacy: .public) size=\(size, privacy: .public) duration=\(durationText, privacy: .public) \(details, privacy: .public)")
    }

    static func logIssue(_ label: String, url: URL?, details: String) {
        logger.error("\(label, privacy: .public) file=\(url?.lastPathComponent ?? "none", privacy: .public) \(details, privacy: .public)")
    }

    static func logByteComparison(
        _ label: String,
        url: URL?,
        declaredBytes: Int64,
        actualBytes: Int64,
        sourceBytes: Int64? = nil,
        playbackBytes: Int64? = nil,
        details: String = ""
    ) {
        let sourceText = sourceBytes.map(String.init) ?? "n/a"
        let playbackText = playbackBytes.map(String.init) ?? "n/a"
        logger.info(
            "\(label, privacy: .public) file=\(url?.lastPathComponent ?? "none", privacy: .public) declared=\(declaredBytes, privacy: .public) actual=\(actualBytes, privacy: .public) source=\(sourceText, privacy: .public) playback=\(playbackText, privacy: .public) \(details, privacy: .public)"
        )
    }
}

@MainActor
private final class RemoteAttachmentDownloadController: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(receivedBytes: Int64, totalBytes: Int64)
        case ready
        case failed
    }

    @Published fileprivate private(set) var state: State = .idle
    fileprivate private(set) var resolvedLocalURL: URL?

    fileprivate func prepare(for attachment: Attachment) async {
        if ChatMediaPersistentStore.isUsableLocalMediaURL(attachment.localURL),
           let localURL = attachment.localURL,
           MediaFileInspector.isValidAttachmentFile(localURL, attachment: attachment) {
            resolvedLocalURL = localURL
            state = .ready
            return
        }

        guard let remoteURL = attachment.remoteURL else {
            resolvedLocalURL = nil
            state = .failed
            return
        }

        if let cachedURL = await RemoteAssetCacheStore.shared.cachedFileURL(for: remoteURL) {
            if MediaFileInspector.isValidAttachmentFile(cachedURL, attachment: attachment) {
                resolvedLocalURL = ChatMediaPersistentStore.persistDownloadedFile(
                    sourceURL: cachedURL,
                    preferredFileName: attachment.fileName
                ) ?? cachedURL
                state = .ready
                return
            }

            await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
        }

        resolvedLocalURL = nil
        state = .idle
    }

    fileprivate func download(for attachment: Attachment) async -> Bool {
        guard let remoteURL = attachment.remoteURL else {
            state = .failed
            return false
        }

        state = .downloading(receivedBytes: 0, totalBytes: max(attachment.byteSize, 0))
        MediaPipelineDiagnostics.logIssue("attachment.download.begin", url: remoteURL, details: "manual download started declaredBytes=\(attachment.byteSize)")

        do {
            let temporaryURL = try await ManualRemoteMediaDownloader.download(
                remoteURL: remoteURL,
                allowsCellularAccess: NetworkUsagePolicy.allowsCellularAccess(for: .mediaDownloads)
            ) { [weak self] receivedBytes, totalBytes in
                guard let self else { return }
                self.state = .downloading(receivedBytes: receivedBytes, totalBytes: totalBytes > 0 ? totalBytes : max(attachment.byteSize, 0))
            }

            guard let cachedURL = await RemoteAssetCacheStore.shared.importDownloadedFile(
                from: temporaryURL,
                for: remoteURL,
                expectedLength: attachment.byteSize > 0 ? attachment.byteSize : nil
            ) else {
                MediaPipelineDiagnostics.logIssue("attachment.download.import_failed", url: remoteURL, details: "cache import returned nil")
                state = .failed
                return false
            }

            guard MediaFileInspector.isValidAttachmentFile(cachedURL, attachment: attachment) else {
                MediaPipelineDiagnostics.logIssue("attachment.download.manual_invalid", url: cachedURL, details: "downloaded attachment failed validation")
                await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
                state = .failed
                return false
            }

            let persistedURL = ChatMediaPersistentStore.persistDownloadedFile(
                sourceURL: cachedURL,
                preferredFileName: attachment.fileName
            ) ?? cachedURL
            resolvedLocalURL = persistedURL
            state = .ready

            let summary = MediaFileInspector.summary(for: persistedURL)
            MediaPipelineDiagnostics.logResolvedFile(
                "attachment.download.manual_ok",
                url: persistedURL,
                size: summary.fileSize,
                duration: summary.durationSeconds
            )
            return true
        } catch {
            MediaPipelineDiagnostics.logIssue("attachment.download.failed", url: remoteURL, details: error.localizedDescription)
            state = .failed
            return false
        }
    }

    fileprivate func resolvedAttachment(for attachment: Attachment) -> Attachment {
        guard let resolvedLocalURL else { return attachment }
        var copy = attachment
        copy.localURL = resolvedLocalURL
        if copy.byteSize <= 0,
           let fileSize = (try? resolvedLocalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            copy.byteSize = Int64(fileSize)
        }
        return copy
    }

    fileprivate var isReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    fileprivate var isDownloading: Bool {
        if case .downloading = state {
            return true
        }
        return false
    }

    fileprivate var progressFraction: Double? {
        guard case let .downloading(receivedBytes, totalBytes) = state,
              totalBytes > 0 else {
            return nil
        }

        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    fileprivate var progressLabel: String {
        switch state {
        case .idle:
            return "Tap to download"
        case let .downloading(receivedBytes, totalBytes):
            let resolvedTotal = totalBytes > 0 ? totalBytes : resolvedByteCount
            if resolvedTotal > 0 {
                return "Downloading \(formattedByteCount(receivedBytes)) / \(formattedByteCount(resolvedTotal))"
            }
            return "Downloading…"
        case .ready:
            return "Tap to play"
        case .failed:
            return "Retry download"
        }
    }

    fileprivate var downloadIconName: String {
        switch state {
        case .downloading:
            return "arrow.down.circle.fill"
        case .failed:
            return "arrow.clockwise.circle"
        case .ready:
            return "play.fill"
        case .idle:
            return "arrow.down.circle"
        }
    }

    private var resolvedByteCount: Int64 {
        if let resolvedLocalURL,
           let fileSize = (try? resolvedLocalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            return Int64(fileSize)
        }
        return 0
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "media" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum ManualRemoteMediaDownloader {
    static func download(
        remoteURL: URL,
        allowsCellularAccess: Bool,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120

        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.allowsCellularAccess = allowsCellularAccess

        var observation: NSKeyValueObservation?

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request) { temporaryURL, response, error in
                observation?.invalidate()
                observation = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL,
                      let httpResponse = response as? HTTPURLResponse,
                      200 ..< 300 ~= httpResponse.statusCode else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                continuation.resume(returning: temporaryURL)
            }

            observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let receivedBytes = max(progress.completedUnitCount, 0)
                let totalBytes = max(progress.totalUnitCount, 0)
                Task { @MainActor in
                    onProgress(Int64(receivedBytes), Int64(totalBytes))
                }
            }

            task.resume()
        }
    }
}

private enum MediaFileInspector {
    struct Summary: Equatable {
        let fileSize: Int64
        let durationSeconds: Double?
        let hasVideoTrack: Bool
        let hasAudioTrack: Bool
        let isPlayable: Bool
    }

    static func summary(for url: URL) -> Summary {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : nil
        let hasVideoTrack = asset.tracks(withMediaType: .video).isEmpty == false
        let hasAudioTrack = asset.tracks(withMediaType: .audio).isEmpty == false
        let isPlayable = asset.isPlayable || hasVideoTrack || hasAudioTrack
        return Summary(
            fileSize: fileSize,
            durationSeconds: normalizedDuration,
            hasVideoTrack: hasVideoTrack,
            hasAudioTrack: hasAudioTrack,
            isPlayable: isPlayable
        )
    }

    static func hasDeclaredByteShortfall(actualBytes: Int64, declaredBytes: Int64) -> Bool {
        declaredBytes > 0 && actualBytes < declaredBytes
    }

    static func isValidAttachmentFile(_ url: URL, attachment: Attachment) -> Bool {
        let summary = summary(for: url)
        guard summary.fileSize > 0 else { return false }
        if hasDeclaredByteShortfall(actualBytes: summary.fileSize, declaredBytes: attachment.byteSize) {
            MediaPipelineDiagnostics.logIssue(
                "attachment.validation.byte_shortfall",
                url: url,
                details: "declared=\(attachment.byteSize) actual=\(summary.fileSize) continuing with track/duration validation"
            )
        }

        switch attachment.type {
        case .video:
            return summary.hasVideoTrack && (summary.durationSeconds ?? 0) > 0.2
        case .audio:
            return summary.hasAudioTrack && (summary.durationSeconds ?? 0) > 0.2
        case .photo, .document, .contact, .location:
            return true
        }
    }

    static func isValidVoiceFile(
        _ url: URL,
        voiceMessage: VoiceMessage,
        enforceDeclaredByteSize: Bool = false
    ) -> Bool {
        let summary = summary(for: url)
        guard summary.fileSize > 0 else { return false }
        if enforceDeclaredByteSize,
           hasDeclaredByteShortfall(actualBytes: summary.fileSize, declaredBytes: voiceMessage.byteSize) {
            return false
        }
        guard summary.hasAudioTrack || summary.isPlayable else { return false }
        let duration = summary.durationSeconds ?? 0
        if duration <= 0.2 {
            return false
        }
        return true
    }
}

private enum VoiceTranscriptStatus: String, Codable {
    case idle
    case transcribing
    case completed
    case failed
    case unavailable
}

private struct VoiceTranscriptRecord: Codable, Hashable {
    var text: String?
    var status: VoiceTranscriptStatus
    var errorMessage: String?
    var updatedAt: Date
}

private enum VoiceTranscriptionKey {
    static func make(for voiceMessage: VoiceMessage) -> String {
        let base: String
        if let remoteURL = voiceMessage.remoteFileURL?.absoluteString, remoteURL.isEmpty == false {
            base = "remote:\(remoteURL)"
        } else if let localURL = voiceMessage.localFileURL?.lastPathComponent, localURL.isEmpty == false {
            base = "local:\(localURL)"
        } else {
            let waveformSummary = voiceMessage.waveformSamples
                .prefix(12)
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            base = "inline:\(voiceMessage.durationSeconds):\(waveformSummary)"
        }

        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum AttachmentPlaybackKey {
    static func make(for attachment: Attachment) -> String {
        if let remoteURL = attachment.remoteURL?.absoluteString, remoteURL.isEmpty == false {
            return "remote:\(remoteURL)"
        }
        if let localURL = attachment.localURL?.standardizedFileURL.path, localURL.isEmpty == false {
            return "local:\(localURL)"
        }
        return "attachment:\(attachment.id.uuidString):\(attachment.fileName)"
    }
}

private enum VoicePlaybackKey {
    static func make(for voiceMessage: VoiceMessage) -> String {
        if let remoteURL = voiceMessage.remoteFileURL?.absoluteString, remoteURL.isEmpty == false {
            return "remote:\(remoteURL)"
        }
        if let localURL = voiceMessage.localFileURL?.standardizedFileURL.path, localURL.isEmpty == false {
            return "local:\(localURL)"
        }
        return "voice:\(voiceMessage.durationSeconds):\(voiceMessage.waveformSamples.count)"
    }
}

@MainActor
final class VideoPlaybackControllerRegistry {
    static let shared = VideoPlaybackControllerRegistry()

    private var controllers: [String: VideoAttachmentPlaybackController] = [:]

    fileprivate func controller(for attachment: Attachment) -> VideoAttachmentPlaybackController {
        let key = AttachmentPlaybackKey.make(for: attachment)
        if let controller = controllers[key] {
            return controller
        }
        let controller = VideoAttachmentPlaybackController()
        controllers[key] = controller
        return controller
    }

    func stopAll() {
        for controller in controllers.values {
            controller.stop()
        }
    }
}

@MainActor
final class VoicePlaybackControllerRegistry {
    static let shared = VoicePlaybackControllerRegistry()

    private var controllers: [String: VoiceMessagePlaybackController] = [:]

    fileprivate func controller(for voiceMessage: VoiceMessage) -> VoiceMessagePlaybackController {
        let key = VoicePlaybackKey.make(for: voiceMessage)
        if let controller = controllers[key] {
            return controller
        }
        let controller = VoiceMessagePlaybackController()
        controllers[key] = controller
        return controller
    }

    func stopAll() {
        for controller in controllers.values {
            controller.stop()
        }
    }
}

@MainActor
final class ChatAttachmentPresentationStore: ObservableObject {
    struct PresentationContext: Equatable {
        let senderDisplayName: String
        let sentAt: Date?
    }

    @Published var presentedPhotoAttachment: Attachment?
    @Published var presentedVideoAttachment: Attachment?
    @Published var presentedDocumentAttachment: Attachment?
    @Published var presentedContext: PresentationContext?
    @Published var transitioningAttachment: Attachment?
    @Published var transitionSourceFrame: CGRect = .zero
    @Published var dismissingAttachment: Attachment?
    @Published var dismissTargetFrame: CGRect = .zero

    private var transitionTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var lastPresentedSourceFrame: CGRect = .zero

    func present(
        _ attachment: Attachment,
        sourceFrame: CGRect? = nil,
        context: PresentationContext? = nil
    ) {
        dismissAll()
        presentedContext = context
        if (attachment.type == .photo || attachment.type == .video),
           let sourceFrame,
           sourceFrame.equalTo(.zero) == false {
            lastPresentedSourceFrame = sourceFrame
            transitionSourceFrame = sourceFrame
            transitioningAttachment = attachment
            transitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(190))
                guard let self, self.transitioningAttachment?.id == attachment.id else { return }
                self.transitioningAttachment = nil
                self.presentImmediately(attachment)
            }
            return
        }

        presentImmediately(attachment)
    }

    func beginDismissalTransition(for attachment: Attachment) {
        guard attachment.type == .photo || attachment.type == .video else { return }
        dismissalTask?.cancel()
        dismissTargetFrame = lastPresentedSourceFrame
        dismissingAttachment = attachment
    }

    func finishDismissalTransition() {
        dismissalTask?.cancel()
        dismissalTask = nil
        dismissingAttachment = nil
        dismissTargetFrame = .zero
        if presentedPhotoAttachment == nil, presentedVideoAttachment == nil, presentedDocumentAttachment == nil {
            presentedContext = nil
        }
    }

    private func presentImmediately(_ attachment: Attachment) {
        switch attachment.type {
        case .photo:
            presentedPhotoAttachment = attachment
        case .video:
            presentedVideoAttachment = attachment
        case .location:
            break
        case .document, .audio, .contact:
            presentedDocumentAttachment = attachment
        }
    }

    func dismissAll() {
        transitionTask?.cancel()
        transitionTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        transitioningAttachment = nil
        transitionSourceFrame = .zero
        dismissingAttachment = nil
        dismissTargetFrame = .zero
        presentedPhotoAttachment = nil
        presentedVideoAttachment = nil
        presentedDocumentAttachment = nil
        presentedContext = nil
    }
}

@MainActor
final class MediaPlaybackActivityStore: ObservableObject {
    static let shared = MediaPlaybackActivityStore()

    @Published private(set) var isPlaybackActive = false
    private var activeKeys = Set<String>()
    private var lastPlaybackEndedAt: Date = .distantPast

    func begin(_ key: String) {
        activeKeys.insert(key)
        isPlaybackActive = activeKeys.isEmpty == false
    }

    func end(_ key: String) {
        activeKeys.remove(key)
        isPlaybackActive = activeKeys.isEmpty == false
        if isPlaybackActive == false {
            lastPlaybackEndedAt = .now
        }
    }

    func shouldDeferChatRefresh(gracePeriod: TimeInterval = 2.0) -> Bool {
        if isPlaybackActive {
            return true
        }
        return Date().timeIntervalSince(lastPlaybackEndedAt) < gracePeriod
    }
}

private actor VoiceTranscriptionStore {
    static let shared = VoiceTranscriptionStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootURL: URL

    init(directoryName: String = "PrimeMessagingVoiceTranscripts") {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = baseDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func loadRecord(for key: String) async -> VoiceTranscriptRecord? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await MainActor.run {
            try? decoder.decode(VoiceTranscriptRecord.self, from: data)
        }
    }

    func saveRecord(_ record: VoiceTranscriptRecord?, for key: String) async {
        let url = fileURL(for: key)
        guard let record else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = await MainActor.run(body: { try? encoder.encode(record) }) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        rootURL.appendingPathComponent("\(key).json")
    }
}

private enum VoiceTranscriptionError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case transcriptionUnavailable
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission is disabled."
        case .recognizerUnavailable:
            return "Voice transcription is not available for this language."
        case .transcriptionUnavailable:
            return "Prime could not transcribe this voice message."
        case .assetUnavailable:
            return "The voice file is unavailable right now."
        }
    }
}

@MainActor
private final class VoiceTranscriptionController: ObservableObject {
    @Published fileprivate private(set) var record: VoiceTranscriptRecord?
    @Published fileprivate private(set) var isLoading = false

    private var loadedKey: String?

    func loadIfNeeded(for voiceMessage: VoiceMessage) async {
        let key = VoiceTranscriptionKey.make(for: voiceMessage)
        guard loadedKey != key else { return }
        loadedKey = key
        record = await VoiceTranscriptionStore.shared.loadRecord(for: key)
    }

    func transcribe(_ voiceMessage: VoiceMessage) async {
        let key = VoiceTranscriptionKey.make(for: voiceMessage)
        loadedKey = key
        isLoading = true

        let loadingRecord = VoiceTranscriptRecord(
            text: record?.text,
            status: .transcribing,
            errorMessage: nil,
            updatedAt: .now
        )
        record = loadingRecord
        await VoiceTranscriptionStore.shared.saveRecord(loadingRecord, for: key)

        defer { isLoading = false }

        #if os(tvOS)
        let unavailableRecord = VoiceTranscriptRecord(
            text: record?.text,
            status: .unavailable,
            errorMessage: "Voice transcription is unavailable on Apple TV.",
            updatedAt: .now
        )
        record = unavailableRecord
        await VoiceTranscriptionStore.shared.saveRecord(unavailableRecord, for: key)
        return
        #else
        do {
            let authorizationStatus = await requestAuthorization()
            guard authorizationStatus == .authorized else {
                throw VoiceTranscriptionError.permissionDenied
            }

            guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer() else {
                throw VoiceTranscriptionError.recognizerUnavailable
            }
            guard recognizer.isAvailable else {
                throw VoiceTranscriptionError.recognizerUnavailable
            }

            let fileURL = try await ChatMediaFileResolver.resolvedFileURL(for: voiceMessage)
            let transcript = try await recognize(url: fileURL, recognizer: recognizer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard transcript.isEmpty == false else {
                throw VoiceTranscriptionError.transcriptionUnavailable
            }

            let completedRecord = VoiceTranscriptRecord(
                text: transcript,
                status: .completed,
                errorMessage: nil,
                updatedAt: .now
            )
            record = completedRecord
            await VoiceTranscriptionStore.shared.saveRecord(completedRecord, for: key)
        } catch {
            let failedRecord = VoiceTranscriptRecord(
                text: record?.text,
                status: .failed,
                errorMessage: error.localizedDescription.isEmpty ? VoiceTranscriptionError.transcriptionUnavailable.localizedDescription : error.localizedDescription,
                updatedAt: .now
            )
            record = failedRecord
            await VoiceTranscriptionStore.shared.saveRecord(failedRecord, for: key)
        }
        #endif
    }

    #if !os(tvOS)
    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            var didResume = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if didResume { return }

                if let error {
                    didResume = true
                    task?.cancel()
                    continuation.resume(throwing: error)
                    return
                }

                if let result, result.isFinal {
                    didResume = true
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
    #endif
}

enum SharedChatContentKind: String, CaseIterable {
    case media
    case files
    case voices
}

private struct SharedAttachmentEntry: Identifiable {
    let id: String
    let message: Message
    let attachment: Attachment
}

private struct SharedVoiceEntry: Identifiable {
    let id: UUID
    let message: Message
    let voiceMessage: VoiceMessage
}

struct SharedChatContentSectionView: View {
    let chat: Chat
    let kind: SharedChatContentKind

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @StateObject private var attachmentPresentation = ChatAttachmentPresentationStore()
    @State private var messages: [Message] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if visibleContentCount == 0 {
                Text(emptyStateText)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else {
                switch kind {
                case .media:
                    mediaGrid
                case .files:
                    filesList
                case .voices:
                    voicesList
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing…")
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
        .fullScreenCover(item: $attachmentPresentation.presentedPhotoAttachment) { attachment in
            PhotoAttachmentViewer(
                attachment: attachment,
                context: attachmentPresentation.presentedContext
            )
        }
        .fullScreenCover(item: $attachmentPresentation.presentedVideoAttachment) { attachment in
            VideoAttachmentViewer(
                attachment: attachment,
                context: attachmentPresentation.presentedContext
            )
        }
        .sheet(item: $attachmentPresentation.presentedDocumentAttachment) { attachment in
            DocumentAttachmentViewer(attachment: attachment)
        }
        .environmentObject(attachmentPresentation)
        .onChange(of: attachmentPresentation.presentedVideoAttachment) { newValue in
            if newValue == nil {
                VideoPlaybackControllerRegistry.shared.stopAll()
            }
        }
        .task(id: taskKey) {
            await hydrate()
        }
    }

    private var taskKey: String {
        "\(chat.id.uuidString)-\(chat.mode.rawValue)-\(kind.rawValue)"
    }

    private var mediaEntries: [SharedAttachmentEntry] {
        messages.flatMap { message in
            message.attachments.compactMap { attachment in
                guard attachment.type == .photo || attachment.type == .video else { return nil }
                return SharedAttachmentEntry(
                    id: "\(message.id.uuidString)-\(attachment.id.uuidString)",
                    message: message,
                    attachment: attachment
                )
            }
        }
    }

    private var fileEntries: [SharedAttachmentEntry] {
        messages.flatMap { message in
            message.attachments.compactMap { attachment in
                guard attachment.type != .photo, attachment.type != .video else { return nil }
                return SharedAttachmentEntry(
                    id: "\(message.id.uuidString)-\(attachment.id.uuidString)",
                    message: message,
                    attachment: attachment
                )
            }
        }
    }

    private var voiceEntries: [SharedVoiceEntry] {
        messages.compactMap { message in
            guard let voiceMessage = message.voiceMessage else { return nil }
            return SharedVoiceEntry(id: message.id, message: message, voiceMessage: voiceMessage)
        }
    }

    private var visibleContentCount: Int {
        switch kind {
        case .media:
            return mediaEntries.count
        case .files:
            return fileEntries.count
        case .voices:
            return voiceEntries.count
        }
    }

    private var emptyStateText: String {
        switch kind {
        case .media:
            return "No shared media yet."
        case .files:
            return "No shared files yet."
        case .voices:
            return "No shared voice messages yet."
        }
    }

    private var mediaGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(mediaEntries) { entry in
                AttachmentView(
                    attachment: entry.attachment,
                    presentationContext: .init(
                        senderDisplayName: senderDisplayName(for: entry.message),
                        sentAt: entry.message.createdAt
                    ),
                    isInteractionEnabled: true
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var filesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(fileEntries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 12) {
                    AttachmentTypeBadge(type: entry.attachment.type)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.attachment.fileName)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(fileSubtitle(for: entry))
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    AttachmentShareInlineButton(attachment: entry.attachment)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if index != fileEntries.count - 1 {
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var voicesList: some View {
        VStack(spacing: 12) {
            ForEach(voiceEntries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(entry.message.createdAt.formatted(.dateTime.day().month().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        Spacer()
                    }

                    VoiceMessagePlayerView(voiceMessage: entry.voiceMessage, style: .bubble(usesLightForeground: false))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    @MainActor
    private func hydrate() async {
        isLoading = true
        defer { isLoading = false }

        let cached = await environment.chatRepository.cachedMessages(chatID: chat.id, mode: chat.mode)
        messages = cached.filter { $0.isDeleted == false }

        guard chat.mode != .offline || NetworkUsagePolicy.hasReachableNetwork() else { return }
        guard let fetched = try? await environment.chatRepository.fetchMessages(chatID: chat.id, mode: chat.mode) else { return }
        messages = fetched.filter { $0.isDeleted == false }
    }

    private func fileSubtitle(for entry: SharedAttachmentEntry) -> String {
        let dateText = entry.message.createdAt.formatted(.dateTime.day().month().hour().minute())
        let sizeText = ByteCountFormatter.string(fromByteCount: entry.attachment.byteSize, countStyle: .file)
        return "\(entry.attachment.mimeType) · \(sizeText) · \(dateText)"
    }

    private func senderDisplayName(for message: Message) -> String {
        if message.senderID == appState.currentUser.id {
            return "You"
        }
        let explicitName = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if explicitName.isEmpty == false {
            return explicitName
        }
        return chat.displayTitle(for: appState.currentUser.id)
    }
}

private struct AttachmentTypeBadge: View {
    let type: AttachmentType

    var body: some View {
        ZStack {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.14))
                .frame(width: 38, height: 38)
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)
        }
    }

    private var symbolName: String {
        switch type {
        case .photo:
            return "photo.fill"
        case .video:
            return "video.fill"
        case .document:
            return "doc.fill"
        case .audio:
            return "waveform"
        case .contact:
            return "person.crop.circle.fill"
        case .location:
            return "mappin.and.ellipse"
        }
    }
}

private struct AttachmentShareInlineButton: View {
    let attachment: Attachment
    @State private var isPresentingShareSheet = false

    var body: some View {
        Button {
            isPresentingShareSheet = true
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingShareSheet) {
            AttachmentShareSheet(attachment: attachment)
        }
    }
}

@MainActor
final class AudioRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    nonisolated(unsafe) private static weak var activeRecorder: AudioRecorderController?
    nonisolated(unsafe) private(set) static var isAnyRecordingActive = false

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var durationTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var isHandlingInterruption = false
    private var shouldResumeAfterInterruption = false
    private var isUserPaused = false
    private var didLogRecordingStall = false
    private var lastHealthResumeAt: Date = .distantPast

    private var audioRecorderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000,
        ]
    }

    deinit {
        recorder?.stop()
        Self.setRecorder(self, active: false)
    }

    @MainActor
    static func hasActiveRecording() -> Bool {
        if let activeRecorder {
            guard let recorder = activeRecorder.recorder else {
                Self.activeRecorder = nil
                isAnyRecordingActive = false
                return false
            }

            let active = activeRecorder.isRecording || activeRecorder.isPaused || recorder.isRecording
            if active {
                isAnyRecordingActive = true
                return true
            }

            Self.activeRecorder = nil
            isAnyRecordingActive = false
            return false
        }
        isAnyRecordingActive = false
        return false
    }

    @MainActor
    static func isCaptureInProgress() -> Bool {
        guard let activeRecorder, let recorder = activeRecorder.recorder else { return false }
        return activeRecorder.isRecording && recorder.isRecording
    }

    nonisolated(unsafe) private static func setRecorder(_ recorder: AudioRecorderController, active: Bool) {
        if active {
            activeRecorder = recorder
            isAnyRecordingActive = true
        } else {
            if activeRecorder === recorder {
                activeRecorder = nil
            }
            isAnyRecordingActive = false
        }
    }

    func startRecording() async throws {
        guard isRecording == false else { return }
        let session = AVAudioSession.sharedInstance()
        try await ensureMicrophonePermission(using: session)
        try configureRecordingAudioSession(using: session)
        installAudioSessionObservers()

        let url = Self.mediaDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let recorder = try makeRecorder(url: url)
        self.recorder = recorder
        Self.setRecorder(self, active: true)
        guard recorder.record() else {
            self.recorder = nil
            Self.setRecorder(self, active: false)
            throw NSError(domain: "PrimeMessagingAudioRecorder", code: -1)
        }

        self.recordingDuration = 0
        isRecording = true
        isPaused = false
        isUserPaused = false
        isHandlingInterruption = false
        shouldResumeAfterInterruption = false
        didLogRecordingStall = false
        lastHealthResumeAt = .distantPast
        startDurationUpdates()
        MediaPipelineDiagnostics.logIssue("voice.recording.start", url: url, details: "started recording")
    }

    func pauseRecording() {
        guard let recorder, isRecording, isPaused == false else { return }
        recorder.pause()
        recordingDuration = max(recorder.currentTime, recordingDuration)
        isPaused = true
        isUserPaused = true
        MediaPipelineDiagnostics.logIssue("voice.recording.pause", url: recorder.url, details: "current=\(recorder.currentTime)")
    }

    func resumeRecording() {
        guard let recorder, isRecording, isPaused else { return }
        let resumed = recorder.record()
        guard resumed else { return }
        recordingDuration = recorder.currentTime
        isPaused = false
        isUserPaused = false
        didLogRecordingStall = false
        lastHealthResumeAt = .distantPast
        MediaPipelineDiagnostics.logIssue("voice.recording.resume", url: recorder.url, details: "current=\(recorder.currentTime)")
    }

    func stopRecording() throws -> VoiceMessage? {
        guard let recorder else {
            Self.setRecorder(self, active: false)
            return nil
        }
        let liveDuration = max(recordingDuration, totalRecordedDuration(for: recorder))
        let recorderURL = recorder.url
        recorder.stop()
        self.recorder = nil
        Self.setRecorder(self, active: false)
        isRecording = false
        isPaused = false
        isUserPaused = false
        isHandlingInterruption = false
        shouldResumeAfterInterruption = false
        removeAudioSessionObservers()
        durationTask?.cancel()
        durationTask = nil
        lastHealthResumeAt = .distantPast
        let recordedURL = finalizedRecordedURL(at: recorderURL, expectedDuration: liveDuration)
        let measuredDuration = actualRecordedDuration(at: recordedURL)
        let finalizedDuration = measuredDuration > 0.2 ? measuredDuration : liveDuration
        let finalizedByteSize = Int64((try? recordedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let durationGap = max(liveDuration - measuredDuration, 0)
        if liveDuration >= 2.0, measuredDuration > 0.2, durationGap > 1.2 {
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.stop.truncated",
                url: recordedURL,
                details: "live=\(liveDuration) measured=\(measuredDuration) gap=\(durationGap) bytes=\(finalizedByteSize)"
            )
            try? FileManager.default.removeItem(at: recordedURL)
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            recordingDuration = 0
            return nil
        }
        guard finalizedByteSize > 0, finalizedDuration > 0.2 else {
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.stop.invalid_file",
                url: recordedURL,
                details: "live=\(liveDuration) finalized=\(finalizedDuration) bytes=\(finalizedByteSize)"
            )
            try? FileManager.default.removeItem(at: recordedURL)
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            recordingDuration = 0
            return nil
        }
        let capturedDuration = max(1, Int(finalizedDuration.rounded(.up)))
        MediaPipelineDiagnostics.logIssue("voice.recording.stop", url: recordedURL, details: "live=\(liveDuration) finalized=\(finalizedDuration)")
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        recordingDuration = 0
        return VoiceMessage(
            durationSeconds: capturedDuration,
            waveformSamples: Self.makeWaveform(duration: capturedDuration),
            byteSize: finalizedByteSize,
            localFileURL: recordedURL,
            remoteFileURL: nil
        )
    }

    func cancelRecording() {
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        Self.setRecorder(self, active: false)
        isRecording = false
        isPaused = false
        isUserPaused = false
        isHandlingInterruption = false
        shouldResumeAfterInterruption = false
        removeAudioSessionObservers()
        recordingDuration = 0
        durationTask?.cancel()
        durationTask = nil
        lastHealthResumeAt = .distantPast
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        MediaPipelineDiagnostics.logIssue("voice.recording.cancel", url: nil, details: "cancelled by user/system")
    }

    private func startDurationUpdates() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            guard let self else { return }
            var lastObservedCurrentTime: TimeInterval = 0
            while !Task.isCancelled {
                if let recorder = self.recorder {
                    recorder.updateMeters()
                    let current = self.totalRecordedDuration(for: recorder)
                    self.recordingDuration = current

                    guard self.isRecording else {
                        lastObservedCurrentTime = current
                        self.didLogRecordingStall = false
                        try? await Task.sleep(for: .milliseconds(200))
                        continue
                    }

                    if recorder.isRecording == false, self.isUserPaused == false, self.didLogRecordingStall == false {
                        self.didLogRecordingStall = true
                        MediaPipelineDiagnostics.logIssue(
                            "voice.recording.health.stalled",
                            url: recorder.url,
                            details: "recorder is not recording while isRecording=true current=\(current) last=\(lastObservedCurrentTime)"
                        )
                    } else if recorder.isRecording, self.didLogRecordingStall {
                        self.didLogRecordingStall = false
                    }

                    let now = Date()
                    let canAttemptHealthResume = now.timeIntervalSince(self.lastHealthResumeAt) >= 1.0
                    if canAttemptHealthResume, recorder.isRecording == false, self.isUserPaused == false, self.isHandlingInterruption == false {
                        var resumed = false
                        do {
                            try self.configureRecordingAudioSession(using: AVAudioSession.sharedInstance())
                            resumed = recorder.record()
                        } catch {
                            MediaPipelineDiagnostics.logIssue("voice.recording.health.resume.error", url: recorder.url, details: error.localizedDescription)
                        }
                        self.lastHealthResumeAt = now
                        if resumed {
                            self.isPaused = false
                            self.isUserPaused = false
                            self.didLogRecordingStall = false
                        }
                        MediaPipelineDiagnostics.logIssue(
                            "voice.recording.health.resume",
                            url: recorder.url,
                            details: "resumed=\(resumed) current=\(current)"
                        )
                    }

                    lastObservedCurrentTime = current
                } else {
                    self.recordingDuration = 0
                    lastObservedCurrentTime = 0
                    self.didLogRecordingStall = false
                    self.lastHealthResumeAt = .distantPast
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func totalRecordedDuration(for recorder: AVAudioRecorder) -> TimeInterval {
        max(recorder.currentTime, 0)
    }

    private func actualRecordedDuration(at url: URL) -> TimeInterval {
        let assetDuration = AVURLAsset(url: url).duration.seconds
        if assetDuration.isFinite, assetDuration > 0 {
            return assetDuration
        }

        if let player = try? AVAudioPlayer(contentsOf: url), player.duration.isFinite, player.duration > 0 {
            return player.duration
        }

        return 0
    }

    private func finalizedRecordedURL(at url: URL, expectedDuration: TimeInterval) -> URL {
        var previousFileSize: Int64 = -1
        var repeatedStableChecks = 0
        let minimumAcceptedDuration = max(expectedDuration - 0.75, 0.8)
        let allowsShortRecordingFastExit = expectedDuration <= 1.2

        for _ in 0 ..< 80 {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let actualDuration = actualRecordedDuration(at: url)
            if fileSize > 0, fileSize == previousFileSize {
                repeatedStableChecks += 1
            } else {
                repeatedStableChecks = 0
            }
            previousFileSize = fileSize

            if fileSize > 0, actualDuration >= minimumAcceptedDuration {
                break
            }

            if fileSize > 0, allowsShortRecordingFastExit, repeatedStableChecks >= 6, actualDuration > 0 {
                break
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        let finalizedDuration = actualRecordedDuration(at: url)
        if finalizedDuration + 0.75 < expectedDuration {
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.finalize_short",
                url: url,
                details: "expectedDuration=\(expectedDuration) finalizedDuration=\(finalizedDuration)"
            )
        }

        let finalSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logIssue(
            "voice.recording.finalized",
            url: url,
            details: "expectedDuration=\(expectedDuration) finalizedDuration=\(finalizedDuration) finalBytes=\(finalSize)"
        )
        return url
    }

    private func ensureMicrophonePermission(using session: AVAudioSession) async throws {
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw NSError(domain: "PrimeMessagingAudioRecorder", code: -2)
        case .undetermined:
            let isGranted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard isGranted else {
                throw NSError(domain: "PrimeMessagingAudioRecorder", code: -2)
            }
        @unknown default:
            throw NSError(domain: "PrimeMessagingAudioRecorder", code: -2)
        }
    }

    private func configureRecordingAudioSession(using session: AVAudioSession) throws {
        #if os(tvOS)
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        #else
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        #endif
        try? session.setPreferredSampleRate(44_100)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        preferExternalRecordingInputIfAvailable(session: session)
    }

    private func preferExternalRecordingInputIfAvailable(session: AVAudioSession) {
        guard let availableInputs = session.availableInputs, availableInputs.isEmpty == false else { return }

        let externalInput = availableInputs.first { input in
            switch input.portType {
            case .builtInMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones:
                return false
            default:
                return true
            }
        }

        guard let externalInput else { return }
        do {
            try session.setPreferredInput(externalInput)
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.input.preferred_external",
                url: recorder?.url,
                details: "portType=\(externalInput.portType.rawValue) portName=\(externalInput.portName)"
            )
        } catch {
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.input.preferred_external_failed",
                url: recorder?.url,
                details: error.localizedDescription
            )
        }
    }

    private static var mediaDirectory: URL {
        ChatMediaStorage.stagedMediaDirectory
    }

    private static func makeWaveform(duration: Int) -> [Float] {
        let count = max(12, min(40, duration * 5))
        return (0 ..< count).map { index in
            let phase = Float(index % 6) / 5
            return 0.2 + (phase * 0.75)
        }
    }

    private func makeRecorder(url: URL) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(url: url, settings: audioRecorderSettings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        return recorder
    }

    private func installAudioSessionObservers() {
        removeAudioSessionObservers()

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.handleAudioSessionInterruption(notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.handleAudioSessionRouteChange(notification)
        }
    }

    private func removeAudioSessionObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard isRecording else { return }
        guard
            let userInfo = notification.userInfo,
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            isHandlingInterruption = true
            shouldResumeAfterInterruption = true
            recorder?.pause()
            isPaused = true
            isUserPaused = false
            MediaPipelineDiagnostics.logIssue("voice.recording.interruption.began", url: recorder?.url, details: "interruption began current=\(recorder?.currentTime ?? 0)")
        case .ended:
            let optionsRaw = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            isHandlingInterruption = false
            guard shouldResumeAfterInterruption, let recorder else {
                MediaPipelineDiagnostics.logIssue("voice.recording.interruption.ended", url: recorder?.url, details: "resume_not_required shouldResume=\(options.contains(.shouldResume))")
                return
            }
            shouldResumeAfterInterruption = false
            var resumed = false
            do {
                try configureRecordingAudioSession(using: AVAudioSession.sharedInstance())
                resumed = recorder.record()
            } catch {
                resumed = false
                MediaPipelineDiagnostics.logIssue("voice.recording.interruption.resume.error", url: recorder.url, details: error.localizedDescription)
            }
            if resumed {
                isPaused = false
                isUserPaused = false
                didLogRecordingStall = false
                lastHealthResumeAt = .distantPast
            }
            MediaPipelineDiagnostics.logIssue("voice.recording.interruption.ended", url: recorder.url, details: "shouldResume=\(options.contains(.shouldResume)) resumed=\(resumed) current=\(recorder.currentTime)")
        @unknown default:
            break
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard isRecording else { return }
        guard
            let userInfo = notification.userInfo,
            let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        MediaPipelineDiagnostics.logIssue("voice.recording.route_change", url: recorder?.url, details: "reason=\(reason.rawValue)")
        guard let recorder, isPaused else { return }

        let resumeReasons: Set<AVAudioSession.RouteChangeReason> = [
            .oldDeviceUnavailable,
            .newDeviceAvailable,
            .categoryChange,
            .override,
            .routeConfigurationChange
        ]
        guard resumeReasons.contains(reason) else { return }

        var resumed = false
        do {
            try configureRecordingAudioSession(using: AVAudioSession.sharedInstance())
            resumed = recorder.record()
        } catch {
            resumed = false
            MediaPipelineDiagnostics.logIssue("voice.recording.route_change.resume.error", url: recorder.url, details: error.localizedDescription)
        }
        if resumed {
            isPaused = false
            isUserPaused = false
        }
        MediaPipelineDiagnostics.logIssue("voice.recording.route_change.resume", url: recorder.url, details: "resumed=\(resumed)")
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, self.isRecording else { return }
            if self.isUserPaused == false, self.isHandlingInterruption == false {
                var resumed = false
                do {
                    try self.configureRecordingAudioSession(using: AVAudioSession.sharedInstance())
                    resumed = recorder.record()
                } catch {
                    MediaPipelineDiagnostics.logIssue("voice.recording.unexpected_finish.resume.error", url: recorder.url, details: error.localizedDescription)
                }
                if resumed {
                    self.isPaused = false
                    self.isUserPaused = false
                    self.didLogRecordingStall = false
                    self.lastHealthResumeAt = Date()
                    MediaPipelineDiagnostics.logIssue(
                        "voice.recording.unexpected_finish.resumed",
                        url: recorder.url,
                        details: "success=\(flag) current=\(recorder.currentTime)"
                    )
                    return
                }
            }
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.unexpected_finish",
                url: recorder.url,
                details: "success=\(flag) current=\(recorder.currentTime)"
            )
            self.recorder = nil
            self.isRecording = false
            self.isPaused = false
            Self.setRecorder(self, active: false)
            self.removeAudioSessionObservers()
            self.durationTask?.cancel()
            self.durationTask = nil
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            MediaPipelineDiagnostics.logIssue(
                "voice.recording.encode_error",
                url: recorder.url,
                details: error?.localizedDescription ?? "unknown"
            )
        }
    }
}

enum ChatMediaDraftBuilder {
    static func makePreparedPhotoAttachment(jpegData: Data) throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory
        let url = directory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try jpegData.write(to: url, options: .atomic)

        return Attachment(
            id: UUID(),
            type: .photo,
            fileName: url.lastPathComponent,
            mimeType: "image/jpeg",
            localURL: url,
            remoteURL: nil,
            byteSize: Int64(jpegData.count)
        )
    }

    static func makePhotoAttachment(
        from data: Data,
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset = NetworkUsagePolicy.preferredUploadQuality(for: .photos)
    ) throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory

        let image = UIImage(data: data)
        let encoded = image.flatMap { makePreparedPhotoData(from: $0, qualityPreset: qualityPreset) } ?? data
        let url = directory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try encoded.write(to: url, options: .atomic)

        return Attachment(
            id: UUID(),
            type: .photo,
            fileName: url.lastPathComponent,
            mimeType: "image/jpeg",
            localURL: url,
            remoteURL: nil,
            byteSize: Int64(encoded.count)
        )
    }

    static func makeVideoAttachment(
        from data: Data,
        fileExtension: String?,
        mimeType: String,
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset = NetworkUsagePolicy.preferredUploadQuality(for: .videos)
    ) throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory
        let resolvedExtension = (fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fileExtension! : "mov")
        let url = directory.appendingPathComponent("video-\(UUID().uuidString).\(resolvedExtension)")
        try data.write(to: url, options: .atomic)

        return Attachment(
            id: UUID(),
            type: .video,
            fileName: url.lastPathComponent,
            mimeType: mimeType,
            localURL: url,
            remoteURL: nil,
            byteSize: Int64(data.count)
        )
    }

    static func makeVideoAttachment(
        copying sourceURL: URL,
        fileExtension: String?,
        mimeType: String,
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset = NetworkUsagePolicy.preferredUploadQuality(for: .videos)
    ) async throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory
        let originalExtension = (fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fileExtension! : sourceURL.pathExtension)
        let originalMimeType = mimeType.isEmpty ? "video/quicktime" : mimeType

        let preparedURL: URL
        let preparedMimeType: String
        if let exported = try await exportVideo(
            from: sourceURL,
            qualityPreset: qualityPreset,
            directory: directory
        ) {
            preparedURL = exported.url
            preparedMimeType = exported.mimeType
        } else {
            let resolvedExtension = originalExtension.isEmpty ? "mov" : originalExtension
            let targetURL = directory.appendingPathComponent("video-\(UUID().uuidString).\(resolvedExtension)")
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try? FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            preparedURL = targetURL
            preparedMimeType = originalMimeType
        }

        let byteSize = (try? preparedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64((try? Data(contentsOf: preparedURL).count) ?? 0)
        return Attachment(
            id: UUID(),
            type: .video,
            fileName: preparedURL.lastPathComponent,
            mimeType: preparedMimeType,
            localURL: preparedURL,
            remoteURL: nil,
            byteSize: byteSize
        )
    }

    static func makeDocumentAttachment(copying sourceURL: URL) throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory
        let targetURL = directory.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)

        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let byteSize = Int64(values?.fileSize ?? 0)
        let mimeType = values?.contentType?.preferredMIMEType ?? "application/octet-stream"

        return Attachment(
            id: UUID(),
            type: .document,
            fileName: sourceURL.lastPathComponent,
            mimeType: mimeType,
            localURL: targetURL,
            remoteURL: nil,
            byteSize: byteSize
        )
    }

    static func makeLocationAttachment(latitude: Double, longitude: Double, accuracyMeters: Double) throws -> Attachment {
        let directory = ChatMediaStorage.stagedMediaDirectory
        let url = directory.appendingPathComponent("location-\(UUID().uuidString).json")
        let payload = LocationAttachmentPayload(latitude: latitude, longitude: longitude, accuracyMeters: accuracyMeters)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)

        return Attachment(
            id: UUID(),
            type: .location,
            fileName: "Location.json",
            mimeType: "application/json",
            localURL: url,
            remoteURL: nil,
            byteSize: Int64(data.count)
        )
    }

    static func readLocationPayload(from attachment: Attachment) -> LocationAttachmentPayload? {
        guard attachment.type == .location else { return nil }
        guard let url = attachment.localURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocationAttachmentPayload.self, from: data)
    }

    static func readLocationPayloadAsync(from attachment: Attachment) async -> LocationAttachmentPayload? {
        guard attachment.type == .location else { return nil }

        if let localURL = attachment.localURL,
           let data = try? Data(contentsOf: localURL),
           let payload = try? JSONDecoder().decode(LocationAttachmentPayload.self, from: data) {
            return payload
        }

        guard let remoteURL = attachment.remoteURL else { return nil }
        guard let data = await RemoteAssetCacheStore.shared.resolvedData(for: remoteURL) else { return nil }
        return try? JSONDecoder().decode(LocationAttachmentPayload.self, from: data)
    }

    private static func makePreparedPhotoData(
        from image: UIImage,
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset
    ) -> Data? {
        let profile = qualityPreset.photoEncodingProfile
        let resized = image.resizedForChat(maxDimension: profile.maxDimension)
        return resized.jpegData(compressionQuality: profile.jpegCompression)
    }

    private static func exportVideo(
        from sourceURL: URL,
        qualityPreset: NetworkUsagePolicy.MediaUploadQualityPreset,
        directory: URL
    ) async throws -> (url: URL, mimeType: String)? {
        let presetName = qualityPreset.videoExportPresetName
        guard let presetName else { return nil }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            return nil
        }

        let outputExtension = exportSession.supportedFileTypes.contains(.mp4) ? "mp4" : "mov"
        let outputFileType: AVFileType = outputExtension == "mp4" ? .mp4 : .mov
        let outputURL = directory.appendingPathComponent("video-\(UUID().uuidString).\(outputExtension)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(
                        returning: (
                            url: outputURL,
                            mimeType: outputFileType == .mp4 ? "video/mp4" : "video/quicktime"
                        )
                    )
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? NSError(domain: "PrimeMessagingVideoExport", code: -1))
                case .cancelled:
                    continuation.resume(returning: nil)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct LocationAttachmentPayload: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
}

private extension LocationAttachmentPayload {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    var coordinatesText: String {
        "\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))"
    }

    var shareText: String {
        "https://maps.apple.com/?ll=\(latitude),\(longitude)"
    }
}

private struct LocationMapAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

private struct LocationMapPreview: View {
    let payload: LocationAttachmentPayload
    var interactionModes: MapInteractionModes = []

    @State private var region: MKCoordinateRegion

    init(payload: LocationAttachmentPayload, interactionModes: MapInteractionModes = []) {
        self.payload = payload
        self.interactionModes = interactionModes
        _region = State(initialValue: payload.region)
    }

    var body: some View {
        Map(
            coordinateRegion: $region,
            interactionModes: interactionModes,
            annotationItems: [LocationMapAnnotation(coordinate: payload.coordinate)]
        ) { item in
            MapMarker(coordinate: item.coordinate, tint: PrimeTheme.Colors.accent)
        }
    }
}

struct MessageAttachmentGallery: View {
    let attachments: [Attachment]
    let alignment: HorizontalAlignment
    let presentationContext: ChatAttachmentPresentationStore.PresentationContext?
    let isInteractionEnabled: Bool

    var body: some View {
        VStack(alignment: alignment, spacing: PrimeTheme.Spacing.small) {
            ForEach(attachments) { attachment in
                AttachmentView(
                    attachment: attachment,
                    presentationContext: presentationContext,
                    isInteractionEnabled: isInteractionEnabled
                )
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

private struct AttachmentView: View {
    let attachment: Attachment
    let presentationContext: ChatAttachmentPresentationStore.PresentationContext?
    let isInteractionEnabled: Bool
    @EnvironmentObject private var attachmentPresentation: ChatAttachmentPresentationStore
    @State private var sourceFrame: CGRect = .zero

    private enum CardLayout {
        static let width: CGFloat = 244
        static let mediaSide: CGFloat = 244
    }

    var body: some View {
        SwiftUI.Group {
            switch attachment.type {
            case .photo:
                imageContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isInteractionEnabled else { return }
                        attachmentPresentation.present(
                            attachment,
                            sourceFrame: sourceFrame,
                            context: presentationContext
                        )
                    }
            case .video:
                VideoAttachmentCard(
                    attachment: attachment,
                    presentationContext: presentationContext,
                    isInteractionEnabled: isInteractionEnabled
                )
            case .location:
                LocationAttachmentCard(attachment: attachment)
            default:
                DocumentAttachmentCard(attachment: attachment)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isInteractionEnabled else { return }
                        attachmentPresentation.present(
                            attachment,
                            sourceFrame: sourceFrame,
                            context: presentationContext
                        )
                    }
            }
        }
        .allowsHitTesting(isInteractionEnabled)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        sourceFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) { newValue in
                        sourceFrame = newValue
                    }
            }
        )
    }

    @ViewBuilder
    private var imageContent: some View {
        if
            let localURL = attachment.localURL,
            let uiImage = UIImage(contentsOfFile: localURL.path)
        {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: CardLayout.mediaSide, height: CardLayout.mediaSide)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
        } else if let remoteURL = attachment.remoteURL {
            CachedRemoteImage(url: remoteURL, networkAccessKind: .autoDownload(attachment.autoDownloadKind)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                imagePlaceholder
            }
            .frame(width: CardLayout.mediaSide, height: CardLayout.mediaSide)
            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var imagePlaceholder: some View {
        let canAutoDownload = NetworkUsagePolicy.canAutoDownload(attachment.autoDownloadKind)

        RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous)
            .fill(Color.white.opacity(0.16))
            .overlay {
                if canAutoDownload {
                    ProgressView()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Tap to load")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
    }
}

@MainActor
private final class DocumentAttachmentThumbnailLoader: ObservableObject {
    @Published fileprivate private(set) var image: UIImage?
    @Published fileprivate private(set) var isLoading = false
    @Published fileprivate private(set) var didFail = false

    private var loadedAttachmentID: UUID?

    fileprivate func loadThumbnail(for attachment: Attachment) async {
        guard loadedAttachmentID != attachment.id else { return }

        if attachment.localURL == nil,
           attachment.remoteURL != nil,
           NetworkUsagePolicy.canAutoDownload(attachment.autoDownloadKind) == false {
            image = nil
            didFail = false
            isLoading = false
            return
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }

        do {
            let resolvedURL = try await ChatMediaFileResolver.resolvedFileURL(
                for: attachment,
                networkAccessKind: .autoDownload(attachment.autoDownloadKind)
            )

            if isPDFAttachment(attachment, resolvedURL: resolvedURL),
               let pdfThumbnail = makePDFThumbnail(for: resolvedURL) {
                self.image = pdfThumbnail
                self.loadedAttachmentID = attachment.id
                return
            }

            #if canImport(QuickLook) && canImport(QuickLookThumbnailing)
            if QLPreviewController.canPreview(resolvedURL as NSURL) == false {
                image = nil
                didFail = true
                return
            }

            let request = QLThumbnailGenerator.Request(
                fileAt: resolvedURL,
                size: CGSize(width: 900, height: 680),
                scale: UIScreen.main.scale,
                representationTypes: .all
            )
            let image = try await QuickLookThumbnailResolver.generate(for: request)
            self.image = image
            self.loadedAttachmentID = attachment.id
            #else
            image = nil
            didFail = true
            #endif
        } catch {
            image = nil
            didFail = true
        }
    }

    private func isPDFAttachment(_ attachment: Attachment, resolvedURL: URL) -> Bool {
        if resolvedURL.pathExtension.lowercased() == "pdf" {
            return true
        }
        if attachment.mimeType.localizedCaseInsensitiveContains("pdf") {
            return true
        }
        return URL(fileURLWithPath: attachment.fileName).pathExtension.lowercased() == "pdf"
    }

    private func makePDFThumbnail(for url: URL) -> UIImage? {
        #if canImport(PDFKit) && !os(tvOS)
        guard let document = PDFDocument(url: url),
              let firstPage = document.page(at: 0) else {
            return nil
        }

        return firstPage.thumbnail(
            of: CGSize(width: 920, height: 1280),
            for: .cropBox
        )
        #else
        return nil
        #endif
    }
}

#if canImport(QuickLookThumbnailing)
private enum QuickLookThumbnailResolver {
    static func generate(for request: QLThumbnailGenerator.Request) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let thumbnail {
                    continuation.resume(returning: thumbnail.uiImage)
                } else {
                    continuation.resume(throwing: AttachmentDocumentPreviewError.thumbnailUnavailable)
                }
            }
        }
    }
}
#endif

private struct DocumentAttachmentCard: View {
    let attachment: Attachment

    @StateObject private var thumbnailLoader = DocumentAttachmentThumbnailLoader()

    private enum CardLayout {
        static let width: CGFloat = 244
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewSurface
                .frame(maxWidth: .infinity, minHeight: 172, maxHeight: 206)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            HStack(alignment: .top, spacing: 10) {
                fileTypeBadge

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.fileName)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(fileSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .frame(width: CardLayout.width, alignment: .leading)
        .task(id: attachment.id) {
            await thumbnailLoader.loadThumbnail(for: attachment)
        }
    }

    private var canAutoLoadPreview: Bool {
        attachment.localURL != nil || NetworkUsagePolicy.canAutoDownload(attachment.autoDownloadKind)
    }

    private var fileSubtitle: String {
        let extensionText = fileExtensionBadge
        if byteSizeText.isEmpty {
            return extensionText
        }
        return "\(extensionText) • \(byteSizeText)"
    }

    private var fileTypeBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .frame(width: 44, height: 44)

            VStack(spacing: 3) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                Text(fileExtensionBadge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = thumbnailLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(Color(red: 0.96, green: 0.96, blue: 0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            .padding(10)
                    )
            } else {
                Color(red: 0.95, green: 0.95, blue: 0.94)

                VStack(spacing: 10) {
                    if thumbnailLoader.isLoading {
                        ProgressView()
                            .tint(PrimeTheme.Colors.accent)
                    } else {
                        Image(systemName: canAutoLoadPreview ? "doc.text.image.fill" : "arrow.down.circle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(PrimeTheme.Colors.accentSoft)
                    }

                    Text(canAutoLoadPreview ? "Preparing first page" : "Tap to preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
    }

    private var byteSizeText: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file)
    }

    private var symbolName: String {
        switch attachment.type {
        case .audio:
            return "waveform"
        case .contact:
            return "person.crop.circle.fill"
        case .document:
            return "doc.fill"
        case .location:
            return "mappin.and.ellipse"
        case .photo:
            return "photo.fill"
        case .video:
            return "video.fill"
        }
    }

    private var fileExtensionBadge: String {
        let extensionCandidate = URL(fileURLWithPath: attachment.fileName).pathExtension
        if extensionCandidate.isEmpty == false {
            return String(extensionCandidate.prefix(4)).uppercased()
        }

        switch attachment.type {
        case .audio:
            return "AUD"
        case .contact:
            return "VCF"
        case .document:
            return "FILE"
        case .location:
            return "MAP"
        case .photo:
            return "IMG"
        case .video:
            return "VID"
        }
    }
}

@MainActor
private final class VideoThumbnailLoader: ObservableObject {
    @Published fileprivate private(set) var image: UIImage?
    @Published fileprivate private(set) var isLoading = false
    @Published fileprivate private(set) var didFail = false

    private var loadedAttachmentID: UUID?

    fileprivate func loadThumbnail(for attachment: Attachment) async {
        guard loadedAttachmentID != attachment.id else { return }

        if attachment.localURL == nil,
           attachment.remoteURL != nil,
           NetworkUsagePolicy.canAutoDownload(.videos) == false {
            image = nil
            didFail = false
            isLoading = false
            return
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }

        do {
            let url = try await ChatMediaFileResolver.resolvedFileURL(
                for: attachment,
                networkAccessKind: .autoDownload(.videos)
            )
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let cgImage = try generator.copyCGImage(
                at: CMTime(seconds: 0.15, preferredTimescale: 600),
                actualTime: nil
            )
            image = UIImage(cgImage: cgImage)
            loadedAttachmentID = attachment.id
        } catch {
            image = nil
            didFail = true
        }
    }
}

private struct VideoAttachmentCard: View {
    let attachment: Attachment
    let presentationContext: ChatAttachmentPresentationStore.PresentationContext?
    let isInteractionEnabled: Bool

    @EnvironmentObject private var attachmentPresentation: ChatAttachmentPresentationStore
    @StateObject private var loader = VideoThumbnailLoader()
    @StateObject private var downloadController = RemoteAttachmentDownloadController()
    @State private var sourceFrame: CGRect = .zero

    private enum CardLayout {
        static let width: CGFloat = 244
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                previewLayer

                LinearGradient(
                    colors: [Color.black.opacity(0.74), Color.black.opacity(0.16), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.34))
                            .frame(width: 64, height: 64)
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            .frame(width: 64, height: 64)
                        if downloadController.isDownloading, let progressFraction = downloadController.progressFraction {
                            ProgressView(value: progressFraction, total: 1)
                                .tint(.white)
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: downloadController.downloadIconName)
                                .font(.system(size: downloadController.isReady ? 23 : 22, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: downloadController.isReady ? 1.5 : 0)
                        }
                    }
                    .padding(.bottom, 18)

                    HStack(alignment: .bottom, spacing: 12) {
                        Text(videoStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.84))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.26), in: Capsule(style: .continuous))

                        Spacer(minLength: 0)

                        Image(systemName: downloadController.isReady ? "arrow.up.left.and.arrow.down.right" : "arrow.down.to.line")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.74))
                            .padding(9)
                            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(12)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: CardLayout.width, alignment: .bottomLeading)
        .frame(minHeight: 160, maxHeight: 206, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task(id: attachment.id) {
            await downloadController.prepare(for: attachment)
            if downloadController.isReady {
                await loader.loadThumbnail(for: downloadController.resolvedAttachment(for: attachment))
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        sourceFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) { newValue in
                        sourceFrame = newValue
                    }
            }
        )
    }

    @ViewBuilder
    private var previewLayer: some View {
        if let image = loader.image, downloadController.isReady {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.14))

                if downloadController.isDownloading {
                    VStack(spacing: 10) {
                        if let progressFraction = downloadController.progressFraction {
                            ProgressView(value: progressFraction, total: 1)
                                .tint(.white)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(downloadController.progressLabel)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 18)
                } else if loader.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading preview…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: loader.didFail ? "video.slash" : downloadController.downloadIconName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(loader.didFail ? "Preview unavailable" : downloadController.progressLabel)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private var videoStatusText: String {
        if downloadController.isDownloading {
            return "Downloading"
        }

        if loader.isLoading, downloadController.isReady {
            return "Loading"
        }

        if downloadController.isReady {
            return loader.didFail ? "Tap to open" : "Tap to play"
        }

        if downloadController.state == .failed {
            return "Retry"
        }

        if attachment.byteSize > 0 {
            return "Download \(ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file))"
        }

        return "Download"
    }

    private func handleTap() {
        guard isInteractionEnabled else { return }
        if downloadController.isReady {
            attachmentPresentation.present(
                downloadController.resolvedAttachment(for: attachment),
                sourceFrame: sourceFrame,
                context: presentationContext
            )
            return
        }

        guard downloadController.isDownloading == false else { return }
        Task {
            let didDownload = await downloadController.download(for: attachment)
            guard didDownload else { return }
            await loader.loadThumbnail(for: downloadController.resolvedAttachment(for: attachment))
            attachmentPresentation.present(
                downloadController.resolvedAttachment(for: attachment),
                sourceFrame: sourceFrame,
                context: presentationContext
            )
        }
    }
}

private struct LocationAttachmentCard: View {
    let attachment: Attachment

    @State private var payload: LocationAttachmentPayload?
    @State private var isPresentingViewer = false

    private enum CardLayout {
        static let width: CGFloat = 244
    }

    var body: some View {
        Button {
            if payload != nil {
                isPresentingViewer = true
            }
        } label: {
            SwiftUI.Group {
                if let payload {
                    ZStack(alignment: .bottomLeading) {
                        LocationMapPreview(payload: payload)
                        .frame(width: CardLayout.width)
                        .frame(minHeight: 152, maxHeight: 182)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        LinearGradient(
                            colors: [Color.black.opacity(0.08), Color.clear, Color.black.opacity(0.56)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                        VStack {
                            HStack {
                                Label("Location", systemImage: "mappin.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                    )
                                Spacer(minLength: 0)
                            }
                            .padding(12)

                            Spacer(minLength: 0)
                        }

                        HStack(alignment: .bottom, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Pinned location")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(payload.coordinatesText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.white.opacity(0.78))
                                Text("Tap to open the map preview")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.66))
                            }

                            Spacer(minLength: 0)

                            ZStack {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(Color.black.opacity(0.24))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                } else {
                    attachmentCard(
                        icon: "mappin.and.ellipse",
                        title: "Shared location",
                        subtitle: "Loading map..."
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) {
            guard payload == nil else { return }
            payload = await ChatMediaDraftBuilder.readLocationPayloadAsync(from: attachment)
        }
        .sheet(isPresented: $isPresentingViewer) {
            if let payload {
                LocationAttachmentViewer(payload: payload)
            }
        }
    }

    @ViewBuilder
    private func attachmentCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(PrimeTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct LocationAttachmentViewer: View {
    let payload: LocationAttachmentPayload

    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: PrimeTheme.Spacing.large) {
                LocationMapPreview(payload: payload, interactionModes: .all)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shared location")
                        .font(.headline)
                    Text(payload.coordinatesText)
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    Text("Accuracy: \(Int(payload.accuracyMeters.rounded())) m")
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: PrimeTheme.Spacing.medium) {
                    Button {
                        openInMaps()
                    } label: {
                        Label("Open in Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PrimeTheme.Colors.accent)

                    Button {
                        isPresentingShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)
            }
            .padding(PrimeTheme.Spacing.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            UIShareSheet(items: [payload.shareText])
        }
    }

    private func openInMaps() {
        #if os(tvOS)
        return
        #else
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: payload.coordinate))
        mapItem.name = "Shared location"
        mapItem.openInMaps()
        #endif
    }
}

struct VideoAttachmentViewer: View {
    let attachment: Attachment
    let context: ChatAttachmentPresentationStore.PresentationContext?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var attachmentPresentation: ChatAttachmentPresentationStore
    @ObservedObject private var playback: VideoAttachmentPlaybackController
    @State private var loadError = ""
    @State private var isPresentingShareSheet = false
    @State private var isSaving = false
    @State private var saveStatus = ""
    @State private var areControlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    init(
        attachment: Attachment,
        context: ChatAttachmentPresentationStore.PresentationContext? = nil
    ) {
        self.attachment = attachment
        self.context = context
        _playback = ObservedObject(
            wrappedValue: VideoPlaybackControllerRegistry.shared.controller(for: attachment)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playback.player {
                VideoAttachmentPlayerContainer(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            areControlsVisible.toggle()
                        }
                    }
                    .overlay {
                        LinearGradient(
                            colors: [Color.black.opacity(0.34), Color.clear, Color.black.opacity(0.52)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }
            } else if loadError.isEmpty == false {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 28, weight: .semibold))
                    Text(loadError)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(24)
            } else {
                ProgressView()
                    .tint(.white)
            }

            if areControlsVisible || saveStatus.isEmpty == false {
                VStack {
                    topVideoChrome

                    Spacer()

                    if let player = playback.player, areControlsVisible {
                        videoControlsOverlay(player: player)
                            .padding(.horizontal, 18)
                            .padding(.bottom, saveStatus.isEmpty ? 26 : 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if saveStatus.isEmpty == false {
                        Text(saveStatus)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Capsule())
                            .padding(.bottom, PrimeTheme.Spacing.xLarge)
                    }
                }
            }
        }
        .onAppear {
            MediaPipelineDiagnostics.logIssue("video.viewer.appear", url: attachment.remoteURL ?? attachment.localURL, details: "viewer presented")
            Task {
                playback.cancelScheduledStop()
                await prepareVideoIfNeeded()
            }
        }
        .onDisappear {
            MediaPipelineDiagnostics.logIssue("video.viewer.disappear", url: attachment.remoteURL ?? attachment.localURL, details: "viewer dismissed")
        }
        .onChange(of: playback.progress) { newValue in
            guard isScrubbing == false else { return }
            scrubProgress = newValue
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            AttachmentShareSheet(attachment: attachment)
        }
    }

    @ViewBuilder
    private func viewerActionButton(systemName: String, isProminent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isProminent ? PrimeTheme.Colors.accent.opacity(0.88) : Color.white.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var topVideoChrome: some View {
        HStack(spacing: 12) {
            viewerActionButton(systemName: "chevron.left", isProminent: false) {
                playback.stop()
                attachmentPresentation.beginDismissalTransition(for: attachment)
                dismiss()
            }

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Text(videoHeaderTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(videoHeaderSubtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            Spacer(minLength: 0)

            viewerActionButton(systemName: "square.and.arrow.up", isProminent: false) {
                isPresentingShareSheet = true
            }

            viewerActionButton(systemName: isSaving ? "arrow.down.circle.fill" : "arrow.down.circle", isProminent: true) {
                Task {
                    await saveVideo()
                }
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.top, PrimeTheme.Spacing.large)
    }

    @MainActor
    private func saveVideo() async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await AttachmentLibrarySaver.saveVideo(from: attachment)
            saveStatus = "Saved to Photos"
        } catch {
            saveStatus = "Could not save the video"
        }
    }

    @MainActor
    private func prepareVideoIfNeeded() async {
        do {
            try await playback.prepareIfNeeded(for: attachment)
            playback.play()
            loadError = ""
            scrubProgress = playback.progress
        } catch {
            loadError = "Video preview is unavailable right now."
        }
    }

    @ViewBuilder
    private func videoControlsOverlay(player: AVPlayer) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                transportButton(systemName: "gobackward.15") {
                    playback.seek(bySeconds: -15)
                }

                Button {
                    playback.togglePlayback()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.5))
                            .frame(width: 86, height: 86)
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            .frame(width: 86, height: 86)
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: playback.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)

                transportButton(systemName: "goforward.15") {
                    playback.seek(bySeconds: 15)
                }
            }

            VStack(spacing: 10) {
                #if os(tvOS)
                HStack(spacing: 10) {
                    transportButton(systemName: "gobackward.15") {
                        playback.seek(bySeconds: -15)
                    }

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white)
                                .frame(width: max(12, CGFloat(playback.progress) * 180), height: 6)
                        }

                    transportButton(systemName: "goforward.15") {
                        playback.seek(bySeconds: 15)
                    }
                }
                #else
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubProgress : playback.progress },
                        set: { scrubProgress = $0 }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing == false {
                            playback.seek(toProgress: scrubProgress)
                        }
                    }
                )
                .tint(.white)
                #endif

                HStack {
                    Text(playback.elapsedTimeLabel)
                    Spacer(minLength: 0)
                    Text(playback.durationLabel)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.92))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.36))
                    .frame(width: 62, height: 62)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    .frame(width: 62, height: 62)
                Image(systemName: systemName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var videoHeaderTitle: String {
        let senderName = context?.senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if senderName.isEmpty == false {
            return senderName
        }
        let cleaned = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 28 else { return cleaned }
        return String(cleaned.prefix(28)) + "…"
    }

    private var videoHeaderSubtitle: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file)
        let extensionText = URL(fileURLWithPath: attachment.fileName)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var segments: [String] = []
        if let sentAt = context?.sentAt {
            segments.append(sentAt.formatted(date: .omitted, time: .shortened))
        }
        if extensionText.isEmpty == false {
            segments.append(extensionText)
        }
        if sizeText.isEmpty == false {
            segments.append(sizeText)
        }
        if segments.isEmpty {
            return "Video"
        }
        return segments.joined(separator: " • ")
    }
}

@MainActor
private final class VideoAttachmentPlaybackController: ObservableObject {
    @Published fileprivate private(set) var player: AVPlayer?
    @Published fileprivate private(set) var isPlaying = false
    @Published fileprivate private(set) var progress: Double = 0
    @Published fileprivate private(set) var durationSeconds: Double = 0

    private var cachedURL: URL?
    private var stablePlaybackURL: URL?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackStallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    private var shouldResumeAfterStall = false
    private var shouldRemainPlaying = false
    private var lastRecoveryAttemptAt: Date = .distantPast
    private var scheduledStopTask: Task<Void, Never>?
    private var playbackActivityKey: String?
    private var pinnedRemoteURL: URL?
    private var isRemotePinned = false

    deinit {
        scheduledStopTask?.cancel()
        let remoteURLToRelease = (isRemotePinned ? pinnedRemoteURL : nil)
        if let remoteURLToRelease {
            Task {
                await RemoteAssetCacheStore.shared.endPlaybackPin(remoteURL: remoteURLToRelease)
            }
        }
        if let playbackActivityKey {
            Task { @MainActor in
                MediaPlaybackActivityStore.shared.end(playbackActivityKey)
            }
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        if let playbackStallObserver {
            NotificationCenter.default.removeObserver(playbackStallObserver)
        }
    }

    fileprivate func prepareIfNeeded(for attachment: Attachment) async throws {
        cancelScheduledStop()
        playbackActivityKey = AttachmentPlaybackKey.make(for: attachment)
        if isPlaying, player != nil {
            MediaPipelineDiagnostics.logIssue(
                "video.playback.prepare.skipped",
                url: stablePlaybackURL,
                details: "skipping prepare while playback is active"
            )
            return
        }
        let resolvedURL: URL
        let playbackURL: URL
        do {
            let candidateURL = try await ChatMediaFileResolver.resolvedFileURL(for: attachment)
            let candidatePlaybackURL = try makeStablePlaybackURL(from: candidateURL, attachment: attachment)
            resolvedURL = candidateURL
            playbackURL = candidatePlaybackURL
        } catch {
            guard attachment.remoteURL != nil else { throw error }
            MediaPipelineDiagnostics.logIssue("video.playback.force_refresh", url: attachment.remoteURL, details: "rebuilding playback copy after invalid local media")
            let refreshedURL = try await ChatMediaFileResolver.resolvedFileURL(for: attachment, forceRefresh: true)
            resolvedURL = refreshedURL
            playbackURL = try makeStablePlaybackURL(from: refreshedURL, attachment: attachment)
        }

        if cachedURL == resolvedURL, stablePlaybackURL == playbackURL, player != nil {
            return
        }

        removeObservers()

        let item = AVPlayerItem(url: playbackURL)
        item.preferredForwardBufferDuration = 24
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self else { return }
            if let playbackActivityKey = self.playbackActivityKey {
                MediaPlaybackActivityStore.shared.end(playbackActivityKey)
            }
            self.isPlaying = false
            self.shouldRemainPlaying = false
            self.releasePinnedRemoteURL()
            player?.seek(to: .zero)
        }

        playbackStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self else { return }
            let observedPlayer = player
            Task { @MainActor in
                MediaPipelineDiagnostics.logIssue(
                    "video.playback.stalled",
                    url: self.stablePlaybackURL,
                    details: "current=\(CMTimeGetSeconds(observedPlayer?.currentTime() ?? .zero))"
                )
                self.shouldResumeAfterStall = true
                self.attemptPlaybackRecovery(using: observedPlayer, reason: "stalled_notification")
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            guard let self else { return }
            let observedPlayer = player
            Task { @MainActor in
                if item.status == .failed {
                    MediaPipelineDiagnostics.logIssue(
                        "video.item.failed",
                        url: self.stablePlaybackURL,
                        details: item.error?.localizedDescription ?? "unknown item failure"
                    )
                }
                if item.status == .readyToPlay, self.shouldResumeAfterStall {
                    self.shouldResumeAfterStall = false
                    observedPlayer?.play()
                }
            }
        }

        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self, weak player] item, _ in
            guard let self else { return }
            let observedPlayer = player
            Task { @MainActor in
                guard item.isPlaybackLikelyToKeepUp else { return }
                if self.shouldResumeAfterStall {
                    self.shouldResumeAfterStall = false
                    self.attemptPlaybackRecovery(using: observedPlayer, reason: "likely_to_keep_up")
                }
            }
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.isPlaybackBufferEmpty {
                    self.shouldResumeAfterStall = true
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = player.timeControlStatus == .playing
                let statusLabel: String
                switch player.timeControlStatus {
                case .paused:
                    statusLabel = "paused"
                case .waitingToPlayAtSpecifiedRate:
                    statusLabel = "waiting"
                case .playing:
                    statusLabel = "playing"
                @unknown default:
                    statusLabel = "unknown"
                }
                let currentTime = CMTimeGetSeconds(player.currentTime())
                let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
                MediaPipelineDiagnostics.logIssue(
                    "video.time_control",
                    url: self.stablePlaybackURL,
                    details: "status=\(statusLabel) current=\(currentTime) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
                )
                if self.shouldRemainPlaying,
                   player.timeControlStatus == .paused,
                   duration.isFinite,
                   duration > 0.25,
                   currentTime + 0.25 < duration {
                    self.shouldResumeAfterStall = true
                    self.attemptPlaybackRecovery(using: player, reason: "time_control_paused")
                }
                if self.shouldRemainPlaying, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.isPlaying = true
                }
            }
        }

        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let currentTime = CMTimeGetSeconds(time)
            let duration = CMTimeGetSeconds(item.duration)
            Task { @MainActor in
                if duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                    self.progress = min(max(currentTime / duration, 0), 1)
                } else {
                    self.durationSeconds = 0
                    self.progress = 0
                }
            }
        }

        self.player = player
        self.cachedURL = resolvedURL
        self.stablePlaybackURL = playbackURL
        self.pinnedRemoteURL = attachment.remoteURL
        let summary = MediaFileInspector.summary(for: playbackURL)
        MediaPipelineDiagnostics.logResolvedFile(
            "video.playback.prepared",
            url: playbackURL,
            size: summary.fileSize,
            duration: summary.durationSeconds,
            details: "source=\(resolvedURL.lastPathComponent)"
        )
    }

    fileprivate func play() {
        cancelScheduledStop()
        shouldResumeAfterStall = true
        shouldRemainPlaying = true
        pinRemoteURLIfNeeded()
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.begin(playbackActivityKey)
        }
        MediaPipelineDiagnostics.logIssue("video.play", url: stablePlaybackURL, details: "requesting buffered playback")
        player?.play()
    }

    fileprivate func pause() {
        cancelScheduledStop()
        player?.pause()
        shouldResumeAfterStall = false
        shouldRemainPlaying = false
        releasePinnedRemoteURL()
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.end(playbackActivityKey)
        }
        let currentTime = CMTimeGetSeconds(player?.currentTime() ?? .zero)
        MediaPipelineDiagnostics.logIssue("video.pause", url: stablePlaybackURL, details: "manual pause current=\(currentTime)")
    }

    fileprivate func togglePlayback() {
        if isPlaying {
            pause()
            return
        }

        if progress >= 0.995 {
            seek(toProgress: 0)
        }
        play()
    }

    fileprivate func seek(toProgress progress: Double) {
        guard let player else { return }
        let duration = max(durationSeconds, 0)
        let targetTime = duration * min(max(progress, 0), 1)
        let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        self.progress = min(max(progress, 0), 1)
    }

    fileprivate func seek(bySeconds delta: Double) {
        guard let player else { return }
        let currentTime = CMTimeGetSeconds(player.currentTime())
        let duration = max(durationSeconds, 0)
        guard duration > 0 else { return }
        let targetTime = min(max(currentTime + delta, 0), duration)
        seek(toProgress: targetTime / duration)
    }

    fileprivate func stop() {
        cancelScheduledStop()
        player?.pause()
        shouldResumeAfterStall = false
        shouldRemainPlaying = false
        isPlaying = false
        releasePinnedRemoteURL()
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.end(playbackActivityKey)
        }
    }

    fileprivate func scheduleStop(after delay: Duration = .milliseconds(900)) {
        cancelScheduledStop()
        scheduledStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false, let self else { return }
            MediaPipelineDiagnostics.logIssue("video.playback.stop_scheduled", url: self.stablePlaybackURL, details: "stopping after delayed disappear")
            self.stop()
        }
    }

    fileprivate func cancelScheduledStop() {
        scheduledStopTask?.cancel()
        scheduledStopTask = nil
    }

    fileprivate var elapsedTimeLabel: String {
        format(seconds: durationSeconds * progress)
    }

    fileprivate var remainingTimeLabel: String {
        format(seconds: max(durationSeconds - (durationSeconds * progress), 0))
    }

    fileprivate var durationLabel: String {
        format(seconds: max(durationSeconds, 0))
    }

    private func removeObservers() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        if let playbackStallObserver {
            NotificationCenter.default.removeObserver(playbackStallObserver)
            self.playbackStallObserver = nil
        }
        itemStatusObservation = nil
        keepUpObservation = nil
        bufferEmptyObservation = nil
        timeControlStatusObservation = nil
        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
    }

    private func makeStablePlaybackURL(from sourceURL: URL, attachment: Attachment) throws -> URL {
        let directory = ChatMediaStorage.playbackMediaDirectory
        let pathExtension = sourceURL.pathExtension.isEmpty ? attachment.fileName.split(separator: ".").last.map(String.init) ?? "mov" : sourceURL.pathExtension
        let stableIdentifier = attachment.remoteURL?.lastPathComponent.isEmpty == false
            ? (attachment.remoteURL?.lastPathComponent ?? attachment.localURL?.lastPathComponent ?? attachment.id.uuidString)
            : (attachment.localURL?.lastPathComponent ?? attachment.id.uuidString)
        let targetURL = directory.appendingPathComponent("video-playback-\(stableIdentifier).\(pathExtension)")

        let sourceSize = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let targetSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison("video.playback.source.bytes", url: sourceURL, declaredBytes: attachment.byteSize, actualBytes: sourceSize)
        if MediaFileInspector.hasDeclaredByteShortfall(actualBytes: sourceSize, declaredBytes: attachment.byteSize) {
            MediaPipelineDiagnostics.logIssue("video.playback.source.byte_shortfall", url: sourceURL, details: "source media bytes are smaller than declared bytes; keeping playable source")
        }
        if FileManager.default.fileExists(atPath: targetURL.path),
           sourceSize > 0,
           sourceSize == targetSize {
            MediaPipelineDiagnostics.logByteComparison(
                "video.playback.bytes",
                url: targetURL,
                declaredBytes: attachment.byteSize,
                actualBytes: targetSize,
                sourceBytes: sourceSize,
                playbackBytes: targetSize
            )
            return targetURL
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        let copiedSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison(
            "video.playback.bytes",
            url: targetURL,
            declaredBytes: attachment.byteSize,
            actualBytes: copiedSize,
            sourceBytes: sourceSize,
            playbackBytes: copiedSize
        )
        if copiedSize != sourceSize || MediaFileInspector.hasDeclaredByteShortfall(actualBytes: copiedSize, declaredBytes: attachment.byteSize) {
            MediaPipelineDiagnostics.logIssue("video.playback.invalid", url: targetURL, details: "playback copy bytes do not match source size")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        if copiedSize <= 0 {
            MediaPipelineDiagnostics.logIssue("video.playback.invalid", url: targetURL, details: "playback copy bytes are empty")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        return targetURL
    }

    private func format(seconds: Double) -> String {
        let clamped = max(Int(seconds.rounded(.down)), 0)
        let minutes = clamped / 60
        let remainder = clamped % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }

    private func pinRemoteURLIfNeeded() {
        guard let pinnedRemoteURL, isRemotePinned == false else { return }
        isRemotePinned = true
        Task {
            await RemoteAssetCacheStore.shared.beginPlaybackPin(remoteURL: pinnedRemoteURL)
        }
    }

    private func releasePinnedRemoteURL() {
        guard let pinnedRemoteURL, isRemotePinned else { return }
        isRemotePinned = false
        Task {
            await RemoteAssetCacheStore.shared.endPlaybackPin(remoteURL: pinnedRemoteURL)
        }
    }

    private func attemptPlaybackRecovery(using player: AVPlayer?, reason: String) {
        guard let player else { return }
        guard shouldRemainPlaying else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecoveryAttemptAt) > 0.8 else { return }
        lastRecoveryAttemptAt = now
        MediaPipelineDiagnostics.logIssue(
            "video.playback.recovery",
            url: stablePlaybackURL,
            details: "reason=\(reason) current=\(CMTimeGetSeconds(player.currentTime()))"
        )
        player.play()
    }
}

private struct VideoAttachmentPlayerContainer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> VideoAttachmentPlayerView {
        let view = VideoAttachmentPlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: VideoAttachmentPlayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private final class VideoAttachmentPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct DocumentAttachmentViewer: View {
    let attachment: Attachment

    @Environment(\.dismiss) private var dismiss
    @State private var resolvedURL: URL?
    @State private var loadError = ""
    @State private var isPresentingShareSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.clear, Color.black.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                topDocumentChrome

                SwiftUI.Group {
                    if let resolvedURL {
                        AttachmentDocumentPreviewSurface(fileURL: resolvedURL)
                    } else if loadError.isEmpty == false {
                        VStack(spacing: 14) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(loadError)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.74))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text("Preparing file preview…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .padding(.horizontal, PrimeTheme.Spacing.large)
                .padding(.bottom, 10)

                bottomDocumentToolbar
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.bottom, PrimeTheme.Spacing.large)
            }
        }
        .task {
            await preparePreview()
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            AttachmentShareSheet(attachment: attachment)
        }
    }

    private var fileSubtitle: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file)
        let extensionText = URL(fileURLWithPath: attachment.fileName).pathExtension.uppercased()
        if extensionText.isEmpty {
            return sizeText
        }
        return sizeText.isEmpty ? extensionText : "\(extensionText) • \(sizeText)"
    }

    private var topDocumentChrome: some View {
        HStack(spacing: 12) {
            viewerActionButton(systemName: "xmark", isProminent: false) {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.fileName)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(fileSubtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            Spacer(minLength: 0)

            viewerActionButton(systemName: "square.and.arrow.up", isProminent: false) {
                isPresentingShareSheet = true
            }
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.top, PrimeTheme.Spacing.large)
    }

    private var bottomDocumentToolbar: some View {
        HStack(spacing: 10) {
            Label("Preview", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))

            Spacer(minLength: 0)

            Text(fileSubtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.68))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func viewerActionButton(systemName: String, isProminent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isProminent ? PrimeTheme.Colors.accent.opacity(0.88) : Color.white.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func preparePreview() async {
        guard resolvedURL == nil, loadError.isEmpty else { return }

        do {
            let resolvedURL = try await ChatMediaFileResolver.resolvedFileURL(for: attachment)
            self.resolvedURL = resolvedURL
            loadError = ""
        } catch {
            loadError = "This file could not be prepared for preview."
        }
    }
}

private struct AttachmentDocumentPreviewSurface: View {
    let fileURL: URL

    var body: some View {
        previewContent
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var previewContent: some View {
        #if canImport(QuickLook)
        AttachmentQuickLookPreviewController(fileURL: fileURL)
        #else
        AttachmentDocumentFallbackPreview(fileURL: fileURL)
        #endif
    }
}

private struct AttachmentDocumentFallbackPreview: View {
    let fileURL: URL

    private var fileSubtitle: String {
        let extensionText = fileURL.pathExtension.uppercased()
        return extensionText.isEmpty ? "Document preview is unavailable on Apple TV." : "\(extensionText) document preview is unavailable on Apple TV."
    }

    var body: some View {
        VStack(spacing: 18) {
            if let previewImage = pdfPreviewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            VStack(spacing: 8) {
                Text(fileURL.lastPathComponent)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(fileSubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(Color.white.opacity(0.04))
    }

    private var pdfPreviewImage: UIImage? {
        #if canImport(PDFKit) && !os(tvOS)
        guard fileURL.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: fileURL),
              let firstPage = document.page(at: 0) else {
            return nil
        }

        return firstPage.thumbnail(of: CGSize(width: 1100, height: 1500), for: .cropBox)
        #else
        return nil
        #endif
    }
}

#if canImport(QuickLook)
private struct AttachmentQuickLookPreviewController: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.fileURL = fileURL
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}
#endif

private struct AttachmentShareSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedItems: [Any] = []
    @State private var loadError = ""

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if resolvedItems.isEmpty == false {
                    ResolvedShareSheetController(items: resolvedItems)
                        .ignoresSafeArea()
                } else if loadError.isEmpty == false {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(PrimeTheme.Colors.warning)
                        Text(loadError)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                    .padding(24)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .navigationTitle("Share")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await resolveShareItems()
        }
    }

    @MainActor
    private func resolveShareItems() async {
        guard resolvedItems.isEmpty, loadError.isEmpty else { return }

        do {
            let resolvedURL = try await ChatMediaFileResolver.resolvedFileURL(for: attachment)
            resolvedItems = [resolvedURL]
        } catch {
            if let localURL = attachment.localURL {
                resolvedItems = [localURL]
            } else if let remoteURL = attachment.remoteURL {
                resolvedItems = [remoteURL]
            } else {
                loadError = "This attachment is unavailable right now."
            }
        }
    }
}

private enum AttachmentDocumentPreviewError: LocalizedError {
    case thumbnailUnavailable

    var errorDescription: String? {
        switch self {
        case .thumbnailUnavailable:
            return "Preview unavailable."
        }
    }
}

 #if !os(tvOS)
private struct ResolvedShareSheetController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

private struct UIShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
#else
private struct ResolvedShareSheetController: View {
    let items: [Any]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            Text("Sharing is unavailable on Apple TV.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

private struct UIShareSheet: View {
    let items: [Any]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            Text("Sharing is unavailable on Apple TV.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

private struct ChatBubbleTailShape: Shape {
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

enum VoiceMessagePlayerStyle: Equatable {
    case capsule
    case composer
    case bubble(usesLightForeground: Bool)
    case standaloneOutgoing(deliveryState: MessageDeliveryState)
    case standaloneIncoming

    var tint: Color {
        switch self {
        case .capsule, .composer:
            return .white
        case let .bubble(usesLightForeground):
            return usesLightForeground ? .white : PrimeTheme.Colors.textPrimary
        case .standaloneOutgoing:
            return .white.opacity(0.96)
        case .standaloneIncoming:
            return PrimeTheme.Colors.voiceIncomingText
        }
    }

    var secondaryTint: Color {
        switch self {
        case .capsule, .composer:
            return Color.white.opacity(0.34)
        case let .bubble(usesLightForeground):
            return usesLightForeground ? Color.white.opacity(0.28) : PrimeTheme.Colors.textSecondary.opacity(0.24)
        case .standaloneOutgoing:
            return Color.white.opacity(0.26)
        case .standaloneIncoming:
            return PrimeTheme.Colors.voiceIncomingText.opacity(0.24)
        }
    }

    var controlFill: Color {
        switch self {
        case .capsule, .composer:
            return Color.white.opacity(0.16)
        case let .bubble(usesLightForeground):
            return usesLightForeground ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        case .standaloneOutgoing:
            return Color.white.opacity(0.12)
        case .standaloneIncoming:
            return PrimeTheme.Colors.voiceIncomingText.opacity(0.10)
        }
    }

    var containerFill: Color {
        switch self {
        case .capsule, .composer:
            return Color.white.opacity(0.16)
        case let .bubble(usesLightForeground):
            return usesLightForeground ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        case .standaloneOutgoing, .standaloneIncoming:
            return .clear
        }
    }

    var transcriptFill: Color {
        switch self {
        case .capsule, .composer:
            return Color.white.opacity(0.16)
        case let .bubble(usesLightForeground):
            return usesLightForeground ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        case .standaloneOutgoing:
            return Color.white.opacity(0.12)
        case .standaloneIncoming:
            return Color.black.opacity(0.05)
        }
    }

    var containerStroke: Color {
        switch self {
        case .capsule, .composer:
            return Color.clear
        case let .bubble(usesLightForeground):
            return usesLightForeground ? Color.white.opacity(0.1) : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.9)
        case .standaloneOutgoing, .standaloneIncoming:
            return .clear
        }
    }

    var primaryControlFill: Color {
        switch self {
        case .standaloneOutgoing:
            return Color.white.opacity(0.18)
        case .standaloneIncoming:
            return PrimeTheme.Colors.voiceIncomingAccent.opacity(0.14)
        case .capsule, .composer, .bubble:
            return controlFill
        }
    }

    var primaryControlTint: Color {
        switch self {
        case .standaloneOutgoing:
            return .white
        case .standaloneIncoming:
            return PrimeTheme.Colors.voiceIncomingAccent
        case .capsule, .composer, .bubble:
            return tint
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .capsule:
            return 210
        case .composer:
            return 0
        case .bubble:
            return 218
        case .standaloneOutgoing, .standaloneIncoming:
            return 0
        }
    }

    var prefersExpandedLayout: Bool {
        switch self {
        case .standaloneOutgoing, .standaloneIncoming:
            return true
        case .capsule, .composer, .bubble:
            return false
        }
    }

    var showsTail: Bool {
        switch self {
        case .standaloneOutgoing, .standaloneIncoming:
            return false
        case .capsule, .composer, .bubble:
            return false
        }
    }

    var showsContainer: Bool {
        switch self {
        case .standaloneOutgoing, .standaloneIncoming:
            return false
        case .capsule, .composer, .bubble:
            return true
        }
    }

    var showsPlaybackRateControl: Bool {
        switch self {
        case .composer:
            return false
        case .standaloneOutgoing, .standaloneIncoming:
            return false
        case .capsule, .bubble:
            return true
        }
    }
}

struct VoiceMessagePlayerView: View {
    let voiceMessage: VoiceMessage
    var style: VoiceMessagePlayerStyle = .capsule
    var footerTimestampText: String? = nil
    var footerShowsEdited = false
    var footerStatus: MessageStatus? = nil
    var footerShowsSyncing = false

    @ObservedObject private var playback: VoiceMessagePlaybackController
    @StateObject private var transcription = VoiceTranscriptionController()
    @State private var isTranscriptExpanded = false

    init(
        voiceMessage: VoiceMessage,
        style: VoiceMessagePlayerStyle = .capsule,
        footerTimestampText: String? = nil,
        footerShowsEdited: Bool = false,
        footerStatus: MessageStatus? = nil,
        footerShowsSyncing: Bool = false
    ) {
        self.voiceMessage = voiceMessage
        self.style = style
        self.footerTimestampText = footerTimestampText
        self.footerShowsEdited = footerShowsEdited
        self.footerStatus = footerStatus
        self.footerShowsSyncing = footerShowsSyncing
        _playback = ObservedObject(
            wrappedValue: VoicePlaybackControllerRegistry.shared.controller(for: voiceMessage)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style.prefersExpandedLayout {
                HStack(alignment: .center, spacing: 10) {
                    playButton(size: 56, iconSize: 18)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            VoiceWaveformView(
                                samples: voiceMessage.waveformSamples,
                                progress: playback.progress,
                                activeColor: style.tint,
                                inactiveColor: style.secondaryTint,
                                barWidth: 3,
                                spacing: 2.5,
                                minimumBarHeight: 5,
                                maximumBarHeight: 18
                            )
                            .frame(width: 128, height: 24, alignment: .leading)
                            .clipped()

                            transcriptControlButton
                        }
                        .layoutPriority(1)

                        footerRow
                    }
                    .frame(width: 176, alignment: .leading)

                    if style.showsPlaybackRateControl {
                        rateButton
                    }
                }
            } else {
                HStack(spacing: PrimeTheme.Spacing.small) {
                    playButton(size: 30, iconSize: 12)

                    VoiceWaveformView(
                        samples: voiceMessage.waveformSamples,
                        progress: playback.progress,
                        activeColor: style.tint,
                        inactiveColor: style.secondaryTint
                    )
                    .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    if style.showsPlaybackRateControl {
                        rateButton
                    }

                    Text(playback.durationLabel(for: voiceMessage))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(style.tint)
                }
            }

            if isTranscriptExpanded, let transcriptText = transcriptText {
                Text(transcriptText)
                    .font(.footnote)
                    .foregroundStyle(style.tint.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(style.transcriptFill.opacity(0.96))
                    )
                    .padding(.leading, style.prefersExpandedLayout ? 66 : 0)
            }

            if isTranscriptExpanded, let transcriptError {
                HStack(spacing: 8) {
                    Text(transcriptError)
                        .font(.caption2)
                        .foregroundStyle(style.secondaryTint)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.leading, style.prefersExpandedLayout ? 66 : 0)
            }
        }
        .padding(.horizontal, style.prefersExpandedLayout ? 0 : PrimeTheme.Spacing.medium)
        .padding(.vertical, style.prefersExpandedLayout ? 0 : PrimeTheme.Spacing.small)
        .frame(minWidth: style.minimumWidth, alignment: .leading)
        .background(backgroundBody)
        .onAppear {
            MediaPipelineDiagnostics.logIssue("voice.viewer.appear", url: voiceMessage.remoteFileURL ?? voiceMessage.localFileURL, details: "voice bubble appeared")
            Task {
                playback.cancelScheduledStop()
                if voiceMessage.localFileURL != nil || NetworkUsagePolicy.canAutoDownload(.voiceMessages) {
                    await playback.prepareIfNeeded(for: voiceMessage)
                }
                await transcription.loadIfNeeded(for: voiceMessage)
            }
        }
        .onDisappear {
            MediaPipelineDiagnostics.logIssue("voice.viewer.disappear", url: voiceMessage.remoteFileURL ?? voiceMessage.localFileURL, details: "voice bubble disappeared")
        }
    }

    private var transcriptText: String? {
        let text = transcription.record?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private var transcriptError: String? {
        guard transcription.record?.status == .failed || transcription.record?.status == .unavailable else { return nil }
        return transcription.record?.errorMessage
    }

    private var shouldShowTranscriptionControls: Bool {
        transcriptText == nil || transcriptError != nil || transcription.isLoading
    }

    private var transcriptButtonTitle: String {
        if transcription.isLoading {
            return "Transcribing…"
        }
        return transcriptText == nil ? "Transcribe" : "Retry transcription"
    }

    private var isOutgoingStandaloneStyle: Bool {
        if case .standaloneOutgoing = style {
            return true
        }
        return false
    }

    private var tailAlignment: Alignment {
        isOutgoingStandaloneStyle ? .bottomTrailing : .bottomLeading
    }

    @ViewBuilder
    private var backgroundBody: some View {
        if style.showsContainer == false {
            Color.clear
        } else {
            Capsule(style: .continuous)
                .fill(style.containerFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(style.containerStroke, lineWidth: 1)
                )
                .overlay(alignment: tailAlignment) {
                    if style.showsTail {
                        ZStack {
                            ChatBubbleTailShape(isOutgoing: isOutgoingStandaloneStyle)
                                .fill(style.containerFill)
                            ChatBubbleTailShape(isOutgoing: isOutgoingStandaloneStyle)
                                .stroke(style.containerStroke, lineWidth: 1)
                        }
                        .frame(width: 15, height: 16)
                        .offset(x: isOutgoingStandaloneStyle ? 5 : -5, y: 2)
                    }
                }
        }
    }

    private func playButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            Task {
                await playback.togglePlayback(for: voiceMessage)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(style.primaryControlFill)
                    .frame(width: size, height: size)

                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(style.primaryControlTint)
                    .offset(x: playback.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(playback.durationLabel(for: voiceMessage))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(style.tint)

            Circle()
                .fill(style.tint.opacity(0.96))
                .frame(width: 6, height: 6)
                .opacity(playback.isPlaying ? 1 : 0.45)

            Spacer(minLength: 0)

            if let footerTimestampText {
                HStack(spacing: 5) {
                    if footerShowsSyncing {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .medium))
                    }

                    Text(footerTimestampText)
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())

                    if footerShowsEdited {
                        Text("edited")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    }

                    if let footerStatus {
                        VoiceFooterStatusGlyph(status: footerStatus, tint: style.tint)
                    }
                }
                .foregroundStyle(style.tint.opacity(0.96))
            }
        }
    }

    @ViewBuilder
    private var transcriptControlButton: some View {
        if shouldShowTranscriptionControls || transcriptText != nil {
            Button {
                if transcriptText != nil {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isTranscriptExpanded.toggle()
                    }
                } else {
                    Task {
                        await transcription.transcribe(voiceMessage)
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isTranscriptExpanded = transcriptText != nil || transcriptError != nil
                            }
                        }
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style.transcriptFill.opacity(0.98))
                        .frame(width: 34, height: 34)
                    if transcription.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(style.tint)
                    } else {
                        Text("A")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(style.tint)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(transcription.isLoading)
        }
    }

    private var rateButton: some View {
        Button {
            playback.cyclePlaybackRate()
        } label: {
            Text(playback.rateLabel)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(style.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(style.controlFill.opacity(0.94))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceFooterStatusGlyph: View {
    let status: MessageStatus
    let tint: Color

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
            ZStack {
                Image(systemName: "checkmark")
                    .offset(x: -3)
                Image(systemName: "checkmark")
                    .offset(x: 3)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint.opacity(0.86))
        case .read:
            ZStack {
                Image(systemName: "checkmark")
                    .offset(x: -3)
                Image(systemName: "checkmark")
                    .offset(x: 3)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.warning)
        }
    }
}

@MainActor
private final class VoiceMessagePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    nonisolated(unsafe) private static var activeVoiceSessionOwners = Set<ObjectIdentifier>()

    @Published fileprivate private(set) var isPlaying = false
    @Published fileprivate private(set) var progress: Double = 0
    @Published fileprivate private(set) var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var cachedURL: URL?
    private var cachedSourceURL: URL?
    private var progressTask: Task<Void, Never>?
    private var scheduledStopTask: Task<Void, Never>?
    private var playbackActivityKey: String?
    private var pinnedRemoteURL: URL?
    private var isRemotePinned = false
    private var shouldRemainPlaying = false
    private var ownsVoiceAudioSession = false
    private let supportedRates: [Float] = [1.0, 1.5, 2.0]

    deinit {
        progressTask?.cancel()
        scheduledStopTask?.cancel()
        let remoteURLToRelease = (isRemotePinned ? pinnedRemoteURL : nil)
        if let remoteURLToRelease {
            Task {
                await RemoteAssetCacheStore.shared.endPlaybackPin(remoteURL: remoteURLToRelease)
            }
        }
        if let playbackActivityKey {
            Task { @MainActor in
                MediaPlaybackActivityStore.shared.end(playbackActivityKey)
            }
        }
        Self.activeVoiceSessionOwners.remove(ObjectIdentifier(self))
    }

    fileprivate func prepareIfNeeded(for voiceMessage: VoiceMessage) async {
        cancelScheduledStop()
        playbackActivityKey = VoicePlaybackKey.make(for: voiceMessage)
        if isPlaying, player != nil {
            MediaPipelineDiagnostics.logIssue(
                "voice.playback.prepare.skipped",
                url: cachedURL,
                details: "skipping prepare while playback is active"
            )
            return
        }
        guard cachedURL == nil else { return }
        _ = try? await installPlayerIfNeeded(for: voiceMessage)
    }

    fileprivate func togglePlayback(for voiceMessage: VoiceMessage) async {
        cancelScheduledStop()
        if isPlaying {
            pause()
            return
        }

        guard let player = try? await installPlayerIfNeeded(
            for: voiceMessage,
            networkAccessKind: .general
        ) else {
            MediaPipelineDiagnostics.logIssue(
                "voice.play.prepare.failed",
                url: voiceMessage.remoteFileURL ?? voiceMessage.localFileURL,
                details: "installPlayerIfNeeded failed on user-initiated playback"
            )
            return
        }

        if AudioRecorderController.isCaptureInProgress() {
            MediaPipelineDiagnostics.logIssue("voice.play.skipped.recording_active", url: cachedURL, details: "skipping playback while recorder is active")
            return
        }

        let session = AVAudioSession.sharedInstance()
        let sessionActivated = activateVoiceAudioSession(using: session)
        if sessionActivated == false {
            MediaPipelineDiagnostics.logIssue("voice.play.session.failed", url: cachedURL, details: "could not activate dedicated voice playback session")
            MediaPipelineDiagnostics.logIssue("voice.play.session.fallback", url: cachedURL, details: "continuing playback attempt without dedicated session activation")
        }

        if player.currentTime >= max(player.duration - 0.1, 0) {
            player.currentTime = 0
        }
        pinRemoteURLIfNeeded()
        shouldRemainPlaying = true
        player.rate = playbackRate
        player.prepareToPlay()
        if player.play() == false {
            MediaPipelineDiagnostics.logIssue("voice.play.failed", url: cachedURL, details: "primary play() returned false")
            self.player = nil
            self.cachedURL = nil
            guard let retryPlayer = try? await installPlayerIfNeeded(
                for: voiceMessage,
                forceReload: true,
                networkAccessKind: .general
            ) else {
                guard await installDataFallbackPlayerIfNeeded(for: voiceMessage) else {
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                guard let recoveredPlayer = self.player else {
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                recoveredPlayer.rate = playbackRate
                recoveredPlayer.prepareToPlay()
                guard recoveredPlayer.play() else {
                    MediaPipelineDiagnostics.logIssue("voice.play.failed", url: cachedURL, details: "data fallback play() returned false")
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                isPlaying = true
                if let playbackActivityKey {
                    MediaPlaybackActivityStore.shared.begin(playbackActivityKey)
                }
                MediaPipelineDiagnostics.logIssue("voice.play", url: cachedURL, details: "fallback=data current=\(recoveredPlayer.currentTime) duration=\(recoveredPlayer.duration)")
                startProgressUpdates()
                return
            }
            retryPlayer.rate = playbackRate
            retryPlayer.prepareToPlay()
            if retryPlayer.play() == false {
                MediaPipelineDiagnostics.logIssue("voice.play.failed", url: cachedURL, details: "retry play() returned false")
                guard await installDataFallbackPlayerIfNeeded(for: voiceMessage) else {
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                guard let recoveredPlayer = self.player else {
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                recoveredPlayer.rate = playbackRate
                recoveredPlayer.prepareToPlay()
                guard recoveredPlayer.play() else {
                    MediaPipelineDiagnostics.logIssue("voice.play.failed", url: cachedURL, details: "retry data fallback play() returned false")
                    isPlaying = false
                    progress = 0
                    shouldRemainPlaying = false
                    return
                }
                isPlaying = true
                if let playbackActivityKey {
                    MediaPlaybackActivityStore.shared.begin(playbackActivityKey)
                }
                MediaPipelineDiagnostics.logIssue("voice.play", url: cachedURL, details: "retry fallback=data current=\(recoveredPlayer.currentTime) duration=\(recoveredPlayer.duration)")
                startProgressUpdates()
                return
            }
        }
        isPlaying = true
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.begin(playbackActivityKey)
        }
        MediaPipelineDiagnostics.logIssue("voice.play", url: cachedURL, details: "current=\(player.currentTime) duration=\(player.duration)")
        startProgressUpdates()
    }

    fileprivate func cyclePlaybackRate() {
        guard let currentIndex = supportedRates.firstIndex(of: playbackRate) else {
            playbackRate = supportedRates[0]
            player?.rate = playbackRate
            return
        }

        let nextIndex = (currentIndex + 1) % supportedRates.count
        playbackRate = supportedRates[nextIndex]
        player?.rate = playbackRate
    }

    fileprivate func pause() {
        cancelScheduledStop()
        player?.pause()
        shouldRemainPlaying = false
        isPlaying = false
        releasePinnedRemoteURL()
        progressTask?.cancel()
        progressTask = nil
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.end(playbackActivityKey)
        }
        MediaPipelineDiagnostics.logIssue("voice.pause", url: cachedURL, details: "current=\(player?.currentTime ?? 0) duration=\(player?.duration ?? 0)")
        releaseVoiceAudioSessionOwnership()
    }

    fileprivate func stop() {
        cancelScheduledStop()
        player?.pause()
        player?.currentTime = 0
        shouldRemainPlaying = false
        isPlaying = false
        progress = 0
        releasePinnedRemoteURL()
        progressTask?.cancel()
        progressTask = nil
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.end(playbackActivityKey)
        }
        releaseVoiceAudioSessionOwnership()
    }

    fileprivate func scheduleStop(after delay: Duration = .milliseconds(900)) {
        cancelScheduledStop()
        scheduledStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false, let self else { return }
            MediaPipelineDiagnostics.logIssue("voice.playback.stop_scheduled", url: self.cachedURL, details: "stopping after delayed disappear")
            self.stop()
        }
    }

    fileprivate func cancelScheduledStop() {
        scheduledStopTask?.cancel()
        scheduledStopTask = nil
    }

    fileprivate func durationLabel(for voiceMessage: VoiceMessage) -> String {
        let actualDuration = player?.duration ?? Double(voiceMessage.durationSeconds)
        let duration = max(Int(actualDuration.rounded(.up)), 0)
        let currentSeconds = Int(Double(duration) * progress)
        let primary = (isPlaying || progress > 0.001) ? currentSeconds : duration
        return format(seconds: primary)
    }

    fileprivate var rateLabel: String {
        if playbackRate.rounded(.towardZero) == playbackRate {
            return "\(Int(playbackRate))x"
        }
        return String(format: "%.1fx", playbackRate)
    }

    private func installPlayerIfNeeded(
        for voiceMessage: VoiceMessage,
        forceReload: Bool = false,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async throws -> AVAudioPlayer? {
        var resolvedURL: URL
        var url: URL
        do {
            let candidateURL = try await ChatMediaFileResolver.resolvedFileURL(
                for: voiceMessage,
                networkAccessKind: networkAccessKind,
                forceRefresh: forceReload
            )
            let candidatePlaybackURL = try makeStablePlaybackURL(from: candidateURL, voiceMessage: voiceMessage)
            resolvedURL = candidateURL
            url = candidatePlaybackURL
        } catch {
            if forceReload == false, voiceMessage.remoteFileURL != nil {
                do {
                    MediaPipelineDiagnostics.logIssue("voice.playback.force_refresh", url: voiceMessage.remoteFileURL, details: "rebuilding playback copy after invalid local voice media")
                    let refreshedURL = try await ChatMediaFileResolver.resolvedFileURL(
                        for: voiceMessage,
                        networkAccessKind: networkAccessKind,
                        forceRefresh: true
                    )
                    resolvedURL = refreshedURL
                    url = try makeStablePlaybackURL(from: refreshedURL, voiceMessage: voiceMessage)
                } catch {
                    if let localFallbackURL = directLocalVoiceFallbackURL(for: voiceMessage) {
                        let playbackURL = (try? makeStablePlaybackURL(from: localFallbackURL, voiceMessage: voiceMessage)) ?? localFallbackURL
                        MediaPipelineDiagnostics.logIssue(
                            "voice.playback.local_fallback",
                            url: playbackURL,
                            details: "using direct local fallback after refresh failure"
                        )
                        resolvedURL = localFallbackURL
                        url = playbackURL
                    } else {
                        throw error
                    }
                }
            } else if let localFallbackURL = directLocalVoiceFallbackURL(for: voiceMessage) {
                let playbackURL = (try? makeStablePlaybackURL(from: localFallbackURL, voiceMessage: voiceMessage)) ?? localFallbackURL
                MediaPipelineDiagnostics.logIssue(
                    "voice.playback.local_fallback",
                    url: playbackURL,
                    details: "using direct local fallback after resolver failure"
                )
                resolvedURL = localFallbackURL
                url = playbackURL
            } else {
                throw error
            }
        }

        if forceReload == false, cachedSourceURL == resolvedURL, cachedURL == url, let player {
            return player
        }

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.enableRate = true
        player.rate = playbackRate
        player.prepareToPlay()

        self.player = player
        self.cachedURL = url
        self.cachedSourceURL = resolvedURL
        self.pinnedRemoteURL = voiceMessage.remoteFileURL
        self.progress = 0
        self.isPlaying = false
        let summary = MediaFileInspector.summary(for: url)
        MediaPipelineDiagnostics.logResolvedFile(
            "voice.playback.prepared",
            url: url,
            size: summary.fileSize,
            duration: summary.durationSeconds,
            details: "source=\(resolvedURL.lastPathComponent)"
        )
        return player
    }

    private func installDataFallbackPlayerIfNeeded(for voiceMessage: VoiceMessage) async -> Bool {
        if let localURL = directLocalVoiceFallbackURL(for: voiceMessage),
           let data = try? Data(contentsOf: localURL),
           data.isEmpty == false,
           let fallbackPlayer = try? AVAudioPlayer(data: data)
        {
            fallbackPlayer.delegate = self
            fallbackPlayer.enableRate = true
            fallbackPlayer.rate = playbackRate
            fallbackPlayer.prepareToPlay()
            self.player = fallbackPlayer
            self.cachedURL = localURL
            self.cachedSourceURL = localURL
            self.pinnedRemoteURL = voiceMessage.remoteFileURL
            self.progress = 0
            self.isPlaying = false
            MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.local", url: localURL, details: "using direct data fallback from local voice file")
            return true
        }

        guard let remoteURL = voiceMessage.remoteFileURL else { return false }
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: .mediaDownloads)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
                MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.remote_failed", url: remoteURL, details: "unexpected status code")
                return false
            }
            guard data.isEmpty == false else {
                MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.remote_failed", url: remoteURL, details: "empty data")
                return false
            }
            guard let fallbackPlayer = try? AVAudioPlayer(data: data) else {
                MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.remote_failed", url: remoteURL, details: "AVAudioPlayer(data:) init failed")
                return false
            }
            fallbackPlayer.delegate = self
            fallbackPlayer.enableRate = true
            fallbackPlayer.rate = playbackRate
            fallbackPlayer.prepareToPlay()
            self.player = fallbackPlayer
            self.cachedURL = remoteURL
            self.cachedSourceURL = remoteURL
            self.pinnedRemoteURL = voiceMessage.remoteFileURL
            self.progress = 0
            self.isPlaying = false
            MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.remote", url: remoteURL, details: "using direct data fallback from remote voice file")
            return true
        } catch {
            MediaPipelineDiagnostics.logIssue("voice.playback.data_fallback.remote_error", url: remoteURL, details: error.localizedDescription)
            return false
        }
    }

    private func directLocalVoiceFallbackURL(for voiceMessage: VoiceMessage) -> URL? {
        guard let localURL = voiceMessage.localFileURL, localURL.isFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        let fileSize = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard fileSize > 0 else { return nil }
        return localURL
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let player else {
                    self.progress = 0
                    return
                }

                let duration = max(player.duration, 0.001)
                self.progress = min(max(player.currentTime / duration, 0), 1)
                if player.isPlaying == false {
                    if self.shouldRemainPlaying, player.currentTime + 0.25 < duration {
                        MediaPipelineDiagnostics.logIssue(
                            "voice.auto_resume",
                            url: self.cachedURL,
                            details: "resuming after unexpected stop current=\(player.currentTime) duration=\(player.duration)"
                        )
                        player.prepareToPlay()
                        if player.play() {
                            self.isPlaying = true
                            try? await Task.sleep(for: .milliseconds(120))
                            continue
                        }
                    }
                    MediaPipelineDiagnostics.logIssue(
                        "voice.progress.stopped",
                        url: self.cachedURL,
                        details: "current=\(player.currentTime) duration=\(player.duration) progress=\(self.progress)"
                    )
                    self.isPlaying = false
                    self.shouldRemainPlaying = false
                    if self.progress >= 0.999 {
                        self.progress = 0
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        shouldRemainPlaying = false
        progress = 0
        releasePinnedRemoteURL()
        progressTask?.cancel()
        progressTask = nil
        if let playbackActivityKey {
            MediaPlaybackActivityStore.shared.end(playbackActivityKey)
        }
        MediaPipelineDiagnostics.logIssue("voice.finished", url: cachedURL, details: "success=\(flag) duration=\(player.duration)")
        releaseVoiceAudioSessionOwnership()
    }

    private func makeStablePlaybackURL(from sourceURL: URL, voiceMessage: VoiceMessage) throws -> URL {
        let directory = ChatMediaStorage.playbackMediaDirectory
        let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let stableIdentifier = voiceMessage.remoteFileURL?.lastPathComponent.isEmpty == false
            ? (voiceMessage.remoteFileURL?.lastPathComponent ?? voiceMessage.localFileURL?.lastPathComponent ?? UUID().uuidString)
            : (voiceMessage.localFileURL?.lastPathComponent ?? UUID().uuidString)
        let targetURL = directory.appendingPathComponent("voice-playback-\(stableIdentifier)")

        let sourceSize = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let targetSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison("voice.playback.source.bytes", url: sourceURL, declaredBytes: voiceMessage.byteSize, actualBytes: sourceSize)
        if MediaFileInspector.hasDeclaredByteShortfall(actualBytes: sourceSize, declaredBytes: voiceMessage.byteSize) {
            MediaPipelineDiagnostics.logIssue("voice.playback.source.byte_shortfall", url: sourceURL, details: "source voice bytes are smaller than declared bytes; keeping playable source")
        }
        if FileManager.default.fileExists(atPath: targetURL.path),
           sourceSize > 0,
           sourceSize == targetSize {
            MediaPipelineDiagnostics.logByteComparison(
                "voice.playback.bytes",
                url: targetURL,
                declaredBytes: voiceMessage.byteSize,
                actualBytes: targetSize,
                sourceBytes: sourceSize,
                playbackBytes: targetSize
            )
            return targetURL
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        if stableIdentifier.hasSuffix(".\(pathExtension)") == false, targetURL.pathExtension.isEmpty {
            let correctedURL = directory.appendingPathComponent("voice-playback-\(stableIdentifier).\(pathExtension)")
            if FileManager.default.fileExists(atPath: correctedURL.path) {
                try? FileManager.default.removeItem(at: correctedURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: correctedURL)
            let copiedSize = Int64((try? correctedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            MediaPipelineDiagnostics.logByteComparison(
                "voice.playback.bytes",
                url: correctedURL,
                declaredBytes: voiceMessage.byteSize,
                actualBytes: copiedSize,
                sourceBytes: sourceSize,
                playbackBytes: copiedSize
            )
            if copiedSize != sourceSize {
                MediaPipelineDiagnostics.logIssue("voice.playback.invalid", url: correctedURL, details: "playback voice copy bytes do not match source size")
                try? FileManager.default.removeItem(at: correctedURL)
                throw AttachmentLibrarySaverError.unavailableAsset
            }
            if copiedSize <= 0 {
                MediaPipelineDiagnostics.logIssue("voice.playback.invalid", url: correctedURL, details: "playback voice copy bytes are empty")
                try? FileManager.default.removeItem(at: correctedURL)
                throw AttachmentLibrarySaverError.unavailableAsset
            }
            return correctedURL
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        let copiedSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison(
            "voice.playback.bytes",
            url: targetURL,
            declaredBytes: voiceMessage.byteSize,
            actualBytes: copiedSize,
            sourceBytes: sourceSize,
            playbackBytes: copiedSize
        )
        if copiedSize != sourceSize {
            MediaPipelineDiagnostics.logIssue("voice.playback.invalid", url: targetURL, details: "playback voice copy bytes do not match source size")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        if copiedSize <= 0 {
            MediaPipelineDiagnostics.logIssue("voice.playback.invalid", url: targetURL, details: "playback voice copy bytes are empty")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        return targetURL
    }

    private func activateVoiceAudioSession(using session: AVAudioSession) -> Bool {
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
            registerVoiceAudioSessionOwnership()
            return true
        } catch {
            MediaPipelineDiagnostics.logIssue("voice.session.activate.error", url: cachedURL, details: error.localizedDescription)
            return false
        }
    }

    private func registerVoiceAudioSessionOwnership() {
        let identifier = ObjectIdentifier(self)
        Self.activeVoiceSessionOwners.insert(identifier)
        ownsVoiceAudioSession = true
    }

    private func releaseVoiceAudioSessionOwnership() {
        guard ownsVoiceAudioSession else { return }
        ownsVoiceAudioSession = false
        let identifier = ObjectIdentifier(self)
        Self.activeVoiceSessionOwners.remove(identifier)

        guard Self.activeVoiceSessionOwners.isEmpty else { return }
        guard AudioRecorderController.isCaptureInProgress() == false else {
            MediaPipelineDiagnostics.logIssue("voice.session.deactivate.skipped", url: cachedURL, details: "recorder_active=true")
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func format(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):" + String(format: "%02d", remainder)
    }

    private func pinRemoteURLIfNeeded() {
        guard let pinnedRemoteURL, isRemotePinned == false else { return }
        isRemotePinned = true
        Task {
            await RemoteAssetCacheStore.shared.beginPlaybackPin(remoteURL: pinnedRemoteURL)
        }
    }

    private func releasePinnedRemoteURL() {
        guard let pinnedRemoteURL, isRemotePinned else { return }
        isRemotePinned = false
        Task {
            await RemoteAssetCacheStore.shared.endPlaybackPin(remoteURL: pinnedRemoteURL)
        }
    }
}

private struct VoiceWaveformView: View {
    let samples: [Float]
    let progress: Double
    let activeColor: Color
    let inactiveColor: Color
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var minimumBarHeight: CGFloat = 8
    var maximumBarHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: barWidth, height: max(minimumBarHeight, CGFloat(sample) * maximumBarHeight))
            }
        }
        .frame(height: 24)
    }

    private func color(for index: Int) -> Color {
        let threshold = Int(Double(samples.count) * progress)
        return index <= threshold ? activeColor.opacity(0.96) : inactiveColor
    }
}

struct PhotoAttachmentViewer: View {
    let attachment: Attachment
    let context: ChatAttachmentPresentationStore.PresentationContext?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var attachmentPresentation: ChatAttachmentPresentationStore
    @State private var isPresentingShareSheet = false
    @State private var isSaving = false
    @State private var saveStatus = ""

    init(
        attachment: Attachment,
        context: ChatAttachmentPresentationStore.PresentationContext? = nil
    ) {
        self.attachment = attachment
        self.context = context
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            imageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PrimeTheme.Spacing.large)

            VStack {
                HStack(spacing: 12) {
                    viewerActionButton(systemName: "xmark", isProminent: false) {
                        attachmentPresentation.beginDismissalTransition(for: attachment)
                        dismiss()
                    }

                    Spacer()

                    viewerActionButton(systemName: "square.and.arrow.up", isProminent: false) {
                        isPresentingShareSheet = true
                    }

                    viewerActionButton(systemName: isSaving ? "arrow.down.circle.fill" : "arrow.down.circle", isProminent: true) {
                        Task {
                            await savePhoto()
                        }
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, PrimeTheme.Spacing.large)
                .padding(.top, PrimeTheme.Spacing.large)

                Spacer()

                if saveStatus.isEmpty == false {
                    Text(saveStatus)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(.bottom, PrimeTheme.Spacing.xLarge)
                }
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            AttachmentShareSheet(attachment: attachment)
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let localURL = attachment.localURL,
           let uiImage = UIImage(contentsOfFile: localURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else if let remoteURL = attachment.remoteURL {
            CachedRemoteImage(url: remoteURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                ProgressView()
                    .tint(.white)
            }
        }
    }

    @ViewBuilder
    private func viewerActionButton(systemName: String, isProminent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isProminent ? PrimeTheme.Colors.accent.opacity(0.88) : Color.white.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func savePhoto() async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await AttachmentLibrarySaver.savePhoto(from: attachment)
            saveStatus = "Saved to Photos"
        } catch {
            saveStatus = "Could not save the photo"
        }
    }
}

private enum ChatMediaFileResolver {
    static func resolvedData(
        for attachment: Attachment,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async throws -> Data {
        if ChatMediaPersistentStore.isUsableLocalMediaURL(attachment.localURL),
           let localURL = attachment.localURL,
           MediaFileInspector.isValidAttachmentFile(localURL, attachment: attachment) {
            return try Data(contentsOf: localURL)
        }

        guard let remoteURL = attachment.remoteURL else {
            throw AttachmentLibrarySaverError.unavailableAsset
        }

        guard let data = await RemoteAssetCacheStore.shared.resolvedData(for: remoteURL, networkAccessKind: networkAccessKind) else {
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        return data
    }

    static func resolvedFileURL(
        for attachment: Attachment,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads,
        forceRefresh: Bool = false
    ) async throws -> URL {
        if forceRefresh == false,
           ChatMediaPersistentStore.isUsableLocalMediaURL(attachment.localURL),
           let localURL = attachment.localURL {
            if MediaFileInspector.isValidAttachmentFile(localURL, attachment: attachment) {
                let summary = MediaFileInspector.summary(for: localURL)
                MediaPipelineDiagnostics.logResolvedFile("attachment.local.hit", url: localURL, size: summary.fileSize, duration: summary.durationSeconds)
                MediaPipelineDiagnostics.logByteComparison("attachment.local.bytes", url: localURL, declaredBytes: attachment.byteSize, actualBytes: summary.fileSize)
                return localURL
            }
            let summary = MediaFileInspector.summary(for: localURL)
            MediaPipelineDiagnostics.logByteComparison("attachment.local.invalid.bytes", url: localURL, declaredBytes: attachment.byteSize, actualBytes: summary.fileSize)
            MediaPipelineDiagnostics.logIssue("attachment.local.invalid", url: localURL, details: "discarding invalid local file before refetch")
            try? FileManager.default.removeItem(at: localURL)
        }

        if let remoteURL = attachment.remoteURL {
            if let resolvedRemoteURL = try await resolveValidatedRemoteFileURL(
                remoteURL: remoteURL,
                preferredFileName: attachment.fileName,
                declaredByteSize: attachment.byteSize,
                networkAccessKind: networkAccessKind,
                validator: { MediaFileInspector.isValidAttachmentFile($0, attachment: attachment) },
                logLabel: "attachment.remote"
            ) {
                return resolvedRemoteURL
            }
        }

        let data = try await resolvedData(for: attachment, networkAccessKind: networkAccessKind)
        let targetURL: URL
        if let remoteURL = attachment.remoteURL {
            targetURL = makeDownloadURL(fileName: attachment.fileName, remoteURL: remoteURL)
        } else {
            targetURL = makeDownloadURL(fileName: attachment.fileName)
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try data.write(to: targetURL, options: .atomic)
        let targetSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison("attachment.download.fallback.bytes", url: targetURL, declaredBytes: attachment.byteSize, actualBytes: targetSize)
        if MediaFileInspector.isValidAttachmentFile(targetURL, attachment: attachment) == false {
            MediaPipelineDiagnostics.logIssue("attachment.download.invalid", url: targetURL, details: "fallback downloaded file is not playable")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        let summary = MediaFileInspector.summary(for: targetURL)
        MediaPipelineDiagnostics.logResolvedFile("attachment.download.fallback", url: targetURL, size: summary.fileSize, duration: summary.durationSeconds)
        return targetURL
    }

    static func resolvedFileURL(
        for voiceMessage: VoiceMessage,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads,
        forceRefresh: Bool = false
    ) async throws -> URL {
        if forceRefresh == false,
           ChatMediaPersistentStore.isUsableLocalMediaURL(voiceMessage.localFileURL),
           let localFileURL = voiceMessage.localFileURL {
            if MediaFileInspector.isValidVoiceFile(localFileURL, voiceMessage: voiceMessage) {
                let summary = MediaFileInspector.summary(for: localFileURL)
                MediaPipelineDiagnostics.logResolvedFile("voice.local.hit", url: localFileURL, size: summary.fileSize, duration: summary.durationSeconds)
                MediaPipelineDiagnostics.logByteComparison("voice.local.bytes", url: localFileURL, declaredBytes: voiceMessage.byteSize, actualBytes: summary.fileSize)
                return localFileURL
            }
            if MediaFileInspector.isValidVoiceFile(
                localFileURL,
                voiceMessage: voiceMessage,
                enforceDeclaredByteSize: false
            ) {
                let summary = MediaFileInspector.summary(for: localFileURL)
                MediaPipelineDiagnostics.logIssue(
                    "voice.local.accept_relaxed",
                    url: localFileURL,
                    details: "using playable local voice despite declared byte mismatch declared=\(voiceMessage.byteSize) actual=\(summary.fileSize)"
                )
                return localFileURL
            }
            let summary = MediaFileInspector.summary(for: localFileURL)
            MediaPipelineDiagnostics.logByteComparison("voice.local.invalid.bytes", url: localFileURL, declaredBytes: voiceMessage.byteSize, actualBytes: summary.fileSize)
            MediaPipelineDiagnostics.logIssue("voice.local.invalid", url: localFileURL, details: "discarding invalid local voice file before refetch")
            try? FileManager.default.removeItem(at: localFileURL)
        }

        guard let remoteFileURL = voiceMessage.remoteFileURL else {
            throw AttachmentLibrarySaverError.unavailableAsset
        }

        if let resolvedRemoteURL = try await resolveValidatedRemoteFileURL(
            remoteURL: remoteFileURL,
            preferredFileName: remoteFileURL.lastPathComponent.isEmpty ? "voice.m4a" : remoteFileURL.lastPathComponent,
            declaredByteSize: voiceMessage.byteSize,
            networkAccessKind: networkAccessKind,
            validator: { MediaFileInspector.isValidVoiceFile($0, voiceMessage: voiceMessage) },
            logLabel: "voice.remote"
        ) {
            return resolvedRemoteURL
        }

        guard let data = await RemoteAssetCacheStore.shared.resolvedData(for: remoteFileURL, networkAccessKind: networkAccessKind) else {
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        let targetURL = makeDownloadURL(
            fileName: remoteFileURL.lastPathComponent.isEmpty ? "voice.m4a" : remoteFileURL.lastPathComponent,
            remoteURL: remoteFileURL
        )
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try data.write(to: targetURL, options: .atomic)
        let targetSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        MediaPipelineDiagnostics.logByteComparison("voice.download.fallback.bytes", url: targetURL, declaredBytes: voiceMessage.byteSize, actualBytes: targetSize)
        if MediaFileInspector.isValidVoiceFile(targetURL, voiceMessage: voiceMessage) == false {
            MediaPipelineDiagnostics.logIssue("voice.download.invalid", url: targetURL, details: "fallback downloaded voice file is not playable")
            try? FileManager.default.removeItem(at: targetURL)
            throw AttachmentLibrarySaverError.unavailableAsset
        }
        let summary = MediaFileInspector.summary(for: targetURL)
        MediaPipelineDiagnostics.logResolvedFile("voice.download.fallback", url: targetURL, size: summary.fileSize, duration: summary.durationSeconds)
        return targetURL
    }

    private static func makeDownloadURL(fileName: String) -> URL {
        let directory = ChatMediaStorage.downloadedMediaDirectory
        let sanitizedFileName = fileName.isEmpty ? "media.bin" : fileName
        return directory.appendingPathComponent("fallback-\(sanitizedFileName)")
    }

    private static func makeDownloadURL(fileName: String, remoteURL: URL) -> URL {
        let directory = ChatMediaStorage.downloadedMediaDirectory
        let sanitizedFileName = fileName.isEmpty ? "media.bin" : fileName
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let stablePrefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(stablePrefix)-\(sanitizedFileName)")
    }

    private static func resolveValidatedRemoteFileURL(
        remoteURL: URL,
        preferredFileName: String,
        declaredByteSize: Int64,
        networkAccessKind: NetworkUsagePolicy.AccessKind,
        validator: (URL) -> Bool,
        logLabel: String
    ) async throws -> URL? {
        if let cachedURL = await RemoteAssetCacheStore.shared.resolvedFileURL(for: remoteURL, networkAccessKind: networkAccessKind) {
            let cachedSummary = MediaFileInspector.summary(for: cachedURL)
            MediaPipelineDiagnostics.logByteComparison("\(logLabel).cache.bytes", url: cachedURL, declaredBytes: declaredByteSize, actualBytes: cachedSummary.fileSize)
            if let remoteLength = await remoteContentLength(for: remoteURL, networkAccessKind: networkAccessKind),
               remoteLength > 0,
               cachedSummary.fileSize > 0,
               cachedSummary.fileSize < remoteLength {
                MediaPipelineDiagnostics.logIssue(
                    "\(logLabel).cache.truncated",
                    url: cachedURL,
                    details: "cachedBytes=\(cachedSummary.fileSize) remoteBytes=\(remoteLength) invalidating cache"
                )
                await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
            } else if validator(cachedURL) {
                let persistedURL = ChatMediaPersistentStore.persistDownloadedFile(
                    sourceURL: cachedURL,
                    preferredFileName: preferredFileName
                ) ?? cachedURL
                let summary = MediaFileInspector.summary(for: persistedURL)
                MediaPipelineDiagnostics.logByteComparison(
                    "\(logLabel).persisted.bytes",
                    url: persistedURL,
                    declaredBytes: declaredByteSize,
                    actualBytes: summary.fileSize,
                    sourceBytes: cachedSummary.fileSize
                )
                if validator(persistedURL) {
                    MediaPipelineDiagnostics.logResolvedFile("\(logLabel).cache.hit", url: persistedURL, size: summary.fileSize, duration: summary.durationSeconds)
                    return persistedURL
                }
                MediaPipelineDiagnostics.logIssue("\(logLabel).persisted.invalid", url: persistedURL, details: "persisted media copy is invalid")
                try? FileManager.default.removeItem(at: persistedURL)
                await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
                return nil
            } else {
                MediaPipelineDiagnostics.logIssue("\(logLabel).cache.invalid", url: cachedURL, details: "forcing cache refresh for invalid media file")
                await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
            }
        }

        guard let refreshedURL = await RemoteAssetCacheStore.shared.refresh(remoteURL, force: true, networkAccessKind: networkAccessKind) else {
            return nil
        }

        guard validator(refreshedURL) else {
            MediaPipelineDiagnostics.logIssue("\(logLabel).refresh.invalid", url: refreshedURL, details: "refreshed media file is still invalid")
            await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
            return nil
        }

        let persistedURL = ChatMediaPersistentStore.persistDownloadedFile(
            sourceURL: refreshedURL,
            preferredFileName: preferredFileName
        ) ?? refreshedURL
        let summary = MediaFileInspector.summary(for: persistedURL)
        let refreshedSummary = MediaFileInspector.summary(for: refreshedURL)
        MediaPipelineDiagnostics.logByteComparison(
            "\(logLabel).refresh.bytes",
            url: persistedURL,
            declaredBytes: declaredByteSize,
            actualBytes: summary.fileSize,
            sourceBytes: refreshedSummary.fileSize
        )
        guard validator(persistedURL) else {
            MediaPipelineDiagnostics.logIssue("\(logLabel).persisted.refresh.invalid", url: persistedURL, details: "persisted refreshed media copy is invalid")
            try? FileManager.default.removeItem(at: persistedURL)
            await RemoteAssetCacheStore.shared.invalidate(remoteURL: remoteURL)
            return nil
        }
        MediaPipelineDiagnostics.logResolvedFile("\(logLabel).refresh.ok", url: persistedURL, size: summary.fileSize, duration: summary.durationSeconds)
        return persistedURL
    }

    private static func remoteContentLength(
        for remoteURL: URL,
        networkAccessKind: NetworkUsagePolicy.AccessKind
    ) async -> Int64? {
        guard NetworkUsagePolicy.canUseNetwork(for: networkAccessKind) else { return nil }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: networkAccessKind)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200 ..< 400 ~= httpResponse.statusCode else {
                return nil
            }
            return httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil
        } catch {
            return nil
        }
    }
}

private extension Attachment {
    var autoDownloadKind: NetworkUsagePolicy.MediaAutoDownloadKind {
        switch type {
        case .photo:
            return .photos
        case .video:
            return .videos
        case .document, .audio, .contact, .location:
            return .files
        }
    }
}

private enum AttachmentLibrarySaver {
    static func savePhoto(from attachment: Attachment) async throws {
        let data = try await ChatMediaFileResolver.resolvedData(for: attachment)
        guard let image = UIImage(data: data) else {
            throw AttachmentLibrarySaverError.unavailableAsset
        }

        guard await requestAccess() else {
            throw AttachmentLibrarySaverError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AttachmentLibrarySaverError.saveFailed)
                }
            }
        }
    }

    static func saveVideo(from attachment: Attachment) async throws {
        let url = try await ChatMediaFileResolver.resolvedFileURL(for: attachment)

        guard await requestAccess() else {
            throw AttachmentLibrarySaverError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AttachmentLibrarySaverError.saveFailed)
                }
            }
        }
    }

    private static func requestAccess() async -> Bool {
        if #available(iOS 14, *) {
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

}

private enum AttachmentLibrarySaverError: LocalizedError {
    case unavailableAsset
    case permissionDenied
    case saveFailed
}

private struct PhotoEncodingProfile {
    let maxDimension: CGFloat
    let jpegCompression: CGFloat
}

private extension NetworkUsagePolicy.MediaUploadQualityPreset {
    var photoEncodingProfile: PhotoEncodingProfile {
        switch self {
        case .original:
            return PhotoEncodingProfile(maxDimension: 2_048, jpegCompression: 0.9)
        case .balanced:
            return PhotoEncodingProfile(maxDimension: 1_280, jpegCompression: 0.72)
        case .dataSaver:
            return PhotoEncodingProfile(maxDimension: 960, jpegCompression: 0.58)
        }
    }

    var videoExportPresetName: String? {
        switch self {
        case .original:
            return AVAssetExportPresetHighestQuality
        case .balanced:
            return AVAssetExportPreset1280x720
        case .dataSaver:
            return AVAssetExportPreset640x480
        }
    }
}

#if !os(tvOS)
extension NetworkUsagePolicy.MediaUploadQualityPreset {
    var cameraVideoQuality: UIImagePickerController.QualityType {
        switch self {
        case .original:
            return .typeHigh
        case .balanced:
            return .typeMedium
        case .dataSaver:
            return .typeLow
        }
    }
}
#endif

extension UIImage {
    func resizedForChat(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }

        let scale = maxDimension / maxSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
