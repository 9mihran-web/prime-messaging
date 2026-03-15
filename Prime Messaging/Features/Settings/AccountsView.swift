import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("settings.accounts".localized) {
                ForEach(appState.accounts) { account in
                    HStack(spacing: PrimeTheme.Spacing.medium) {
                        AvatarBadgeView(profile: account.profile, size: 44)

                        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                            Text(account.profile.displayName)
                            Text("@\(account.profile.username)")
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }

                        Spacer()

                        if account.id == appState.currentUser.id {
                            Text("settings.accounts.current".localized)
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.success)
                        } else {
                            Button("settings.accounts.switch".localized) {
                                appState.switchToAccount(account.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, PrimeTheme.Spacing.xSmall)
                }
                .onDelete { offsets in
                    for offset in offsets {
                        let account = appState.accounts[offset]
                        appState.removeAccount(account.id)
                    }
                }
            }

            Section {
                Button("settings.account.add".localized) {
                    appState.beginAddingAccount()
                }
            }
        }
        .navigationTitle("settings.accounts".localized)
    }
}
