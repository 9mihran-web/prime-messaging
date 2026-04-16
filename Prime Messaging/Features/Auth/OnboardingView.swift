#if canImport(Contacts)
import Contacts
#endif
import SwiftUI

struct OnboardingView: View {
    private enum FlowMode: String {
        case standard
        case offlineOnly
        case guest

        var accountKind: AccountKind {
            switch self {
            case .standard:
                return .standard
            case .offlineOnly:
                return .offlineOnly
            case .guest:
                return .guest
            }
        }
    }

    private enum Step: String {
        case entry
        case password
        case createPassword
        case resetPassword
        case profile
        case guestProfile
    }

    private enum UsernameAvailability {
        case idle
        case checking
        case available
        case taken
        case unavailable
    }

    private enum PendingIdentifierKind: String {
        case phone
        case username
        case email

        var title: String {
            switch self {
            case .phone:
                return "Phone"
            case .username:
                return "Username"
            case .email:
                return "E-mail"
            }
        }
    }

    private struct CountryDialCode: Identifiable, Hashable {
        let name: String
        let code: String

        var id: String { code }

        static let all: [CountryDialCode] = [
            CountryDialCode(name: "Armenia", code: "+374"),
            CountryDialCode(name: "Georgia", code: "+995"),
            CountryDialCode(name: "Russia", code: "+7"),
            CountryDialCode(name: "United States", code: "+1"),
            CountryDialCode(name: "United Kingdom", code: "+44"),
            CountryDialCode(name: "United Arab Emirates", code: "+971")
        ]

        static let `default` = CountryDialCode.all.first { $0.code == "+374" } ?? CountryDialCode(name: "Armenia", code: "+374")
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var mode: FlowMode = .standard
    @State private var step: Step = .entry
    @State private var selectedCountry = CountryDialCode.default
    @State private var localIdentifierInput = ""
    @State private var email = ""
    @State private var passwordInput = ""
    @State private var confirmPasswordInput = ""
    @State private var pendingPassword = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var birthDate = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now
    @State private var pendingIdentifier = ""
    @State private var pendingContactValue = ""
    @State private var pendingIdentifierKind: PendingIdentifierKind = .phone
    @State private var pendingLookup: AccountLookupResult?
    @State private var authError = ""
    @State private var isSubmitting = false
    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var hasRestoredPersistedState = false
    @State private var onboardingPersistenceTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar

                switch step {
                case .entry:
                    entryStep
                case .password:
                    passwordStep
                case .createPassword:
                    createPasswordStep
                case .resetPassword:
                    resetPasswordStep
                case .profile:
                    profileStep
                case .guestProfile:
                    guestProfileStep
                }

                if authError.isEmpty == false {
                    Text(authError)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }
            .padding(24)
        }
        .background(PrimeTheme.Colors.background)
        .task {
            await restorePersistedStateIfNeeded()
        }
        .task(id: username + "\(step)") {
            await refreshUsernameAvailability()
        }
        .onChange(of: persistedOnboardingState) { _ in
            scheduleOnboardingProgressPersistence()
        }
        .onChange(of: username) { newValue in
            let normalized = appState.normalizedUsername(newValue)
            if normalized != newValue {
                username = normalized
            }
        }
        .onDisappear {
            onboardingPersistenceTask?.cancel()
        }
    }

    private var topBar: some View {
        HStack {
            if canGoBack {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle()
                                .fill(PrimeTheme.Colors.elevated)
                        )
                        .overlay(
                            Circle()
                                .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private var entryStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode == .offlineOnly ? "Offline-Only Access" : "Enter Phone Number Or Username")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(entrySubtitle)
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            if mode == .standard {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(CountryDialCode.all) { country in
                            Button("\(country.name) \(country.code)") {
                                selectedCountry = country
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedCountry.code)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .frame(width: 112)
                        .frame(minHeight: 58)
                        .background(PrimeTheme.Colors.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    TextField("Phone number or username", text: $localIdentifierInput)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(PrimeTheme.Spacing.large)
                        .background(PrimeTheme.Colors.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                }

                Text("Use phone in international format like +37499111222, or enter a username like @prime_user.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            } else {
                TextField("E-mail", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(PrimeTheme.Spacing.large)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                Text("Phone number is not required for offline-only accounts. E-mail is mandatory.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Button(isSubmitting ? "Continuing..." : entryPrimaryButtonTitle) {
                Task {
                    await continueFromEntry()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || isEntryDisabled)

            if mode == .standard {
                Button("I Will Use Only Offline Mode") {
                    authError = ""
                    mode = .offlineOnly
                    email = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Button("Guest Mode") {
                    authError = ""
                    mode = .guest
                    step = .guestProfile
                    displayName = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
            } else {
                Button("Use Phone Number Instead") {
                    authError = ""
                    mode = .standard
                    clearPasswordDrafts()
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Button("Guest Mode") {
                    authError = ""
                    mode = .guest
                    step = .guestProfile
                    displayName = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
            }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter Password")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(passwordSubtitle)
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            infoField(title: pendingIdentifierKind.title, value: pendingContactValue)

            SecureField("Password", text: $passwordInput)
                .textContentType(.password)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Signing In..." : "Continue") {
                Task {
                    await submitPasswordLogin()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || passwordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            HStack {
                Button("I Forgot Password") {
                    authError = ""
                    passwordInput = ""
                    confirmPasswordInput = ""
                    step = .resetPassword
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Spacer()

                Button("Reset Password") {
                    authError = ""
                    passwordInput = ""
                    confirmPasswordInput = ""
                    step = .resetPassword
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.accent)
            }

            if mode == .standard {
                if pendingIdentifierKind == .phone {
                    Button("Create New Account") {
                        authError = ""
                        pendingLookup = nil
                        clearPasswordDrafts()
                        seedProfileDraftIfNeeded()
                        step = .createPassword
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                } else {
                    Button("Use Phone Number To Register") {
                        authError = ""
                        step = .entry
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                }
            }
        }
    }

    private var createPasswordStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Create Password")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("Create a password before finishing your profile.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            infoField(title: pendingIdentifierKind.title, value: pendingContactValue)

            SecureField("Enter password", text: $passwordInput)
                .textContentType(.newPassword)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            SecureField("Confirm password", text: $confirmPasswordInput)
                .textContentType(.newPassword)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Preparing..." : "Continue") {
                Task {
                    await continueWithNewPassword()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || isCreatePasswordDisabled)
        }
    }

    private var resetPasswordStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reset Password")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("Temporary flow until recovery OTP is connected. Set a new password for this account.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            infoField(title: pendingIdentifierKind.title, value: pendingContactValue)

            SecureField("New password", text: $passwordInput)
                .textContentType(.newPassword)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            SecureField("Confirm new password", text: $confirmPasswordInput)
                .textContentType(.newPassword)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Updating..." : "Save New Password") {
                Task {
                    await resetPasswordAndSignIn()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || isCreatePasswordDisabled)
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode == .offlineOnly ? "Finish Offline-Only Profile" : "Set Up Your Profile")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("Birthday, username, and your public profile are required before entering chats.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            infoField(title: pendingIdentifierKind.title, value: pendingContactValue)

            TextField("Name", text: $displayName)
                .textContentType(.name)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(PrimeTheme.Spacing.large)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                Text(usernameStatusText)
                    .font(.footnote)
                    .foregroundStyle(usernameStatusColor)
            }

            #if os(tvOS)
            LabeledContent("Birthday", value: birthDate.formatted(date: .abbreviated, time: .omitted))
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
            #else
            DatePicker(
                "Birthday",
                selection: $birthDate,
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .padding(PrimeTheme.Spacing.large)
            .background(PrimeTheme.Colors.elevated)
            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
            #endif

            if mode == .standard {
                TextField("E-mail", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(PrimeTheme.Spacing.large)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
            } else {
                Text("Offline-only accounts use the e-mail you entered as the primary identifier.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            TextField("About you", text: $bio, axis: .vertical)
                .lineLimit(3 ... 5)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Creating..." : "Create Account") {
                Task {
                    await submitProfileRegistration()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || isProfileDisabled)
        }
    }

    private var guestProfileStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guest Mode")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("Guest accounts last for 3 days, are limited to 2 activations per month on this device, cannot upload avatars, and use an automatic @guest-xxxxxxx username.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            TextField("Name", text: $displayName)
                .textContentType(.name)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Text("Guest Mode lets you write only your name right now. Advanced profile fields and avatar upload are disabled.")
                .font(.footnote)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Button(isSubmitting ? "Entering..." : "Enter Chats") {
                Task {
                    await submitGuestMode()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var entrySubtitle: String {
        switch mode {
        case .standard:
            return "Enter your phone number or username. Existing accounts go to password entry, and new phone numbers continue to account creation."
        case .offlineOnly:
            return "This path skips phone login. E-mail is required and the account starts in offline mode."
        case .guest:
            return "Temporary guest access."
        }
    }

    private var entryPrimaryButtonTitle: String {
        if mode == .standard, standardEntryLooksLikeUsername {
            return "Continue"
        }
        return mode == .standard ? "Sync Contacts And Continue" : "Continue"
    }

    private var passwordSubtitle: String {
        if let displayName = pendingLookup?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           displayName.isEmpty == false {
            return "Welcome back, \(displayName)."
        }
        switch pendingIdentifierKind {
        case .phone:
            return pendingLookup?.exists == false
                ? "This phone number looks new. You can create a new account or try an existing password."
                : "Enter the password for this phone number."
        case .username:
            return "Enter the password for this username."
        case .email:
            return "Enter the password for this e-mail."
        }
    }

    private var canGoBack: Bool {
        step != .entry || mode != .standard
    }

    private var isEntryDisabled: Bool {
        switch mode {
        case .standard:
            return resolvedStandardEntry() == nil
        case .offlineOnly:
            return appState.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == false
        case .guest:
            return false
        }
    }

    private var isCreatePasswordDisabled: Bool {
        let trimmedPassword = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPassword.isEmpty || confirmPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isProfileDisabled: Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let emailIsValid = mode == .standard ? appState.isValidEmail(normalizedEmail) : true

        return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            pendingPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            appState.isValidUsername(username) == false ||
            usernameAvailability != .available ||
            emailIsValid == false
    }

    private var usernameStatusText: String {
        guard username.isEmpty == false else {
            return "Username must use 5-32 symbols and allow only a-z, 0-9, or _."
        }

        guard appState.isValidUsername(username) else {
            return "Username must use 5-32 symbols and allow only a-z, 0-9, or _."
        }

        switch usernameAvailability {
        case .idle, .checking:
            return "Checking username..."
        case .available:
            return "Username is available."
        case .taken:
            return "Username is already taken."
        case .unavailable:
            return "Username service is unavailable."
        }
    }

    private var usernameStatusColor: Color {
        switch usernameAvailability {
        case .available:
            return PrimeTheme.Colors.success
        case .taken, .unavailable:
            return PrimeTheme.Colors.warning
        case .idle, .checking:
            return PrimeTheme.Colors.textSecondary
        }
    }

    private var standardEntryLooksLikeUsername: Bool {
        isUsernameLikeEntry(localIdentifierInput)
    }

    private var persistedOnboardingState: OnboardingProgressStore.StoredState {
        OnboardingProgressStore.StoredState(
            modeRawValue: mode.rawValue,
            stepRawValue: step.rawValue,
            selectedCountryCode: selectedCountry.code,
            localIdentifierInput: localIdentifierInput,
            email: email,
            displayName: displayName,
            username: username,
            bio: bio,
            birthDate: birthDate,
            pendingIdentifier: pendingIdentifier,
            pendingContactValue: pendingContactValue,
            pendingIdentifierKindRawValue: pendingIdentifierKind.rawValue,
            pendingLookup: pendingLookup.map {
                OnboardingProgressStore.StoredLookup(
                    exists: $0.exists,
                    accountKindRawValue: $0.accountKind?.rawValue,
                    displayName: $0.displayName
                )
            }
        )
    }

    private func isUsernameLikeEntry(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        if trimmed.hasPrefix("@") {
            return true
        }
        return trimmed.contains("_") || trimmed.contains { $0.isLetter }
    }

    private func normalizedUsernameEntry(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.normalizedUsername(trimmed.replacingOccurrences(of: "@", with: ""))
    }

    private func resolvedStandardEntry() -> (identifier: String, contactValue: String, kind: PendingIdentifierKind)? {
        let trimmed = localIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if isUsernameLikeEntry(trimmed) {
            let normalizedUsername = normalizedUsernameEntry(trimmed)
            guard appState.isValidLegacyUsername(normalizedUsername) else { return nil }
            return (normalizedUsername, "@\(normalizedUsername)", .username)
        }

        let fullPhoneNumber = appState.normalizedInternationalPhoneNumber(countryCode: selectedCountry.code, localNumber: trimmed)
        guard appState.isValidInternationalPhoneNumber(fullPhoneNumber) else { return nil }
        return (fullPhoneNumber, fullPhoneNumber, .phone)
    }

    @ViewBuilder
    private func infoField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .padding(PrimeTheme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrimeTheme.Colors.elevated)
        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
    }

    @MainActor
    private func continueFromEntry() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let resolvedEntry: (identifier: String, contactValue: String, kind: PendingIdentifierKind)
        switch mode {
        case .standard:
            guard let standardEntry = resolvedStandardEntry() else {
                authError = standardEntryLooksLikeUsername
                    ? "Enter a valid username using 3-32 symbols with only a-z, 0-9, or _."
                    : "Enter the phone number in international format, for example +37499111222."
                return
            }
            resolvedEntry = standardEntry
            if standardEntry.kind == .phone {
                await requestContactsAccessIfNeeded()
            }
        case .offlineOnly:
            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard appState.isValidEmail(normalizedEmail) else {
                authError = "Enter a valid e-mail address."
                return
            }
            resolvedEntry = (normalizedEmail, normalizedEmail, .email)
        case .guest:
            step = .guestProfile
            return
        }

        pendingIdentifier = resolvedEntry.identifier
        pendingContactValue = resolvedEntry.contactValue
        pendingIdentifierKind = resolvedEntry.kind

        do {
            pendingLookup = try await environment.authRepository.lookupAccount(identifier: resolvedEntry.identifier)
            clearPasswordDrafts()

            if pendingLookup?.exists == true {
                step = .password
            } else {
                if resolvedEntry.kind == .username {
                    authError = "This username was not found. Enter a phone number to create a new account."
                    return
                }

                step = .createPassword
                seedProfileDraftIfNeeded()
            }
        } catch {
            pendingLookup = nil
            clearPasswordDrafts()
            step = .password
        }
    }

    @MainActor
    private func submitPasswordLogin() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedPassword = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.isEmpty == false else {
            authError = "Enter your password."
            return
        }

        do {
            let user = try await environment.authRepository.logIn(identifier: pendingIdentifier, password: trimmedPassword)
            await finalizeAuthentication(with: user)
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not sign in." : error.localizedDescription
        }
    }

    @MainActor
    private func continueWithNewPassword() async {
        authError = ""

        let trimmedPassword = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirmation = confirmPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedPassword.isEmpty == false else {
            authError = "Password cannot be empty."
            return
        }
        guard trimmedPassword == trimmedConfirmation else {
            authError = "Passwords do not match."
            return
        }

        pendingPassword = trimmedPassword
        passwordInput = ""
        confirmPasswordInput = ""
        seedProfileDraftIfNeeded()
        step = .profile
    }

    @MainActor
    private func resetPasswordAndSignIn() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedPassword = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirmation = confirmPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedPassword.isEmpty == false else {
            authError = "Password cannot be empty."
            return
        }
        guard trimmedPassword == trimmedConfirmation else {
            authError = "Passwords do not match."
            return
        }

        do {
            try await environment.authRepository.resetPassword(identifier: pendingIdentifier, newPassword: trimmedPassword)
            let user = try await environment.authRepository.logIn(identifier: pendingIdentifier, password: trimmedPassword)
            await finalizeAuthentication(with: user)
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not reset the password." : error.localizedDescription
        }
    }

    @MainActor
    private func submitProfileRegistration() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard trimmedDisplayName.isEmpty == false else {
            authError = "Enter your name."
            return
        }
        guard appState.isValidUsername(username), usernameAvailability == .available else {
            authError = "Choose an available username."
            return
        }
        if mode == .standard, appState.isValidEmail(normalizedEmail) == false {
            authError = "Enter a valid e-mail address."
            return
        }
        guard pendingPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            authError = "Create your password first."
            return
        }

        let methodType: IdentityMethodType = mode == .standard ? .phone : .email
        let contactValue = mode == .standard ? pendingContactValue : pendingContactValue.lowercased()

        do {
            let createdUser = try await environment.authRepository.signUp(
                displayName: trimmedDisplayName,
                username: username,
                password: pendingPassword,
                contactValue: contactValue,
                methodType: methodType,
                accountKind: mode.accountKind
            )

            var profile = createdUser.profile
            profile.displayName = trimmedDisplayName
            profile.username = username
            profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.status = mode == .offlineOnly ? "Offline only" : "Available"
            profile.birthday = birthDate
            profile.email = mode == .standard ? normalizedEmail : contactValue
            profile.phoneNumber = mode == .standard ? contactValue : nil

            let updatedUser = try await environment.authRepository.updateProfile(profile, for: createdUser.id)
            await finalizeAuthentication(with: updatedUser)
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not create the account." : error.localizedDescription
        }
    }

    @MainActor
    private func submitGuestMode() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDisplayName.isEmpty == false else {
            authError = "Enter your name."
            return
        }

        do {
            let guestUsername = try await resolveGuestUsername()
            let guestUser = try await environment.authRepository.signUp(
                displayName: trimmedDisplayName,
                username: guestUsername,
                password: guestUsername,
                contactValue: guestUsername,
                methodType: .username,
                accountKind: .guest
            )
            await finalizeAuthentication(with: guestUser)
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not start Guest Mode." : error.localizedDescription
        }
    }

    @MainActor
    private func refreshUsernameAvailability() async {
        guard step == .profile else {
            usernameAvailability = .idle
            return
        }

        let normalized = appState.normalizedUsername(username)
        guard normalized.isEmpty == false else {
            usernameAvailability = .idle
            return
        }
        guard appState.isValidUsername(normalized) else {
            usernameAvailability = .taken
            return
        }

        usernameAvailability = .checking

        do {
            let available = try await environment.settingsRepository.isUsernameAvailable(normalized, for: nil)
            usernameAvailability = available ? .available : .taken
        } catch {
            usernameAvailability = .unavailable
        }
    }

    @MainActor
    private func finalizeAuthentication(with user: User) async {
        await OnboardingProgressStore.shared.clear()
        let hasServerSession = await AuthSessionStore.shared.session(for: user.id) != nil
        appState.applyAuthenticatedUser(user, requiresServerSessionValidation: hasServerSession)
    }

    @MainActor
    private func resolveGuestUsername() async throws -> String {
        for _ in 0 ..< 8 {
            let candidate = appState.generatedGuestUsername()
            let available = try await environment.settingsRepository.isUsernameAvailable(candidate, for: nil)
            if available {
                return candidate
            }
        }
        throw LocalAuthError.invalidUsername
    }

    @MainActor
    private func requestContactsAccessIfNeeded() async {
        #if canImport(Contacts)
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }

        let store = CNContactStore()
        _ = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { _, _ in
                continuation.resume()
            }
        }
        #endif
    }

    private func seedProfileDraftIfNeeded() {
        if displayName.isEmpty, username.isEmpty, bio.isEmpty {
            displayName = ""
            username = ""
            bio = ""
            birthDate = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now
        }

        if mode == .offlineOnly {
            email = pendingContactValue.lowercased()
        } else if email == pendingContactValue.lowercased() {
            email = ""
        }
    }

    private func clearPasswordDrafts() {
        passwordInput = ""
        confirmPasswordInput = ""
        pendingPassword = ""
    }

    @MainActor
    private func scheduleOnboardingProgressPersistence() {
        guard hasRestoredPersistedState else { return }
        onboardingPersistenceTask?.cancel()
        let snapshot = persistedOnboardingState
        onboardingPersistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard Task.isCancelled == false else { return }
            await OnboardingProgressStore.shared.save(snapshot)
        }
    }

    @MainActor
    private func restorePersistedStateIfNeeded() async {
        guard hasRestoredPersistedState == false else { return }
        hasRestoredPersistedState = true

        guard let storedState = await OnboardingProgressStore.shared.load() else { return }

        mode = FlowMode(rawValue: storedState.modeRawValue) ?? .standard
        selectedCountry = CountryDialCode.all.first(where: { $0.code == storedState.selectedCountryCode }) ?? .default
        localIdentifierInput = storedState.localIdentifierInput
        email = storedState.email
        displayName = storedState.displayName
        username = storedState.username
        bio = storedState.bio
        birthDate = storedState.birthDate
        pendingIdentifier = storedState.pendingIdentifier
        pendingContactValue = storedState.pendingContactValue
        pendingIdentifierKind = PendingIdentifierKind(rawValue: storedState.pendingIdentifierKindRawValue) ?? .phone
        pendingLookup = storedState.pendingLookup.map {
            AccountLookupResult(
                exists: $0.exists,
                accountKind: $0.accountKindRawValue.flatMap(AccountKind.init(rawValue:)),
                displayName: $0.displayName
            )
        }

        var restoredStep = Step(rawValue: storedState.stepRawValue) ?? .entry
        let requiresResolvedIdentifier = restoredStep == .password || restoredStep == .createPassword || restoredStep == .resetPassword || restoredStep == .profile
        if requiresResolvedIdentifier && pendingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restoredStep = .entry
        }
        if restoredStep == .profile {
            restoredStep = .createPassword
        }
        if mode == .guest {
            restoredStep = .guestProfile
        }
        step = restoredStep
    }

    private func goBack() {
        authError = ""

        switch step {
        case .entry:
            mode = .standard
            pendingIdentifierKind = .phone
            pendingLookup = nil
            clearPasswordDrafts()
        case .password, .createPassword:
            step = .entry
            pendingIdentifierKind = .phone
            pendingLookup = nil
            clearPasswordDrafts()
        case .resetPassword:
            step = .password
            passwordInput = ""
            confirmPasswordInput = ""
        case .profile:
            step = .createPassword
        case .guestProfile:
            step = .entry
            mode = .standard
            pendingIdentifierKind = .phone
            pendingLookup = nil
            clearPasswordDrafts()
        }
    }
}
