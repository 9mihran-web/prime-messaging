import CryptoKit
import Combine
import Foundation
import OSLog
import SwiftUI
import UIKit

struct RemoteAssetCacheSummary: Equatable {
    var fileCount: Int
    var totalBytes: Int64

    nonisolated static let empty = RemoteAssetCacheSummary(fileCount: 0, totalBytes: 0)
}

actor RemoteAssetCacheStore {
    static let shared = RemoteAssetCacheStore()

    private let fileManager = FileManager.default
    private let session: URLSession
    private let directoryURL: URL
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "RemoteAssetCache")
    private let imageCache = NSCache<NSString, UIImage>()
    private let dataCache = NSCache<NSString, NSData>()
    private var inFlightDownloads: [String: Task<URL?, Never>] = [:]
    private var pinnedAssetRefCounts: [String: Int] = [:]

    init() {
        let fileManager = FileManager.default
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration)

        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directoryURL = cachesDirectory.appendingPathComponent("PrimeMessagingRemoteAssets", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        imageCache.countLimit = 128
        dataCache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedFileURL(for remoteURL: URL) -> URL? {
        let targetURL = targetURL(for: remoteURL)
        return fileManager.fileExists(atPath: targetURL.path) ? targetURL : nil
    }

    func cachedImage(for remoteURL: URL) -> UIImage? {
        let cacheKey = cacheKey(for: remoteURL)
        if let inMemoryImage = imageCache.object(forKey: cacheKey) {
            return inMemoryImage
        }
        guard let url = cachedFileURL(for: remoteURL) else { return nil }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func resolvedData(
        for remoteURL: URL,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async -> Data? {
        let cacheKey = cacheKey(for: remoteURL)
        if let inMemoryData = dataCache.object(forKey: cacheKey) {
            return inMemoryData as Data
        }

        if let cachedURL = cachedFileURL(for: remoteURL),
           let data = try? Data(contentsOf: cachedURL) {
            cache(data: data, for: remoteURL)
            return data
        }

        guard let localURL = await resolvedFileURL(for: remoteURL, networkAccessKind: networkAccessKind) else {
            return nil
        }
        return try? Data(contentsOf: localURL)
    }

    func resolvedFileURL(
        for remoteURL: URL,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async -> URL? {
        if let cachedURL = cachedFileURL(for: remoteURL) {
            return cachedURL
        }

        guard NetworkUsagePolicy.canUseNetwork(for: networkAccessKind) else {
            return nil
        }

        return await refresh(remoteURL, networkAccessKind: networkAccessKind)
    }

    func refresh(
        _ remoteURL: URL,
        force: Bool = false,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async -> URL? {
        let key = remoteURL.absoluteString
        let isPinned = pinnedAssetRefCounts[key, default: 0] > 0
        if !force, let task = inFlightDownloads[key] {
            return await task.value
        }

        if force {
            if isPinned {
                return cachedFileURL(for: remoteURL)
            }
            invalidateCachedArtifacts(for: remoteURL)
        }

        let existingURL = cachedFileURL(for: remoteURL)
        let task = Task<URL?, Never> { [directoryURL, session] in
            do {
                var request = URLRequest(url: remoteURL)
                request.timeoutInterval = 20
                request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: networkAccessKind)

                let (temporaryURL, response) = try await session.download(for: request)
                guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
                    await MainActor.run {
                        self.logger.error("download failed status file=\(remoteURL.lastPathComponent, privacy: .public) status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                    }
                    return existingURL
                }

                let expectedLength = httpResponse.expectedContentLength
                let temporaryFileSize = Int64((try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if expectedLength > 0, temporaryFileSize > 0, temporaryFileSize < expectedLength {
                    await MainActor.run {
                        self.logger.error("download size mismatch file=\(remoteURL.lastPathComponent, privacy: .public) expected=\(expectedLength, privacy: .public) actual=\(temporaryFileSize, privacy: .public)")
                    }
                    return existingURL
                }

                let targetURL = Self.targetURL(remoteURL, inside: directoryURL)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try? FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
                if let data = try? Data(contentsOf: targetURL) {
                    self.cache(data: data, for: remoteURL)
                }
                await MainActor.run {
                    self.logger.info("download ok file=\(remoteURL.lastPathComponent, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) size=\(temporaryFileSize, privacy: .public) expected=\(expectedLength, privacy: .public)")
                }
                return targetURL
            } catch {
                await MainActor.run {
                    self.logger.error("download error file=\(remoteURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                return existingURL
            }
        }

        inFlightDownloads[key] = task
        let result = await task.value
        inFlightDownloads.removeValue(forKey: key)
        return result
    }

    func invalidate(remoteURL: URL) {
        invalidateCachedArtifacts(for: remoteURL)
    }

    func beginPlaybackPin(remoteURL: URL) {
        let key = remoteURL.absoluteString
        pinnedAssetRefCounts[key, default: 0] += 1
    }

    func endPlaybackPin(remoteURL: URL) {
        let key = remoteURL.absoluteString
        let current = pinnedAssetRefCounts[key, default: 0]
        if current <= 1 {
            pinnedAssetRefCounts.removeValue(forKey: key)
        } else {
            pinnedAssetRefCounts[key] = current - 1
        }
    }

    func importDownloadedFile(
        from temporaryURL: URL,
        for remoteURL: URL,
        expectedLength: Int64? = nil
    ) -> URL? {
        let temporaryFileSize = Int64((try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let expectedLength, expectedLength > 0, temporaryFileSize > 0, temporaryFileSize < expectedLength {
            logger.error("manual import size mismatch file=\(remoteURL.lastPathComponent, privacy: .public) expected=\(expectedLength, privacy: .public) actual=\(temporaryFileSize, privacy: .public)")
            try? fileManager.removeItem(at: temporaryURL)
            return nil
        }

        let targetURL = targetURL(for: remoteURL)
        if fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.removeItem(at: targetURL)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
            if let data = try? Data(contentsOf: targetURL) {
                cache(data: data, for: remoteURL)
            }
            logger.info("manual import ok file=\(remoteURL.lastPathComponent, privacy: .public) size=\(temporaryFileSize, privacy: .public)")
            return targetURL
        } catch {
            logger.error("manual import failed file=\(remoteURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: temporaryURL)
            return nil
        }
    }

    func cacheSummary() -> RemoteAssetCacheSummary {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var fileCount = 0
        var totalBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }

            fileCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }

        return RemoteAssetCacheSummary(fileCount: fileCount, totalBytes: totalBytes)
    }

    func clearCache() {
        imageCache.removeAllObjects()
        dataCache.removeAllObjects()
        inFlightDownloads.values.forEach { $0.cancel() }
        inFlightDownloads.removeAll()

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.removeItem(at: directoryURL)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    func prewarm(
        urls: [URL],
        limit: Int = 24,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads
    ) async {
        guard urls.isEmpty == false else { return }

        var uniqueURLs: [URL] = []
        var seen = Set<String>()
        for url in urls where seen.insert(url.absoluteString).inserted {
            uniqueURLs.append(url)
            if uniqueURLs.count >= limit {
                break
            }
        }

        for url in uniqueURLs {
            _ = await resolvedFileURL(for: url, networkAccessKind: networkAccessKind)
        }
    }

    func prewarm(requests: [RemoteAssetWarmupRequest], limit: Int = 24) async {
        guard requests.isEmpty == false else { return }

        var uniqueRequests: [RemoteAssetWarmupRequest] = []
        var seen = Set<RemoteAssetWarmupRequest>()
        for request in requests where seen.insert(request).inserted {
            uniqueRequests.append(request)
            if uniqueRequests.count >= limit {
                break
            }
        }

        for request in uniqueRequests {
            _ = await resolvedFileURL(for: request.url, networkAccessKind: request.networkAccessKind)
        }
    }

    private func targetURL(for remoteURL: URL) -> URL {
        Self.targetURL(remoteURL, inside: directoryURL)
    }

    private func cacheKey(for remoteURL: URL) -> NSString {
        remoteURL.absoluteString as NSString
    }

    private func cache(data: Data, for remoteURL: URL) {
        let cacheKey = cacheKey(for: remoteURL)
        dataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        if let image = UIImage(data: data) {
            imageCache.setObject(image, forKey: cacheKey)
        }
    }

    private func invalidateCachedArtifacts(for remoteURL: URL) {
        if pinnedAssetRefCounts[remoteURL.absoluteString, default: 0] > 0 {
            return
        }
        let cacheKey = cacheKey(for: remoteURL)
        imageCache.removeObject(forKey: cacheKey)
        dataCache.removeObject(forKey: cacheKey)
        inFlightDownloads[remoteURL.absoluteString]?.cancel()
        inFlightDownloads.removeValue(forKey: remoteURL.absoluteString)
        let targetURL = targetURL(for: remoteURL)
        if fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.removeItem(at: targetURL)
        }
    }

    private static func targetURL(_ remoteURL: URL, inside directoryURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let pathExtension = remoteURL.pathExtension.isEmpty ? "bin" : remoteURL.pathExtension
        return directoryURL.appendingPathComponent("\(hash).\(pathExtension)")
    }

}

@MainActor
final class CachedRemoteImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    func load(from remoteURL: URL?, networkAccessKind: NetworkUsagePolicy.AccessKind) async {
        guard let remoteURL else {
            image = nil
            isLoading = false
            return
        }

        isLoading = true
        if let cachedImage = await RemoteAssetCacheStore.shared.cachedImage(for: remoteURL) {
            image = cachedImage
        }

        if let localURL = await RemoteAssetCacheStore.shared.resolvedFileURL(for: remoteURL, networkAccessKind: networkAccessKind),
           let refreshedImage = UIImage(contentsOfFile: localURL.path) {
            image = refreshedImage
        }
        isLoading = false
    }
}

struct RemoteAssetWarmupRequest: Hashable {
    let url: URL
    let networkAccessKind: NetworkUsagePolicy.AccessKind
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let networkAccessKind: NetworkUsagePolicy.AccessKind
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @StateObject private var loader = CachedRemoteImageLoader()

    init(
        url: URL?,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaDownloads,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.networkAccessKind = networkAccessKind
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        SwiftUI.Group {
            if let uiImage = loader.image {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loader.load(from: url, networkAccessKind: networkAccessKind)
        }
    }
}
