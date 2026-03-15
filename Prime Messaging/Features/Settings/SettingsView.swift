import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("settings.account".localized) {
                NavigationLink("settings.profile".localized) {
                    ProfileView()
                }
                NavigationLink("settings.accounts".localized) {
                    AccountsView()
                }
                Button("settings.account.add".localized) {
                    appState.beginAddingAccount()
                }
                Button("settings.account.logout".localized, role: .destructive) {
                    appState.logOutCurrentAccount()
                }
            }

            Section("settings.language".localized) {
                Picker("settings.language".localized, selection: Binding(
                    get: { appState.selectedLanguage },
                    set: { appState.updateLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
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
                NavigationLink("settings.nearby.access".localized) {
                    NearbyAccessView()
                }
            }

            Section("settings.about".localized) {
                LabeledContent("Brand", value: "MG Collective")
                LabeledContent("Creator", value: "Mihran Gevorgyan")
                Text("settings.about.body".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
        .navigationTitle("settings.title".localized)
    }
}
