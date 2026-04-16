import SwiftUI
import WatchConnectivity
import Combine
import WatchKit

private enum PrimeWatchPalette {
    static let accent = Color(red: 0.78, green: 0.13, blue: 0.18)
    static let accentSoft = Color(red: 0.58, green: 0.10, blue: 0.15)
    static let card = Color.white.opacity(0.08)
    static let bubbleOutgoing = Color(red: 0.58, green: 0.14, blue: 0.20)
    static let bubbleIncoming = Color.white.opacity(0.08)
}

struct WatchHomeView: View {
    @EnvironmentObject private var syncStore: PrimeWatchSyncStore
    @State private var loginIdentifier = ""
    @State private var loginPassword = ""
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            Group {
                if syncStore.shouldShowStandaloneLogin {
                    standaloneLoginView
                } else if syncStore.visibleChats.isEmpty {
                    emptyChatsState
                } else {
                    List {
                        Section {
                            modeSwitcher
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                        }

                        Section("Chats") {
                            ForEach(syncStore.visibleChats) { chat in
                                NavigationLink {
                                    WatchChatDetailView(chat: chat)
                                        .environmentObject(syncStore)
                                } label: {
                                    WatchChatRow(chat: chat)
                                }
                            }
                        }
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle("Prime")
            .task {
                await syncStore.refreshForCurrentMode()
            }
        }
    }

    private var standaloneLoginView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                brandHeader

                Text("Sign in to Prime on watch")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                TextField("Username / email / phone", text: $loginIdentifier)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $loginPassword)

                Button {
                    Task {
                        guard isSigningIn == false else { return }
                        isSigningIn = true
                        defer { isSigningIn = false }
                        await syncStore.signInStandalone(
                            identifier: loginIdentifier,
                            password: loginPassword
                        )
                    }
                } label: {
                    HStack {
                        if isSigningIn {
                            ProgressView()
                        }
                        Text(isSigningIn ? "Signing in..." : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimeWatchPalette.accent)
                .disabled(loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loginPassword.isEmpty || isSigningIn)

                if let message = syncStore.standaloneStatusMessage {
                    Text(message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 4)
                }

                statusCard(
                    title: "Autonomous mode",
                    systemName: "network",
                    subtitle: "After login, watch works directly through internet using app server config."
                )
            }
            .padding(12)
        }
    }

    private var emptyChatsState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                modeSwitcher
                statusCard(
                    title: syncStore.isCompanionReachable ? "Connected to iPhone" : "No chats in this mode",
                    systemName: syncStore.isCompanionReachable ? "applewatch.radiowaves.left.and.right" : "iphone.slash",
                    subtitle: syncStore.isCompanionReachable
                        ? "Switch mode or open a chat on iPhone once to sync."
                        : "Open Prime Messaging on iPhone once to sync online chats."
                )
                statusCard(
                    title: "Offline stays local",
                    systemName: "tray.full.fill",
                    subtitle: "Offline mode keeps local history on watch even when iPhone is away."
                )
            }
            .padding(12)
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            modeButton(.online, title: "Online")
            modeButton(.offline, title: "Offline")
        }
        .padding(6)
        .background(
            Capsule(style: .continuous)
                .fill(PrimeWatchPalette.card)
        )
    }

    private func modeButton(_ mode: WatchChatModeFilter, title: String) -> some View {
        Button {
            syncStore.selectChatMode(mode)
            Task { await syncStore.refreshForCurrentMode() }
        } label: {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(syncStore.selectedChatMode == mode ? .white : .white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(syncStore.selectedChatMode == mode ? PrimeWatchPalette.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prime Messaging")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(syncStore.accountDisplayName.nilIfEmpty ?? "Messaging on your wrist.")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [PrimeWatchPalette.accent, PrimeWatchPalette.accentSoft],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private func statusCard(title: String, systemName: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PrimeWatchPalette.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.06)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PrimeWatchPalette.card)
        )
    }
}

private struct WatchChatRow: View {
    let chat: PrimeWatchChatSnapshot

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(PrimeWatchPalette.card)
                    .frame(width: 34, height: 34)
                Image(systemName: chat.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PrimeWatchPalette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chat.title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }

                Text(chat.preview)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(chat.lastActivityAt, style: .time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                if chat.unreadCount > 0 {
                    Text("\(min(chat.unreadCount, 99))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeWatchPalette.accent)
                        )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WatchChatDetailView: View {
    let chat: PrimeWatchChatSnapshot

    @EnvironmentObject private var syncStore: PrimeWatchSyncStore
    @State private var customReply = ""
    @State private var isSending = false

    private let quickReplies = ["On my way", "Seen", "Call me", "Yes", "No", "👍"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard

                ForEach(chat.messages) { message in
                    messageBubble(message)
                }

                replyComposer

                Button {
                    Task {
                        await syncStore.requestOpenOnPhone(chat: chat)
                    }
                } label: {
                    Label("Open on iPhone", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(PrimeWatchPalette.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .navigationTitle(chat.title)
        .task {
            await syncStore.ensureMessages(for: chat.id)
        }
    }

    private var headerCard: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PrimeWatchPalette.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(chat.subtitle.nilIfEmpty ?? chat.preview)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PrimeWatchPalette.card)
        )
    }

    private func messageBubble(_ message: PrimeWatchMessageSnapshot) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
            Text(message.senderName)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))

            Text(message.summary)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(message.isOutgoing ? PrimeWatchPalette.bubbleOutgoing : PrimeWatchPalette.bubbleIncoming)
                )

            Text(message.createdAt, style: .time)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Reply")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickReplies, id: \.self) { reply in
                        Button(reply) {
                            Task {
                                await send(reply)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(PrimeWatchPalette.accent)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Reply", text: $customReply)
                    .textInputAutocapitalization(.sentences)

                Button {
                    Task {
                        await send(customReply)
                    }
                } label: {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                    }
                }
                .disabled(customReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .tint(PrimeWatchPalette.accent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PrimeWatchPalette.card)
        )
    }

    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard isSending == false else { return }
        isSending = true
        defer { isSending = false }

        let didSend = await syncStore.sendReply(trimmed, in: chat)
        if didSend {
            customReply = ""
        }
    }
}

private struct PrimeWatchSyncPayload: Codable {
    var generatedAt: Date
    var accountDisplayName: String
    var chats: [PrimeWatchChatSnapshot]
}

struct PrimeWatchChatSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var modeRawValue: String
    var title: String
    var subtitle: String
    var preview: String
    var unreadCount: Int
    var isMuted: Bool
    var symbolName: String
    var lastActivityAt: Date
    var messages: [PrimeWatchMessageSnapshot]
}

struct PrimeWatchMessageSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var senderName: String
    var summary: String
    var isOutgoing: Bool
    var createdAt: Date
}

private struct PrimeWatchReplyRequest: Codable {
    var chatID: UUID
    var modeRawValue: String
    var text: String
}

private struct PrimeWatchOpenChatRequest: Codable {
    var chatID: UUID
    var modeRawValue: String
}

private struct PrimeWatchModeRequest: Codable {
    var modeRawValue: String
}

private struct PrimeWatchLoginRequest: Encodable {
    var identifier: String
    var password: String
}

private struct PrimeWatchAuthSessionResponse: Decodable {
    var user: PrimeWatchAuthUser
    var session: PrimeWatchAuthSession
}

private struct PrimeWatchAuthUser: Decodable {
    var id: UUID
    var profile: PrimeWatchAuthProfile
}

private struct PrimeWatchAuthProfile: Decodable {
    var displayName: String?
}

private struct PrimeWatchAuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date
    var refreshTokenExpiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessTokenExpiresAt = "access_token_expires_at"
        case refreshTokenExpiresAt = "refresh_token_expires_at"
    }
}

private struct PrimeWatchChatNetworkModel: Decodable {
    var id: UUID
    var mode: String
    var type: String
    var title: String
    var subtitle: String
    var lastMessagePreview: String?
    var lastActivityAt: Date
    var unreadCount: Int
}

private struct PrimeWatchMessageNetworkModel: Decodable {
    var id: UUID
    var senderID: UUID
    var senderDisplayName: String
    var text: String?
    var kind: String
    var createdAt: Date
}

enum PrimeWatchDataMode: String, Codable {
    case standalone
    case companion
}

enum WatchChatModeFilter: String, Codable {
    case online
    case offline
}

@MainActor
final class PrimeWatchSyncStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var accountDisplayName = ""
    @Published private(set) var chats: [PrimeWatchChatSnapshot] = []
    @Published private(set) var isCompanionReachable = false
    @Published private(set) var standaloneStatusMessage: String?
    @Published private(set) var mode: PrimeWatchDataMode = .companion
    @Published private(set) var selectedChatMode: WatchChatModeFilter = .online

    var shouldShowStandaloneLogin: Bool {
        mode == .standalone && standaloneSession == nil
    }

    var visibleChats: [PrimeWatchChatSnapshot] {
        chats
            .filter { chat in
                let modeValue = WatchChatModeFilter(rawValue: chat.modeRawValue.lowercased()) ?? .online
                return modeValue == selectedChatMode
            }
            .sorted {
                if $0.unreadCount != $1.unreadCount {
                    return $0.unreadCount > $1.unreadCount
                }
                return $0.lastActivityAt > $1.lastActivityAt
            }
    }

    private enum Keys {
        static let persistedPayload = "prime_watch.persisted_payload"
        static let payload = "prime_watch_payload"
        static let reply = "prime_watch_reply"
        static let openChat = "prime_watch_open_chat"
        static let mode = "prime_watch_mode"
        static let selectedChatMode = "prime_watch.selected_chat_mode"
        static let standaloneSession = "prime_watch.standalone.session"
        static let standaloneUserID = "prime_watch.standalone.user_id"
        static let standaloneUserName = "prime_watch.standalone.user_name"
        static let standaloneMode = "prime_watch.standalone.mode"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var standaloneSession: PrimeWatchAuthSession?
    private var standaloneUserID: UUID?
    private var standaloneUserName: String?

    override init() {
        super.init()
        configureCodecs()
        restoreStandaloneState()
        loadPersistedPayload()
        activate()
        switchToStandaloneIfPossible()
    }

    func selectChatMode(_ mode: WatchChatModeFilter) {
        guard selectedChatMode != mode else { return }
        selectedChatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.selectedChatMode)
        if self.mode == .companion {
            Task {
                await requestCompanionModeSync(mode)
            }
        }
    }

    func sendReply(_ text: String, in chat: PrimeWatchChatSnapshot) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        if mode == .standalone {
            return await sendStandaloneReply(trimmed, in: chat)
        }

        let request = PrimeWatchReplyRequest(chatID: chat.id, modeRawValue: selectedChatMode.rawValue, text: trimmed)
        guard let data = try? encoder.encode(request) else { return false }

        optimisticAppendOutgoingMessage(trimmed, to: chat.id)
        persistCurrentChatState()

        if selectedChatMode == .offline {
            if WCSession.isSupported() {
                WCSession.default.transferUserInfo([Keys.reply: data])
            }
            return true
        }

        guard isCompanionReachable else {
            standaloneStatusMessage = "Online send requires iPhone sync."
            return false
        }

        if await sendImmediateMessage([Keys.reply: data]) {
            return true
        }

        standaloneStatusMessage = "Send failed. Keep iPhone nearby."
        return false
    }

    func requestOpenOnPhone(chat: PrimeWatchChatSnapshot) async {
        if mode == .standalone {
            standaloneStatusMessage = "Open on iPhone works only in companion mode."
            return
        }
        let request = PrimeWatchOpenChatRequest(chatID: chat.id, modeRawValue: chat.modeRawValue)
        guard let data = try? encoder.encode(request) else { return }
        if await sendImmediateMessage([Keys.openChat: data]) {
            return
        }
        WCSession.default.transferUserInfo([Keys.openChat: data])
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isCompanionReachable = session.isReachable
    }

    func refreshForCurrentMode() async {
        if mode == .standalone {
            await refreshStandaloneChats()
        } else {
            standaloneStatusMessage = nil
            await requestCompanionModeSync(selectedChatMode)
        }
    }

    func signInStandalone(identifier: String, password: String) async {
        guard let baseURL = backendBaseURL else {
            standaloneStatusMessage = "Server URL missing in app config."
            return
        }
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedIdentifier.isEmpty == false, password.isEmpty == false else {
            standaloneStatusMessage = "Enter identifier and password."
            return
        }

        let requestBody = PrimeWatchLoginRequest(identifier: trimmedIdentifier, password: password)
        guard let url = URL(string: "/auth/login", relativeTo: baseURL) else {
            standaloneStatusMessage = "Invalid server URL."
            return
        }

        do {
            let (data, response) = try await request(
                url: url,
                method: "POST",
                body: requestBody,
                auth: nil
            )
            try validateSuccess(response: response, data: data)
            let payload = try decoder.decode(PrimeWatchAuthSessionResponse.self, from: data)
            standaloneSession = payload.session
            standaloneUserID = payload.user.id
            standaloneUserName = payload.user.profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            mode = .standalone
            persistStandaloneState()
            standaloneStatusMessage = nil
            await refreshStandaloneChats()
        } catch {
            standaloneStatusMessage = "Sign in failed. Check credentials/server."
        }
    }

    private func loadPersistedPayload() {
        guard let data = UserDefaults.standard.data(forKey: Keys.persistedPayload),
              let payload = try? decoder.decode(PrimeWatchSyncPayload.self, from: data) else { return }
        apply(payload)
    }

    private func persist(_ payload: PrimeWatchSyncPayload) {
        guard let data = try? encoder.encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Keys.persistedPayload)
    }

    private func persistCurrentChatState() {
        let payload = PrimeWatchSyncPayload(
            generatedAt: .now,
            accountDisplayName: accountDisplayName,
            chats: chats
        )
        persist(payload)
    }

    private func apply(_ payload: PrimeWatchSyncPayload) {
        accountDisplayName = payload.accountDisplayName
        chats = payload.chats
    }

    private func optimisticAppendOutgoingMessage(_ text: String, to chatID: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        var chat = chats[index]
        let message = PrimeWatchMessageSnapshot(
            id: UUID(),
            senderName: "You",
            summary: text,
            isOutgoing: true,
            createdAt: .now
        )
        chat.messages.append(message)
        chat.preview = text
        chat.lastActivityAt = .now
        chats[index] = chat
        persistCurrentChatState()
    }

    private func switchToStandaloneIfPossible() {
        guard standaloneSession != nil, standaloneUserID != nil else { return }
        mode = .standalone
        if let standaloneUserName, standaloneUserName.isEmpty == false {
            accountDisplayName = standaloneUserName
        }
    }

    private func restoreStandaloneState() {
        if let chatModeRaw = UserDefaults.standard.string(forKey: Keys.selectedChatMode),
           let storedChatMode = WatchChatModeFilter(rawValue: chatModeRaw) {
            selectedChatMode = storedChatMode
        }
        if let modeRaw = UserDefaults.standard.string(forKey: Keys.standaloneMode),
           let storedMode = PrimeWatchDataMode(rawValue: modeRaw) {
            mode = storedMode
        }
        if let data = UserDefaults.standard.data(forKey: Keys.standaloneSession),
           let session = try? decoder.decode(PrimeWatchAuthSession.self, from: data) {
            standaloneSession = session
        }
        if let userIDString = UserDefaults.standard.string(forKey: Keys.standaloneUserID) {
            standaloneUserID = UUID(uuidString: userIDString)
        }
        standaloneUserName = UserDefaults.standard.string(forKey: Keys.standaloneUserName)
    }

    private func persistStandaloneState() {
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.standaloneMode)
        if let standaloneSession, let data = try? encoder.encode(standaloneSession) {
            UserDefaults.standard.set(data, forKey: Keys.standaloneSession)
        }
        if let standaloneUserID {
            UserDefaults.standard.set(standaloneUserID.uuidString, forKey: Keys.standaloneUserID)
        }
        if let standaloneUserName {
            UserDefaults.standard.set(standaloneUserName, forKey: Keys.standaloneUserName)
        }
    }

    private var backendBaseURL: URL? {
        let candidate = (Bundle.main.object(forInfoDictionaryKey: "PrimeMessagingServerURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard candidate.isEmpty == false else { return nil }
        return URL(string: candidate)
    }

    private func refreshStandaloneChats() async {
        guard mode == .standalone else { return }
        guard let baseURL = backendBaseURL, let userID = standaloneUserID, let session = standaloneSession else {
            standaloneStatusMessage = "Sign in required on watch."
            return
        }
        guard var components = URLComponents(url: baseURL.appending(path: "/chats"), resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "mode", value: selectedChatMode.rawValue)]
        guard let url = components.url else { return }

        do {
            let (data, response) = try await request(url: url, method: "GET", body: Optional<Data>.none, auth: session.accessToken)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                if await refreshStandaloneSession(baseURL: baseURL, userID: userID) {
                    await refreshStandaloneChats()
                    return
                }
            }
            try validateSuccess(response: response, data: data)
            let serverChats = try decoder.decode([PrimeWatchChatNetworkModel].self, from: data)
            chats = serverChats
                .map { item in
                    PrimeWatchChatSnapshot(
                        id: item.id,
                        modeRawValue: item.mode.nilIfEmpty ?? selectedChatMode.rawValue,
                        title: item.title,
                        subtitle: item.subtitle,
                        preview: item.lastMessagePreview?.nilIfEmpty ?? "No messages yet",
                        unreadCount: item.unreadCount,
                        isMuted: false,
                        symbolName: symbol(for: item.type),
                        lastActivityAt: item.lastActivityAt,
                        messages: []
                    )
                }
            persistCurrentChatState()
            standaloneStatusMessage = nil
            if let standaloneUserName, standaloneUserName.isEmpty == false {
                accountDisplayName = standaloneUserName
            }
        } catch {
            standaloneStatusMessage = "Failed to load chats from server."
        }
    }

    func ensureMessages(for chatID: UUID) async {
        guard mode == .standalone else { return }
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        guard let baseURL = backendBaseURL, let session = standaloneSession else { return }
        guard var components = URLComponents(url: baseURL.appending(path: "/messages"), resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "chat_id", value: chatID.uuidString)]
        guard let url = components.url else { return }

        do {
            let (data, response) = try await request(url: url, method: "GET", body: Optional<Data>.none, auth: session.accessToken)
            if (response as? HTTPURLResponse)?.statusCode == 401, let userID = standaloneUserID {
                if await refreshStandaloneSession(baseURL: baseURL, userID: userID) {
                    await ensureMessages(for: chatID)
                    return
                }
            }
            try validateSuccess(response: response, data: data)
            let serverMessages = try decoder.decode([PrimeWatchMessageNetworkModel].self, from: data)
            let currentUserID = standaloneUserID
            chats[index].messages = serverMessages.suffix(40).map { message in
                PrimeWatchMessageSnapshot(
                    id: message.id,
                    senderName: message.senderDisplayName.nilIfEmpty ?? "User",
                    summary: message.text?.nilIfEmpty ?? fallbackSummary(for: message.kind),
                    isOutgoing: currentUserID.map { $0 == message.senderID } ?? false,
                    createdAt: message.createdAt
                )
            }
            if let last = chats[index].messages.last {
                chats[index].preview = last.summary
                chats[index].lastActivityAt = last.createdAt
            }
            persistCurrentChatState()
        } catch {
            standaloneStatusMessage = "Failed to load messages."
        }
    }

    private func sendStandaloneReply(_ text: String, in chat: PrimeWatchChatSnapshot) async -> Bool {
        guard let baseURL = backendBaseURL, let senderID = standaloneUserID, let session = standaloneSession else {
            standaloneStatusMessage = "Sign in required on watch."
            return false
        }
        struct SendBody: Encodable {
            let chat_id: String
            let sender_id: String
            let sender_display_name: String
            let mode: String
            let kind: String
            let text: String
            let attachments: [String]
        }
        let body = SendBody(
            chat_id: chat.id.uuidString,
            sender_id: senderID.uuidString,
            sender_display_name: standaloneUserName?.nilIfEmpty ?? "You",
            mode: selectedChatMode.rawValue,
            kind: "text",
            text: text,
            attachments: []
        )
        guard let url = URL(string: "/messages/send", relativeTo: baseURL) else { return false }

        do {
            let (data, response) = try await request(url: url, method: "POST", body: body, auth: session.accessToken)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                if await refreshStandaloneSession(baseURL: baseURL, userID: senderID) {
                    return await sendStandaloneReply(text, in: chat)
                }
            }
            try validateSuccess(response: response, data: data)
            optimisticAppendOutgoingMessage(text, to: chat.id)
            return true
        } catch {
            standaloneStatusMessage = "Message send failed."
            return false
        }
    }

    private func refreshStandaloneSession(baseURL: URL, userID: UUID) async -> Bool {
        guard let session = standaloneSession else { return false }
        struct RefreshRequest: Encodable { let refresh_token: String }
        guard let url = URL(string: "/auth/refresh", relativeTo: baseURL) else { return false }
        do {
            let (data, response) = try await request(url: url, method: "POST", body: RefreshRequest(refresh_token: session.refreshToken), auth: nil)
            try validateSuccess(response: response, data: data)
            let payload = try decoder.decode(PrimeWatchAuthSessionResponse.self, from: data)
            standaloneSession = payload.session
            standaloneUserID = userID
            persistStandaloneState()
            return true
        } catch {
            return false
        }
    }

    private func request<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?,
        auth: String?
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 16
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("watchos", forHTTPHeaderField: "X-Prime-Platform")
        request.setValue(WKInterfaceDevice.current().name, forHTTPHeaderField: "X-Prime-Device-Name")
        request.setValue(WKInterfaceDevice.current().model, forHTTPHeaderField: "X-Prime-Device-Model")
        request.setValue("watchOS", forHTTPHeaderField: "X-Prime-OS-Name")
        request.setValue(WKInterfaceDevice.current().systemVersion, forHTTPHeaderField: "X-Prime-OS-Version")
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            request.setValue(appVersion, forHTTPHeaderField: "X-Prime-App-Version")
        }
        if let auth {
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return try await URLSession.shared.data(for: request)
    }

    private func validateSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = payload["error"] as? String {
                throw NSError(domain: "PrimeWatchBackend", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            throw NSError(domain: "PrimeWatchBackend", code: http.statusCode)
        }
    }

    private func configureCodecs() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let parsed = formatter.date(from: value) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date: \(value)")
        }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
    }

    private func symbol(for type: String) -> String {
        switch type {
        case "group": return "person.3.fill"
        case "direct": return "person.fill"
        default: return "bubble.left.and.bubble.right.fill"
        }
    }

    private func fallbackSummary(for kind: String) -> String {
        switch kind {
        case "voice": return "Voice message"
        case "file": return "File"
        case "photo": return "Photo"
        case "video": return "Video"
        case "location": return "Location"
        case "poll": return "Poll"
        default: return "Message"
        }
    }

    private func sendImmediateMessage(_ payload: [String: Any]) async -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.isReachable else { return false }

        return await withCheckedContinuation { continuation in
            session.sendMessage(payload, replyHandler: { _ in
                continuation.resume(returning: true)
            }, errorHandler: { _ in
                continuation.resume(returning: false)
            })
        }
    }

    private func requestCompanionModeSync(_ mode: WatchChatModeFilter) async {
        guard WCSession.isSupported() else { return }
        let request = PrimeWatchModeRequest(modeRawValue: mode.rawValue)
        guard let data = try? encoder.encode(request) else { return }
        if await sendImmediateMessage([Keys.mode: data]) {
            return
        }
        WCSession.default.transferUserInfo([Keys.mode: data])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            isCompanionReachable = session.isReachable
            guard mode == .companion else { return }
            if let payloadData = session.receivedApplicationContext[Keys.payload] as? Data,
               let payload = try? decoder.decode(PrimeWatchSyncPayload.self, from: payloadData) {
                persist(payload)
                apply(payload)
            }
            if let error {
                NSLog("PrimeWatchSyncStore activation error: %@", error.localizedDescription)
            }
            _ = activationState
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isCompanionReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in
            guard mode == .companion else { return }
            guard let payloadData = applicationContext[Keys.payload] as? Data,
                  let payload = try? decoder.decode(PrimeWatchSyncPayload.self, from: payloadData) else { return }
            persist(payload)
            apply(payload)
            isCompanionReachable = session.isReachable
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    WatchHomeView()
        .environmentObject(PrimeWatchSyncStore())
}
