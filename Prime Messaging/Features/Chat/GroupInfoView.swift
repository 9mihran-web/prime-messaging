import PhotosUI
import SwiftUI

struct GroupInfoView: View {
    @Binding var chat: Chat

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var title: String
    @State private var query = ""
    @State private var users: [User] = []
    @State private var selectedUsers: [User] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var statusMessage = ""
    @State private var isSavingTitle = false
    @State private var isAddingMembers = false
    @State private var removingMemberIDs = Set<UUID>()
    @State private var changingRoleMemberIDs = Set<UUID>()
    @State private var selectedSection = "Users"
    @State private var selectedMemberProfile: User?

    init(chat: Binding<Chat>) {
        _chat = chat
        _title = State(initialValue: chat.wrappedValue.group?.title ?? chat.wrappedValue.title)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar

                VStack(spacing: 8) {
                    GroupAvatarView(
                        title: chat.group?.title ?? chat.title,
                        photoURL: chat.group?.photoURL,
                        size: 104
                    )

                    Text(chat.group?.title ?? chat.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)

                    Text("\((chat.group?.members.count ?? max(chat.participantIDs.count, 1))) members")
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

                sectionTabs

                if selectedSection == "Users" {
                    usersSection
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
        .task(id: selectedPhotoItem) {
            await uploadSelectedPhoto()
        }
        .onChange(of: chat.group?.title ?? chat.title) { _, newValue in
            title = newValue
        }
        .sheet(item: $selectedMemberProfile) { user in
            NavigationStack {
                ContactProfileView(user: user)
            }
            .presentationDetents([.large])
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

            Text("Edit")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
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

    private var groupActionRow: some View {
        HStack(spacing: 10) {
            actionButton(title: "Call", systemName: "phone.fill") {
                statusMessage = "Direct calls are available from a member profile."
            }
            actionButton(title: "Sound", systemName: "bell.fill")
            actionButton(title: "Search", systemName: "magnifyingglass")
            actionButton(title: "More", systemName: "ellipsis")
        }
    }

    private var groupSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Group Settings")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            if canManageGroup {
                TextField("Group title", text: $title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )

                HStack(spacing: 10) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        settingsPill(title: "Avatar")
                    }
                    .buttonStyle(.plain)

                    if chat.group?.photoURL != nil {
                        Button {
                            Task {
                                await removeAvatar()
                            }
                        } label: {
                            settingsPill(title: "Remove")
                        }
                        .buttonStyle(.plain)
                    }

                    Button(isSavingTitle ? "Saving..." : "Save") {
                        Task {
                            await saveTitle()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingTitle || normalizedTitle.isEmpty || normalizedTitle == (chat.group?.title ?? chat.title))
                }
            } else {
                Text(chat.group?.title ?? chat.title)
                    .font(.body)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
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

    private var sectionTabs: some View {
        HStack(spacing: 8) {
            ForEach(["Users", "Media", "Files", "Voices"], id: \.self) { item in
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

                    Button(isAddingMembers ? "Adding..." : "Add members") {
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
                ForEach(Array((chat.group?.members ?? []).enumerated()), id: \.element.id) { index, member in
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
                        if removingMemberIDs.contains(member.userID) || changingRoleMemberIDs.contains(member.userID) {
                            ProgressView()
                                .controlSize(.small)
                        } else if canManageRoles(for: member) || canRemove(member) {
                            Menu {
                                if canManageRoles(for: member) {
                                    Button(member.role == .admin ? "Remove admin" : "Make admin") {
                                        Task {
                                            await updateRole(member.role == .admin ? .member : .admin, for: member)
                                        }
                                    }
                                }

                                if canRemove(member) {
                                    Button("Remove from group", role: .destructive) {
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

                    if index != (chat.group?.members.count ?? 1) - 1 {
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
        }
    }

    private var placeholderSection: some View {
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

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusMessageColor: Color {
        statusMessage.hasPrefix("Could not") || statusMessage.hasPrefix("Only") || statusMessage.hasPrefix("Messaging") ?
            PrimeTheme.Colors.warning :
            PrimeTheme.Colors.success
    }

    private var currentGroupRole: GroupMemberRole? {
        chat.group?.members.first(where: { $0.userID == appState.currentUser.id })?.role
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

    private func canRemove(_ member: GroupMember) -> Bool {
        guard let currentGroupRole else { return false }
        guard member.userID != appState.currentUser.id else { return false }
        guard member.userID != chat.group?.ownerID else { return false }

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
        guard member.userID != chat.group?.ownerID else { return false }
        return member.role == .admin || member.role == .member
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
    private func saveTitle() async {
        isSavingTitle = true
        defer { isSavingTitle = false }

        do {
            chat = try await environment.chatRepository.updateGroup(
                chat,
                title: normalizedTitle,
                requesterID: appState.currentUser.id
            )
            title = chat.group?.title ?? chat.title
            statusMessage = "Group updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
        }
    }

    @MainActor
    private func uploadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            chat = try await environment.chatRepository.uploadGroupAvatar(
                imageData: data,
                for: chat,
                requesterID: appState.currentUser.id
            )
            statusMessage = "Group updated."
            self.selectedPhotoItem = nil
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
        }
    }

    @MainActor
    private func removeAvatar() async {
        do {
            chat = try await environment.chatRepository.removeGroupAvatar(for: chat, requesterID: appState.currentUser.id)
            statusMessage = "Group updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
        }
    }

    @MainActor
    private func addSelectedMembers() async {
        isAddingMembers = true
        defer { isAddingMembers = false }

        let existingIDs = Set(chat.participantIDs)
        let memberIDsToAdd = Array(Set(selectedUsers.map(\.id))).filter { existingIDs.contains($0) == false }
        guard memberIDsToAdd.isEmpty == false else {
            statusMessage = "All selected users are already in the group."
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
            statusMessage = "Group updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
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
            statusMessage = "Group updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
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
            statusMessage = "Group updated."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not update the group." : error.localizedDescription
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

    private func toggle(_ user: User) {
        if let existingIndex = selectedUsers.firstIndex(of: user) {
            selectedUsers.remove(at: existingIndex)
        } else {
            selectedUsers.append(user)
        }
    }

    @ViewBuilder
    private func actionButton(title: String, systemName: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(PrimeTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
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
        .buttonStyle(.plain)
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
}

private struct GroupAvatarView: View {
    let title: String
    let photoURL: URL?
    let size: CGFloat

    var body: some View {
        if let photoURL {
            AsyncImage(url: photoURL) { image in
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
