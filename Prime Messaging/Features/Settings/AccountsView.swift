import SwiftUI

struct AccountsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var statusMessage = ""
    @State private var deletingAccountIDs = Set<UUID>()

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

                        if deletingAccountIDs.contains(account.id) {
                            ProgressView()
                        } else if account.id == appState.currentUser.id {
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
                        Task {
                            await deleteAccount(account.id)
                        }
                    }
                }
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
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

    @MainActor
    private func deleteAccount(_ accountID: UUID) async {
        deletingAccountIDs.insert(accountID)
        defer { deletingAccountIDs.remove(accountID) }

        do {
            try await environment.authRepository.deleteAccount(userID: accountID)
            appState.removeAccount(accountID)
            statusMessage = "Account deleted."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not delete account." : error.localizedDescription
        }
    }
}
