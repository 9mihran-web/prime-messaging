import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: PrimeTheme.Spacing.medium) {
                    Circle()
                        .fill(PrimeTheme.Colors.accent.opacity(0.85))
                        .frame(width: 88, height: 88)
                        .overlay(
                            Text(String(appState.currentUser.profile.displayName.prefix(1)))
                                .font(.largeTitle.bold())
                                .foregroundStyle(Color.white)
                        )
                        .frame(maxWidth: .infinity)

                    Text(appState.currentUser.profile.displayName)
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                }
            }

            Section("profile.identity".localized) {
                LabeledContent("profile.username".localized, value: appState.currentUser.profile.username)
                LabeledContent("profile.email".localized, value: appState.currentUser.profile.email ?? "-")
                LabeledContent("profile.phone".localized, value: appState.currentUser.profile.phoneNumber ?? "-")
                LabeledContent("profile.status".localized, value: appState.currentUser.profile.status)
            }
        }
        .navigationTitle("settings.profile".localized)
    }
}
