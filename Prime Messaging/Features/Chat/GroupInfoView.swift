#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
private typealias GroupPhotoPickerItem = PhotosPickerItem
#else
private struct GroupPhotoPickerItem: Hashable {}
#endif
import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct GroupInfoView: View {
    @Binding var chat: Chat
    var onRequestSearch: (() -> Void)? = nil
    var onGroupDeleted: (() -> Void)? = nil
    var onGroupLeft: (() -> Void)? = nil
    let forcedCommunityKind: CommunityKind?

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var groupCallManager = GroupInternetCallManager.shared

    @State private var title: String
    @State private var query = ""
    @State private var users: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var selectedPhotoItem: GroupPhotoPickerItem?
    @State private var statusMessage = ""
    @State private var isSavingTitle = false
    @State private var isAddingMembers = false
    @State private var removingMemberIDs = Set<UUID>()
    @State private var changingRoleMemberIDs = Set<UUID>()
    @State private var transferringOwnershipMemberIDs = Set<UUID>()
    @State private var isLeavingGroup = false
    @State private var selectedSection = "Users"
    @State private var selectedMemberProfile: User?
    @State private var soundMode: ChatMuteState = .active
    @State private var isShowingEditGroupScreen = false
    @State private var isShowingGroupCallRoom = false
    @State private var isStartingGroupCall = false
    @State private var moderationSettings = GroupModerationSettings()
    @State private var moderationEntryQuestionsText = ""
    @State private var isSavingModeration = false
    @State private var moderationDashboard = ModerationDashboard()
    @State private var isRefreshingModerationDashboard = false
    @State private var resolvingJoinRequestUserIDs = Set<UUID>()
    @State private var banningMemberIDs = Set<UUID>()
    @State private var unbanningUserIDs = Set<UUID>()
    @State private var isUpdatingOfficialBadge = false
    @State private var isUpdatingCommunitySettings = false
    @State private var publicHandleDraft = ""
    @State private var isSavingPublicHandle = false
    @State private var resolvedGroup: Group?
    @State private var resolvedCommunityDetails: CommunityChatDetails?

    init(
        chat: Binding<Chat>,
        onRequestSearch: (() -> Void)? = nil,
        onGroupDeleted: (() -> Void)? = nil,
        onGroupLeft: (() -> Void)? = nil,
        forcedCommunityKind: CommunityKind? = nil
    ) {
        _chat = chat
        self.onRequestSearch = onRequestSearch
        self.onGroupDeleted = onGroupDeleted
        self.onGroupLeft = onGroupLeft
        self.forcedCommunityKind = forcedCommunityKind
        _title = State(initialValue: chat.wrappedValue.group?.title ?? chat.wrappedValue.title)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar

                VStack(spacing: 8) {
                    GroupAvatarView(
                        title: presentedGroup?.title ?? chat.title,
                        photoURL: presentedGroup?.photoURL,
                        size: 104
                    )

                    HStack(spacing: 8) {
                        Text(presentedGroup?.title ?? chat.title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)

                        if presentedCommunityDetails?.isOfficial == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(PrimeTheme.Colors.accent)
                        }
                    }

                    Text(communityHeadlineText)
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)

                groupActionRow

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusMessageColor)
                        .multilineTextAlignment(.center)
                }

                groupSettingsCard
                inviteCard
                moderationCard

                sectionTabs

                if selectedSection == "Users" {
                    usersSection
                } else if selectedSection == "Topics" {
                    topicsSection
                } else {
                    placeholderSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: query) {
            await searchUsers()
        }
        .task {
            soundMode = chat.notificationPreferences.muteState
            resolvedGroup = preferredGroup(current: chat.group, fallback: resolvedGroup)
            resolvedCommunityDetails = chat.communityDetails ?? resolvedCommunityDetails
            if chat.mode != .offline {
                await refreshGroupMetadataFromRepository()
            }
            if chat.communityDetails == nil,
               let details = await CommunityChatMetadataStore.shared.details(ownerUserID: appState.currentUser.id, chatID: chat.id) {
                chat.communityDetails = details
                resolvedCommunityDetails = details
            }
            if chat.communityDetails == nil, chat.mode != .offline {
                await refreshCommunityDetailsFromRepository()
            }
            if let settings = await GroupModerationSettingsStore.shared.settings(ownerUserID: appState.currentUser.id, chatID: chat.id) {
                moderationSettings = settings
                moderationEntryQuestionsText = settings.entryQuestions.joined(separator: "\n")
                chat.moderationSettings = settings
            } else if let existing = chat.moderationSettings {
                moderationSettings = existing
                moderationEntryQuestionsText = existing.entryQuestions.joined(separator: "\n")
            }
            if canManageGroup {
                await refreshModerationDashboard()
            }
        }
        .task(id: selectedPhotoItem) {
            await uploadSelectedPhoto()
        }
        .onChange(of: chat.group?.title ?? chat.title) { newValue in
            title = newValue
        }
        .onChange(of: chat.notificationPreferences.muteState) { newValue in
            soundMode = newValue
        }
        .onChange(of: chat.group) { newValue in
            resolvedGroup = preferredGroup(current: newValue, fallback: resolvedGroup)
        }
        .onChange(of: chat.communityDetails) { newValue in
            if let newValue {
                resolvedCommunityDetails = newValue
                publicHandleDraft = newValue.publicHandle ?? ""
            }
        }
        .task {
            publicHandleDraft = chat.communityDetails?.publicHandle ?? resolvedCommunityDetails?.publicHandle ?? ""
        }
        .sheet(item: $selectedMemberProfile) { user in
            NavigationStack {
                ContactProfileView(user: user)
            }
            .presentationDetents([.large])
        }
        .navigationDestination(isPresented: $isShowingEditGroupScreen) {
            GroupEditScreen(
                title: chat.group?.title ?? chat.title,
                photoURL: chat.group?.photoURL,
                canDeleteGroup: isOwner,
                entityTitle: entityTitle,
                deleteTitle: deleteTitle
            ) { updatedTitle in
                try await saveTitle(updatedTitle)
            } onDelete: {
                try await deleteGroup()
            }
        }
        .navigationDestination(isPresented: $isShowingGroupCallRoom) {
            GroupCallRoomView(chat: chat)
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                headerCircleButton(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            if canManageGroup {
                Button {
                    isShowingEditGroupScreen = true
                } label: {
                    headerActionButton(title: "Edit", systemName: "pencil")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var groupActionRow: some View {
        HStack(spacing: 10) {
            actionButton(title: currentGroupCallButtonTitle, systemName: "phone.fill") {
                Task {
                    await startOrOpenGroupCall()
                }
            }
            .disabled(isStartingGroupCall)
            .frame(maxWidth: .infinity)

            soundMenuButton

            actionButton(title: "common.search".localized, systemName: "magnifyingglass") {
                onRequestSearch?()
                if onRequestSearch == nil {
                    statusMessage = "Chat search is only available from the chat screen."
                }
            }
            .frame(maxWidth: .infinity)

            moreMenuButton
        }
    }

    private var soundMenuButton: some View {
        Menu {
            if soundMode != .active {
                Button("Turn sound on") {
                    applySoundMode(.active, message: "Chat sound enabled.")
                }
            } else {
                Button("Turn off for 1 hour") {
                    applySoundMode(.mutedTemporarily, message: "Notifications muted for a while.")
                }

                Button("Turn off sound") {
                    applySoundMode(.mutedPermanently, message: "Chat sound disabled.")
                }
            }

            if soundMode != .mutedPermanently {
                Button("Disable notifications", role: .destructive) {
                    applySoundMode(.mutedPermanently, message: "Notifications disabled.")
                }
            }
        } label: {
            actionButtonLabel(
                title: "common.sound".localized,
                systemName: soundMode == .active ? "bell.fill" : "bell.slash.fill"
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var moreMenuButton: some View {
        Menu {
            Button("Show users") {
                selectedSection = "Users"
            }

            if showsTopicsSection {
                Button("Show topics") {
                    selectedSection = "Topics"
                }
            }

            Button("Show media") {
                selectedSection = "Media"
            }

            Button("Open call room") {
                isShowingGroupCallRoom = true
            }

            Button(copyEntityNameTitle) {
                #if os(tvOS)
                statusMessage = "Copy is unavailable on Apple TV."
                #else
                UIPasteboard.general.string = presentedGroup?.title ?? chat.title
                statusMessage = "\(entityTitle) name copied."
                #endif
            }
        } label: {
            actionButtonLabel(title: "common.more".localized, systemName: "ellipsis.circle")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var groupSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: "community.settings_title".localized, entityTitle))
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            Text(presentedGroup?.title ?? chat.title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let communityDetails = presentedCommunityDetails {
                VStack(alignment: .leading, spacing: 10) {
                    communityInfoRow(title: "Type", value: communityDetails.kind.title, systemName: communityDetails.symbolName)
                    communityInfoRow(title: "Visibility", value: communityDetails.isPublic ? "Public" : "Private", systemName: communityDetails.isPublic ? "globe" : "lock.fill")
                    if let publicLink {
                        communityInfoRow(title: "Public link", value: publicLink.absoluteString, systemName: "link")
                    }
                    communityInfoRow(title: "Threads", value: communityDetails.forumModeEnabled ? "Forum mode enabled" : "Linear chat", systemName: communityDetails.forumModeEnabled ? "text.bubble.fill" : "text.bubble")
                    communityInfoRow(title: "Replies", value: communityDetails.commentsEnabled ? "Comments enabled" : "Comments disabled", systemName: communityDetails.commentsEnabled ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                    if communityDetails.topics.isEmpty == false {
                        communityInfoRow(title: "Topics", value: "\(communityDetails.topics.count) seeded topic\(communityDetails.topics.count == 1 ? "" : "s")", systemName: "number")
                    }

                    if canManageGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Public username")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            TextField("your-group-name", text: $publicHandleDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                                )
                            if let publicLink {
                                Text(publicLink.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    #if !os(tvOS)
                                    .textSelection(.enabled)
                                    #endif
                            }
                            HStack(spacing: 10) {
                                Button {
                                    Task { await savePublicHandle() }
                                } label: {
                                    settingsPill(title: isSavingPublicHandle ? "Saving..." : "Save username")
                                }
                                .buttonStyle(.plain)
                                .disabled(isSavingPublicHandle)

                                if publicHandleDraft.isEmpty == false || communityDetails.publicHandle != nil {
                                    Button {
                                        publicHandleDraft = ""
                                        Task { await savePublicHandle() }
                                    } label: {
                                        settingsPill(title: "Clear")
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isSavingPublicHandle)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        await updateCommunitySettings { $0.commentsEnabled.toggle() }
                                    }
                                } label: {
                                    settingsPill(title: communityDetails.commentsEnabled ? "Disable comments" : "Enable comments")
                                }
                                .buttonStyle(.plain)
                                .disabled(isUpdatingCommunitySettings)

                                Button {
                                    Task {
                                        await updateCommunitySettings { $0.isPublic.toggle() }
                                    }
                                } label: {
                                    settingsPill(title: communityDetails.isPublic ? "Make private" : "Make public")
                                }
                                .buttonStyle(.plain)
                                .disabled(isUpdatingCommunitySettings)
                            }

                            Button {
                                Task {
                                    await updateCommunitySettings { $0.forumModeEnabled.toggle() }
                                }
                            } label: {
                                settingsPill(title: communityDetails.forumModeEnabled ? "Disable threads" : "Enable threads")
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdatingCommunitySettings)
                        }
                    }

                    if canManageOfficialBadge {
                        Button {
                            Task {
                                await toggleOfficialBadge()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isUpdatingOfficialBadge {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Color.white)
                                } else {
                                    Image(systemName: communityDetails.isOfficial ? "checkmark.seal.fill" : "checkmark.seal")
                                        .font(.system(size: 14, weight: .semibold))
                                }

                                Text(communityDetails.isOfficial ? "Remove official badge" : "Mark as official")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(PrimeTheme.Colors.accent)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingOfficialBadge)
                    }
                }
            }

            if canManageGroup {
                HStack(spacing: 10) {
                    #if canImport(PhotosUI) && !os(tvOS)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        settingsPill(title: "Avatar")
                    }
                    .buttonStyle(.plain)
                    #endif

                    if presentedGroup?.photoURL != nil {
                        Button {
                            Task {
                                await removeAvatar()
                            }
                        } label: {
                            settingsPill(title: "Remove")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    private var moderationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Moderation & Safety")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            if canManageGroup {
                Toggle("Require join approval", isOn: binding(\.requiresJoinApproval))
                Toggle("Enable anti-spam", isOn: binding(\.antiSpamEnabled))
                Toggle("Restrict links for \(audiencePluralTitle.lowercased())", isOn: binding(\.restrictLinks))
                Toggle("Restrict media for \(audiencePluralTitle.lowercased())", isOn: binding(\.restrictMedia))

                Picker("Slow mode", selection: Binding(
                    get: { moderationSettings.slowModeSeconds },
                    set: { moderationSettings.slowModeSeconds = $0 }
                )) {
                    Text("Off").tag(0)
                    Text("10s").tag(10)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome message")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    TextField("Welcome to the \(entityTitle.lowercased())", text: Binding(
                        get: { moderationSettings.welcomeMessage },
                        set: { moderationSettings.welcomeMessage = $0 }
                    ), axis: .vertical)
                    .lineLimit(2 ... 4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(PrimeTheme.Colors.background.opacity(0.45))
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(entityTitle) rules")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    TextField("Be respectful. No spam.", text: Binding(
                        get: { moderationSettings.rules },
                        set: { moderationSettings.rules = $0 }
                    ), axis: .vertical)
                    .lineLimit(3 ... 6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(PrimeTheme.Colors.background.opacity(0.45))
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Entry questions")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    TextField("Why do you want to join this \(entityTitle.lowercased())?\nHow did you find it?", text: $moderationEntryQuestionsText, axis: .vertical)
                        .lineLimit(3 ... 6)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(PrimeTheme.Colors.background.opacity(0.45))
                        )
                }

                Button {
                    Task {
                        await saveModerationSettings()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSavingModeration {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.white)
                        } else {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 14, weight: .semibold))
                        }

                        Text("Save moderation")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSavingModeration)

                moderationDashboardManagerSection
            } else if let activeModeration = chat.moderationSettings, activeModeration.hasActiveProtection {
                if let rules = activeModeration.normalizedRules {
                    moderationReadOnlyBlock(title: "Rules", text: rules)
                }
                if let welcome = activeModeration.normalizedWelcomeMessage {
                    moderationReadOnlyBlock(title: "Welcome", text: welcome)
                }
                if activeModeration.normalizedEntryQuestions.isEmpty == false {
                    moderationReadOnlyBlock(
                        title: "Entry questions",
                        text: activeModeration.normalizedEntryQuestions.joined(separator: "\n")
                    )
                }
                if let moderationStatus = chat.moderationStatusText() {
                    Text(moderationStatus)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            } else {
                Text("No active moderation rules.")
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
    private var moderationDashboardManagerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Requests, reports & bans")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                Spacer()

                if isRefreshingModerationDashboard {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh") {
                        Task {
                            await refreshModerationDashboard()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.accent)
                }
            }

            if moderationDashboard.pendingJoinRequests.isEmpty,
               moderationDashboard.reports.isEmpty,
               moderationDashboard.activeBans.isEmpty,
               isRefreshingModerationDashboard == false {
                Text("No pending join requests, reports, or bans.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            } else {
                if moderationDashboard.pendingJoinRequests.isEmpty == false {
                    moderationJoinRequestsSection
                }
                if moderationDashboard.reports.isEmpty == false {
                    moderationReportsSection
                }
                if moderationDashboard.activeBans.isEmpty == false {
                    moderationBansSection
                }
            }
        }
        .padding(.top, 4)
    }

    private var moderationJoinRequestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Join requests")
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            ForEach(moderationDashboard.pendingJoinRequests) { request in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AvatarBadgeView(
                            profile: Profile(
                                displayName: request.requesterDisplayName ?? request.requesterUsername ?? "User",
                                username: request.requesterUsername ?? "primeuser",
                                bio: "",
                                status: "",
                                birthday: nil,
                                email: nil,
                                phoneNumber: nil,
                                profilePhotoURL: nil,
                                socialLink: nil
                            ),
                            size: 34
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.requesterDisplayName ?? request.requesterUsername ?? "User")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            if let username = request.requesterUsername, username.isEmpty == false {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                        }

                        Spacer()

                        Text(request.createdAt.formatted(.dateTime.day().month().hour().minute()))
                            .font(.caption2)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }

                    if request.answers.isEmpty == false {
                        moderationReadOnlyBlock(
                            title: "Answers",
                            text: request.answers.joined(separator: "\n")
                        )
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await resolve(request: request, approve: false)
                            }
                        } label: {
                            Text("Decline")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimeTheme.Colors.warning)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(PrimeTheme.Colors.warning.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvingJoinRequestUserIDs.contains(request.requesterUserID))

                        Button {
                            Task {
                                await resolve(request: request, approve: true)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if resolvingJoinRequestUserIDs.contains(request.requesterUserID) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Color.white)
                                }
                                Text("Approve")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(PrimeTheme.Colors.accent)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvingJoinRequestUserIDs.contains(request.requesterUserID))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                )
            }
        }
    }

    private var moderationReportsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent reports")
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            ForEach(moderationDashboard.reports.prefix(6)) { report in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(report.reason.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PrimeTheme.Colors.warning)
                        Spacer()
                        Text(report.createdAt.formatted(.dateTime.day().month().hour().minute()))
                            .font(.caption2)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }

                    Text(report.reporterDisplayName ?? report.reporterUsername ?? "Reporter")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)

                    if let preview = report.targetPreview, preview.isEmpty == false {
                        moderationReadOnlyBlock(title: "Preview", text: preview)
                    }

                    if let details = report.details, details.isEmpty == false {
                        moderationReadOnlyBlock(title: "Details", text: details)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                )
            }
        }
    }

    private var moderationBansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active bans")
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            ForEach(moderationDashboard.activeBans) { ban in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ban.displayName ?? ban.username ?? "User")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        if let username = ban.username, username.isEmpty == false {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                        if let bannedUntil = ban.bannedUntil {
                            Text("Until \(bannedUntil.formatted(.dateTime.day().month().hour().minute()))")
                                .font(.caption2)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    Button {
                        Task {
                            await unban(ban)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if unbanningUserIDs.contains(ban.userID) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Unban")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(PrimeTheme.Colors.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeTheme.Colors.accent.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(unbanningUserIDs.contains(ban.userID))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                )
            }
        }
    }

    @ViewBuilder
    private var inviteCard: some View {
        if let shareLink = publicLink ?? presentedCommunityDetails?.inviteLink {
            VStack(alignment: .leading, spacing: 12) {
                Text("Invite & QR")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(shareLink.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif

                if let qrImage = qrCodeImage(for: shareLink.absoluteString) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180, maxHeight: 180)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white)
                        )
                }

                HStack(spacing: 10) {
                    Button {
                        #if os(tvOS)
                        statusMessage = "Copy is unavailable on Apple TV."
                        #else
                        UIPasteboard.general.string = shareLink.absoluteString
                        statusMessage = "Invite link copied."
                        #endif
                    } label: {
                        settingsPill(title: "Copy link")
                    }
                    .buttonStyle(.plain)

                    #if os(tvOS)
                    settingsPill(title: "Share unavailable")
                        .opacity(0.6)
                    #else
                    ShareLink(item: shareLink.absoluteString) {
                        settingsPill(title: "Share link")
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 8) {
            ForEach(sectionTabItems, id: \.self) { item in
                Button {
                    selectedSection = item
                } label: {
                    Text(item)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(selectedSection == item ? Color.white : PrimeTheme.Colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedSection == item ? PrimeTheme.Colors.accent : PrimeTheme.Colors.elevated)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let topics = chat.communityDetails?.topics, topics.isEmpty == false {
                VStack(spacing: 0) {
                    ForEach(Array(sortedTopics.enumerated()), id: \.element.id) { index, topic in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(PrimeTheme.Colors.accent.opacity(0.14))
                                    .frame(width: 38, height: 38)
                                Image(systemName: topic.symbolName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(PrimeTheme.Colors.accent)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(topic.title)
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    if topic.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(PrimeTheme.Colors.warning)
                                    }
                                }

                                Text(topic.lastActivityAt.formatted(.dateTime.day().month().hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }

                            Spacer()

                            if topic.unreadCount > 0 {
                                Text("\(topic.unreadCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(PrimeTheme.Colors.accent)
                                    )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        if index != sortedTopics.count - 1 {
                            Divider()
                                .padding(.leading, 64)
                        }
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
            } else {
                placeholderSection
            }
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if canManageGroup {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search username", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(PrimeTheme.Colors.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
                        )

                    if selectedUsers.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedUsers) { user in
                                    Button {
                                        toggle(user)
                                    } label: {
                                        Text(user.profile.displayName)
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(PrimeTheme.Colors.accent.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if users.isEmpty == false {
                        VStack(spacing: 8) {
                            ForEach(users) { user in
                                Button {
                                    toggle(user)
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarBadgeView(profile: user.profile, size: 36)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(user.profile.displayName)
                                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                            Text("@\(user.profile.username)")
                                                .font(.caption)
                                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                        }
                                        Spacer()
                                        if selectedUsers.contains(user) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(PrimeTheme.Colors.accent)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(PrimeTheme.Colors.elevated)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button(isAddingMembers ? addingAudienceProgressTitle : addAudienceTitle) {
                        Task {
                            await addSelectedMembers()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isAddingMembers || selectedUsers.isEmpty)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.elevated)
                    )
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(sortedGroupMembers.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await openMemberProfile(member)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarBadgeView(profile: memberProfile(member), size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(memberDisplayName(member))
                                        .font(.system(.body, design: .rounded).weight(.medium))
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    if let username = member.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if removingMemberIDs.contains(member.userID)
                            || changingRoleMemberIDs.contains(member.userID)
                            || transferringOwnershipMemberIDs.contains(member.userID)
                            || banningMemberIDs.contains(member.userID) {
                            ProgressView()
                                .controlSize(.small)
                        } else if canManageRoles(for: member) || canRemove(member) {
                            Menu {
                                if canTransferOwnership(to: member) {
                                    Button("Transfer ownership") {
                                        Task {
                                            await transferOwnership(to: member)
                                        }
                                    }
                                }

                                if canManageRoles(for: member) {
                                    Button(member.role == .admin ? "Remove admin" : "Make admin") {
                                        Task {
                                            await updateRole(member.role == .admin ? .member : .admin, for: member)
                                        }
                                    }
                                }

                                if canRemove(member) {
                                    Button(removeAudienceTitle, role: .destructive) {
                                        Task {
                                            await removeMember(member)
                                        }
                                    }

                                    Divider()

                                    Button("Ban for 1 day", role: .destructive) {
                                        Task {
                                            await ban(member, duration: 86_400, label: "1 day")
                                        }
                                    }

                                    Button("Ban for 3 days", role: .destructive) {
                                        Task {
                                            await ban(member, duration: 259_200, label: "3 days")
                                        }
                                    }

                                    Button("Ban for 1 week", role: .destructive) {
                                        Task {
                                            await ban(member, duration: 604_800, label: "1 week")
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(member.role.localizationKey.localized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if index != sortedGroupMembers.count - 1 {
                        Divider()
                            .padding(.leading, 62)
                    }
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

            if currentGroupRole != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if isOwner {
                        Text(ownerExitHintText)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }

                    Button {
                        Task {
                            await handlePrimaryOwnerAction()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isLeavingGroup {
                                ProgressView()
                                    .tint(Color.white)
                            } else {
                                Image(systemName: primaryExitSystemImage)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(primaryExitButtonTitle)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(primaryExitButtonColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLeavingGroup || primaryExitDisabled)
                    .opacity(primaryExitDisabled ? 0.6 : 1)
                }
            }
        }
    }

    @ViewBuilder
    private var placeholderSection: some View {
        switch selectedSection {
        case "Media":
            SharedChatContentSectionView(chat: chat, kind: .media)
        case "Files":
            SharedChatContentSectionView(chat: chat, kind: .files)
        case "Voices":
            SharedChatContentSectionView(chat: chat, kind: .voices)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("This section will show shared \(selectedSection.lowercased()) here.")
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
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
    }

    private var statusMessageColor: Color {
        statusMessage.hasPrefix("Could not") || statusMessage.hasPrefix("Only") || statusMessage.hasPrefix("Messaging") ?
            PrimeTheme.Colors.warning :
            PrimeTheme.Colors.success
    }

    private var currentGroupRole: GroupMemberRole? {
        if let explicitRole = presentedGroup?.members.first(where: { $0.userID == appState.currentUser.id })?.role {
            return explicitRole
        }
        if presentedGroup?.ownerID == appState.currentUser.id {
            return .owner
        }
        return nil
    }

    private var effectiveCommunityKind: CommunityKind? {
        forcedCommunityKind ?? presentedCommunityDetails?.kind
    }

    private var isChannel: Bool {
        effectiveCommunityKind == .channel
    }

    private var entityTitle: String {
        switch effectiveCommunityKind {
        case .channel:
            return "Channel"
        case .community:
            return "Community"
        case .supergroup:
            return "Supergroup"
        case .group, nil:
            return "Group"
        }
    }

    private var deleteTitle: String {
        switch effectiveCommunityKind {
        case .channel:
            return "Delete Channel"
        case .community:
            return "Delete Community"
        case .supergroup:
            return "Delete Supergroup"
        case .group, nil:
            return "Delete Group"
        }
    }

    private var canManageOfficialBadge: Bool {
        isOwner && isChannel && AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username)
    }

    private var primaryExitButtonTitle: String {
        if isOwner {
            switch effectiveCommunityKind {
            case .channel:
                return "Delete Channel"
            case .community:
                return "Delete Community"
            case .supergroup:
                return "Delete Supergroup"
            case .group, nil:
                break
            }
        }

        switch effectiveCommunityKind {
        case .channel:
            return "Leave Channel"
        case .community:
            return "Leave Community"
        case .supergroup:
            return "Leave Supergroup"
        case .group, nil:
            return "Leave Group"
        }
    }

    private var primaryExitSystemImage: String {
        isOwner && effectiveCommunityKind != nil ? "trash" : "rectangle.portrait.and.arrow.right"
    }

    private var primaryExitButtonColor: Color {
        if isOwner && effectiveCommunityKind != nil {
            return PrimeTheme.Colors.warning
        }
        return isOwner ? PrimeTheme.Colors.elevated : PrimeTheme.Colors.warning
    }

    private var primaryExitDisabled: Bool {
        if isOwner && effectiveCommunityKind != nil {
            return false
        }
        return isOwner
    }

    private var ownerExitHintText: String {
        if isOwner {
            switch effectiveCommunityKind {
            case .channel:
                return "As the owner, you can delete this channel directly."
            case .community:
            return "As the owner, you can delete this community directly."
            case .supergroup:
                return "As the owner, you can delete this supergroup directly."
            case .group, nil:
                break
            }
        }
        return "Transfer ownership to another member before leaving this group."
    }

    private var sectionTabItems: [String] {
        var items = ["community.section.users".localized]
        if showsTopicsSection {
            items.append("community.section.topics".localized)
        }
        items.append(contentsOf: ["common.media".localized, "common.files".localized, "common.voices".localized])
        return items
    }

    private var showsTopicsSection: Bool {
        presentedCommunityDetails?.forumModeEnabled == true || !(presentedCommunityDetails?.topics.isEmpty ?? true)
    }

    private var sortedTopics: [CommunityTopic] {
        (presentedCommunityDetails?.topics ?? []).sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.unreadCount != rhs.unreadCount {
                return lhs.unreadCount > rhs.unreadCount
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private var communityHeadlineText: String {
        let memberCount = presentedGroup?.members.count ?? max(chat.participantIDs.count, 1)
        guard let communityKind = effectiveCommunityKind else {
            return String(format: "community.headline.member.other".localized, memberCount)
        }

        switch communityKind {
        case .group, .supergroup, .community:
            let key = memberCount == 1 ? "community.headline.member.one" : "community.headline.member.other"
            return String(format: key.localized, memberCount)
        case .channel:
            let key = memberCount == 1 ? "community.headline.subscriber.one" : "community.headline.subscriber.other"
            return String(format: key.localized, memberCount)
        }
    }

    private var publicLink: URL? {
        guard presentedCommunityDetails?.isPublic == true,
              let handle = normalizePublicHandle(presentedCommunityDetails?.publicHandle) else { return nil }
        let routePrefix: String
        switch effectiveCommunityKind ?? .group {
        case .channel:
            routePrefix = "c"
        case .group, .supergroup, .community:
            routePrefix = "g"
        }
        return URL(string: "https://primemsg.site/\(routePrefix)/\(handle)")
    }

    private var canManageGroup: Bool {
        guard let currentGroupRole else {
            return false
        }

        return currentGroupRole == .owner || currentGroupRole == .admin
    }

    private var isOwner: Bool {
        currentGroupRole == .owner
    }

    private var audienceSingularTitle: String {
        isChannel ? "community.audience.subscriber".localized : "community.audience.member".localized
    }

    private var audiencePluralTitle: String {
        isChannel ? "community.audience.subscribers".localized : "community.audience.members".localized
    }

    private var addAudienceTitle: String {
        "Add \(audiencePluralTitle.lowercased())"
    }

    private var addingAudienceProgressTitle: String {
        isAddingMembers ? "Adding..." : addAudienceTitle
    }

    private var removeAudienceTitle: String {
        isChannel ? "Remove subscriber" : "Remove from group"
    }

    private var copyEntityNameTitle: String {
        "Copy \(entityTitle.lowercased()) name"
    }

    private var updatedEntityMessage: String {
        "\(entityTitle) updated."
    }

    private var couldNotUpdateEntityMessage: String {
        "Could not update the \(entityTitle.lowercased())."
    }

    private var couldNotLeaveEntityMessage: String {
        "Could not leave the \(entityTitle.lowercased())."
    }

    private var sortedGroupMembers: [GroupMember] {
        (presentedGroup?.members ?? []).sorted { lhs, rhs in
            let lhsRank = roleRank(lhs.role)
            let rhsRank = roleRank(rhs.role)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.joinedAt != rhs.joinedAt {
                return lhs.joinedAt < rhs.joinedAt
            }
            return memberDisplayName(lhs).localizedCaseInsensitiveCompare(memberDisplayName(rhs)) == .orderedAscending
        }
    }

    private func canRemove(_ member: GroupMember) -> Bool {
        guard let currentGroupRole else { return false }
        guard member.userID != appState.currentUser.id else { return false }
        guard member.userID != presentedGroup?.ownerID else { return false }

        switch currentGroupRole {
        case .owner:
            return true
        case .admin:
            return member.role == .member
        case .member:
            return false
        }
    }

    private func canManageRoles(for member: GroupMember) -> Bool {
        guard isOwner else { return false }
        guard member.userID != appState.currentUser.id else { return false }
        guard member.userID != presentedGroup?.ownerID else { return false }
        return member.role == .admin || member.role == .member
    }

    private func canTransferOwnership(to member: GroupMember) -> Bool {
        guard isOwner else { return false }
        guard member.userID != appState.currentUser.id else { return false }
        return member.userID != presentedGroup?.ownerID
    }

    private func roleRank(_ role: GroupMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }

    private func memberDisplayName(_ member: GroupMember) -> String {
        let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayName, !displayName.isEmpty {
            return displayName
        }

        let username = member.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let username, !username.isEmpty {
            return username
        }

        return "Member"
    }

    private func memberProfile(_ member: GroupMember) -> Profile {
        Profile(
            displayName: memberDisplayName(member),
            username: member.username ?? "member",
            bio: "",
            status: "",
            birthday: nil,
            email: nil,
            phoneNumber: nil,
            profilePhotoURL: nil,
            socialLink: nil
        )
    }

    @MainActor
    private func searchUsers() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            users = []
            return
        }

        do {
            let results = try await environment.authRepository.searchUsers(query: trimmed, excluding: appState.currentUser.id)
            let existingIDs = Set(chat.participantIDs)
            users = results.filter { existingIDs.contains($0.id) == false }
        } catch {
            users = []
            statusMessage = error.localizedDescription.isEmpty ? "Could not search users." : error.localizedDescription
        }
    }

    @MainActor
    private func saveTitle(_ updatedTitle: String) async throws {
        let normalizedTitle = updatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        isSavingTitle = true
        defer { isSavingTitle = false }

        chat = try await environment.chatRepository.updateGroup(
            chat,
            title: normalizedTitle,
            requesterID: appState.currentUser.id
        )
        title = chat.group?.title ?? chat.title
        statusMessage = updatedEntityMessage
    }

    @MainActor
    private func deleteGroup() async throws {
        try await environment.chatRepository.deleteGroup(chat, requesterID: appState.currentUser.id)
        appState.forgetChatRoutes(chatIDs: [chat.id])
        onGroupDeleted?()
    }

    @MainActor
    private func uploadSelectedPhoto() async {
        #if canImport(PhotosUI) && !os(tvOS)
        guard let selectedPhotoItem else { return }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            chat = try await environment.chatRepository.uploadGroupAvatar(
                imageData: data,
                for: chat,
                requesterID: appState.currentUser.id
            )
            statusMessage = updatedEntityMessage
            self.selectedPhotoItem = nil
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
        #else
        statusMessage = "Avatar upload is unavailable on Apple TV."
        #endif
    }

    @MainActor
    private func removeAvatar() async {
        do {
            chat = try await environment.chatRepository.removeGroupAvatar(for: chat, requesterID: appState.currentUser.id)
            statusMessage = updatedEntityMessage
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func addSelectedMembers() async {
        isAddingMembers = true
        defer { isAddingMembers = false }

        let existingIDs = Set(chat.participantIDs)
        let memberIDsToAdd = Array(Set(selectedUsers.map(\.id))).filter { existingIDs.contains($0) == false }
        guard memberIDsToAdd.isEmpty == false else {
            statusMessage = isChannel
                ? "All selected users are already subscribed."
                : "All selected users are already in the group."
            return
        }

        do {
            chat = try await environment.chatRepository.addMembers(
                memberIDsToAdd,
                to: chat,
                requesterID: appState.currentUser.id
            )
            selectedUsers = []
            users = []
            query = ""
            statusMessage = updatedEntityMessage
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func removeMember(_ member: GroupMember) async {
        removingMemberIDs.insert(member.userID)
        defer { removingMemberIDs.remove(member.userID) }

        do {
            chat = try await environment.chatRepository.removeMember(
                member.userID,
                from: chat,
                requesterID: appState.currentUser.id
            )
            selectedUsers.removeAll { $0.id == member.userID }
            users.removeAll { $0.id == member.userID }
            statusMessage = updatedEntityMessage
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func updateRole(_ role: GroupMemberRole, for member: GroupMember) async {
        changingRoleMemberIDs.insert(member.userID)
        defer { changingRoleMemberIDs.remove(member.userID) }

        do {
            chat = try await environment.chatRepository.updateMemberRole(
                role,
                for: member.userID,
                in: chat,
                requesterID: appState.currentUser.id
            )
            statusMessage = updatedEntityMessage
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func transferOwnership(to member: GroupMember) async {
        transferringOwnershipMemberIDs.insert(member.userID)
        defer { transferringOwnershipMemberIDs.remove(member.userID) }

        do {
            chat = try await environment.chatRepository.transferGroupOwnership(
                to: member.userID,
                in: chat,
                requesterID: appState.currentUser.id
            )
            statusMessage = "Ownership transferred."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func leaveCurrentGroup() async {
        isLeavingGroup = true
        defer { isLeavingGroup = false }

        do {
            try await environment.chatRepository.leaveGroup(chat, requesterID: appState.currentUser.id)
            appState.forgetChatRoutes(chatIDs: [chat.id])
            if let onGroupLeft {
                onGroupLeft()
            } else {
                dismiss()
            }
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotLeaveEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func handlePrimaryOwnerAction() async {
        if isOwner && effectiveCommunityKind != nil {
            do {
                try await deleteGroup()
            } catch {
                statusMessage = error.localizedDescription.isEmpty ? "Could not delete the \(entityTitle.lowercased())." : error.localizedDescription
            }
            return
        }

        await leaveCurrentGroup()
    }

    @MainActor
    private func toggleOfficialBadge() async {
        guard var details = presentedCommunityDetails else { return }

        isUpdatingOfficialBadge = true
        defer { isUpdatingOfficialBadge = false }

        details.isOfficial.toggle()

        do {
            chat = try await environment.chatRepository.updateCommunityDetails(
                details,
                for: chat,
                requesterID: appState.currentUser.id
            )
            await CommunityChatMetadataStore.shared.setDetails(
                chat.communityDetails,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            statusMessage = details.isOfficial ? "Channel marked as official." : "Official badge removed."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func updateCommunitySettings(_ mutate: (inout CommunityChatDetails) -> Void) async {
        guard var details = presentedCommunityDetails else { return }

        isUpdatingCommunitySettings = true
        defer { isUpdatingCommunitySettings = false }

        mutate(&details)

        do {
            chat = try await environment.chatRepository.updateCommunityDetails(
                details,
                for: chat,
                requesterID: appState.currentUser.id
            )
            resolvedCommunityDetails = chat.communityDetails ?? details
            await CommunityChatMetadataStore.shared.setDetails(
                chat.communityDetails ?? details,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            statusMessage = "\(entityTitle) settings updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? couldNotUpdateEntityMessage : error.localizedDescription
        }
    }

    @MainActor
    private func savePublicHandle() async {
        guard var details = presentedCommunityDetails else { return }

        isSavingPublicHandle = true
        defer { isSavingPublicHandle = false }

        details.publicHandle = normalizePublicHandle(publicHandleDraft)

        do {
            chat = try await environment.chatRepository.updateCommunityDetails(
                details,
                for: chat,
                requesterID: appState.currentUser.id
            )
            resolvedCommunityDetails = chat.communityDetails ?? details
            publicHandleDraft = resolvedCommunityDetails?.publicHandle ?? ""
            await CommunityChatMetadataStore.shared.setDetails(
                chat.communityDetails ?? details,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            statusMessage = "Public username updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the public username." : error.localizedDescription
        }
    }

    private func normalizePublicHandle(_ rawValue: String?) -> String? {
        let trimmed = (rawValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func refreshCommunityDetailsFromRepository() async {
        guard chat.mode != .offline else { return }

        guard let refreshedChat = try? await environment.chatRepository
            .fetchChats(mode: chat.mode, for: appState.currentUser.id)
            .first(where: { $0.id == chat.id })
        else {
            return
        }

        guard refreshedChat.communityDetails != nil else { return }

        chat = refreshedChat
        resolvedCommunityDetails = refreshedChat.communityDetails
        await CommunityChatMetadataStore.shared.setDetails(
            refreshedChat.communityDetails,
            ownerUserID: appState.currentUser.id,
            chatID: chat.id
        )
    }

    @MainActor
    private func refreshGroupMetadataFromRepository() async {
        guard chat.mode != .offline else { return }

        guard let refreshedChat = try? await environment.chatRepository
            .fetchChats(mode: chat.mode, for: appState.currentUser.id)
            .first(where: { $0.id == chat.id })
        else {
            return
        }

        if refreshedChat.group != nil {
            chat = refreshedChat
            resolvedGroup = preferredGroup(current: refreshedChat.group, fallback: resolvedGroup)
        }

        if let communityDetails = refreshedChat.communityDetails {
            resolvedCommunityDetails = communityDetails
            await CommunityChatMetadataStore.shared.setDetails(
                communityDetails,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
        }

        if let moderationSettings = refreshedChat.moderationSettings {
            await GroupModerationSettingsStore.shared.setSettings(
                moderationSettings,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            self.moderationSettings = moderationSettings
            moderationEntryQuestionsText = moderationSettings.entryQuestions.joined(separator: "\n")
        }
    }

    private var presentedGroup: Group? {
        preferredGroup(current: chat.group, fallback: resolvedGroup)
    }

    private var presentedCommunityDetails: CommunityChatDetails? {
        chat.communityDetails ?? resolvedCommunityDetails
    }

    private func preferredGroup(current: Group?, fallback: Group?) -> Group? {
        switch (current, fallback) {
        case let (current?, fallback?):
            if current.members.count != fallback.members.count {
                return current.members.count >= fallback.members.count ? current : fallback
            }
            if current.ownerID == appState.currentUser.id {
                return current
            }
            if fallback.ownerID == appState.currentUser.id {
                return fallback
            }
            return current
        case let (current?, nil):
            return current
        case let (nil, fallback?):
            return fallback
        case (nil, nil):
            return nil
        }
    }

    @MainActor
    private func openMemberProfile(_ member: GroupMember) async {
        do {
            selectedMemberProfile = try await environment.authRepository.userProfile(userID: member.userID)
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not open the profile." : error.localizedDescription
        }
    }

    @MainActor
    private func applySoundMode(_ newMode: ChatMuteState, message: String) {
        soundMode = newMode
        chat.notificationPreferences.muteState = newMode
        Task {
            await ChatThreadStateStore.shared.setMuteState(
                newMode,
                ownerUserID: appState.currentUser.id,
                mode: chat.mode,
                chatID: chat.id
            )
        }
        statusMessage = message
    }

    private func toggle(_ user: User) {
        if let existingIndex = selectedUsers.firstIndex(of: user) {
            selectedUsers.remove(at: existingIndex)
        } else {
            selectedUsers.append(user)
        }
    }

    @MainActor
    private func saveModerationSettings() async {
        isSavingModeration = true
        defer { isSavingModeration = false }

        let parsedQuestions = moderationEntryQuestionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        moderationSettings.entryQuestions = Array(parsedQuestions.prefix(5))
        let normalizedSettings = moderationSettings.hasActiveProtection ? moderationSettings : nil
        chat.moderationSettings = normalizedSettings

        do {
            let updatedChat = try await environment.chatRepository.updateGroup(
                chat,
                title: presentedGroup?.title ?? chat.title,
                requesterID: appState.currentUser.id
            )
            chat = updatedChat
            await GroupModerationSettingsStore.shared.setSettings(
                updatedChat.moderationSettings,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            if canManageGroup {
                await refreshModerationDashboard()
            }
            statusMessage = "Moderation updated."
        } catch {
            await GroupModerationSettingsStore.shared.setSettings(
                normalizedSettings,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
            statusMessage = error.localizedDescription.isEmpty ? "Could not update moderation." : error.localizedDescription
        }
    }

    @MainActor
    private func refreshModerationDashboard() async {
        guard canManageGroup, chat.mode != .offline else { return }
        isRefreshingModerationDashboard = true
        defer { isRefreshingModerationDashboard = false }

        do {
            moderationDashboard = try await environment.chatRepository.fetchModerationDashboard(
                for: chat,
                requesterID: appState.currentUser.id
            )
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not refresh moderation." : error.localizedDescription
        }
    }

    @MainActor
    private func resolve(request: GroupJoinRequest, approve: Bool) async {
        resolvingJoinRequestUserIDs.insert(request.requesterUserID)
        defer { resolvingJoinRequestUserIDs.remove(request.requesterUserID) }

        do {
            moderationDashboard = try await environment.chatRepository.resolveJoinRequest(
                for: request.requesterUserID,
                approve: approve,
                in: chat,
                requesterID: appState.currentUser.id
            )
            await refreshGroupMetadataFromRepository()
            statusMessage = approve ? "Join request approved." : "Join request declined."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the join request." : error.localizedDescription
        }
    }

    @MainActor
    private func ban(_ member: GroupMember, duration: TimeInterval, label: String) async {
        banningMemberIDs.insert(member.userID)
        defer { banningMemberIDs.remove(member.userID) }

        do {
            moderationDashboard = try await environment.chatRepository.banMember(
                member.userID,
                duration: duration,
                reason: nil,
                in: chat,
                requesterID: appState.currentUser.id
            )
            await refreshGroupMetadataFromRepository()
            statusMessage = "\(memberDisplayName(member)) banned for \(label)."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not ban \(memberDisplayName(member))." : error.localizedDescription
        }
    }

    @MainActor
    private func unban(_ ban: GroupBanRecord) async {
        unbanningUserIDs.insert(ban.userID)
        defer { unbanningUserIDs.remove(ban.userID) }

        do {
            moderationDashboard = try await environment.chatRepository.removeBan(
                for: ban.userID,
                in: chat,
                requesterID: appState.currentUser.id
            )
            statusMessage = "\(ban.displayName ?? ban.username ?? "User") unbanned."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not remove the ban." : error.localizedDescription
        }
    }

    private func qrCodeImage(for text: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func binding(_ keyPath: WritableKeyPath<GroupModerationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { moderationSettings[keyPath: keyPath] },
            set: { moderationSettings[keyPath: keyPath] = $0 }
        )
    }

    private var currentGroupCallButtonTitle: String {
        return "Call"
    }

    @MainActor
    private func startOrOpenGroupCall() async {
        guard isStartingGroupCall == false else { return }

        isStartingGroupCall = true
        defer { isStartingGroupCall = false }

        do {
            groupCallManager.configure(
                currentUserID: appState.currentUser.id,
                repository: environment.callRepository
            )
            try await groupCallManager.startOrJoinCall(in: chat)
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription.isEmpty
                ? "Could not start the group call."
                : error.localizedDescription
        }
    }

    @ViewBuilder
    private func actionButton(title: String, systemName: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            actionButtonLabel(title: title, systemName: systemName)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButtonLabel(title: String, systemName: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: title == "More" ? 18 : 16, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(PrimeTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.horizontal, 8)
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
    private func settingsPill(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(PrimeTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }

    @ViewBuilder
    private func headerCircleButton(systemName: String) -> some View {
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

    @ViewBuilder
    private func headerActionButton(title: String, systemName: String) -> some View {
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

    @ViewBuilder
    private func communityInfoRow(title: String, value: String, systemName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)
                .frame(width: 18)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func moderationReadOnlyBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PrimeTheme.Colors.background.opacity(0.45))
        )
    }
}

private struct GroupAvatarView: View {
    let title: String
    let photoURL: URL?
    let size: CGFloat

    var body: some View {
        if let photoURL {
            CachedRemoteImage(url: photoURL, maxPixelSize: 320) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            placeholder
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(PrimeTheme.Colors.accent.opacity(0.85))
            .overlay(
                Text(String(title.prefix(1)))
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Color.white)
            )
    }

    @ViewBuilder
    private func communityInfoRow(title: String, value: String, systemName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)
                .frame(width: 18)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct GroupEditScreen: View {
    let title: String
    let photoURL: URL?
    let canDeleteGroup: Bool
    let entityTitle: String
    let deleteTitle: String
    let onSave: (String) async throws -> Void
    let onDelete: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle = ""
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

                    GroupAvatarView(title: draftTitle.isEmpty ? title : draftTitle, photoURL: photoURL, size: 72)

                    Spacer(minLength: 12)

                    editorHeaderButton(title: "Done", systemName: "checkmark", isPrimary: true) {
                        Task {
                            await save()
                        }
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isDeleting)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(entityTitle) Name")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    TextField("\(entityTitle) Name", text: $draftTitle)
                        .textFieldStyle(.plain)
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

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                        .multilineTextAlignment(.center)
                }

                if canDeleteGroup {
                    Button {
                        Task {
                            await deleteGroup()
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
                            Text(deleteTitle)
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
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            draftTitle = title
        }
    }

    @MainActor
    private func save() async {
        statusMessage = ""
        isSaving = true
        defer { isSaving = false }

        do {
            try await onSave(draftTitle)
            dismiss()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
        }
    }

    @MainActor
    private func deleteGroup() async {
        statusMessage = ""
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await onDelete()
            dismiss()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not delete the group." : error.localizedDescription
        }
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
