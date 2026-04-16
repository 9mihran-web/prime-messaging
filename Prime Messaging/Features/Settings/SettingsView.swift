import SwiftUI

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var isDeletingAccount = false
    @State private var isShowingDeleteAlert = false
    @State private var statusMessage = ""

    var body: some View {
        List {
            Section {
                NavigationLink("settings.profile".localized) {
                    ProfileView()
                }
                NavigationLink("settings.accounts".localized) {
                    AccountsView()
                }
                NavigationLink("settings.favorites".localized) {
                    FavoritesView()
                }
                NavigationLink("settings.devices".localized) {
                    DevicesView()
                }
            }

            Section {
                NavigationLink("settings.notifications".localized) {
                    NotificationsView()
                }
                NavigationLink("Security") {
                    SecuritySettingsView()
                }
                NavigationLink("settings.privacy".localized) {
                    PrivacySettingsView()
                }
                NavigationLink("settings.data_storage".localized) {
                    DataAndStorageView()
                }
                NavigationLink("settings.language".localized) {
                    LanguageSettingsView()
                }
            }

            Section("settings.offline".localized) {
                NavigationLink("settings.offline.nearby".localized) {
                    OfflineModeInfoView()
                }
                NavigationLink("settings.nearby.access".localized) {
                    NearbyAccessView()
                }
            }

            if AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username) {
                Section("settings.admin_console".localized) {
                    NavigationLink("settings.admin_console".localized) {
                        AdminConsoleView()
                    }
                }
            }

            Section("settings.about".localized) {
                LabeledContent("settings.about.corporation".localized, value: "Prime Holding")
                LabeledContent("settings.about.creator".localized, value: "Mihran Gevorgyan")
                Text("settings.about.footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            Section {
                Button("settings.account.logout".localized, role: .destructive) {
                    appState.logOutCurrentAccount()
                }

                Button(isDeletingAccount ? "settings.delete_account.deleting".localized : "settings.accounts.delete_everywhere".localized, role: .destructive) {
                    isShowingDeleteAlert = true
                }
                .disabled(isDeletingAccount)
            }
        }
        .navigationTitle("settings.title".localized)
        .alert("settings.accounts.delete_everywhere".localized, isPresented: $isShowingDeleteAlert) {
            Button("settings.accounts.delete_confirm".localized, role: .destructive) {
                Task {
                    await deleteCurrentAccount()
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("settings.delete_account.message".localized)
        }
    }

    @MainActor
    private func deleteCurrentAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            let currentUserID = appState.currentUser.id
            try await environment.authRepository.deleteAccount(userID: currentUserID)
            appState.logOutCurrentAccount()
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "settings.accounts.delete_failed".localized : error.localizedDescription
        }
    }
}

struct SecuritySettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLockStore = AppLockStore.shared

    @State private var is2FAEnabled = false
    @State private var backupCodesRemaining = 0
    @State private var generatedBackupCodes: [String] = []
    @State private var twoFactorCodeInput = ""
    @State private var statusMessage = ""
    @State private var isLoading = false
    @State private var isShowingEnableSheet = false
    @State private var isShowingDisableSheet = false
    @State private var isShowingRegenerateSheet = false
    @State private var isShowingAppLockSetup = false
    @State private var appLockPasscodeFirst = ""
    @State private var appLockPasscodeConfirm = ""
    @State private var isShowingFaceIDPrompt = false

    var body: some View {
        List {
            Section("App Lock") {
                if appLockStore.isConfigured == false {
                    Button("Setup App Lock") {
                        appLockPasscodeFirst = ""
                        appLockPasscodeConfirm = ""
                        isShowingAppLockSetup = true
                    }
                } else {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(appLockStore.isEnabled ? "Enabled" : "Disabled")
                            .foregroundStyle(appLockStore.isEnabled ? PrimeTheme.Colors.success : PrimeTheme.Colors.textSecondary)
                    }
                    Toggle("Use Face ID", isOn: $appLockStore.usesBiometrics)
                        .disabled(appLockStore.isEnabled == false)
                    Button("Lock App Now") {
                        appLockStore.lockFromUserAction()
                    }
                    if appLockStore.isEnabled {
                        Button("Disable App Lock", role: .destructive) {
                            appLockStore.disableAppLock()
                        }
                    } else {
                        Button("Enable App Lock") {
                            appLockStore.isEnabled = true
                        }
                    }
                }
            }

            Section("Two-Factor Authentication") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(is2FAEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(is2FAEnabled ? PrimeTheme.Colors.success : PrimeTheme.Colors.textSecondary)
                }
                HStack {
                    Text("Backup codes")
                    Spacer()
                    Text("\(backupCodesRemaining)")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                if is2FAEnabled {
                    Button("Disable 2FA", role: .destructive) {
                        twoFactorCodeInput = ""
                        isShowingDisableSheet = true
                    }
                    Button("Regenerate backup codes") {
                        twoFactorCodeInput = ""
                        isShowingRegenerateSheet = true
                    }
                } else {
                    Button("Enable 2FA") {
                        twoFactorCodeInput = ""
                        isShowingEnableSheet = true
                    }
                }
            }

            if generatedBackupCodes.isEmpty == false {
                Section("Backup Codes") {
                    ForEach(generatedBackupCodes, id: \.self) { code in
                        HStack {
                            Text(code)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                            Spacer()
                            Button {
                                UIPasteboard.general.string = code
                                statusMessage = "Code copied."
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if statusMessage.isEmpty == false {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("Security")
        .task {
            await load2FAStatus()
        }
        .sheet(isPresented: $isShowingEnableSheet) {
            twoFactorActionSheet(
                title: "Enable 2FA",
                actionTitle: "Enable",
                actionRole: nil
            ) {
                await enableTwoFactor()
            }
        }
        .sheet(isPresented: $isShowingDisableSheet) {
            twoFactorActionSheet(
                title: "Disable 2FA",
                actionTitle: "Disable",
                actionRole: .destructive
            ) {
                await disableTwoFactor()
            }
        }
        .sheet(isPresented: $isShowingRegenerateSheet) {
            twoFactorActionSheet(
                title: "Regenerate Backup Codes",
                actionTitle: "Regenerate",
                actionRole: nil
            ) {
                await regenerateBackupCodes()
            }
        }
        .sheet(isPresented: $isShowingAppLockSetup) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Enter new passcode", text: $appLockPasscodeFirst)
                            .keyboardType(.numberPad)
                            .textContentType(.newPassword)
                        SecureField("Re-enter passcode", text: $appLockPasscodeConfirm)
                            .keyboardType(.numberPad)
                            .textContentType(.newPassword)
                    } header: {
                        Text("Create Passcode")
                    } footer: {
                        Text("Enter the same passcode twice. Minimum 4 digits.")
                    }
                }
                .navigationTitle("Setup App Lock")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            isShowingAppLockSetup = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            let first = appLockPasscodeFirst.trimmingCharacters(in: .whitespacesAndNewlines)
                            let confirm = appLockPasscodeConfirm.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard first.count >= 4 else {
                                statusMessage = "Passcode must be at least 4 digits."
                                return
                            }
                            guard first == confirm else {
                                statusMessage = "Passcodes do not match."
                                return
                            }
                            appLockStore.completeSetup(passcode: first, enableBiometrics: false)
                            isShowingAppLockSetup = false
                            isShowingFaceIDPrompt = true
                            statusMessage = "App Lock configured."
                        }
                    }
                }
            }
        }
        .alert("Enable Face ID?", isPresented: $isShowingFaceIDPrompt) {
            Button("Enable") {
                appLockStore.usesBiometrics = true
            }
            Button("Not now", role: .cancel) {
                appLockStore.usesBiometrics = false
            }
        } message: {
            Text("Use Face ID to unlock Prime Messaging faster.")
        }
    }

    @ViewBuilder
    private func twoFactorActionSheet(
        title: String,
        actionTitle: String,
        actionRole: ButtonRole?,
        onAction: @escaping @MainActor () async -> Void
    ) -> some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Enter 2FA code", text: $twoFactorCodeInput)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                } footer: {
                    Text("Use your current 2FA code. For disable, a backup code also works.")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        isShowingEnableSheet = false
                        isShowingDisableSheet = false
                        isShowingRegenerateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(actionTitle, role: actionRole) {
                        Task {
                            await onAction()
                        }
                    }
                    .disabled(twoFactorCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
        }
    }

    @MainActor
    private func load2FAStatus() async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/auth/2fa-status",
                method: "GET",
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                statusMessage = "Failed to load 2FA status."
                return
            }
            let payload = try BackendJSONDecoder.make().decode(TwoFactorStatusPayload.self, from: data)
            is2FAEnabled = payload.twoFactorEnabled
            backupCodesRemaining = payload.backupCodesRemaining
            statusMessage = ""
        } catch {
            statusMessage = "Failed to load 2FA status."
        }
    }

    @MainActor
    private func enableTwoFactor() async {
        await performTwoFactorMutation(
            path: "/auth/2fa-enable",
            body: ["code": twoFactorCodeInput]
        ) { payload in
            is2FAEnabled = true
            generatedBackupCodes = payload.backupCodes
            backupCodesRemaining = payload.backupCodesRemaining
            statusMessage = "2FA enabled. Save backup codes."
            isShowingEnableSheet = false
        }
    }

    @MainActor
    private func disableTwoFactor() async {
        await performTwoFactorMutation(
            path: "/auth/2fa-disable",
            body: [
                "code": twoFactorCodeInput,
                "backup_code": twoFactorCodeInput.uppercased(),
            ]
        ) { _ in
            is2FAEnabled = false
            generatedBackupCodes = []
            backupCodesRemaining = 0
            statusMessage = "2FA disabled."
            isShowingDisableSheet = false
        }
    }

    @MainActor
    private func regenerateBackupCodes() async {
        await performTwoFactorMutation(
            path: "/auth/2fa-regenerate-backup",
            body: ["code": twoFactorCodeInput]
        ) { payload in
            generatedBackupCodes = payload.backupCodes
            backupCodesRemaining = payload.backupCodesRemaining
            statusMessage = "Backup codes regenerated."
            isShowingRegenerateSheet = false
        }
    }

    @MainActor
    private func performTwoFactorMutation(
        path: String,
        body: [String: String],
        onSuccess: @MainActor (TwoFactorMutationPayload) -> Void
    ) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let requestBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: requestBody,
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                statusMessage = "2FA request failed."
                return
            }

            let payload = (try? BackendJSONDecoder.make().decode(TwoFactorMutationPayload.self, from: data))
                ?? TwoFactorMutationPayload(ok: true, backupCodes: [], backupCodesRemaining: 0)
            onSuccess(payload)
        } catch {
            statusMessage = "2FA request failed."
        }
    }
}

private struct TwoFactorStatusPayload: Decodable {
    let twoFactorEnabled: Bool
    let backupCodesRemaining: Int
}

private struct TwoFactorMutationPayload: Decodable {
    let ok: Bool
    let backupCodes: [String]
    let backupCodesRemaining: Int
}
