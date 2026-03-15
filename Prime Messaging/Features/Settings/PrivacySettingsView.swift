import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var settings = PrivacySettings.defaultEmailOnly

    var body: some View {
        Form {
            Toggle("privacy.show_email".localized, isOn: $settings.showEmail)
            Toggle("privacy.show_phone".localized, isOn: $settings.showPhoneNumber)
            Toggle("privacy.last_seen".localized, isOn: $settings.allowLastSeen)
            Toggle("privacy.profile_photo".localized, isOn: $settings.allowProfilePhoto)
            Toggle("privacy.calls".localized, isOn: $settings.allowCallsFromNonContacts)
            Toggle("privacy.group_invites".localized, isOn: $settings.allowGroupInvitesFromNonContacts)
            Toggle("privacy.forwarding".localized, isOn: $settings.allowForwardLinkToProfile)
        }
        .navigationTitle("settings.privacy.controls".localized)
        .task {
            do {
                settings = try await environment.settingsRepository.fetchPrivacySettings()
            } catch { }
        }
        .onDisappear {
            Task {
                try? await environment.settingsRepository.updatePrivacySettings(settings)
            }
        }
    }
}
