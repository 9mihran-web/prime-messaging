import PhotosUI
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
    @State private var editedUsername = ""
    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarError = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: PrimeTheme.Spacing.medium) {
                    AvatarBadgeView(profile: appState.currentUser.profile, size: 88)
                        .frame(maxWidth: .infinity)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Text("profile.avatar.button".localized)
                    }
                    .buttonStyle(.bordered)

                    Text(appState.currentUser.profile.displayName)
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)

                    if !avatarError.isEmpty {
                        Text(avatarError)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }
                }
            }

            Section("profile.identity".localized) {
                TextField("profile.username".localized, text: $editedUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: editedUsername) { _, newValue in
                        let normalized = appState.normalizedUsername(newValue)
                        if normalized != newValue {
                            editedUsername = normalized
                        }
                    }
                Text(profileUsernameStatus)
                    .font(.footnote)
                    .foregroundStyle(profileUsernameStatusColor)
                Button("profile.username.save".localized) {
                    Task {
                        do {
                            try await environment.settingsRepository.claimUsername(editedUsername, for: appState.currentUser.id)
                            await MainActor.run {
                                appState.updateCurrentUsername(editedUsername)
                                usernameAvailability = .saved
                            }
                        } catch {
                            await MainActor.run {
                                if case UsernameRepositoryError.usernameTaken = error {
                                    usernameAvailability = .taken
                                } else {
                                    usernameAvailability = .unavailable
                                }
                            }
                        }
                    }
                }
                .disabled(usernameAvailability != .available)
                LabeledContent("profile.email".localized, value: appState.currentUser.profile.email ?? "-")
                LabeledContent("profile.phone".localized, value: appState.currentUser.profile.phoneNumber ?? "-")
                LabeledContent("profile.status".localized, value: appState.currentUser.profile.status)
            }
        }
        .navigationTitle("settings.profile".localized)
        .task {
            editedUsername = appState.currentUser.profile.username
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
            return "onboarding.username.hint".localized
        }

        if !appState.isValidUsername(editedUsername) {
            return "onboarding.username.invalid".localized
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

    @MainActor
    private func refreshUsernameAvailability() async {
        guard !editedUsername.isEmpty else {
            usernameAvailability = .idle
            return
        }

        guard appState.isValidUsername(editedUsername) else {
            usernameAvailability = .taken
            return
        }

        if editedUsername == appState.currentUser.profile.username {
            usernameAvailability = .saved
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
    private func uploadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            let updatedUser = try await environment.authRepository.uploadAvatar(imageData: data, for: appState.currentUser.id)
            appState.applyAuthenticatedUser(updatedUser)
            avatarError = ""
        } catch {
            avatarError = "profile.avatar.failed".localized
        }
    }
}
