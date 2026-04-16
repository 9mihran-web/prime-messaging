import SwiftUI
import UIKit

struct FavoritesView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var onlineChats: [Chat] = []
    @State private var offlineChats: [Chat] = []
    @State private var statusMessage = ""

    var body: some View {
        List {
            if favoriteChats.isEmpty {
                Section {
                    Text(statusMessage.isEmpty ? "settings.favorites.empty".localized : statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section {
                    ForEach(favoriteChats) { chat in
                        Button {
                            appState.updateSelectedMode(chat.mode)
                            appState.selectedChat = chat
                            appState.routedChat = chat
                            appState.selectedMainTab = .chats
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chat.displayTitle(for: appState.currentUser.id))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    Text(chat.mode.titleKey.localized)
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }
                                Spacer()
                                if chat.type == .selfChat {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                } else if chat.isPinned {
                                    Image(systemName: "pin.fill")
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("settings.favorites".localized)
        .task {
            await loadFavorites()
        }
    }

    private var favoriteChats: [Chat] {
        (onlineChats + offlineChats)
            .filter { $0.type == .selfChat || $0.isPinned }
            .sorted { lhs, rhs in
                if lhs.type == .selfChat, rhs.type != .selfChat {
                    return true
                }
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
    }

    @MainActor
    private func loadFavorites() async {
        do {
            async let fetchedOnlineChats = environment.chatRepository.fetchChats(mode: .online, for: appState.currentUser.id)
            async let fetchedOfflineChats = environment.chatRepository.fetchChats(mode: .offline, for: appState.currentUser.id)
            onlineChats = try await fetchedOnlineChats
            offlineChats = try await fetchedOfflineChats
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "settings.favorites.load_failed".localized : error.localizedDescription
        }
    }
}

struct DevicesView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var activeDevices: [AccountDeviceSession] = []
    @State private var statusMessage = ""
    @State private var isLoading = false
    @State private var isRevoking = false

    var body: some View {
        List {
            Section("settings.devices.this_device".localized) {
                LabeledContent("settings.devices.name".localized, value: UIDevice.current.name)
                LabeledContent("settings.devices.system".localized, value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledContent("settings.devices.current_account".localized, value: "@\(appState.currentUser.profile.username)")
            }

            Section("Active devices") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if activeDevices.isEmpty {
                    Text(statusMessage.nilIfEmpty ?? "No active sessions found.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                } else {
                    ForEach(activeDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.symbolName)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.primaryLabel)
                                Text(device.secondaryLabel)
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                Text("Active: \(device.lastActiveAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary.opacity(0.8))
                            }

                            Spacer()

                            if device.isCurrent {
                                Text("Current")
                                    .font(.caption2)
                                    .foregroundStyle(PrimeTheme.Colors.success)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if device.isCurrent == false {
                                Button(role: .destructive) {
                                    Task {
                                        await revokeDeviceSession(device)
                                    }
                                } label: {
                                    Label("Sign out", systemImage: "xmark.circle")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }

            Section("settings.devices.signed_in_accounts".localized) {
                ForEach(appState.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.profile.displayName)
                            Text("@\(account.profile.username)")
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                        Spacer()
                        if account.id == appState.currentUser.id {
                            Text("settings.current".localized)
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.success)
                        }
                    }
                }
            }
        }
        .navigationTitle("settings.devices".localized)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await revokeOtherSessions()
                    }
                } label: {
                    if isRevoking {
                        ProgressView()
                    } else {
                        Text("Sign out others")
                    }
                }
                .disabled(isLoading || isRevoking || activeDevices.count <= 1)
            }
        }
        .task {
            await loadActiveDevices()
        }
    }

    @MainActor
    private func loadActiveDevices() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/devices",
                method: "GET",
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                statusMessage = "Failed to load devices."
                return
            }
            activeDevices = try BackendJSONDecoder.make().decode([AccountDeviceSession].self, from: data)
            statusMessage = activeDevices.isEmpty ? "No active sessions found." : ""
        } catch {
            let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = fallback.isEmpty ? "Failed to load devices." : fallback
        }
    }

    @MainActor
    private func revokeOtherSessions() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }

        isRevoking = true
        defer { isRevoking = false }

        do {
            let body = try JSONSerialization.data(withJSONObject: [:], options: [])
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/devices/revoke-others",
                method: "POST",
                body: body,
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                statusMessage = "Failed to revoke other sessions."
                return
            }

            struct RevokeResult: Decodable { let ok: Bool; let revoked: Int }
            let result = try? BackendJSONDecoder.make().decode(RevokeResult.self, from: data)
            let revokedCount = result?.revoked ?? 0
            statusMessage = revokedCount > 0 ? "Signed out \(revokedCount) session(s)." : "No other sessions to revoke."
            await loadActiveDevices()
        } catch {
            statusMessage = "Failed to revoke other sessions."
        }
    }

    @MainActor
    private func revokeDeviceSession(_ device: AccountDeviceSession) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }
        guard device.isCurrent == false else { return }

        isRevoking = true
        defer { isRevoking = false }

        do {
            let (_, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/devices/\(device.id.uuidString)",
                method: "DELETE",
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                statusMessage = "Failed to revoke this session."
                return
            }

            statusMessage = "Session signed out."
            await loadActiveDevices()
        } catch {
            statusMessage = "Failed to revoke this session."
        }
    }
}

private struct AccountDeviceSession: Decodable, Identifiable {
    let id: UUID
    let platform: String
    let deviceName: String?
    let deviceModel: String?
    let osName: String?
    let osVersion: String?
    let appVersion: String?
    let lastActiveAt: Date
    let isCurrent: Bool

    var primaryLabel: String {
        deviceName?.nilIfEmpty ?? deviceModel?.nilIfEmpty ?? platformDisplayName
    }

    var secondaryLabel: String {
        let osLabel = [osName?.nilIfEmpty, osVersion?.nilIfEmpty].compactMap { $0 }.joined(separator: " ")
        let appLabel = appVersion?.nilIfEmpty.map { "Prime \($0)" }
        let parts = [platformDisplayName, osLabel.nilIfEmpty, appLabel].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    var symbolName: String {
        switch platform.lowercased() {
        case "watchos":
            return "applewatch"
        case "tvos":
            return "appletv"
        case "macos":
            return "laptopcomputer"
        case "ipados":
            return "ipad"
        case "ios":
            return "iphone"
        default:
            return "desktopcomputer"
        }
    }

    private var platformDisplayName: String {
        switch platform.lowercased() {
        case "watchos":
            return "Apple Watch"
        case "tvos":
            return "Apple TV"
        case "macos":
            return "Mac"
        case "ipados":
            return "iPad"
        case "ios":
            return "iPhone"
        default:
            return platform.capitalized
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DataAndStorageView: View {
    @State private var allowsCellularSync = NetworkUsagePolicy.allowsCellularSync()
    @State private var allowsCellularMediaDownloads = NetworkUsagePolicy.allowsCellularMediaDownloads()
    @State private var allowsCellularMediaUploads = NetworkUsagePolicy.allowsCellularMediaUploads()
    @State private var autoDownloadRules: [NetworkUsagePolicy.MediaAutoDownloadKind: NetworkUsagePolicy.MediaAutoDownloadRule] = Dictionary(
        uniqueKeysWithValues: NetworkUsagePolicy.MediaAutoDownloadKind.allCases.map {
            ($0, NetworkUsagePolicy.autoDownloadRule(for: $0))
        }
    )
    @State private var wifiUploadQualities: [NetworkUsagePolicy.MediaUploadKind: NetworkUsagePolicy.MediaUploadQualityPreset] = Dictionary(
        uniqueKeysWithValues: NetworkUsagePolicy.MediaUploadKind.allCases.map {
            ($0, NetworkUsagePolicy.preferredUploadQuality(for: $0, onCellular: false))
        }
    )
    @State private var cellularUploadQualities: [NetworkUsagePolicy.MediaUploadKind: NetworkUsagePolicy.MediaUploadQualityPreset] = Dictionary(
        uniqueKeysWithValues: NetworkUsagePolicy.MediaUploadKind.allCases.map {
            ($0, NetworkUsagePolicy.preferredUploadQuality(for: $0, onCellular: true))
        }
    )
    @State private var cacheSummary = RemoteAssetCacheSummary.empty
    @State private var connectionStatusTitle = NetworkUsagePolicy.connectionStatusTitle()
    @State private var isClearingCache = false
    @State private var statusMessage = ""

    var body: some View {
        List {
            Section("settings.network".localized) {
                LabeledContent("settings.network.current".localized, value: connectionStatusTitle)

                Toggle(
                    "settings.network.sync.cellular".localized,
                    isOn: Binding(
                        get: { allowsCellularSync },
                        set: { newValue in
                            allowsCellularSync = newValue
                            NetworkUsagePolicy.setAllowsCellularSync(newValue)
                            refreshConnectionStatus()
                        }
                    )
                )

                Toggle(
                    "settings.network.downloads.cellular".localized,
                    isOn: Binding(
                        get: { allowsCellularMediaDownloads },
                        set: { newValue in
                            allowsCellularMediaDownloads = newValue
                            NetworkUsagePolicy.setAllowsCellularMediaDownloads(newValue)
                        }
                    )
                )

                Toggle(
                    "settings.network.uploads.cellular".localized,
                    isOn: Binding(
                        get: { allowsCellularMediaUploads },
                        set: { newValue in
                            allowsCellularMediaUploads = newValue
                            NetworkUsagePolicy.setAllowsCellularMediaUploads(newValue)
                        }
                    )
                )

                Text("settings.network.footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("settings.network.auto_download".localized) {
                ForEach(NetworkUsagePolicy.MediaAutoDownloadKind.allCases) { kind in
                    Picker(
                        kind.titleKey.localized,
                        selection: autoDownloadRuleBinding(for: kind)
                    ) {
                        ForEach(NetworkUsagePolicy.MediaAutoDownloadRule.allCases) { rule in
                            Text(rule.titleKey.localized).tag(rule)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text("settings.network.auto_download.footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("settings.network.upload_quality".localized) {
                ForEach(NetworkUsagePolicy.MediaUploadKind.allCases) { kind in
                    Picker(
                        uploadQualityTitleKey(for: kind, onCellular: false).localized,
                        selection: uploadQualityBinding(for: kind, onCellular: false)
                    ) {
                        ForEach(NetworkUsagePolicy.MediaUploadQualityPreset.allCases) { preset in
                            Text(preset.titleKey.localized).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(
                        uploadQualityTitleKey(for: kind, onCellular: true).localized,
                        selection: uploadQualityBinding(for: kind, onCellular: true)
                    ) {
                        ForEach(NetworkUsagePolicy.MediaUploadQualityPreset.allCases) { preset in
                            Text(preset.titleKey.localized).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text("settings.network.upload_quality.footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("settings.storage".localized) {
                LabeledContent("settings.storage.remote_cache".localized, value: formattedCacheSummary)

                Button(isClearingCache ? "settings.storage.clearing".localized : "settings.storage.clear_cache".localized, role: .destructive) {
                    Task {
                        await clearRemoteAssetCache()
                    }
                }
                .disabled(isClearingCache)

                Label("settings.storage.media".localized, systemImage: "externaldrive")
                Label("settings.storage.voice_drafts".localized, systemImage: "waveform")

                Text("settings.storage.clear_footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("settings.compatibility".localized) {
                Text("settings.compatibility.content".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                Text("settings.compatibility.reply".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("settings.data_storage".localized)
        .task {
            await refreshCacheSummary()
            refreshConnectionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingReachabilityChanged)) { _ in
            refreshConnectionStatus()
        }
    }

    private var formattedCacheSummary: String {
        guard cacheSummary.fileCount > 0, cacheSummary.totalBytes > 0 else {
            return "settings.storage.remote_cache.empty".localized
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let byteCount = formatter.string(fromByteCount: cacheSummary.totalBytes)
        return String(format: "settings.storage.remote_cache.count".localized, cacheSummary.fileCount, byteCount)
    }

    @MainActor
    private func refreshCacheSummary() async {
        cacheSummary = await RemoteAssetCacheStore.shared.cacheSummary()
    }

    @MainActor
    private func clearRemoteAssetCache() async {
        isClearingCache = true
        defer { isClearingCache = false }

        await RemoteAssetCacheStore.shared.clearCache()
        await refreshCacheSummary()
        statusMessage = "settings.storage.cleared".localized
    }

    private func refreshConnectionStatus() {
        connectionStatusTitle = NetworkUsagePolicy.connectionStatusTitle()
    }

    private func autoDownloadRuleBinding(
        for kind: NetworkUsagePolicy.MediaAutoDownloadKind
    ) -> Binding<NetworkUsagePolicy.MediaAutoDownloadRule> {
        Binding(
            get: {
                autoDownloadRules[kind] ?? NetworkUsagePolicy.autoDownloadRule(for: kind)
            },
            set: { newValue in
                autoDownloadRules[kind] = newValue
                NetworkUsagePolicy.setAutoDownloadRule(newValue, for: kind)
            }
        )
    }

    private func uploadQualityBinding(
        for kind: NetworkUsagePolicy.MediaUploadKind,
        onCellular: Bool
    ) -> Binding<NetworkUsagePolicy.MediaUploadQualityPreset> {
        Binding(
            get: {
                if onCellular {
                    return cellularUploadQualities[kind] ?? NetworkUsagePolicy.preferredUploadQuality(for: kind, onCellular: true)
                }
                return wifiUploadQualities[kind] ?? NetworkUsagePolicy.preferredUploadQuality(for: kind, onCellular: false)
            },
            set: { newValue in
                if onCellular {
                    cellularUploadQualities[kind] = newValue
                } else {
                    wifiUploadQualities[kind] = newValue
                }
                NetworkUsagePolicy.setPreferredUploadQuality(newValue, for: kind, onCellular: onCellular)
            }
        )
    }

    private func uploadQualityTitleKey(
        for kind: NetworkUsagePolicy.MediaUploadKind,
        onCellular: Bool
    ) -> String {
        switch (kind, onCellular) {
        case (.photos, false):
            return "settings.network.upload_quality.photos.wifi"
        case (.photos, true):
            return "settings.network.upload_quality.photos.cellular"
        case (.videos, false):
            return "settings.network.upload_quality.videos.wifi"
        case (.videos, true):
            return "settings.network.upload_quality.videos.cellular"
        }
    }
}

struct LanguageSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Picker("settings.language".localized, selection: Binding(
                get: { appState.selectedLanguage },
                set: { appState.updateLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.inline)
        }
        .navigationTitle("settings.language".localized)
    }
}

private struct AdminConsoleSummary: Decodable {
    var users: Int
    var legacyUsers: Int
    var chats: Int
    var messages: Int
    var sessions: Int
    var deviceTokens: Int

    enum CodingKeys: String, CodingKey {
        case users
        case legacyUsers
        case chats
        case messages
        case sessions
        case deviceTokens
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        users = container.decodeLossyIntIfPresent(forKey: .users) ?? 0
        legacyUsers = container.decodeLossyIntIfPresent(forKey: .legacyUsers) ?? 0
        chats = container.decodeLossyIntIfPresent(forKey: .chats) ?? 0
        messages = container.decodeLossyIntIfPresent(forKey: .messages) ?? 0
        sessions = container.decodeLossyIntIfPresent(forKey: .sessions) ?? 0
        deviceTokens = container.decodeLossyIntIfPresent(forKey: .deviceTokens) ?? 0
    }
}

private struct AdminConsoleUser: Identifiable, Decodable, Hashable {
    var id: String
    var displayName: String
    var username: String
    var email: String?
    var phoneNumber: String?
    var accountKind: AccountKind
    var createdAt: Date
    var guestExpiresAt: Date?
    var bannedUntil: Date?
    var isLegacyPlaceholder: Bool
    var chatCount: Int
    var sentMessageCount: Int
    var sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case username
        case email
        case phoneNumber
        case accountKind
        case createdAt
        case guestExpiresAt
        case bannedUntil
        case isLegacyPlaceholder
        case chatCount
        case sentMessageCount
        case sessionCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id) ?? UUID().uuidString
        displayName = container.decodeLossyStringIfPresent(forKey: .displayName) ?? ""
        username = container.decodeLossyStringIfPresent(forKey: .username) ?? ""
        email = container.decodeLossyStringIfPresent(forKey: .email)
        phoneNumber = container.decodeLossyStringIfPresent(forKey: .phoneNumber)
        accountKind = (try? container.decode(AccountKind.self, forKey: .accountKind)) ?? .standard
        createdAt = container.decodeLossyDateIfPresent(forKey: .createdAt) ?? .now
        guestExpiresAt = container.decodeLossyDateIfPresent(forKey: .guestExpiresAt)
        bannedUntil = container.decodeLossyDateIfPresent(forKey: .bannedUntil)
        isLegacyPlaceholder = container.decodeLossyBoolIfPresent(forKey: .isLegacyPlaceholder) ?? false
        chatCount = container.decodeLossyIntIfPresent(forKey: .chatCount) ?? 0
        sentMessageCount = container.decodeLossyIntIfPresent(forKey: .sentMessageCount) ?? 0
        sessionCount = container.decodeLossyIntIfPresent(forKey: .sessionCount) ?? 0
    }

    var uuidValue: UUID? {
        UUID(uuidString: id)
    }
}

private struct AdminConsoleMessagesPayload: Decodable {
    var chat: Chat?
    var messages: [Message]

    enum CodingKeys: String, CodingKey {
        case chat
        case messages
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chat = try? container.decodeIfPresent(Chat.self, forKey: .chat)
        messages = (try? container.decode([Message].self, forKey: .messages)) ?? []
    }
}

private struct AdminConsoleBulkDeleteResponse: Decodable {
    var ok: Bool
    var removed: Int
    var skipped: Int?
}

private struct AdminConsoleBanResponse: Decodable {
    var ok: Bool
    var bannedUntil: Date?
}

private struct AdminConsoleCreateUserRequest: Encodable {
    var displayName: String
    var username: String
    var password: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case password
    }
}

private struct AdminConsoleServerError: Decodable {
    var error: String
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let rawValue = try? decodeIfPresent(String.self, forKey: key) {
            return Int(rawValue)
        }
        return nil
    }

    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let rawValue = try? decodeIfPresent(String.self, forKey: key) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func decodeLossyDateIfPresent(forKey key: Key) -> Date? {
        if let value = try? decodeIfPresent(Date.self, forKey: key) {
            return value
        }
        guard let rawValue = try? decodeIfPresent(String.self, forKey: key),
              let date =
                ISO8601DateFormatter.fractionalAdmin.date(from: rawValue) ??
                ISO8601DateFormatter.internetAdmin.date(from: rawValue) else {
            return nil
        }
        return date
    }
}

private extension ISO8601DateFormatter {
    static let internetAdmin: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractionalAdmin: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum AdminConsoleAccessControl {
    static let allowedUsername = "mihran"

    static func isAllowed(_ username: String) -> Bool {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUsername = trimmedUsername.hasPrefix("@") ? String(trimmedUsername.dropFirst()) : trimmedUsername
        return normalizedUsername == allowedUsername
    }
}

private enum AdminConsoleStorage {
    static let loginKey = "developer.admin_console.login"
    static let passwordKey = "developer.admin_console.password"
}

private extension Notification.Name {
    static let primeMessagingAdminUsersChanged = Notification.Name("primeMessagingAdminUsersChanged")
}

private struct AdminConsoleCredentials {
    let login: String
    let password: String

    var isEmpty: Bool {
        login.isEmpty || password.isEmpty
    }
}

private struct AdminConsoleService {
    let baseURL: URL
    let credentials: AdminConsoleCredentials
    let currentUserID: UUID

    func fetchSummary() async throws -> AdminConsoleSummary {
        let data = try await performRequest(path: "/admin/summary")
        return try BackendJSONDecoder.make().decode(AdminConsoleSummary.self, from: data)
    }

    func fetchUsers(query: String, placeholdersOnly: Bool) async throws -> [AdminConsoleUser] {
        let data = try await performRequest(
            path: "/admin/users",
            queryItems: [
                URLQueryItem(name: "query", value: query.isEmpty ? nil : query),
                URLQueryItem(name: "placeholders_only", value: placeholdersOnly ? "1" : "0"),
            ]
        )
        let decoder = BackendJSONDecoder.make()
        if let rawItems = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return rawItems.compactMap { item in
                guard JSONSerialization.isValidJSONObject(item),
                      let itemData = try? JSONSerialization.data(withJSONObject: item) else {
                    return nil
                }
                return try? decoder.decode(AdminConsoleUser.self, from: itemData)
            }
        }
        return try decoder.decode([AdminConsoleUser].self, from: data)
    }

    func fetchChats(for userID: String) async throws -> [Chat] {
        let data = try await performRequest(
            path: "/admin/chats",
            queryItems: [URLQueryItem(name: "user_id", value: userID)]
        )
        return try BackendJSONDecoder.make().decode([Chat].self, from: data)
    }

    func fetchMessages(chatID: UUID) async throws -> AdminConsoleMessagesPayload {
        let data = try await performRequest(
            path: "/admin/messages",
            queryItems: [URLQueryItem(name: "chat_id", value: chatID.uuidString)]
        )
        return try BackendJSONDecoder.make().decode(AdminConsoleMessagesPayload.self, from: data)
    }

    func deleteUser(_ userID: String) async throws {
        _ = try await performRequest(path: "/admin/users/\(userID)", method: "DELETE")
    }

    func createUser(displayName: String, username: String, password: String) async throws -> AdminConsoleUser {
        let request = AdminConsoleCreateUserRequest(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let body = try JSONEncoder().encode(request)
        let data = try await performRequest(path: "/admin/users/create", method: "POST", body: body)
        return try BackendJSONDecoder.make().decode(AdminConsoleUser.self, from: data)
    }

    func cleanupLegacyUsers() async throws -> Int {
        let data = try await performRequest(path: "/admin/cleanup/legacy-placeholders", method: "POST")
        let payload = try JSONDecoder().decode([String: Int].self, from: data)
        return payload["removed"] ?? 0
    }

    func bulkDeleteUsers(_ userIDs: [String]) async throws -> Int {
        let requestBody = try JSONSerialization.data(withJSONObject: ["user_ids": userIDs])
        let data = try await performRequest(path: "/admin/users/bulk-delete", method: "POST", body: requestBody)
        let payload = try JSONDecoder().decode(AdminConsoleBulkDeleteResponse.self, from: data)
        return payload.removed
    }

    func banUser(_ userID: String, durationDays: Int) async throws -> Date? {
        let requestBody = try JSONSerialization.data(withJSONObject: ["duration_days": durationDays])
        let data = try await performRequest(path: "/admin/users/\(userID)/ban", method: "POST", body: requestBody)
        let payload = try BackendJSONDecoder.make().decode(AdminConsoleBanResponse.self, from: data)
        return payload.bannedUntil
    }

    func setOfficialBadge(chatID: UUID, isOfficial: Bool) async throws -> Chat {
        let requestBody = try JSONSerialization.data(withJSONObject: ["is_official": isOfficial])
        let data = try await performRequest(path: "/admin/chats/\(chatID.uuidString)/official", method: "PATCH", body: requestBody)
        return try BackendJSONDecoder.make().decode(Chat.self, from: data)
    }

    private func performRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        let sanitizedItems = queryItems.compactMap { item -> URLQueryItem? in
            guard let value = item.value else { return nil }
            return value.isEmpty ? nil : item
        }

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            queryItems: sanitizedItems,
            userID: currentUserID,
            networkAccessKind: .chatSync,
            additionalHeaders: [
                "X-Prime-Admin-Login": credentials.login,
                "X-Prime-Admin-Password": credentials.password,
            ]
        )
        try validate(response: response, data: data)
        return data
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            if let serverError = try? JSONDecoder().decode(AdminConsoleServerError.self, from: data) {
                switch serverError.error {
                case "admin_not_configured":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.not_configured".localized])
                case "admin_credentials_required", "admin_token_required", "admin_forbidden":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.invalid_credentials".localized])
                case "admin_auth_required":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.auth_required".localized])
                case "admin_account_required":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.account_only".localized])
                case "admin_account_protected":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.account_protected".localized])
                case "invalid_ban_duration":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.invalid_ban_duration".localized])
                case "invalid_username":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.invalid_username".localized])
                case "user_not_found":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "User not found."])
                case "chat_not_found":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Chat not found."])
                case "invalid_group_chat":
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "settings.admin_console.error.invalid_verification_chat".localized])
                default:
                    throw NSError(domain: "AdminConsole", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: serverError.error])
                }
            }

            throw ChatRepositoryError.backendUnavailable
        }
    }
}

struct AdminConsoleView: View {
    @EnvironmentObject private var appState: AppState

    @State private var adminLogin = UserDefaults.standard.string(forKey: AdminConsoleStorage.loginKey) ?? "admin"
    @State private var adminPassword = UserDefaults.standard.string(forKey: AdminConsoleStorage.passwordKey) ?? "Prime-admin-very-secret-2026"
    @State private var previewUsers: [AdminConsoleUser] = []
    @State private var managementUsername = ""
    @State private var managementUser: AdminConsoleUser?
    @State private var createDisplayName = ""
    @State private var createUsername = ""
    @State private var createPassword = ""
    @State private var isLoading = false
    @State private var isLookingUpManagementUser = false
    @State private var isCreatingUser = false
    @State private var isTokenValidated = false
    @State private var tokenStatusMessage = ""
    @State private var managementLookupMessage = ""
    @State private var statusMessage = ""

    var body: some View {
        List {
            if isAllowedAdminAccount {
                Section("settings.admin_console.access".localized) {
                    TextField("settings.admin_console.login".localized, text: $adminLogin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("settings.admin_console.password".localized, text: $adminPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await saveCredentialsAndRefresh()
                        }
                    } label: {
                        Text(isLoading ? "settings.admin_console.loading".localized : "settings.admin_console.save_access".localized)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)

                    Text("settings.admin_console.footer".localized)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)

                    if tokenStatusMessage.isEmpty == false {
                        Text(tokenStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(tokenStatusMessage == "settings.admin_console.credentials_saved".localized ? PrimeTheme.Colors.accent : PrimeTheme.Colors.warning)
                    }
                }

                Section("settings.admin_console.create_account".localized) {
                    TextField("settings.admin_console.create_account.display_name".localized, text: $createDisplayName)

                    TextField("settings.admin_console.create_account.username".localized, text: $createUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("settings.admin_console.create_account.password".localized, text: $createPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await createAdminManagedUser()
                        }
                    } label: {
                        Text(isCreatingUser ? "settings.admin_console.loading".localized : "settings.admin_console.create_account.button".localized)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingUser || trimmedCredentials.isEmpty)

                    Text("settings.admin_console.create_account.footer".localized)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Section("settings.admin_console.users_cleanup".localized) {
                    if isTokenValidated == false, tokenStatusMessage.isEmpty == false {
                        Text(tokenStatusMessage)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else if previewUsers.isEmpty {
                        Text(
                            statusMessage.isEmpty
                                ? "settings.admin_console.empty".localized
                                : statusMessage
                        )
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else {
                        ForEach(Array(previewUsers.prefix(3))) { user in
                            NavigationLink {
                                AdminUserManagementView(
                                    user: user,
                                    credentials: trimmedCredentials,
                                    currentUserID: appState.currentUser.id
                                )
                            } label: {
                                AdminConsoleUserRow(user: user, showsManageBadge: false)
                            }
                            #if !os(tvOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if canDelete(user) {
                                    Button("settings.admin_console.user.delete".localized, role: .destructive) {
                                        Task {
                                            await deleteUser(user)
                                        }
                                    }
                                }
                            }
                            #endif
                            }
                    }

                    NavigationLink("settings.admin_console.users.see_all".localized) {
                        AdminAllUsersView(
                            credentials: trimmedCredentials,
                            currentUserID: appState.currentUser.id,
                            initialUsers: previewUsers
                        )
                    }
                    .disabled(trimmedCredentials.isEmpty)
                }

                Section("settings.admin_console.user_management".localized) {
                    TextField("settings.admin_console.user_lookup".localized, text: $managementUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: managementUsername) { newValue in
                            scheduleManagementLookup(for: newValue)
                        }

                    if isLookingUpManagementUser {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("settings.admin_console.loading".localized)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    } else if let managementUser {
                        NavigationLink {
                            AdminUserManagementView(
                                user: managementUser,
                                credentials: trimmedCredentials,
                                currentUserID: appState.currentUser.id
                            )
                        } label: {
                            AdminConsoleUserRow(user: managementUser, showsManageBadge: true)
                        }
                        .disabled(trimmedCredentials.isEmpty)
                    } else if managementLookupMessage.isEmpty == false {
                        Text(managementLookupMessage)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else if normalizedManagementUsername.isEmpty == false {
                        Text("settings.admin_console.user_lookup.empty".localized)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }

                if statusMessage.isEmpty == false {
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }
            } else {
                Section {
                    Text("settings.admin_console.error.account_only".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("settings.admin_console".localized)
        .task {
            guard isAllowedAdminAccount, trimmedCredentials.isEmpty == false else { return }
            await saveCredentialsAndRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingAdminUsersChanged)) { _ in
            Task {
                await loadPreviewUsers()
                if isTokenValidated, normalizedManagementUsername.isEmpty == false {
                    await lookupManagedUser(exactUsername: normalizedManagementUsername)
                }
            }
        }
    }

    @MainActor
    private func loadPreviewUsers() async {
        guard isAllowedAdminAccount else {
            statusMessage = "settings.admin_console.error.account_only".localized
            return
        }

        guard trimmedCredentials.isEmpty == false else {
            previewUsers = []
            managementUser = nil
            return
        }

        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        isLoading = true
        defer { isLoading = false }
        let service = AdminConsoleService(baseURL: baseURL, credentials: trimmedCredentials, currentUserID: appState.currentUser.id)

        do {
            previewUsers = try await service.fetchUsers(query: "", placeholdersOnly: false)
            isTokenValidated = true
            tokenStatusMessage = "settings.admin_console.credentials_saved".localized
            statusMessage = ""
        } catch {
            previewUsers = []
            isTokenValidated = false
            tokenStatusMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteUser(_ user: AdminConsoleUser) async {
        guard isAllowedAdminAccount else {
            statusMessage = "settings.admin_console.error.account_only".localized
            return
        }

        guard
            trimmedCredentials.isEmpty == false,
            let baseURL = BackendConfiguration.currentBaseURL
        else {
            statusMessage = "settings.admin_console.error.invalid_credentials".localized
            return
        }

        guard canDelete(user) else {
            statusMessage = "settings.admin_console.error.account_protected".localized
            return
        }

        do {
            try await AdminConsoleService(baseURL: baseURL, credentials: trimmedCredentials, currentUserID: appState.currentUser.id).deleteUser(user.id)
            statusMessage = String(format: "settings.admin_console.user.deleted".localized, user.displayName.isEmpty ? user.username : user.displayName)
            if managementUser?.id == user.id {
                managementUser = nil
            }
            NotificationCenter.default.post(name: .primeMessagingAdminUsersChanged, object: nil, userInfo: ["userID": user.id])
            await loadPreviewUsers()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveCredentialsAndRefresh() async {
        persistCredentials()
        guard trimmedCredentials.isEmpty == false else {
            isTokenValidated = false
            tokenStatusMessage = "settings.admin_console.error.invalid_credentials".localized
            statusMessage = "settings.admin_console.error.invalid_credentials".localized
            previewUsers = []
            managementUser = nil
            managementLookupMessage = ""
            return
        }

        tokenStatusMessage = ""
        statusMessage = ""
        managementLookupMessage = ""
        await loadPreviewUsers()
        if isTokenValidated, normalizedManagementUsername.isEmpty == false {
            await lookupManagedUser(exactUsername: normalizedManagementUsername)
        }
    }

    private func persistCredentials() {
        UserDefaults.standard.set(trimmedAdminLogin, forKey: AdminConsoleStorage.loginKey)
        UserDefaults.standard.set(trimmedAdminPassword, forKey: AdminConsoleStorage.passwordKey)
    }

    private var isAllowedAdminAccount: Bool {
        AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username)
    }

    private var trimmedAdminLogin: String {
        adminLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAdminPassword: String {
        adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCredentials: AdminConsoleCredentials {
        AdminConsoleCredentials(login: trimmedAdminLogin, password: trimmedAdminPassword)
    }

    private var normalizedManagementUsername: String {
        let trimmed = managementUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    private func canDelete(_ user: AdminConsoleUser) -> Bool {
        AdminConsoleAccessControl.isAllowed(user.username) == false
    }

    private func scheduleManagementLookup(for value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        managementUser = nil
        statusMessage = ""
        managementLookupMessage = ""

        let exactUsername = normalized.hasPrefix("@") ? String(normalized.dropFirst()) : normalized
        guard exactUsername.isEmpty == false else {
            isLookingUpManagementUser = false
            return
        }

        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard normalizedManagementUsername == exactUsername else { return }
            await lookupManagedUser(exactUsername: exactUsername)
        }
    }

    @MainActor
    private func lookupManagedUser(exactUsername: String) async {
        guard isAllowedAdminAccount else { return }
        guard trimmedCredentials.isEmpty == false else {
            managementLookupMessage = "settings.admin_console.error.invalid_credentials".localized
            return
        }
        guard isTokenValidated else {
            managementLookupMessage = tokenStatusMessage.isEmpty ? "settings.admin_console.error.invalid_credentials".localized : tokenStatusMessage
            return
        }
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            managementLookupMessage = "auth.server.unavailable".localized
            return
        }

        isLookingUpManagementUser = true
        defer { isLookingUpManagementUser = false }

        if let localMatch = matchingUser(in: previewUsers, query: exactUsername) {
            managementUser = localMatch
            managementLookupMessage = ""
            return
        }

        do {
            if previewUsers.isEmpty {
                previewUsers = try await AdminConsoleService(
                    baseURL: baseURL,
                    credentials: trimmedCredentials,
                    currentUserID: appState.currentUser.id
                ).fetchUsers(query: "", placeholdersOnly: false)
                if let localMatch = matchingUser(in: previewUsers, query: exactUsername) {
                    managementUser = localMatch
                    managementLookupMessage = ""
                    return
                }
            }

            let remoteUsers = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: trimmedCredentials,
                currentUserID: appState.currentUser.id
            ).fetchUsers(query: exactUsername, placeholdersOnly: false)

            managementUser = matchingUser(in: remoteUsers, query: exactUsername) ?? remoteUsers.first
            managementLookupMessage = managementUser == nil ? "settings.admin_console.user_lookup.empty".localized : ""
        } catch {
            managementUser = nil
            managementLookupMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func matchingUser(in users: [AdminConsoleUser], query: String) -> AdminConsoleUser? {
        let normalizedQuery = normalizedLookup(query)

        if let exactMatch = users.first(where: {
            normalizedLookup($0.username) == normalizedQuery
        }) {
            return exactMatch
        }

        return users.first(where: { user in
            normalizedLookup(user.username).contains(normalizedQuery)
                || normalizedLookup(user.displayName).contains(normalizedQuery)
                || normalizedLookup(user.email ?? "").contains(normalizedQuery)
                || normalizedLookup(user.phoneNumber ?? "").contains(normalizedQuery)
        })
    }

    private func normalizedLookup(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    @MainActor
    private func createAdminManagedUser() async {
        guard isAllowedAdminAccount else { return }
        guard trimmedCredentials.isEmpty == false else {
            statusMessage = "settings.admin_console.error.invalid_credentials".localized
            return
        }
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        let normalizedUsername = normalizedLookup(createUsername)
        let trimmedDisplayName = createDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = createPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUsername.isEmpty == false, trimmedPassword.isEmpty == false else {
            statusMessage = "settings.admin_console.error.invalid_username".localized
            return
        }

        isCreatingUser = true
        defer { isCreatingUser = false }

        do {
            let createdUser = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: trimmedCredentials,
                currentUserID: appState.currentUser.id
            ).createUser(
                displayName: trimmedDisplayName.isEmpty ? normalizedUsername : trimmedDisplayName,
                username: normalizedUsername,
                password: trimmedPassword
            )
            createDisplayName = ""
            createUsername = ""
            createPassword = ""
            managementUsername = createdUser.username
            managementUser = createdUser
            statusMessage = String(format: "settings.admin_console.create_account.created".localized, createdUser.username)
            NotificationCenter.default.post(name: .primeMessagingAdminUsersChanged, object: nil, userInfo: ["userID": createdUser.id])
            await loadPreviewUsers()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct AdminConsoleUserRow: View {
    let user: AdminConsoleUser
    var showsManageBadge: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(user.isLegacyPlaceholder ? PrimeTheme.Colors.warning.opacity(0.25) : PrimeTheme.Colors.accent.opacity(0.2))
                .frame(width: 42, height: 42)
                .overlay(
                    Text(String(user.displayName.isEmpty ? user.username.prefix(1) : user.displayName.prefix(1)).uppercased())
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.displayName.isEmpty ? "@\(user.username)" : user.displayName)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    if user.isLegacyPlaceholder {
                        Text("LEGACY")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PrimeTheme.Colors.warning.opacity(0.16), in: Capsule())
                    }
                    if user.bannedUntil.map({ $0 > .now }) == true {
                        Text("BANNED")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PrimeTheme.Colors.accentSoft.opacity(0.16), in: Capsule())
                    }
                }
                Text("@\(user.username)")
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                Text("\(user.chatCount) chats · \(user.sentMessageCount) msgs · \(user.sessionCount) sessions")
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Spacer()

            if showsManageBadge {
                Text("settings.admin_console.manage".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.accent)
            }
        }
    }
}

private extension Chat {
    var isAdminVerifiableCommunity: Bool {
        guard type == .group, let kind = communityDetails?.kind else { return false }
        return kind == .channel || kind == .community
    }

    var adminVerificationStatusText: String {
        communityDetails?.isOfficial == true
            ? "settings.admin_console.verification.verified".localized
            : "settings.admin_console.verification.not_verified".localized
    }
}

private struct AdminAllUsersView: View {
    let credentials: AdminConsoleCredentials
    let currentUserID: UUID
    let initialUsers: [AdminConsoleUser]

    @State private var query = ""
    @State private var users: [AdminConsoleUser] = []
    @State private var isLoading = false
    @State private var statusMessage = ""

    var body: some View {
        List {
            if users.isEmpty {
                Section {
                    Text(statusMessage.isEmpty ? "settings.admin_console.empty".localized : statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section("settings.admin_console.users_all".localized) {
                    ForEach(users) { user in
                        NavigationLink {
                            AdminUserManagementView(user: user, credentials: credentials, currentUserID: currentUserID)
                        } label: {
                            AdminConsoleUserRow(user: user, showsManageBadge: false)
                        }
                        #if !os(tvOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if AdminConsoleAccessControl.isAllowed(user.username) == false {
                                Button("settings.admin_console.user.delete".localized, role: .destructive) {
                                    Task {
                                        await deleteUser(user)
                                    }
                                }
                            }
                        }
                        #endif
                    }
                }
            }
        }
        .navigationTitle("settings.admin_console.users_all".localized)
        .searchable(text: $query, prompt: "settings.admin_console.search".localized)
        .task {
            if users.isEmpty, initialUsers.isEmpty == false {
                users = initialUsers
            }
            await loadUsers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingAdminUsersChanged)) { notification in
            let deletedUserID = notification.userInfo?["userID"] as? String
            if let deletedUserID {
                users.removeAll(where: { $0.id == deletedUserID })
            }
            Task {
                await loadUsers()
            }
        }
        .onChange(of: query) { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                await loadUsers()
            }
        }
    }

    @MainActor
    private func loadUsers() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            users = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: credentials,
                currentUserID: currentUserID
            ).fetchUsers(query: query.trimmingCharacters(in: .whitespacesAndNewlines), placeholdersOnly: false)
            statusMessage = ""
        } catch {
            if users.isEmpty {
                users = initialUsers
            }
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteUser(_ user: AdminConsoleUser) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        do {
            try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID).deleteUser(user.id)
            users.removeAll(where: { $0.id == user.id })
            NotificationCenter.default.post(name: .primeMessagingAdminUsersChanged, object: nil, userInfo: ["userID": user.id])
            statusMessage = String(format: "settings.admin_console.user.deleted".localized, user.displayName.isEmpty ? user.username : user.displayName)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct AdminUserManagementView: View {
    @Environment(\.dismiss) private var dismiss

    let user: AdminConsoleUser
    let credentials: AdminConsoleCredentials
    let currentUserID: UUID

    @State private var chats: [Chat] = []
    @State private var bannedUntil: Date?
    @State private var isDeletingUser = false
    @State private var isApplyingBan = false
    @State private var updatingOfficialChatIDs = Set<UUID>()
    @State private var isShowingBanOptions = false
    @State private var isShowingDeleteAlert = false
    @State private var statusMessage = ""

    var body: some View {
        List {
            Section("settings.admin_console.user_management".localized) {
                LabeledContent("profile.name".localized, value: user.displayName.isEmpty ? "@\(user.username)" : user.displayName)
                LabeledContent("profile.username".localized, value: "@\(user.username)")
                LabeledContent("settings.admin_console.chats".localized, value: "\(user.chatCount)")
                LabeledContent("settings.admin_console.messages".localized, value: "\(user.sentMessageCount)")
                if let bannedUntil, bannedUntil > .now {
                    LabeledContent("settings.admin_console.user.banned_until".localized, value: bannedUntil.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if chats.isEmpty {
                Section("settings.admin_console.user_chats".localized) {
                    Text(statusMessage.isEmpty ? "settings.admin_console.chats.empty".localized : statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section("settings.admin_console.user_chats".localized) {
                    ForEach(Array(chats.prefix(3))) { chat in
                        NavigationLink {
                            AdminChatMessagesView(chat: chat, credentials: credentials, currentUserID: currentUserID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.displayTitle(for: user.uuidValue ?? currentUserID))
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                Text("\(chat.mode.rawValue.capitalized) · \(chat.type.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                if let preview = chat.lastMessagePreview, preview.isEmpty == false {
                                    Text(preview)
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }

                    NavigationLink("settings.admin_console.users.see_all".localized) {
                        AdminUserAllChatsView(user: user, credentials: credentials, currentUserID: currentUserID)
                    }
                }
            }

            if verifiableChats.isEmpty == false {
                Section("settings.admin_console.verification".localized) {
                    ForEach(verifiableChats) { chat in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(chat.displayTitle(for: user.uuidValue ?? currentUserID))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    if chat.communityDetails?.isOfficial == true {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(PrimeTheme.Colors.accent)
                                    }
                                }
                                Text("\((chat.communityDetails?.kind.title ?? "Chat")) · \(chat.adminVerificationStatusText)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }

                            Spacer()

                            Button {
                                Task {
                                    await toggleOfficialBadge(for: chat)
                                }
                            } label: {
                                if updatingOfficialChatIDs.contains(chat.id) {
                                    ProgressView()
                                } else {
                                    Text(
                                        chat.communityDetails?.isOfficial == true
                                            ? "settings.admin_console.verification.remove".localized
                                            : "settings.admin_console.verification.verify".localized
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("settings.admin_console.user_restrictions".localized) {
                Button(isApplyingBan ? "settings.admin_console.user.banning".localized : "settings.admin_console.user.ban".localized, role: .destructive) {
                    isShowingBanOptions = true
                }
                .disabled(isApplyingBan)

                Button(isDeletingUser ? "settings.admin_console.user.deleting".localized : "settings.admin_console.user.delete".localized, role: .destructive) {
                    isShowingDeleteAlert = true
                }
                .disabled(isDeletingUser)
            }

            if statusMessage.isEmpty == false {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle(user.displayName.isEmpty ? "@\(user.username)" : user.displayName)
        .confirmationDialog("settings.admin_console.user.ban".localized, isPresented: $isShowingBanOptions, titleVisibility: .visible) {
            Button("settings.admin_console.user.ban_1_day".localized, role: .destructive) {
                Task { await applyBan(durationDays: 1) }
            }
            Button("settings.admin_console.user.ban_3_days".localized, role: .destructive) {
                Task { await applyBan(durationDays: 3) }
            }
            Button("settings.admin_console.user.ban_1_week".localized, role: .destructive) {
                Task { await applyBan(durationDays: 7) }
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .alert("settings.admin_console.user.delete".localized, isPresented: $isShowingDeleteAlert) {
            Button("settings.admin_console.user.delete.confirm".localized, role: .destructive) {
                Task { await deleteManagedUser() }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text(String(format: "settings.admin_console.user.delete.message".localized, "@\(user.username)"))
        }
        .task {
            bannedUntil = user.bannedUntil
            await loadChats()
        }
    }

    private var verifiableChats: [Chat] {
        chats.filter(\.isAdminVerifiableCommunity)
    }

    @MainActor
    private func loadChats() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        do {
            chats = try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID).fetchChats(for: user.id)
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleOfficialBadge(for chat: Chat) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }
        guard chat.isAdminVerifiableCommunity else { return }

        updatingOfficialChatIDs.insert(chat.id)
        defer { updatingOfficialChatIDs.remove(chat.id) }

        do {
            let updatedChat = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: credentials,
                currentUserID: currentUserID
            ).setOfficialBadge(
                chatID: chat.id,
                isOfficial: chat.communityDetails?.isOfficial != true
            )
            if let index = chats.firstIndex(where: { $0.id == updatedChat.id }) {
                chats[index] = updatedChat
            }
            statusMessage = updatedChat.communityDetails?.isOfficial == true
                ? "settings.admin_console.verification.enabled".localized
                : "settings.admin_console.verification.disabled".localized
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteManagedUser() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        isDeletingUser = true
        defer { isDeletingUser = false }

        do {
            try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID).deleteUser(user.id)
            NotificationCenter.default.post(name: .primeMessagingAdminUsersChanged, object: nil, userInfo: ["userID": user.id])
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyBan(durationDays: Int) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        isApplyingBan = true
        defer { isApplyingBan = false }

        do {
            bannedUntil = try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID)
                .banUser(user.id, durationDays: durationDays)
            if let bannedUntil {
                statusMessage = String(format: "settings.admin_console.user.banned".localized, "@\(user.username)", bannedUntil.formatted(date: .abbreviated, time: .shortened))
            } else {
                statusMessage = "settings.admin_console.user.ban_applied".localized
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct AdminUserAllChatsView: View {
    let user: AdminConsoleUser
    let credentials: AdminConsoleCredentials
    let currentUserID: UUID

    @State private var chats: [Chat] = []
    @State private var updatingOfficialChatIDs = Set<UUID>()
    @State private var statusMessage = ""

    var body: some View {
        List {
            if chats.isEmpty {
                Section {
                    Text(statusMessage.isEmpty ? "settings.admin_console.chats.empty".localized : statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section("settings.admin_console.user_chats".localized) {
                    ForEach(chats) { chat in
                        NavigationLink {
                            AdminChatMessagesView(chat: chat, credentials: credentials, currentUserID: currentUserID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(chat.displayTitle(for: user.uuidValue ?? currentUserID))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    if chat.communityDetails?.isOfficial == true {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(PrimeTheme.Colors.accent)
                                    }
                                }
                                Text("\(chat.mode.rawValue.capitalized) · \(chat.type.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                if let preview = chat.lastMessagePreview, preview.isEmpty == false {
                                    Text(preview)
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        #if !os(tvOS)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if chat.isAdminVerifiableCommunity {
                                Button(
                                    chat.communityDetails?.isOfficial == true
                                        ? "settings.admin_console.verification.remove".localized
                                        : "settings.admin_console.verification.verify".localized
                                ) {
                                    Task {
                                        await toggleOfficialBadge(for: chat)
                                    }
                                }
                                .tint(chat.communityDetails?.isOfficial == true ? .orange : .blue)
                            }
                        }
                        #endif
                    }
                }
            }
        }
        .navigationTitle("settings.admin_console.user_chats".localized)
        .task {
            await loadChats()
        }
    }

    @MainActor
    private func loadChats() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        do {
            chats = try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID).fetchChats(for: user.id)
            statusMessage = ""
        } catch {
            chats = []
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleOfficialBadge(for chat: Chat) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }
        guard chat.isAdminVerifiableCommunity else { return }

        updatingOfficialChatIDs.insert(chat.id)
        defer { updatingOfficialChatIDs.remove(chat.id) }

        do {
            let updatedChat = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: credentials,
                currentUserID: currentUserID
            ).setOfficialBadge(
                chatID: chat.id,
                isOfficial: chat.communityDetails?.isOfficial != true
            )
            if let index = chats.firstIndex(where: { $0.id == updatedChat.id }) {
                chats[index] = updatedChat
            }
            statusMessage = updatedChat.communityDetails?.isOfficial == true
                ? "settings.admin_console.verification.enabled".localized
                : "settings.admin_console.verification.disabled".localized
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct AdminChatMessagesView: View {
    let chat: Chat
    let credentials: AdminConsoleCredentials
    let currentUserID: UUID

    @State private var messages: [Message] = []
    @State private var currentChat: Chat
    @State private var isUpdatingOfficialBadge = false
    @State private var statusMessage = ""

    init(chat: Chat, credentials: AdminConsoleCredentials, currentUserID: UUID) {
        self.chat = chat
        self.credentials = credentials
        self.currentUserID = currentUserID
        _currentChat = State(initialValue: chat)
    }

    var body: some View {
        List {
            if currentChat.isAdminVerifiableCommunity {
                Section("settings.admin_console.verification".localized) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(currentChat.displayTitle(for: currentChat.participantIDs.first ?? currentChat.id))
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                if currentChat.communityDetails?.isOfficial == true {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }
                            }
                            Text(currentChat.adminVerificationStatusText)
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                await toggleOfficialBadge()
                            }
                        } label: {
                            if isUpdatingOfficialBadge {
                                ProgressView()
                            } else {
                                Text(
                                    currentChat.communityDetails?.isOfficial == true
                                        ? "settings.admin_console.verification.remove".localized
                                        : "settings.admin_console.verification.verify".localized
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if messages.isEmpty {
                Section {
                    Text(statusMessage.isEmpty ? "settings.admin_console.messages.empty".localized : statusMessage)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section("settings.admin_console.messages".localized) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(message.senderDisplayName ?? message.senderID.uuidString)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                Spacer()
                                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }

                            if let text = message.text, text.isEmpty == false {
                                Text(text)
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            } else {
                                Text(message.kind.rawValue.capitalized)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }

                            Text("\(message.deliveryState.rawValue.capitalized) · \(message.status.rawValue.capitalized)")
                                .font(.caption2)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(chat.displayTitle(for: chat.participantIDs.first ?? chat.id))
        .task {
            await loadMessages()
        }
    }

    @MainActor
    private func loadMessages() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }

        do {
            let payload = try await AdminConsoleService(baseURL: baseURL, credentials: credentials, currentUserID: currentUserID).fetchMessages(chatID: chat.id)
            currentChat = payload.chat ?? currentChat
            messages = payload.messages
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleOfficialBadge() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "auth.server.unavailable".localized
            return
        }
        guard currentChat.isAdminVerifiableCommunity else { return }

        isUpdatingOfficialBadge = true
        defer { isUpdatingOfficialBadge = false }

        do {
            currentChat = try await AdminConsoleService(
                baseURL: baseURL,
                credentials: credentials,
                currentUserID: currentUserID
            ).setOfficialBadge(
                chatID: currentChat.id,
                isOfficial: currentChat.communityDetails?.isOfficial != true
            )
            statusMessage = currentChat.communityDetails?.isOfficial == true
                ? "settings.admin_console.verification.enabled".localized
                : "settings.admin_console.verification.disabled".localized
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
