import Foundation
import SwiftUI

struct ContactProfileView: View {
    private enum SharedSectionTab: CaseIterable, Identifiable {
        case media
        case files
        case voices
        case links

        var id: String { title }

        var title: String {
            switch self {
            case .media:
                return "common.media".localized
            case .files:
                return "common.files".localized
            case .voices:
                return "common.voices".localized
            case .links:
                return "common.links".localized
            }
        }

        var contentKind: SharedChatContentKind? {
            switch self {
            case .media:
                return .media
            case .files:
                return .files
            case .voices:
                return .voices
            case .links:
                return nil
            }
        }
    }

    private enum ChatClearScope {
        case forMe
        case forEveryone
    }

    private struct SharedLinkEntry: Identifiable, Hashable {
        let id: String
        let url: URL
        let messageDate: Date
        let senderID: UUID
    }

    let user: User
    var chatBinding: Binding<Chat>? = nil
    var onRequestSearch: (() -> Void)? = nil

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var internetCallManager = InternetCallManager.shared
    @FocusState private var isAliasFieldFocused: Bool
    @State private var localContactName = ""
    @State private var isContactAdded = false
    @State private var isSavingContact = false
    @State private var isShowingEditContactScreen = false
    @State private var callStatusMessage = ""
    @State private var soundMode: ChatMuteState = .active
    @State private var isUserBlocked = false
    @State private var isApplyingMoreAction = false
    @State private var selectedSharedSection: SharedSectionTab = .media
    @State private var sharedLinkEntries: [SharedLinkEntry] = []
    @State private var isLoadingSharedLinks = false
    @State private var isShowingClearChatOptions = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar

                VStack(spacing: 8) {
                    AvatarBadgeView(profile: visibleProfile, size: 104)
                    Text(displayName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(statusLine)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                actionRow

                if !callStatusMessage.isEmpty {
                    Text(callStatusMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                if user.id != appState.currentUser.id && isContactAdded == false {
                    contactCard
                }

                VStack(spacing: 12) {
                    if visibleEmail != nil {
                        infoCard(title: "profile.email".localized, value: visibleEmail ?? "common.private".localized)
                    }

                    if let visibleBirthday {
                        infoCard(title: "profile.birthday".localized, value: visibleBirthday)
                    }

                    infoCard(title: "profile.username".localized, value: "@\(user.profile.username)")
                }

                if chatBinding != nil {
                    sharedContentSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: user.id) {
            await loadContactState()
            syncSoundModeFromChat()
            await refreshBlockedState()
        }
        .navigationDestination(isPresented: $isShowingEditContactScreen) {
            ContactEditScreen(
                user: user,
                initialDisplayName: localContactName
            ) { updatedName in
                try await saveEditedContact(name: updatedName)
            } onDelete: {
                try await deleteContactAlias()
            }
        }
        .onChange(of: chatBinding?.wrappedValue.notificationPreferences.muteState) { _ in
            syncSoundModeFromChat()
        }
        .confirmationDialog(
            "contact.profile.more.clear_chat".localized,
            isPresented: $isShowingClearChatOptions,
            titleVisibility: .visible
        ) {
            Button("contact.profile.more.clear_chat_for_me".localized, role: .destructive) {
                Task {
                    await clearChatHistory(for: .forMe)
                }
            }
            Button("contact.profile.more.clear_chat_for_everyone".localized, role: .destructive) {
                Task {
                    await clearChatHistory(for: .forEveryone)
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        }
    }

    private var headerBar: some View {
        HStack {
            profileCircleButton(systemName: "chevron.left") {
                dismiss()
            }

            Spacer()

            if user.id != appState.currentUser.id {
                Button {
                    isShowingEditContactScreen = true
                } label: {
                    actionHeaderButton(title: "common.edit".localized, systemName: "pencil")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            profileActionButton(title: "common.call".localized, systemName: "phone.fill", action: startCall)
            soundMenuButton
            profileActionButton(title: "common.search".localized, systemName: "magnifyingglass") {
                onRequestSearch?()
            }
            moreMenuButton
        }
    }

    private var soundMenuButton: some View {
        Menu {
            if soundMode != .active {
                Button("chat.sound.turn_on".localized) {
                    applySoundMode(.active, message: "chat.sound.enabled".localized)
                }
            } else {
                Button("chat.sound.turn_off_hour".localized) {
                    applySoundMode(.mutedTemporarily, message: "chat.sound.muted_temporarily".localized)
                }

                Button("chat.sound.turn_off".localized) {
                    applySoundMode(.mutedPermanently, message: "chat.sound.disabled".localized)
                }
            }

            if soundMode != .mutedPermanently {
                Button("chat.sound.disable_notifications".localized, role: .destructive) {
                    applySoundMode(.mutedPermanently, message: "chat.sound.notifications_disabled".localized)
                }
            }
        } label: {
            profileActionLabel(title: "common.sound".localized, systemName: soundMode == .active ? "bell.fill" : "bell.slash.fill")
        }
        .buttonStyle(.plain)
    }

    private var moreMenuButton: some View {
        Menu {
            if user.id != appState.currentUser.id {
                Button(
                    isUserBlocked
                        ? "contact.profile.more.unblock".localized
                        : "contact.profile.more.block".localized,
                    role: isUserBlocked ? nil : .destructive
                ) {
                    Task {
                        await toggleBlockedState()
                    }
                }
            }

            if isContactAdded {
                Button("contact.profile.more.delete_contact".localized, role: .destructive) {
                    Task {
                        await deleteContactFromMore()
                    }
                }
            }

            if chatBinding != nil {
                Button("contact.profile.more.clear_chat".localized, role: .destructive) {
                    isShowingClearChatOptions = true
                }
            }
        } label: {
            profileActionLabel(title: "common.more".localized, systemName: "ellipsis")
        }
        .buttonStyle(.plain)
        .disabled(isApplyingMoreAction)
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("contact.profile.add".localized)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            TextField("contact.profile.alias.placeholder".localized, text: $localContactName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($isAliasFieldFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PrimeTheme.Colors.background)
                )

            Button {
                Task {
                    await saveContact()
                }
            } label: {
                HStack {
                    if isSavingContact {
                        ProgressView()
                            .tint(Color.white)
                    }
                    Text(contactButtonTitle)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(PrimeTheme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingContact || trimmedLocalContactName.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sharedContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SharedSectionTab.allCases) { item in
                        Button {
                            selectedSharedSection = item
                        } label: {
                            Text(item.title)
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(selectedSharedSection == item ? Color.white : PrimeTheme.Colors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedSharedSection == item ? PrimeTheme.Colors.accent : PrimeTheme.Colors.elevated)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(
                                            selectedSharedSection == item
                                                ? Color.white.opacity(0.15)
                                                : PrimeTheme.Colors.separator.opacity(0.3),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            if let chat = chatBinding?.wrappedValue {
                if let kind = selectedSharedSection.contentKind {
                    SharedChatContentSectionView(chat: chat, kind: kind)
                } else {
                    linksSection
                        .task(id: linksTaskKey) {
                            await loadSharedLinks()
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sharedLinkEntries.isEmpty {
                Text(isLoadingSharedLinks ? "contact.shared.refreshing_links".localized : "contact.shared.no_links".localized)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sharedLinkEntries.enumerated()), id: \.element.id) { index, entry in
                        Link(destination: entry.url) {
                            HStack(spacing: 12) {
                                Image(systemName: "link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(PrimeTheme.Colors.accent.opacity(0.12))
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.url.host ?? entry.url.absoluteString)
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        .lineLimit(1)

                                    Text(entry.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        if index != sharedLinkEntries.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if isLoadingSharedLinks {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("common.refreshing".localized)
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
    }

    private var linksTaskKey: String {
        guard let chat = chatBinding?.wrappedValue else {
            return "links-none"
        }
        return "\(chat.id.uuidString)-\(chat.mode.rawValue)-\(selectedSharedSection.id)"
    }

    private var displayName: String {
        let trimmed = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.profile.username : trimmed
    }

    private var statusLine: String {
        let status = user.profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Last seen recently" : status
    }

    private var visibleEmail: String? {
        let email = user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, email.isEmpty == false else {
            return nil
        }
        return user.privacySettings.showEmail ? email : nil
    }

    private var visibleProfile: Profile {
        guard user.id != appState.currentUser.id else {
            return user.profile
        }

        var profile = user.profile
        if user.privacySettings.allowProfilePhoto == false {
            profile.profilePhotoURL = nil
        }
        return profile
    }

    private var visibleBirthday: String? {
        guard let birthday = user.profile.birthday else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .long
        return formatter.string(from: birthday)
    }

    private var trimmedLocalContactName: String {
        localContactName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCallUser: Bool {
        user.id != appState.currentUser.id
    }

    @MainActor
    private func loadContactState() async {
        let existingAlias = await ContactAliasStore.shared.alias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            username: user.profile.username
        )
        if let existingAlias, existingAlias.isEmpty == false {
            localContactName = existingAlias
            isContactAdded = true
            return
        }

        localContactName = displayName
        isContactAdded = false
    }

    @MainActor
    private func saveContact() async {
        let trimmedName = trimmedLocalContactName
        guard trimmedName.isEmpty == false else { return }

        isSavingContact = true
        defer { isSavingContact = false }

        await ContactAliasStore.shared.saveAlias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            remoteUsername: user.profile.username,
            localDisplayName: trimmedName
        )
        isContactAdded = true
        isAliasFieldFocused = false
        callStatusMessage = ""
    }

    private func startCall() {
        guard canCallUser else {
            callStatusMessage = "calls.error.invalid_operation".localized
            return
        }

        callStatusMessage = ""
        Task {
            do {
                try await internetCallManager.startOutgoingCall(to: user)
            } catch {
                callStatusMessage = (error as? LocalizedError)?.errorDescription ?? "calls.unavailable.start".localized
            }
        }
    }

    private var contactButtonTitle: String {
        "contact.profile.add".localized
    }

    @MainActor
    private func saveEditedContact(name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }

        await ContactAliasStore.shared.saveAlias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            remoteUsername: user.profile.username,
            localDisplayName: trimmedName
        )
        localContactName = trimmedName
        isContactAdded = true
    }

    @MainActor
    private func deleteContactAlias() async throws {
        await ContactAliasStore.shared.removeAlias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            username: user.profile.username
        )
        localContactName = displayName
        isContactAdded = false
    }

    @MainActor
    private func applySoundMode(_ newMode: ChatMuteState, message: String) {
        soundMode = newMode
        if let chatBinding {
            chatBinding.wrappedValue.notificationPreferences.muteState = newMode
            Task {
                await ChatThreadStateStore.shared.setMuteState(
                    newMode,
                    ownerUserID: appState.currentUser.id,
                    mode: chatBinding.wrappedValue.mode,
                    chatID: chatBinding.wrappedValue.id
                )
            }
        }
        callStatusMessage = message
    }

    @MainActor
    private func syncSoundModeFromChat() {
        if let chatBinding {
            soundMode = chatBinding.wrappedValue.notificationPreferences.muteState
        }
    }

    @MainActor
    private func refreshBlockedState() async {
        guard user.id != appState.currentUser.id else {
            isUserBlocked = false
            return
        }

        do {
            let blockedUsers = try await environment.authRepository.fetchBlockedUsers(for: appState.currentUser.id)
            isUserBlocked = blockedUsers.contains(where: { $0.id == user.id })
        } catch {
            isUserBlocked = false
        }
    }

    @MainActor
    private func toggleBlockedState() async {
        guard user.id != appState.currentUser.id else { return }

        isApplyingMoreAction = true
        defer { isApplyingMoreAction = false }

        do {
            if isUserBlocked {
                try await environment.authRepository.unblockUser(user.id, for: appState.currentUser.id)
                isUserBlocked = false
                callStatusMessage = "contact.profile.more.unblocked".localized
            } else {
                try await environment.authRepository.blockUser(user.id, for: appState.currentUser.id)
                isUserBlocked = true
                try? await deleteContactAlias()
                await clearChatHistory(for: .forMe, showStatusMessage: false)
                callStatusMessage = "contact.profile.more.blocked".localized
            }
        } catch {
            callStatusMessage = error.localizedDescription.isEmpty
                ? "contact.profile.more.action_failed".localized
                : error.localizedDescription
        }
    }

    @MainActor
    private func deleteContactFromMore() async {
        isApplyingMoreAction = true
        defer { isApplyingMoreAction = false }

        do {
            try await deleteContactAlias()
            callStatusMessage = "contact.profile.more.contact_deleted".localized
        } catch {
            callStatusMessage = error.localizedDescription.isEmpty
                ? "contact.profile.more.action_failed".localized
                : error.localizedDescription
        }
    }

    @MainActor
    private func clearChatHistory(for scope: ChatClearScope, showStatusMessage: Bool = true) async {
        guard let chatBinding else { return }

        isApplyingMoreAction = true
        defer { isApplyingMoreAction = false }

        let chat = chatBinding.wrappedValue
        if scope == .forEveryone {
            let failedDeletes = await clearChatForEveryone(chat: chat)
            await clearChatLocally(chat: chat)

            if showStatusMessage {
                callStatusMessage = failedDeletes == 0
                    ? "contact.profile.more.chat_cleared_everyone".localized
                    : "contact.profile.more.chat_cleared_everyone_partial".localized
            }
            return
        }

        await clearChatLocally(chat: chat)
        if showStatusMessage {
            callStatusMessage = "contact.profile.more.chat_cleared".localized
        }
    }

    @MainActor
    private func clearChatLocally(chat: Chat) async {
        for mode in ChatMode.allCases {
            await ChatSnapshotStore.shared.saveMessages([], chatID: chat.id, userID: appState.currentUser.id, mode: mode)
            await ChatThreadStateStore.shared.clearChat(
                ownerUserID: appState.currentUser.id,
                mode: mode,
                chatID: chat.id
            )
        }

        var updatedChat = chat
        updatedChat.lastMessagePreview = nil
        updatedChat.unreadCount = 0
        updatedChat.draft = nil
        chatBinding?.wrappedValue = updatedChat
        sharedLinkEntries = []
    }

    @MainActor
    private func clearChatForEveryone(chat: Chat) async -> Int {
        let fetchedMessages: [Message]
        if let remoteMessages = try? await environment.chatRepository.fetchMessages(chatID: chat.id, mode: chat.mode) {
            fetchedMessages = remoteMessages
        } else {
            fetchedMessages = await environment.chatRepository.cachedMessages(chatID: chat.id, mode: chat.mode)
        }
        let deletableMessages = fetchedMessages.filter { $0.isDeleted == false }

        var failedDeletes = 0
        for message in deletableMessages {
            do {
                _ = try await environment.chatRepository.deleteMessage(
                    message.id,
                    in: chat.id,
                    mode: chat.mode,
                    requesterID: appState.currentUser.id
                )
            } catch {
                failedDeletes += 1
            }
        }
        return failedDeletes
    }

    @MainActor
    private func loadSharedLinks() async {
        guard selectedSharedSection == .links else { return }
        guard let chat = chatBinding?.wrappedValue else {
            sharedLinkEntries = []
            return
        }

        isLoadingSharedLinks = true
        defer { isLoadingSharedLinks = false }

        let cachedMessages = await environment.chatRepository.cachedMessages(chatID: chat.id, mode: chat.mode)
        sharedLinkEntries = extractLinks(from: cachedMessages)

        guard chat.mode != .offline || NetworkUsagePolicy.hasReachableNetwork() else { return }
        guard let fetchedMessages = try? await environment.chatRepository.fetchMessages(chatID: chat.id, mode: chat.mode) else { return }
        sharedLinkEntries = extractLinks(from: fetchedMessages)
    }

    private func extractLinks(from messages: [Message]) -> [SharedLinkEntry] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        var entries: [SharedLinkEntry] = []
        var seenKeys = Set<String>()
        for message in messages where message.isDeleted == false {
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.isEmpty == false else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = detector.matches(in: text, options: [], range: range)
            for match in matches {
                guard let url = match.url else { continue }
                let dedupeKey = "\(message.id.uuidString)|\(url.absoluteString.lowercased())"
                guard seenKeys.insert(dedupeKey).inserted else { continue }
                entries.append(
                    SharedLinkEntry(
                        id: dedupeKey,
                        url: url,
                        messageDate: message.createdAt,
                        senderID: message.senderID
                    )
                )
            }
        }

        return entries.sorted { lhs, rhs in
            lhs.messageDate > rhs.messageDate
        }
    }

    @ViewBuilder
    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func profileActionButton(title: String, systemName: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            profileActionLabel(title: title, systemName: systemName)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func profileActionLabel(title: String, systemName: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(PrimeTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func profileCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(PrimeTheme.Colors.elevated)
                    .frame(width: 42, height: 42)
                Circle()
                    .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                    .frame(width: 42, height: 42)
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionHeaderButton(title: String, systemName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(PrimeTheme.Colors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct ContactEditScreen: View {
    let user: User
    let initialDisplayName: String
    let onSave: (String) async throws -> Void
    let onDelete: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var statusMessage = ""
    @State private var isSaving = false
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    editorHeaderButton(title: "Cancel", systemName: "xmark", isPrimary: false) {
                        dismiss()
                    }

                    Spacer(minLength: 12)

                    AvatarBadgeView(profile: user.profile, size: 72)

                    Spacer(minLength: 12)

                    editorHeaderButton(title: "Done", systemName: "checkmark", isPrimary: true) {
                        Task {
                            await save()
                        }
                    }
                    .disabled(combinedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isDeleting)
                }

                VStack(spacing: 14) {
                    editorFieldCard(title: "First Name", text: $firstName)
                    editorFieldCard(title: "Last Name", text: $lastName)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        await deleteContact()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isDeleting {
                            ProgressView()
                                .tint(Color.white)
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("Delete Contact")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.warning)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDeleting || isSaving)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let parts = initialDisplayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .map(String.init)
            firstName = parts.first ?? ""
            lastName = parts.count > 1 ? parts[1] : ""
        }
    }

    private var combinedName: String {
        [firstName.trimmingCharacters(in: .whitespacesAndNewlines), lastName.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @MainActor
    private func save() async {
        statusMessage = ""
        isSaving = true
        defer { isSaving = false }

        do {
            try await onSave(combinedName)
            dismiss()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the contact." : error.localizedDescription
        }
    }

    @MainActor
    private func deleteContact() async {
        statusMessage = ""
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await onDelete()
            dismiss()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not delete the contact." : error.localizedDescription
        }
    }

    @ViewBuilder
    private func editorFieldCard(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func editorHeaderButton(title: String, systemName: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(isPrimary ? Color.white : PrimeTheme.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(isPrimary ? PrimeTheme.Colors.accent : PrimeTheme.Colors.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isPrimary ? Color.clear : PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
