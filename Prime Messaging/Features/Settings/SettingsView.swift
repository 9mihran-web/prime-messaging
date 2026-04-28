import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var isDeletingAccount = false
    @State private var isShowingDeleteAlert = false
    @State private var isShowingProfileQR = false
    @State private var statusMessage = ""
    @State private var settingsScrollOffset: CGFloat = 0
    @State private var settingsScrollBaselineMinY: CGFloat?

    private static let helpCenterURL = configuredURL(
        for: "PrimeMessagingHelpCenterURL",
        fallback: "https://primemsg.site/helpcenter/"
    )
    private static let privacyPolicyURL = configuredURL(
        for: "PrimeMessagingPrivacyPolicyURL",
        fallback: "https://primemsg.site/privacypolicy/"
    )
    private static let supportEmail = "support@primemsg.site"

    var body: some View {
        GeometryReader { geometry in
            let topInset = geometry.safeAreaInsets.top
            let expandedHeight = max(topInset + 236, min(geometry.size.height * 0.38, topInset + 332))
            let collapsedHeight = topInset + 64
            let collapseDistance = max(1, expandedHeight - collapsedHeight)
            let progress = min(max(settingsScrollOffset / collapseDistance, 0), 1)

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    SettingsScrollOffsetReader()
                    VStack(spacing: 0) {
                        profileHeroCard(
                            topInset: topInset,
                            expandedHeight: expandedHeight,
                            progress: progress
                        )
                        VStack(spacing: 16) {
                            settingsContent
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
                .coordinateSpace(name: "settingsScroll")
                .onPreferenceChange(SettingsScrollOffsetPreferenceKey.self) { minY in
                    if settingsScrollBaselineMinY == nil {
                        settingsScrollBaselineMinY = minY
                    }
                    let baseline = settingsScrollBaselineMinY ?? minY
                    settingsScrollOffset = max(0, baseline - minY)
                }
                .background(PrimeTheme.Colors.background)

                compactProfileBar(
                    topInset: topInset,
                    progress: progress
                )
                .allowsHitTesting(false)
            }
            .background(PrimeTheme.Colors.background.ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            settingsScrollOffset = 0
            settingsScrollBaselineMinY = nil
        }
        .sheet(isPresented: $isShowingProfileQR) {
            NavigationStack {
                profileQRCodeSheet
            }
        }
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

    private var settingsContent: some View {
        VStack(spacing: 16) {
            settingsCard {
                settingsNavigationRow("settings.accounts".localized) { AccountsView() }
                settingsDivider
                settingsNavigationRow("settings.favorites".localized) { FavoritesView() }
                settingsDivider
                settingsNavigationRow("settings.devices".localized) { DevicesView() }
            }

            settingsCard {
                settingsNavigationRow("settings.notifications".localized) { NotificationsView() }
                settingsDivider
                settingsNavigationRow("settings.security".localized) { SecuritySettingsView() }
                settingsDivider
                settingsNavigationRow("settings.privacy".localized) { PrivacySettingsView() }
                settingsDivider
                settingsNavigationRow("settings.blocked_users".localized) { BlockedUsersView() }
                settingsDivider
                settingsNavigationRow("settings.data_storage".localized) { DataAndStorageView() }
                settingsDivider
                settingsNavigationRow("settings.language".localized) { LanguageSettingsView() }
            }

            settingsSectionTitle("settings.offline".localized)
            settingsCard {
                settingsNavigationRow("settings.offline.nearby".localized) { OfflineModeInfoView() }
                settingsDivider
                settingsNavigationRow("settings.nearby.access".localized) { NearbyAccessView() }
            }

            if AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username) {
                settingsSectionTitle("settings.admin_console".localized)
                settingsCard {
                    settingsNavigationRow("settings.admin_console".localized) { AdminConsoleView() }
                }
            }

            settingsSectionTitle("settings.about".localized)
            settingsCard {
                settingsStaticRow("settings.about.creator".localized, value: "Mihran Gevorgyan")
                settingsDivider
                settingsExternalLinkRow(
                    "settings.about.help_center".localized,
                    value: Self.helpCenterURL.host ?? Self.helpCenterURL.absoluteString,
                    url: Self.helpCenterURL
                )
                settingsDivider
                settingsExternalLinkRow(
                    "settings.about.privacy_policy".localized,
                    value: Self.privacyPolicyURL.host ?? Self.privacyPolicyURL.absoluteString,
                    url: Self.privacyPolicyURL
                )
                settingsDivider
                settingsExternalLinkRow(
                    "settings.about.support".localized,
                    value: Self.supportEmail,
                    url: URL(string: "mailto:\(Self.supportEmail)")!
                )
            }

            if !statusMessage.isEmpty {
                settingsCard {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
            }

            settingsCard {
                settingsActionRow(
                    isDeletingAccount ? "settings.delete_account.deleting".localized : "settings.accounts.delete_everywhere".localized,
                    role: .destructive
                ) {
                    isShowingDeleteAlert = true
                }
                .disabled(isDeletingAccount)
                settingsDivider
                settingsActionRow("settings.account.logout".localized, role: .destructive) {
                    appState.logOutCurrentAccount()
                }
            }
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 1)
            .padding(.leading, 18)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PrimeTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .textCase(.uppercase)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(PrimeTheme.Colors.elevated.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func settingsNavigationRow<Destination: View>(
        _ title: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsActionRow(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        return Button(role: role, action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isDestructive ? Color.red : PrimeTheme.Colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(isDestructive ? .red : PrimeTheme.Colors.textPrimary)
    }

    private func settingsStaticRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private func settingsExternalLinkRow(_ title: String, value: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func configuredURL(for key: String, fallback: String) -> URL {
        let candidate = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
        return URL(string: candidate) ?? URL(string: fallback)!
    }

    private func profileHeroCard(
        topInset: CGFloat,
        expandedHeight: CGFloat,
        progress: CGFloat
    ) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let avatarOpacity = max(0, 1 - clampedProgress * 2.2)
        let titleOpacity = max(0, 1 - clampedProgress * 2.1)
        let subtitleOpacity = max(0, 1 - clampedProgress * 2.5)
        let avatarSize = max(54, 126 - (clampedProgress * 72))
        let heroBackgroundOpacity = max(0, 1 - clampedProgress * 1.25)
        let detailsScale = max(0.8, 1 - (clampedProgress * 0.2))

        return ZStack(alignment: .top) {
            ZStack {
                LinearGradient(
                    colors: [
                        PrimeTheme.Colors.accent.opacity(0.96),
                        PrimeTheme.Colors.accentSoft.opacity(0.88),
                        Color.black.opacity(0.72),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.11),
                        .clear,
                    ],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 280
                )
            }
            .opacity(heroBackgroundOpacity)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(clampedProgress * 0.78)

            VStack(spacing: 0) {
                Spacer(minLength: topInset + 22)

                VStack(spacing: 10) {
                    AvatarBadgeView(profile: appState.currentUser.profile, size: avatarSize)
                        .opacity(avatarOpacity)
                        .scaleEffect(1 - (clampedProgress * 0.08))

                    Text(displayName)
                        .font(.system(size: 41, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .opacity(titleOpacity)

                    Text(usernameSummary)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(subtitleOpacity)
                }
                .scaleEffect(detailsScale, anchor: .top)
                .offset(y: -clampedProgress * 50)
                .padding(.horizontal, 24)

                Spacer(minLength: 28)
            }
        }
        .frame(height: expandedHeight + 8)
        .offset(y: -8)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
        .overlay(alignment: .top) {
            HStack {
                profileQRButton
                Spacer()
                profileEditButton
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset + 8)
            .opacity(max(0.18, 1 - clampedProgress * 1.9))
        }
        .clipped()
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: clampedProgress)
    }

    private func compactProfileBar(topInset: CGFloat, progress: CGFloat) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let chromeOpacity = min(1, max(0, (clampedProgress - 0.08) / 0.26))
        let titleOpacity = min(1, max(0, (clampedProgress - 0.2) / 0.24))

        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(chromeOpacity)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            PrimeTheme.Colors.accent.opacity(0.45),
                            PrimeTheme.Colors.accentSoft.opacity(0.2),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(chromeOpacity)

            VStack(spacing: 0) {
                HStack {
                    Text(displayName)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                        .opacity(titleOpacity)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, topInset + 8)
                .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)
                    .opacity(chromeOpacity)
            }
        }
        .frame(height: topInset + 64)
        .offset(y: -1)
        .ignoresSafeArea(edges: .top)
    }

    private var profileQRButton: some View {
        Button {
            isShowingProfileQR = true
        } label: {
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .buttonStyle(.plain)
    }

    private var profileEditButton: some View {
        NavigationLink {
            ProfileView()
        } label: {
            Text("common.edit".localized)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.black.opacity(0.28), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var profileQRCodeSheet: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Profile QR")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                if let qrImage = qrCodeImage(for: qrCodePayload) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 248, height: 248)
                        .padding(14)
                        .background(PrimeTheme.Colors.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Text(displayName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(usernameSummary)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("My QR")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    isShowingProfileQR = false
                }
            }
        }
    }

    private var displayName: String {
        let name = appState.currentUser.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? appState.currentUser.profile.username : name
    }

    private var usernameSummary: String {
        let username = appState.currentUser.profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty {
            return "primemsg.site/u/\(appState.currentUser.id.uuidString)"
        }
        return "@\(username)"
    }

    private var qrCodePayload: String {
        let username = appState.currentUser.profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty {
            return "https://primemsg.site/u/\(appState.currentUser.id.uuidString)"
        }
        return "https://primemsg.site/@\(username)"
    }

    private func qrCodeImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 12, y: 12)
        let context = CIContext()
        let scaledImage = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct SettingsScrollOffsetReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: SettingsScrollOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named("settingsScroll")).minY
                )
        }
        .frame(height: 0)
    }
}

private struct SettingsScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BlockedUsersView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var blockedUsers: [User] = []
    @State private var isLoading = false
    @State private var statusMessage = ""

    var body: some View {
        List {
            if blockedUsers.isEmpty, isLoading == false {
                Section {
                    Text("settings.blocked_users.empty".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                Section {
                    ForEach(blockedUsers, id: \.id) { blockedUser in
                        HStack(spacing: 12) {
                            AvatarBadgeView(profile: blockedUser.profile, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(blockedUser.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? blockedUser.profile.username : blockedUser.profile.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text("@\(blockedUser.profile.username)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }

                            Spacer()

                            Button("settings.blocked_users.unblock".localized) {
                                Task {
                                    await unblock(blockedUser)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("settings.blocked_users.unblock".localized, role: .destructive) {
                                Task {
                                    await unblock(blockedUser)
                                }
                            }
                        }
                    }
                }
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
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
        .navigationTitle("settings.blocked_users".localized)
        .task {
            await loadBlockedUsers()
        }
        .refreshable {
            await loadBlockedUsers()
        }
    }

    @MainActor
    private func loadBlockedUsers() async {
        isLoading = true
        defer { isLoading = false }

        do {
            blockedUsers = try await environment.authRepository.fetchBlockedUsers(for: appState.currentUser.id)
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription.isEmpty
                ? "settings.blocked_users.load_failed".localized
                : error.localizedDescription
        }
    }

    @MainActor
    private func unblock(_ user: User) async {
        do {
            try await environment.authRepository.unblockUser(user.id, for: appState.currentUser.id)
            blockedUsers.removeAll(where: { $0.id == user.id })
            statusMessage = "settings.blocked_users.unblocked".localized
        } catch {
            statusMessage = error.localizedDescription.isEmpty
                ? "settings.blocked_users.action_failed".localized
                : error.localizedDescription
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

            Section("Password") {
                NavigationLink("Request password change") {
                    PasswordRecoverySettingsView()
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

private struct PasswordRecoverySettingsView: View {
    private enum Step {
        case email
        case otp
        case newPassword
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var step: Step = .email
    @State private var email: String = ""
    @State private var otpCode: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var challenge: OTPChallenge?
    @State private var verifiedChallengeID: String?
    @State private var isLoading = false
    @State private var statusMessage = ""

    var body: some View {
        Form {
            switch step {
            case .email:
                Section("Recovery E-mail") {
                    TextField("E-mail", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(isLoading ? "Sending..." : "Send OTP") {
                        Task { await sendOTP() }
                    }
                    .disabled(isLoading || appState.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == false)
                }
            case .otp:
                Section("E-mail OTP") {
                    if let challenge {
                        Text("Sent to \(challenge.destinationMasked)")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                    TextField("OTP Code", text: $otpCode)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(isLoading ? "Verifying..." : "Verify OTP") {
                        Task { await verifyOTP() }
                    }
                    .disabled(isLoading || otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .newPassword:
                Section("New Password") {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                    Button(isLoading ? "Saving..." : "Change Password") {
                        Task { await changePassword() }
                    }
                    .disabled(isLoading || newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .navigationTitle("Password Reset")
        .onAppear {
            if email.isEmpty {
                email = appState.currentUser.profile.email ?? ""
            }
        }
    }

    @MainActor
    private func sendOTP() async {
        isLoading = true
        statusMessage = ""
        defer { isLoading = false }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard appState.isValidEmail(normalizedEmail) else {
            statusMessage = "Enter a valid e-mail address."
            return
        }

        do {
            challenge = try await environment.authRepository.requestOTP(identifier: normalizedEmail, purpose: .resetPassword)
            otpCode = ""
            verifiedChallengeID = nil
            step = .otp
            statusMessage = "OTP sent to e-mail."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not send OTP." : error.localizedDescription
        }
    }

    @MainActor
    private func verifyOTP() async {
        isLoading = true
        statusMessage = ""
        defer { isLoading = false }

        guard let challengeID = challenge?.challengeID else {
            statusMessage = "OTP challenge is missing. Request a new code."
            step = .email
            return
        }
        let trimmedOTP = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOTP.isEmpty == false else {
            statusMessage = "Enter OTP code."
            return
        }

        do {
            _ = try await environment.authRepository.verifyOTPChallenge(challengeID: challengeID, otpCode: trimmedOTP)
            verifiedChallengeID = challengeID
            step = .newPassword
            statusMessage = "OTP verified. Set your new password."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "OTP verification failed." : error.localizedDescription
        }
    }

    @MainActor
    private func changePassword() async {
        isLoading = true
        statusMessage = ""
        defer { isLoading = false }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard appState.isValidEmail(normalizedEmail) else {
            statusMessage = "Enter a valid e-mail address."
            return
        }
        guard trimmedPassword.isEmpty == false else {
            statusMessage = "Password cannot be empty."
            return
        }
        guard trimmedPassword == trimmedConfirm else {
            statusMessage = "Passwords do not match."
            return
        }
        guard let verifiedChallengeID else {
            statusMessage = "OTP verification is required."
            step = .email
            return
        }

        do {
            try await environment.authRepository.resetPassword(
                identifier: normalizedEmail,
                newPassword: trimmedPassword,
                challengeID: verifiedChallengeID
            )
            statusMessage = "Password changed successfully."
            step = .email
            otpCode = ""
            newPassword = ""
            confirmPassword = ""
            challenge = nil
            self.verifiedChallengeID = nil
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not change password." : error.localizedDescription
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
