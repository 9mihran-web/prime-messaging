import Foundation
import Network

struct NetworkConnectionSnapshot: Equatable {
    var isSatisfied: Bool
    var usesWiFi: Bool
    var usesWiredEthernet: Bool
    var usesCellular: Bool
}

extension Notification.Name {
    static let primeMessagingReachabilityChanged = Notification.Name("primeMessagingReachabilityChanged")
}

final class NetworkReachabilityMonitor {
    nonisolated static let shared = NetworkReachabilityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "prime.messaging.network-monitor")
    private let lock = NSLock()
    private nonisolated(unsafe) var snapshot = NetworkConnectionSnapshot(
        isSatisfied: true,
        usesWiFi: false,
        usesWiredEthernet: false,
        usesCellular: false
    )

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateSnapshot(from: path)
        }
        monitor.start(queue: queue)
    }

    nonisolated var currentSnapshot: NetworkConnectionSnapshot {
        lock.withCriticalScope {
            snapshot
        }
    }

    private func updateSnapshot(from path: NWPath) {
        let nextSnapshot = NetworkConnectionSnapshot(
            isSatisfied: path.status == .satisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular)
        )

        var shouldNotify = false
        lock.withCriticalScope {
            shouldNotify = snapshot != nextSnapshot
            snapshot = nextSnapshot
        }

        guard shouldNotify else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .primeMessagingReachabilityChanged,
                object: nil,
                userInfo: ["snapshot": nextSnapshot]
            )
        }
    }
}

enum NetworkUsagePolicy {
    private enum StorageKeys {
        nonisolated static let allowsCellularSync = "network.usage.allows_cellular_sync"
        nonisolated static let allowsCellularMediaDownloads = "network.usage.allows_cellular_media_downloads"
        nonisolated static let allowsCellularMediaUploads = "network.usage.allows_cellular_media_uploads"

        nonisolated static func autoDownloadRuleKey(for kind: MediaAutoDownloadKind) -> String {
            "network.usage.auto_download.\(kind.rawValue)"
        }

        nonisolated static func uploadQualityKey(for kind: MediaUploadKind, onCellular: Bool) -> String {
            "network.usage.upload_quality.\(kind.rawValue).\(onCellular ? "cellular" : "wifi")"
        }
    }

    enum MediaAutoDownloadKind: String, CaseIterable, Identifiable, Hashable {
        case photos
        case videos
        case files
        case voiceMessages

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .photos:
                return "settings.network.auto_download.photos"
            case .videos:
                return "settings.network.auto_download.videos"
            case .files:
                return "settings.network.auto_download.files"
            case .voiceMessages:
                return "settings.network.auto_download.voices"
            }
        }
    }

    enum MediaAutoDownloadRule: String, CaseIterable, Identifiable {
        case never
        case wifiOnly
        case wifiAndCellular

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .never:
                return "settings.network.auto_download.rule.never"
            case .wifiOnly:
                return "settings.network.auto_download.rule.wifi_only"
            case .wifiAndCellular:
                return "settings.network.auto_download.rule.wifi_cellular"
            }
        }
    }

    enum MediaUploadKind: String, CaseIterable, Identifiable, Hashable {
        case photos
        case videos

        var id: String { rawValue }
    }

    enum MediaUploadQualityPreset: String, CaseIterable, Identifiable {
        case original
        case balanced
        case dataSaver

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .original:
                return "settings.network.upload_quality.rule.original"
            case .balanced:
                return "settings.network.upload_quality.rule.balanced"
            case .dataSaver:
                return "settings.network.upload_quality.rule.data_saver"
            }
        }
    }

    enum AccessKind: Hashable {
        case general
        case chatSync
        case mediaDownloads
        case mediaUploads
        case autoDownload(MediaAutoDownloadKind)
    }

    nonisolated static func allowsCellularSync(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: StorageKeys.allowsCellularSync) as? Bool ?? false
    }

    nonisolated static func setAllowsCellularSync(_ allows: Bool, defaults: UserDefaults = .standard) {
        defaults.set(allows, forKey: StorageKeys.allowsCellularSync)
    }

    nonisolated static func allowsCellularMediaDownloads(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: StorageKeys.allowsCellularMediaDownloads) as? Bool ?? false
    }

    nonisolated static func setAllowsCellularMediaDownloads(_ allows: Bool, defaults: UserDefaults = .standard) {
        defaults.set(allows, forKey: StorageKeys.allowsCellularMediaDownloads)
    }

    nonisolated static func allowsCellularMediaUploads(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: StorageKeys.allowsCellularMediaUploads) as? Bool ?? false
    }

    nonisolated static func setAllowsCellularMediaUploads(_ allows: Bool, defaults: UserDefaults = .standard) {
        defaults.set(allows, forKey: StorageKeys.allowsCellularMediaUploads)
    }

    nonisolated static func autoDownloadRule(
        for kind: MediaAutoDownloadKind,
        defaults: UserDefaults = .standard
    ) -> MediaAutoDownloadRule {
        guard let rawValue = defaults.string(forKey: StorageKeys.autoDownloadRuleKey(for: kind)),
              let rule = MediaAutoDownloadRule(rawValue: rawValue) else {
            return defaultAutoDownloadRule(for: kind)
        }
        return rule
    }

    nonisolated static func setAutoDownloadRule(
        _ rule: MediaAutoDownloadRule,
        for kind: MediaAutoDownloadKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(rule.rawValue, forKey: StorageKeys.autoDownloadRuleKey(for: kind))
    }

    nonisolated static func preferredUploadQuality(
        for kind: MediaUploadKind,
        onCellular: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> MediaUploadQualityPreset {
        let resolvedCellular = onCellular ?? NetworkReachabilityMonitor.shared.currentSnapshot.usesCellular
        let key = StorageKeys.uploadQualityKey(for: kind, onCellular: resolvedCellular)
        guard let rawValue = defaults.string(forKey: key),
              let preset = MediaUploadQualityPreset(rawValue: rawValue) else {
            return defaultUploadQuality(for: kind, onCellular: resolvedCellular)
        }
        return preset
    }

    nonisolated static func setPreferredUploadQuality(
        _ preset: MediaUploadQualityPreset,
        for kind: MediaUploadKind,
        onCellular: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(preset.rawValue, forKey: StorageKeys.uploadQualityKey(for: kind, onCellular: onCellular))
    }

    nonisolated static func canUseChatSyncNetwork(defaults: UserDefaults = .standard) -> Bool {
        canUseNetwork(for: .chatSync, defaults: defaults)
    }

    nonisolated static func canUseNetwork(for accessKind: AccessKind, defaults: UserDefaults = .standard) -> Bool {
        let snapshot = NetworkReachabilityMonitor.shared.currentSnapshot
        guard snapshot.isSatisfied else { return false }

        if case let .autoDownload(kind) = accessKind {
            switch autoDownloadRule(for: kind, defaults: defaults) {
            case .never:
                return false
            case .wifiOnly:
                return snapshot.usesWiFi || snapshot.usesWiredEthernet
            case .wifiAndCellular:
                if snapshot.usesWiFi || snapshot.usesWiredEthernet {
                    return true
                }
                if snapshot.usesCellular {
                    return allowsCellularMediaDownloads(defaults: defaults)
                }
                return true
            }
        }

        if snapshot.usesWiFi || snapshot.usesWiredEthernet {
            return true
        }

        if snapshot.usesCellular {
            return allowsCellularAccess(for: accessKind, defaults: defaults)
        }

        return true
    }

    nonisolated static func allowsCellularAccess(for accessKind: AccessKind, defaults: UserDefaults = .standard) -> Bool {
        switch accessKind {
        case .general:
            return true
        case .chatSync:
            return allowsCellularSync(defaults: defaults)
        case .mediaDownloads:
            return allowsCellularMediaDownloads(defaults: defaults)
        case .mediaUploads:
            return allowsCellularMediaUploads(defaults: defaults)
        case let .autoDownload(kind):
            guard allowsCellularMediaDownloads(defaults: defaults) else { return false }
            return autoDownloadRule(for: kind, defaults: defaults) == .wifiAndCellular
        }
    }

    nonisolated static func canAutoDownload(
        _ kind: MediaAutoDownloadKind,
        defaults: UserDefaults = .standard
    ) -> Bool {
        canUseNetwork(for: .autoDownload(kind), defaults: defaults)
    }

    nonisolated static func hasReachableNetwork() -> Bool {
        NetworkReachabilityMonitor.shared.currentSnapshot.isSatisfied
    }

    nonisolated static func isActuallyOffline() -> Bool {
        !hasReachableNetwork()
    }

    nonisolated static func isCellularSyncBlocked(defaults: UserDefaults = .standard) -> Bool {
        isCellularBlocked(for: .chatSync, defaults: defaults)
    }

    nonisolated static func isCellularBlocked(for accessKind: AccessKind, defaults: UserDefaults = .standard) -> Bool {
        let snapshot = NetworkReachabilityMonitor.shared.currentSnapshot
        return snapshot.isSatisfied && snapshot.usesCellular && !allowsCellularAccess(for: accessKind, defaults: defaults)
    }

    nonisolated static func connectionStatusTitle(defaults: UserDefaults = .standard) -> String {
        let snapshot = NetworkReachabilityMonitor.shared.currentSnapshot
        guard snapshot.isSatisfied else {
            return "settings.network.current.offline".localized
        }

        if snapshot.usesWiFi || snapshot.usesWiredEthernet {
            return "settings.network.current.wifi".localized
        }

        if snapshot.usesCellular {
            if allowsCellularSync(defaults: defaults) {
                return "settings.network.current.cellular".localized
            }
            return "settings.network.current.cellular_limited".localized
        }

        return "settings.network.current.online".localized
    }

    private nonisolated static func defaultAutoDownloadRule(for kind: MediaAutoDownloadKind) -> MediaAutoDownloadRule {
        switch kind {
        case .files:
            return .never
        case .photos, .videos, .voiceMessages:
            return .wifiOnly
        }
    }

    private nonisolated static func defaultUploadQuality(
        for kind: MediaUploadKind,
        onCellular: Bool
    ) -> MediaUploadQualityPreset {
        switch (kind, onCellular) {
        case (.photos, false):
            return .original
        case (.photos, true):
            return .balanced
        case (.videos, false):
            return .balanced
        case (.videos, true):
            return .dataSaver
        }
    }
}

private extension NSLock {
    nonisolated func withCriticalScope<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
