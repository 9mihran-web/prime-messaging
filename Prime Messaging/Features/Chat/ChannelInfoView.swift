import CoreImage.CIFilterBuiltins
#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
private typealias ChannelPhotoPickerItem = PhotosPickerItem
#else
private struct ChannelPhotoPickerItem: Hashable {}
#endif
import SwiftUI
import UIKit

struct ChannelInfoView: View {
    @Binding var chat: Chat
    var onRequestSearch: (() -> Void)? = nil
    var onGroupDeleted: (() -> Void)? = nil
    var onGroupLeft: (() -> Void)? = nil

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var title: String
    @State private var query = ""
    @State private var users: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var selectedPhotoItem: ChannelPhotoPickerItem?
    @State private var statusMessage = ""
    @State private var soundMode: ChatMuteState = .active
    @State private var resolvedGroup: Group?
    @State private var resolvedCommunityDetails: CommunityChatDetails?
    @State private var selectedMemberProfile: User?
    @State private var isShowingEditScreen = false
    @State private var isAddingSubscribers = false
    @State private var removingMemberIDs = Set<UUID>()
    @State private var changingRoleMemberIDs = Set<UUID>()
    @State private var transferringOwnershipMemberIDs = Set<UUID>()
    @State private var isLeavingChannel = false
    @State private var isUpdatingOfficialBadge = false
    @State private var isUpdatingChannelSettings = false
    @State private var publicHandleDraft = ""
    @State private var isSavingPublicHandle = false

    init(
        chat: Binding<Chat>,
        onRequestSearch: (() -> Void)? = nil,
        onGroupDeleted: (() -> Void)? = nil,
        onGroupLeft: (() -> Void)? = nil
    ) {
        _chat = chat
        self.onRequestSearch = onRequestSearch
        self.onGroupDeleted = onGroupDeleted
        self.onGroupLeft = onGroupLeft
        _title = State(initialValue: chat.wrappedValue.group?.title ?? chat.wrappedValue.title)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar
                headerCard
                actionRow

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusMessageColor)
                        .multilineTextAlignment(.center)
                }

                settingsCard
                inviteCard
                subscribersCard
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
            await hydrateChannel()
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
        .navigationDestination(isPresented: $isShowingEditScreen) {
            ChannelEditScreen(
                title: presentedGroup?.title ?? chat.title,
                photoURL: presentedGroup?.photoURL,
                canDeleteChannel: isOwner,
                onSave: { updatedTitle in
                    try await saveTitle(updatedTitle)
                },
                onDelete: {
                    try await deleteChannel()
                }
            )
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                circleHeaderButton(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            if canManageChannel {
                Button {
                    isShowingEditScreen = true
                } label: {
                    headerActionButton(title: "Edit", systemName: "pencil")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var headerCard: some View {
        VStack(spacing: 8) {
            ChannelAvatarView(
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

            Text(subscriberHeadlineText)
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(title: "common.search".localized, systemName: "magnifyingglass") {
                onRequestSearch?()
                if onRequestSearch == nil {
                    statusMessage = "Channel search is only available from the chat screen."
                }
            }
            .frame(maxWidth: .infinity)

            soundMenuButton

            actionButton(title: "common.invite".localized, systemName: "qrcode") {
                if inviteLink == nil {
                    statusMessage = "This channel does not have an invite link yet."
                } else {
                    statusMessage = "Scroll down to Invite & QR."
                }
            }
            .frame(maxWidth: .infinity)

            actionButton(title: "common.more".localized, systemName: "ellipsis.circle") {
                #if os(tvOS)
                statusMessage = "Copy is unavailable on Apple TV."
                #else
                UIPasteboard.general.string = presentedGroup?.title ?? chat.title
                statusMessage = "Channel name copied."
                #endif
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var soundMenuButton: some View {
        Menu {
            if soundMode != .active {
                Button("Turn sound on") {
                    applySoundMode(.active, message: "Channel sound enabled.")
                }
            } else {
                Button("Turn off for 1 hour") {
                    applySoundMode(.mutedTemporarily, message: "Notifications muted for a while.")
                }

                Button("Turn off sound") {
                    applySoundMode(.mutedPermanently, message: "Channel sound disabled.")
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

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("community.channel_settings".localized)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            Text(presentedGroup?.title ?? chat.title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let details = presentedCommunityDetails {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow(title: "common.type".localized, value: "community.kind.channel".localized, systemName: "megaphone.fill")
                    infoRow(title: "community.visibility".localized, value: details.isPublic ? "common.public".localized : "common.private".localized, systemName: details.isPublic ? "globe" : "lock.fill")
                    if let publicLink {
                        infoRow(title: "Public link", value: publicLink.absoluteString, systemName: "link")
                    }
                    infoRow(title: "community.comments".localized, value: details.commentsEnabled ? "common.enabled".localized : "common.disabled".localized, systemName: "bubble.left.and.text.bubble.right.fill")
                    infoRow(title: "community.threads".localized, value: details.forumModeEnabled ? "community.forum_mode_enabled".localized : "community.linear_posts".localized, systemName: details.forumModeEnabled ? "text.bubble.fill" : "text.bubble")

                    if canManageChannel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Public username")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            TextField("your-channel-name", text: $publicHandleDraft)
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

                                if publicHandleDraft.isEmpty == false || details.publicHandle != nil {
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
                                        await updateChannelSettings { $0.commentsEnabled.toggle() }
                                    }
                                } label: {
                                    settingsPill(title: details.commentsEnabled ? "community.disable_comments".localized : "community.enable_comments".localized)
                                }
                                .buttonStyle(.plain)
                                .disabled(isUpdatingChannelSettings)

                                Button {
                                    Task {
                                        await updateChannelSettings { $0.isPublic.toggle() }
                                    }
                                } label: {
                                    settingsPill(title: details.isPublic ? "community.make_private".localized : "community.make_public".localized)
                                }
                                .buttonStyle(.plain)
                                .disabled(isUpdatingChannelSettings)
                            }

                            Button {
                                Task {
                                    await updateChannelSettings { $0.forumModeEnabled.toggle() }
                                }
                            } label: {
                                settingsPill(title: details.forumModeEnabled ? "Disable threads" : "Enable threads")
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdatingChannelSettings)
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
                                    Image(systemName: details.isOfficial ? "checkmark.seal.fill" : "checkmark.seal")
                                        .font(.system(size: 14, weight: .semibold))
                                }

                                Text(details.isOfficial ? "Remove official badge" : "Mark as official")
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

            if canManageChannel {
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

    @ViewBuilder
    private var inviteCard: some View {
        if let shareLink = publicLink ?? inviteLink {
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

    private var subscribersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subscribers")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            if canManageChannel {
                addSubscribersComposer
            }

            subscribersList

            if currentRole != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if isOwner {
                        Text("As the owner, you can delete this channel directly.")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }

                    Button {
                        Task {
                            await handlePrimaryAction()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isLeavingChannel {
                                ProgressView()
                                    .tint(Color.white)
                            } else {
                                Image(systemName: isOwner ? "trash" : "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(primaryActionTitle)
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
                    .disabled(isLeavingChannel)
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

    private var addSubscribersComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search username", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PrimeTheme.Colors.background.opacity(0.45))
                )

            if !selectedUsers.isEmpty {
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

            if !users.isEmpty {
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
                                    .fill(PrimeTheme.Colors.background.opacity(0.45))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(isAddingSubscribers ? "Adding..." : "Add subscribers") {
                Task {
                    await addSelectedMembers()
                }
            }
            .buttonStyle(.plain)
            .disabled(isAddingSubscribers || selectedUsers.isEmpty)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PrimeTheme.Colors.background.opacity(0.45))
            )
        }
    }

    private var subscribersList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedMembers.enumerated()), id: \.element.id) { index, member in
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

                    if removingMemberIDs.contains(member.userID) || changingRoleMemberIDs.contains(member.userID) || transferringOwnershipMemberIDs.contains(member.userID) {
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
                                Button("Remove subscriber", role: .destructive) {
                                    Task {
                                        await removeMember(member)
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

                if index != sortedMembers.count - 1 {
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PrimeTheme.Colors.background.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    private var presentedGroup: Group? {
        preferredGroup(current: chat.group, fallback: resolvedGroup)
    }

    private var presentedCommunityDetails: CommunityChatDetails? {
        chat.communityDetails ?? resolvedCommunityDetails
    }

    private var currentRole: GroupMemberRole? {
        if let explicitRole = presentedGroup?.members.first(where: { $0.userID == appState.currentUser.id })?.role {
            return explicitRole
        }
        if presentedGroup?.ownerID == appState.currentUser.id {
            return .owner
        }
        return nil
    }

    private var isOwner: Bool {
        currentRole == .owner
    }

    private var canManageChannel: Bool {
        currentRole == .owner || currentRole == .admin
    }

    private var canManageOfficialBadge: Bool {
        isOwner && AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username)
    }

    private var subscriberHeadlineText: String {
        let count = max(presentedGroup?.members.count ?? chat.participantIDs.count, 1)
        let key = count == 1 ? "community.headline.subscriber.one" : "community.headline.subscriber.other"
        return String(format: key.localized, count)
    }

    private var primaryActionTitle: String {
        isOwner ? "Delete Channel" : "Leave Channel"
    }

    private var inviteLink: URL? {
        presentedCommunityDetails?.inviteLink
    }

    private var publicLink: URL? {
        guard presentedCommunityDetails?.isPublic == true,
              let handle = normalizePublicHandle(presentedCommunityDetails?.publicHandle) else { return nil }
        return URL(string: "https://primemsg.site/c/\(handle)")
    }

    private var sortedMembers: [GroupMember] {
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

    private var statusMessageColor: Color {
        statusMessage.hasPrefix("Could not") || statusMessage.hasPrefix("Only") || statusMessage.hasPrefix("Messaging")
            ? PrimeTheme.Colors.warning
            : PrimeTheme.Colors.success
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

        return "Subscriber"
    }

    private func memberProfile(_ member: GroupMember) -> Profile {
        Profile(
            displayName: memberDisplayName(member),
            username: member.username ?? "subscriber",
            bio: "",
            status: "",
            birthday: nil,
            email: nil,
            phoneNumber: nil,
            profilePhotoURL: nil,
            socialLink: nil
        )
    }

    private func canRemove(_ member: GroupMember) -> Bool {
        guard let currentRole else { return false }
        guard member.userID != appState.currentUser.id else { return false }
        guard member.userID != presentedGroup?.ownerID else { return false }

        switch currentRole {
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

    @MainActor
    private func hydrateChannel() async {
        soundMode = chat.notificationPreferences.muteState
        resolvedGroup = preferredGroup(current: chat.group, fallback: resolvedGroup)
        resolvedCommunityDetails = chat.communityDetails ?? resolvedCommunityDetails

        if chat.communityDetails == nil,
           let details = await CommunityChatMetadataStore.shared.details(ownerUserID: appState.currentUser.id, chatID: chat.id) {
            resolvedCommunityDetails = details
            chat.communityDetails = details
        }

        if chat.mode != .offline {
            await refreshChannelMetadataFromRepository()
        }
    }

    @MainActor
    private func refreshChannelMetadataFromRepository() async {
        guard chat.mode != .offline else { return }

        guard let refreshedChat = try? await environment.chatRepository
            .fetchChats(mode: chat.mode, for: appState.currentUser.id)
            .first(where: { $0.id == chat.id })
        else {
            return
        }

        chat = refreshedChat
        resolvedGroup = preferredGroup(current: refreshedChat.group, fallback: resolvedGroup)
        if let details = refreshedChat.communityDetails {
            resolvedCommunityDetails = details
            await CommunityChatMetadataStore.shared.setDetails(
                details,
                ownerUserID: appState.currentUser.id,
                chatID: chat.id
            )
        }
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
        guard !normalizedTitle.isEmpty else {
            throw ChatRepositoryError.invalidGroupOperation
        }

        chat = try await environment.chatRepository.updateGroup(
            chat,
            title: normalizedTitle,
            requesterID: appState.currentUser.id
        )
        title = chat.group?.title ?? chat.title
        statusMessage = "Channel updated."
    }

    @MainActor
    private func deleteChannel() async throws {
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
            statusMessage = "Channel updated."
            self.selectedPhotoItem = nil
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
        }
        #else
        statusMessage = "Avatar upload is unavailable on Apple TV."
        #endif
    }

    @MainActor
    private func removeAvatar() async {
        do {
            chat = try await environment.chatRepository.removeGroupAvatar(for: chat, requesterID: appState.currentUser.id)
            statusMessage = "Channel updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
        }
    }

    @MainActor
    private func addSelectedMembers() async {
        isAddingSubscribers = true
        defer { isAddingSubscribers = false }

        let existingIDs = Set(chat.participantIDs)
        let memberIDsToAdd = Array(Set(selectedUsers.map(\.id))).filter { !existingIDs.contains($0) }
        guard !memberIDsToAdd.isEmpty else {
            statusMessage = "All selected users are already subscribed."
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
            statusMessage = "Channel updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
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
            statusMessage = "Channel updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
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
            statusMessage = "Channel updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
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
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
        }
    }

    @MainActor
    private func leaveCurrentChannel() async {
        isLeavingChannel = true
        defer { isLeavingChannel = false }

        do {
            try await environment.chatRepository.leaveGroup(chat, requesterID: appState.currentUser.id)
            appState.forgetChatRoutes(chatIDs: [chat.id])
            if let onGroupLeft {
                onGroupLeft()
            } else {
                dismiss()
            }
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not leave the channel." : error.localizedDescription
        }
    }

    @MainActor
    private func handlePrimaryAction() async {
        if isOwner {
            do {
                try await deleteChannel()
            } catch {
                statusMessage = error.localizedDescription.isEmpty ? "Could not delete the channel." : error.localizedDescription
            }
            return
        }

        await leaveCurrentChannel()
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
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
        }
    }

    @MainActor
    private func updateChannelSettings(_ mutate: (inout CommunityChatDetails) -> Void) async {
        guard var details = presentedCommunityDetails else { return }

        isUpdatingChannelSettings = true
        defer { isUpdatingChannelSettings = false }

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
            statusMessage = "Channel settings updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
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
                .font(.system(size: 16, weight: .semibold))
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
    private func circleHeaderButton(systemName: String) -> some View {
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
    private func infoRow(title: String, value: String, systemName: String) -> some View {
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

private struct ChannelAvatarView: View {
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
}

private struct ChannelEditScreen: View {
    let title: String
    let photoURL: URL?
    let canDeleteChannel: Bool
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

                    ChannelAvatarView(title: draftTitle.isEmpty ? title : draftTitle, photoURL: photoURL, size: 72)

                    Spacer(minLength: 12)

                    editorHeaderButton(title: "Done", systemName: "checkmark", isPrimary: true) {
                        Task {
                            await save()
                        }
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isDeleting)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Channel Name")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    TextField("Channel Name", text: $draftTitle)
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

                if canDeleteChannel {
                    Button {
                        Task {
                            await deleteChannel()
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
                            Text("Delete Channel")
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
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the channel." : error.localizedDescription
        }
    }

    @MainActor
    private func deleteChannel() async {
        statusMessage = ""
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await onDelete()
            dismiss()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not delete the channel." : error.localizedDescription
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
