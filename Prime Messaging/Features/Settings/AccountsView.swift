import SwiftUI

struct AccountsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var statusMessage = ""
    @State private var deletingAccountIDs = Set<UUID>()
    @State private var pendingAccountAction: User?
    @State private var pendingDeletionAccount: User?

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
                        pendingAccountAction = appState.accounts[offset]
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
        .confirmationDialog(
            "settings.accounts.actions.title".localized,
            isPresented: Binding(
                get: { pendingAccountAction != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingAccountAction = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingAccountAction
        ) { account in
            Button("settings.account.logout".localized, role: .destructive) {
                appState.removeAccount(account.id)
                statusMessage = "settings.accounts.logged_out".localized
                pendingAccountAction = nil
            }

            Button("settings.accounts.delete_everywhere".localized, role: .destructive) {
                pendingDeletionAccount = account
                pendingAccountAction = nil
            }

            Button("common.cancel".localized, role: .cancel) {
                pendingAccountAction = nil
            }
        } message: { account in
            Text(String(format: "settings.accounts.actions.message".localized, "@\(account.profile.username)"))
        }
        .alert(
            "settings.accounts.delete_everywhere".localized,
            isPresented: Binding(
                get: { pendingDeletionAccount != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletionAccount = nil
                    }
                }
            ),
            presenting: pendingDeletionAccount
        ) { account in
            Button("settings.accounts.delete_confirm".localized, role: .destructive) {
                Task {
                    await deleteAccount(account.id)
                    pendingDeletionAccount = nil
                }
            }
            Button("common.cancel".localized, role: .cancel) {
                pendingDeletionAccount = nil
            }
        } message: { account in
            Text(String(format: "settings.accounts.delete_everywhere.message".localized, "@\(account.profile.username)"))
        }
    }

    @MainActor
    private func deleteAccount(_ accountID: UUID) async {
        deletingAccountIDs.insert(accountID)
        defer { deletingAccountIDs.remove(accountID) }

        do {
            try await environment.authRepository.deleteAccount(userID: accountID)
            appState.removeAccount(accountID)
            statusMessage = "settings.accounts.deleted".localized
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "settings.accounts.delete_failed".localized : error.localizedDescription
        }
    }
}
