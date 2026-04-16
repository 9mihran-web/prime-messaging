import SwiftUI

struct ContactProfileView: View {
    let user: User
    var chatBinding: Binding<Chat>? = nil
    var onRequestSearch: (() -> Void)? = nil

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
                    if visiblePhone != nil {
                        infoCard(title: "Phone Number", value: visiblePhone ?? "Private")
                    }

                    if visibleEmail != nil {
                        infoCard(title: "E-mail", value: visibleEmail ?? "Private")
                    }

                    if let visibleBirthday {
                        infoCard(title: "Birthday", value: visibleBirthday)
                    }

                    infoCard(title: "Username", value: "@\(user.profile.username)")
                }

                infoPills
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
                    actionHeaderButton(title: "Edit", systemName: "pencil")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            profileActionButton(title: "Call", systemName: "phone.fill", action: startCall)
            soundMenuButton
            profileActionButton(title: "Search", systemName: "magnifyingglass") {
                onRequestSearch?()
            }
            profileActionButton(title: "More", systemName: "ellipsis")
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
            profileActionLabel(title: "Sound", systemName: soundMode == .active ? "bell.fill" : "bell.slash.fill")
        }
        .buttonStyle(.plain)
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

    private var infoPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Media", "Files", "Music", "Voices", "Links"], id: \.self) { item in
                    Text(item)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeTheme.Colors.elevated)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var displayName: String {
        let trimmed = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.profile.username : trimmed
    }

    private var statusLine: String {
        let status = user.profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Last seen recently" : status
    }

    private var visiblePhone: String? {
        if appState.currentUser.isOfflineOnly {
            return nil
        }
        let phoneNumber = user.profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let phoneNumber, phoneNumber.isEmpty == false else {
            return nil
        }
        return user.privacySettings.showPhoneNumber ? phoneNumber : nil
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
