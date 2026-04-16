#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
private typealias ProfilePhotoPickerItem = PhotosPickerItem
#else
private struct ProfilePhotoPickerItem: Hashable {}
#endif
import SwiftUI

struct ProfileView: View {
    enum UsernameAvailability {
        case idle
        case checking
        case available
        case taken
        case saved
        case unavailable
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var editedDisplayName = ""
    @State private var editedStatus = ""
    @State private var editedBio = ""
    @State private var editedUsername = ""
    @State private var editedBirthday = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now
    @State private var editedEmail = ""
    @State private var editedPhone = ""

    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var selectedPhotoItem: ProfilePhotoPickerItem?
    @State private var avatarError = ""
    @State private var profileMessage = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordMessage = ""
    @State private var isSavingProfile = false
    @State private var isSavingPassword = false

    var body: some View {
        List {
            if appState.currentUser.canUploadAvatar {
                Section {
                    VStack(alignment: .center, spacing: PrimeTheme.Spacing.medium) {
                        AvatarBadgeView(profile: appState.currentUser.profile, size: 88)
                            .frame(maxWidth: .infinity)

                        #if canImport(PhotosUI) && !os(tvOS)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Text("Change Avatar")
                        }
                        .buttonStyle(.bordered)
                        #else
                        Text("Avatar upload is unavailable on Apple TV.")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        #endif

                        if appState.currentUser.profile.profilePhotoURL != nil {
                            Button("Remove Avatar", role: .destructive) {
                                Task {
                                    await removeAvatar()
                                }
                            }
                        }

                        if !avatarError.isEmpty {
                            Text(avatarError)
                                .font(.footnote)
                                .foregroundStyle(PrimeTheme.Colors.warning)
                        }
                    }
                }
            }

            Section("Public Profile") {
                TextField("Display name", text: $editedDisplayName)
                TextField("Status", text: $editedStatus)
                TextField("Bio", text: $editedBio, axis: .vertical)
                    .lineLimit(3 ... 5)
                #if !os(tvOS)
                DatePicker("Birthday", selection: $editedBirthday, in: ...Date.now, displayedComponents: .date)
                #else
                LabeledContent("Birthday", value: editedBirthday.formatted(date: .abbreviated, time: .omitted))
                #endif
            }

            if appState.currentUser.canEditAdvancedProfile {
                Section("Username") {
                    TextField("profile.username".localized, text: $editedUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: editedUsername) { newValue in
                            let normalized = appState.normalizedUsername(newValue)
                            if normalized != newValue {
                                editedUsername = normalized
                            }
                        }

                    Text(profileUsernameStatus)
                        .font(.footnote)
                        .foregroundStyle(profileUsernameStatusColor)

                    Button("Save username") {
                        Task {
                            await saveUsername()
                        }
                    }
                    .disabled(usernameAvailability != .available)
                }
            } else {
                Section("Guest Mode") {
                    Text("Guest accounts can change only the basic name, status, and bio for now.")
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            if appState.currentUser.canEditAdvancedProfile {
                Section("Contacts") {
                    TextField("E-mail", text: $editedEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if appState.currentUser.isOfflineOnly == false {
                        TextField("Phone", text: $editedPhone)
                            .keyboardType(.phonePad)
                    }
                }
            }

            Section {
                Button(isSavingProfile ? "Saving..." : "Save profile") {
                    Task {
                        await saveProfile()
                    }
                }
                .disabled(isSavingProfile || editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !profileMessage.isEmpty {
                    Text(profileMessage)
                        .font(.footnote)
                        .foregroundStyle(profileMessageColor)
                }
            }

            if appState.currentUser.isGuest == false {
                Section("Password") {
                    SecureField("New password", text: $newPassword)
                    SecureField("Repeat new password", text: $confirmPassword)

                    Button(isSavingPassword ? "Updating..." : "Update password") {
                        Task {
                            await updatePassword()
                        }
                    }
                    .disabled(isSavingPassword || newPassword.isEmpty || confirmPassword.isEmpty)

                    if !passwordMessage.isEmpty {
                        Text(passwordMessage)
                            .font(.footnote)
                            .foregroundStyle(passwordMessageColor)
                    }
                }
            }
        }
        .navigationTitle("settings.profile".localized)
        .task(id: appState.currentUser.id) {
            synchronizeForm()
        }
        .task(id: editedUsername) {
            await refreshUsernameAvailability()
        }
        .task(id: selectedPhotoItem) {
            await uploadSelectedPhoto()
        }
    }

    private var profileUsernameStatus: String {
        if editedUsername.isEmpty {
            return "Use 5-32 characters with only a-z, 0-9, or _."
        }

        if editedUsername == appState.currentUser.profile.username, appState.isValidLegacyUsername(editedUsername) {
            return "profile.username.saved".localized
        }

        if !appState.isValidUsername(editedUsername) {
            return "Use 5-32 characters with only a-z, 0-9, or _."
        }

        switch usernameAvailability {
        case .idle, .checking:
            return "onboarding.username.checking".localized
        case .available:
            return "onboarding.username.available".localized
        case .taken:
            return "onboarding.username.taken".localized
        case .saved:
            return "profile.username.saved".localized
        case .unavailable:
            return "auth.server.unavailable".localized
        }
    }

    private var profileUsernameStatusColor: Color {
        switch usernameAvailability {
        case .available, .saved:
            return PrimeTheme.Colors.success
        case .taken, .unavailable:
            return PrimeTheme.Colors.warning
        case .idle, .checking:
            return PrimeTheme.Colors.textSecondary
        }
    }

    private var profileMessageColor: Color {
        profileMessage == "Profile updated." ? PrimeTheme.Colors.success : PrimeTheme.Colors.warning
    }

    private var passwordMessageColor: Color {
        passwordMessage == "Password updated." ? PrimeTheme.Colors.success : PrimeTheme.Colors.warning
    }

    private func synchronizeForm() {
        editedDisplayName = appState.currentUser.profile.displayName
        editedStatus = appState.currentUser.profile.status
        editedBio = appState.currentUser.profile.bio
        editedUsername = appState.currentUser.profile.username
        editedBirthday = appState.currentUser.profile.birthday ?? (Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now)
        editedEmail = appState.currentUser.profile.email ?? ""
        editedPhone = appState.currentUser.profile.phoneNumber ?? ""
        profileMessage = ""
        passwordMessage = ""
    }

    @MainActor
    private func refreshUsernameAvailability() async {
        guard !editedUsername.isEmpty else {
            usernameAvailability = .idle
            return
        }

        if editedUsername == appState.currentUser.profile.username, appState.isValidLegacyUsername(editedUsername) {
            usernameAvailability = .saved
            return
        }

        guard appState.isValidUsername(editedUsername) else {
            usernameAvailability = .taken
            return
        }

        usernameAvailability = .checking

        do {
            let available = try await environment.settingsRepository.isUsernameAvailable(editedUsername, for: appState.currentUser.id)
            usernameAvailability = available ? .available : .taken
        } catch {
            usernameAvailability = .unavailable
        }
    }

    @MainActor
    private func saveUsername() async {
        do {
            try await environment.settingsRepository.claimUsername(editedUsername, for: appState.currentUser.id)
            appState.updateCurrentUsername(editedUsername)
            usernameAvailability = .saved
            profileMessage = "Profile updated."
        } catch {
            profileMessage = error.localizedDescription.isEmpty ? "Could not save username." : error.localizedDescription
        }
    }

    @MainActor
    private func saveProfile() async {
        isSavingProfile = true
        defer { isSavingProfile = false }

        var profile = appState.currentUser.profile
        profile.displayName = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.status = editedStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.bio = editedBio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.birthday = editedBirthday
        profile.email = editedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.phoneNumber = editedPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editedPhone.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var user = try await environment.authRepository.updateProfile(profile, for: appState.currentUser.id)
            if user.profile.birthday == nil {
                user.profile.birthday = profile.birthday
            }
            appState.refreshCurrentUserPreservingNavigation(user)
            synchronizeForm()
            profileMessage = "Profile updated."
        } catch {
            profileMessage = error.localizedDescription.isEmpty ? "Could not update profile." : error.localizedDescription
        }
    }

    @MainActor
    private func updatePassword() async {
        guard newPassword == confirmPassword else {
            passwordMessage = "Passwords do not match."
            return
        }

        guard newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            passwordMessage = "Password cannot be empty."
            return
        }

        isSavingPassword = true
        defer { isSavingPassword = false }

        do {
            try await environment.authRepository.updatePassword(newPassword, for: appState.currentUser.id)
            newPassword = ""
            confirmPassword = ""
            passwordMessage = "Password updated."
        } catch {
            passwordMessage = error.localizedDescription.isEmpty ? "Could not update password." : error.localizedDescription
        }
    }

    @MainActor
    private func uploadSelectedPhoto() async {
        #if canImport(PhotosUI) && !os(tvOS)
        guard let selectedPhotoItem else { return }
        defer { self.selectedPhotoItem = nil }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            let updatedUser = try await environment.authRepository.uploadAvatar(imageData: data, for: appState.currentUser.id)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
            synchronizeForm()
            avatarError = ""
            profileMessage = "Profile updated."
        } catch {
            avatarError = "profile.avatar.failed".localized
        }
        #else
        avatarError = "Avatar upload is unavailable on Apple TV."
        #endif
    }

    @MainActor
    private func removeAvatar() async {
        do {
            let updatedUser = try await environment.authRepository.removeAvatar(for: appState.currentUser.id)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
            synchronizeForm()
            avatarError = ""
            profileMessage = "Profile updated."
        } catch {
            avatarError = error.localizedDescription.isEmpty ? "Could not remove avatar." : error.localizedDescription
        }
    }
}
