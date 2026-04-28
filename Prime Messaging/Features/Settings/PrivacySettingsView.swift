import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var settings = PrivacySettings.defaultEmailOnly

    var body: some View {
        Form {
            Toggle("privacy.show_email".localized, isOn: $settings.showEmail)
            Toggle("privacy.last_seen".localized, isOn: $settings.allowLastSeen)
            Toggle("privacy.profile_photo".localized, isOn: $settings.allowProfilePhoto)
            Toggle("privacy.calls".localized, isOn: $settings.allowCallsFromNonContacts)
            Toggle("privacy.group_invites".localized, isOn: $settings.allowGroupInvitesFromNonContacts)
            Toggle("privacy.forwarding".localized, isOn: $settings.allowForwardLinkToProfile)

            Picker("Guest message requests", selection: $settings.guestMessageRequests) {
                Text("Approve first").tag(GuestMessageRequestPolicy.approvalRequired)
                Text("Block guest requests").tag(GuestMessageRequestPolicy.blocked)
            }
        }
        .navigationTitle("settings.privacy.controls".localized)
        .task {
            do {
                settings = try await environment.settingsRepository.fetchPrivacySettings()
            } catch { }
        }
        .onDisappear {
            var resolvedSettings = settings
            resolvedSettings.showPhoneNumber = false
            Task {
                do {
                    try await environment.settingsRepository.updatePrivacySettings(resolvedSettings)
                    await MainActor.run {
                        var updatedUser = appState.currentUser
                        updatedUser.privacySettings = resolvedSettings
                        appState.applyAuthenticatedUser(
                            updatedUser,
                            requiresServerSessionValidation: appState.requiresServerSessionValidation
                        )
                    }
                } catch { }
            }
        }
    }
}
