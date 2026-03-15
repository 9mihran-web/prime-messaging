import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("settings.account".localized) {
                NavigationLink("settings.profile".localized) {
                    ProfileView()
                }
            }

            Section("settings.privacy".localized) {
                NavigationLink("settings.privacy.controls".localized) {
                    PrivacySettingsView()
                }
            }

            Section("settings.notifications".localized) {
                Label("settings.notifications.push".localized, systemImage: "bell.badge")
                Label("settings.notifications.preview".localized, systemImage: "text.bubble")
            }

            Section("settings.offline".localized) {
                NavigationLink("settings.offline.nearby".localized) {
                    OfflineModeInfoView()
                }
            }
        }
        .navigationTitle("settings.title".localized)
    }
}
