#if canImport(Contacts)
import Contacts
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
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
        case signupEmail
        case otp
        case password
        case resetPasswordEmailOTP
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
        case username
        case email

        var title: String {
            switch self {
            case .username:
                return "Username"
            case .email:
                return "E-mail"
            }
        }
    }

    private enum LoginCredentialMode: String {
        case password
        case otp

        var title: String {
            switch self {
            case .password:
                return "Password"
            case .otp:
                return "OTP"
            }
        }
    }

    private enum EntryActionTone {
        case primary
        case secondary
    }

    private struct EntryActionButtonStyle: ButtonStyle {
        let tone: EntryActionTone
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.headline.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(backgroundColor(isPressed: configuration.isPressed))
                .overlay(
                    RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous)
                        .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: tone == .secondary ? 1 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }

        private var foregroundColor: Color {
            switch tone {
            case .primary:
                return .white
            case .secondary:
                return isEnabled ? PrimeTheme.Colors.textPrimary : PrimeTheme.Colors.textSecondary
            }
        }

        private func backgroundColor(isPressed: Bool) -> Color {
            let base: Color = {
                switch tone {
                case .primary:
                    return PrimeTheme.Colors.accent
                case .secondary:
                    return PrimeTheme.Colors.elevated
                }
            }()

            guard isEnabled else {
                return base.opacity(0.45)
            }
            return isPressed ? base.opacity(0.82) : base
        }

        private func borderColor(isPressed: Bool) -> Color {
            guard tone == .secondary else { return .clear }
            guard isEnabled else { return PrimeTheme.Colors.separator.opacity(0.24) }
            return isPressed ? PrimeTheme.Colors.separator.opacity(0.28) : PrimeTheme.Colors.separator.opacity(0.42)
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

    private let restoresPersistedDraft: Bool

    @State private var mode: FlowMode = .standard
    @State private var step: Step = .entry
    @State private var selectedCountry = CountryDialCode.default
    @State private var localIdentifierInput = ""
    @State private var usernameInput = ""
    @State private var useUsernameLogin = false
    @State private var email = ""
    @State private var passwordInput = ""
    @State private var confirmPasswordInput = ""
    @State private var pendingPassword = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var birthDate = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now
    @State private var pendingIdentifier = ""
    @State private var pendingPostResetLoginIdentifier = ""
    @State private var pendingContactValue = ""
    @State private var pendingIdentifierKind: PendingIdentifierKind = .email
    @State private var pendingLookup: AccountLookupResult?
    @State private var authError = ""
    @State private var isSubmitting = false
    @State private var isSigningWithApple = false
    @State private var isContactSyncEnabled = true
    @State private var otpCodeInput = ""
    @State private var loginCredentialMode: LoginCredentialMode = .password
    @State private var pendingOTPChallenge: OTPChallenge?
    @State private var pendingOTPPurpose: OTPPurpose?
    @State private var pendingVerifiedSignupOTPChallengeID: String?
    @State private var pendingVerifiedResetOTPChallengeID: String?
    @State private var pendingAppleNewUserID: UUID?
    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var hasRestoredPersistedState = false
    @State private var onboardingPersistenceTask: Task<Void, Never>?

    init(restoresPersistedDraft: Bool = false) {
        self.restoresPersistedDraft = restoresPersistedDraft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar

                switch step {
                case .entry:
                    entryStep
                case .signupEmail:
                    signupEmailStep
                case .otp:
                    otpStep
                case .password:
                    passwordStep
                case .resetPasswordEmailOTP:
                    resetPasswordEmailOTPStep
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
        .onChange(of: localIdentifierInput) { _ in
            guard step == .entry else { return }
            clearPendingLookupState()
        }
        .onChange(of: usernameInput) { _ in
            guard step == .entry else { return }
            clearPendingLookupState()
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
                Text(mode == .offlineOnly ? "Offline-Only Access" : "Enter E-mail Or Username")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(entrySubtitle)
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            if mode == .standard {
                TextField(useUsernameLogin ? "Username" : "E-mail", text: useUsernameLogin ? $usernameInput : $localIdentifierInput)
                    .keyboardType(useUsernameLogin ? .asciiCapable : .emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(PrimeTheme.Spacing.large)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                Text(useUsernameLogin
                    ? "Use your username like @prime_user. Existing users only."
                    : "Use your account e-mail. New users continue through e-mail OTP verification.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                if shouldShowIdentifierSwitchButton {
                    Button(useUsernameLogin ? "Continue With E-mail" : "Continue With Username") {
                        authError = ""
                        useUsernameLogin.toggle()
                    }
                    .buttonStyle(.bordered)
                    .tint(PrimeTheme.Colors.textPrimary)
                }

                Toggle(isOn: $isContactSyncEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync Contacts")
                            .font(.headline)
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        Text("Import your contacts on first login.")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
                SignInWithAppleButton(.continue) { request in
                    configureAppleSignIn(request: request)
                } onCompletion: { result in
                    handleAppleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: 375)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                .disabled(isSubmitting || isSigningWithApple)
                #endif
            } else {
                TextField("E-mail", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(PrimeTheme.Spacing.large)
                    .background(PrimeTheme.Colors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                Text("E-mail is mandatory for offline-only accounts.")
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Button(isSubmitting ? "Continuing..." : "Continue") {
                Task {
                    await continueFromEntry()
                }
            }
            .buttonStyle(EntryActionButtonStyle(tone: .primary))
            .disabled(isSubmitting || isSigningWithApple || isEntryDisabled)

            if mode == .standard {
                Button("Continue Offline") {
                    authError = ""
                    mode = .offlineOnly
                    email = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(EntryActionButtonStyle(tone: .secondary))

                Button("Guest Mode") {
                    authError = ""
                    mode = .guest
                    step = .guestProfile
                    displayName = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(EntryActionButtonStyle(tone: .secondary))
            } else {
                Button("Use E-mail Login") {
                    authError = ""
                    mode = .standard
                    clearPasswordDrafts()
                }
                .buttonStyle(EntryActionButtonStyle(tone: .secondary))

                Button("Guest Mode") {
                    authError = ""
                    mode = .guest
                    step = .guestProfile
                    displayName = ""
                    clearPasswordDrafts()
                }
                .buttonStyle(EntryActionButtonStyle(tone: .secondary))
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
                    step = .resetPasswordEmailOTP
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Spacer()

                Button("Reset Password") {
                    authError = ""
                    passwordInput = ""
                    confirmPasswordInput = ""
                    step = .resetPasswordEmailOTP
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrimeTheme.Colors.accent)
            }

            if mode == .standard {
                if pendingIdentifierKind == .email {
                    Button("Create New Account") {
                        authError = ""
                        pendingLookup = nil
                        clearPasswordDrafts()
                        Task {
                            let challenge = try? await environment.authRepository.requestOTP(
                                identifier: pendingIdentifier,
                                purpose: .signup
                            )
                            await MainActor.run {
                                if let challenge {
                                    pendingOTPChallenge = challenge
                                    pendingOTPPurpose = .signup
                                    otpCodeInput = ""
                                    step = .otp
                                } else {
                                    authError = "Could not request OTP."
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                } else {
                    Button("Use E-mail To Register") {
                        authError = ""
                        step = .entry
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                }
            }
        }
    }

    private var signupEmailStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter E-mail")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("E-mail is required for registration and recovery.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            TextField("E-mail", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Sending..." : "Send OTP To E-mail") {
                Task {
                    await requestSignupEmailOTP()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || appState.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == false)
        }
    }

    private var otpStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter Verification Code")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("We sent an OTP code to \(pendingOTPChallenge?.destinationMasked ?? pendingContactValue).")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            infoField(title: pendingIdentifierKind.title, value: pendingContactValue)

            TextField("OTP Code", text: $otpCodeInput)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            if let challenge = pendingOTPChallenge {
                Text(otpMetaText(for: challenge))
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Button(isSubmitting ? "Verifying..." : "Verify And Continue") {
                Task {
                    await verifyOTPAndContinue()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || otpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Resend Code") {
                Task {
                    await resendOTPCode()
                }
            }
            .buttonStyle(.bordered)
            .tint(PrimeTheme.Colors.textPrimary)
            .disabled(isSubmitting || canResendOTP == false)
        }
    }

    private var resetPasswordEmailOTPStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reset Password")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text("Enter your account e-mail. We will send OTP to continue password reset.")
                    .font(.title3)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            TextField("E-mail", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(PrimeTheme.Spacing.large)
                .background(PrimeTheme.Colors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

            Button(isSubmitting ? "Sending..." : "Send OTP To E-mail") {
                Task {
                    await requestResetPasswordEmailOTP()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PrimeTheme.Colors.accent)
            .disabled(isSubmitting || appState.isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == false)
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

            Button(isSubmitting ? "Saving..." : profilePrimaryButtonTitle) {
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
            return "Use e-mail or Continue with Username. Existing users go to password, new users continue to e-mail OTP."
        case .offlineOnly:
            return "E-mail is required and the account starts in offline mode."
        case .guest:
            return "Temporary guest access."
        }
    }

    private var passwordSubtitle: String {
        switch pendingIdentifierKind {
        case .username:
            let usernameValue = pendingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if usernameValue.isEmpty == false {
                return "Enter the password for @\(usernameValue)."
            }
            return "Enter the password for this username."
        case .email:
            let emailValue = pendingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if emailValue.isEmpty == false {
                return "Enter the password for \(emailValue)."
            }
            return "Enter the password for this e-mail."
        }
    }

    private var canGoBack: Bool {
        step != .entry || mode != .standard
    }

    private var shouldShowIdentifierSwitchButton: Bool {
        if useUsernameLogin {
            return usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return localIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canResendOTP: Bool {
        guard let challenge = pendingOTPChallenge else { return false }
        return Date.now >= challenge.resendAvailableAt
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

    private var isAppleProfileCompletionFlow: Bool {
        pendingAppleNewUserID != nil
    }

    private var profilePrimaryButtonTitle: String {
        isAppleProfileCompletionFlow ? "Finish Setup" : "Create Account"
    }

    private var isProfileDisabled: Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let emailIsValid = mode == .standard ? appState.isValidEmail(normalizedEmail) : true
        let requiresPassword = isAppleProfileCompletionFlow == false

        return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (requiresPassword && pendingPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
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

    private var standardEntryLooksLikeUsername: Bool { useUsernameLogin }

    private var persistedOnboardingState: OnboardingProgressStore.StoredState {
        OnboardingProgressStore.StoredState(
            modeRawValue: mode.rawValue,
            stepRawValue: step.rawValue,
            isContactSyncEnabled: isContactSyncEnabled,
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
            loginCredentialModeRawValue: loginCredentialMode.rawValue,
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
        if useUsernameLogin {
            let trimmed = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let normalizedUsername = normalizedUsernameEntry(trimmed)
            guard appState.isValidLegacyUsername(normalizedUsername) else { return nil }
            return (normalizedUsername, "@\(normalizedUsername)", .username)
        }

        let normalizedEmail = localIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard appState.isValidEmail(normalizedEmail) else { return nil }
        return (normalizedEmail, normalizedEmail, .email)
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

    #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
    private func configureAppleSignIn(request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        Task {
            await submitAppleSignIn(result)
        }
    }

    @MainActor
    private func submitAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        isSigningWithApple = true
        authError = ""
        defer { isSigningWithApple = false }

        switch result {
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }
            authError = error.localizedDescription.isEmpty ? "Sign in with Apple failed." : error.localizedDescription
            return
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authError = "Sign in with Apple failed."
                return
            }
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  identityToken.isEmpty == false else {
                authError = "Could not read Apple identity token."
                return
            }

            if isContactSyncEnabled {
                await requestContactsAccessIfNeeded()
            }

            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let email = credential.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let givenName = credential.fullName?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let familyName = credential.fullName?.familyName?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let result = try await environment.authRepository.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    appleUserID: credential.user,
                    email: email,
                    givenName: givenName,
                    familyName: familyName
                )
                clearPasswordDrafts()
                if result.isNewUser {
                    prepareAppleProfileCompletion(using: result.user)
                } else {
                    await finalizeAuthentication(with: result.user)
                }
            } catch {
                authError = error.localizedDescription.isEmpty ? "Sign in with Apple failed." : error.localizedDescription
            }
        }
    }
    #endif

    @MainActor
    private func continueFromEntry() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }
        clearPendingLookupState()

        let resolvedEntry: (identifier: String, contactValue: String, kind: PendingIdentifierKind)
        switch mode {
        case .standard:
            guard let standardEntry = resolvedStandardEntry() else {
                authError = standardEntryLooksLikeUsername
                    ? "Enter a valid username using 3-32 symbols with only a-z, 0-9, or _."
                    : "Enter a valid e-mail address."
                return
            }
            resolvedEntry = standardEntry
            if standardEntry.kind == .email, isContactSyncEnabled {
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
        pendingVerifiedSignupOTPChallengeID = nil

        do {
            do {
                pendingLookup = try await environment.authRepository.lookupAccount(identifier: resolvedEntry.identifier)
            } catch let authError as AuthRepositoryError {
                // Some backend builds may return 404 for lookup even for "not exists".
                // For phone/email entry we should continue into signup OTP instead of hard failing.
                if case .accountNotFound = authError, resolvedEntry.kind != .username {
                    pendingLookup = AccountLookupResult(exists: false, accountKind: nil, displayName: nil)
                } else {
                    throw authError
                }
            }
            clearPasswordDrafts()

            if resolvedEntry.kind == .username {
                if pendingLookup?.exists == true {
                    step = .password
                } else {
                    authError = "This username was not found. Enter your e-mail to create a new account."
                }
                return
            }

            if pendingLookup?.exists == true {
                step = .password
            } else {
                let challenge = try await environment.authRepository.requestOTP(
                    identifier: resolvedEntry.identifier,
                    purpose: .signup
                )
                pendingOTPChallenge = challenge
                pendingOTPPurpose = .signup
                otpCodeInput = ""
                step = .otp
            }
        } catch {
            pendingLookup = nil
            clearPasswordDrafts()
            authError = error.localizedDescription.isEmpty ? "Could not continue." : error.localizedDescription
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

        print("auth.login.attempt identifier=\(pendingIdentifier) kind=\(pendingIdentifierKind.rawValue)")
        do {
            let user = try await environment.authRepository.logIn(identifier: pendingIdentifier, password: trimmedPassword)
            print("auth.login.success identifier=\(pendingIdentifier) user_id=\(user.id.uuidString)")
            await finalizeAuthentication(with: user)
        } catch {
            print("auth.login.failed identifier=\(pendingIdentifier) reason=\(error.localizedDescription)")
            authError = error.localizedDescription.isEmpty ? "Could not sign in." : error.localizedDescription
        }
    }

    @MainActor
    private func submitOTPLogin() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedOTP = otpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOTP.isEmpty == false else {
            authError = "Enter OTP code."
            return
        }

        do {
            if let user = try await environment.authRepository.authenticate(
                identifier: pendingIdentifier,
                otpCode: trimmedOTP,
                challengeID: pendingOTPChallenge?.challengeID
            ) {
                await finalizeAuthentication(with: user)
            } else {
                authError = "Account not found for this identifier."
            }
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not sign in with OTP." : error.localizedDescription
        }
    }

    @MainActor
    private func verifyOTPAndContinue() async {
        let purpose = pendingOTPPurpose ?? .signup
        switch purpose {
        case .login, .signup:
            await verifySignupOTPAndContinue()
        case .resetPassword:
            await verifyResetOTPAndContinue()
        }
    }

    @MainActor
    private func verifySignupOTPAndContinue() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedOTP = otpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOTP.isEmpty == false else {
            authError = "Enter OTP code."
            return
        }
        guard let challengeID = pendingOTPChallenge?.challengeID else {
            authError = "OTP challenge is missing. Request a new code."
            step = .entry
            return
        }

        do {
            let verifiedChallenge = try await environment.authRepository.verifyOTPChallenge(
                challengeID: challengeID,
                otpCode: trimmedOTP
            )
            pendingOTPChallenge = verifiedChallenge
            pendingVerifiedSignupOTPChallengeID = verifiedChallenge.challengeID
            otpCodeInput = ""
            step = .createPassword
            seedProfileDraftIfNeeded()
        } catch {
            authError = error.localizedDescription.isEmpty ? "OTP verification failed." : error.localizedDescription
        }
    }

    @MainActor
    private func verifyResetOTPAndContinue() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let trimmedOTP = otpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOTP.isEmpty == false else {
            authError = "Enter OTP code."
            return
        }
        guard let challengeID = pendingOTPChallenge?.challengeID else {
            authError = "OTP challenge is missing. Request a new code."
            step = .resetPasswordEmailOTP
            return
        }

        do {
            let verifiedChallenge = try await environment.authRepository.verifyOTPChallenge(
                challengeID: challengeID,
                otpCode: trimmedOTP
            )
            pendingOTPChallenge = verifiedChallenge
            pendingVerifiedResetOTPChallengeID = verifiedChallenge.challengeID
            otpCodeInput = ""
            step = .resetPassword
        } catch {
            authError = error.localizedDescription.isEmpty ? "OTP verification failed." : error.localizedDescription
        }
    }

    @MainActor
    private func resendOTPCode() async {
        guard canResendOTP else { return }
        guard let purpose = pendingOTPPurpose else {
            step = .entry
            return
        }
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        do {
            let challenge = try await environment.authRepository.requestOTP(
                identifier: pendingIdentifier,
                purpose: purpose
            )
            pendingOTPChallenge = challenge
            otpCodeInput = ""
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not resend OTP." : error.localizedDescription
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
    private func requestSignupEmailOTP() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard appState.isValidEmail(normalizedEmail) else {
            authError = "Enter a valid e-mail address."
            return
        }

        do {
            let challenge = try await environment.authRepository.requestOTP(
                identifier: normalizedEmail,
                purpose: .signup
            )
            pendingIdentifier = normalizedEmail
            pendingContactValue = normalizedEmail
            pendingIdentifierKind = .email
            pendingOTPChallenge = challenge
            pendingOTPPurpose = .signup
            pendingVerifiedSignupOTPChallengeID = nil
            otpCodeInput = ""
            step = .otp
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not request OTP." : error.localizedDescription
        }
    }

    @MainActor
    private func requestResetPasswordEmailOTP() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard appState.isValidEmail(normalizedEmail) else {
            authError = "Enter a valid e-mail address."
            return
        }

        do {
            let challenge = try await environment.authRepository.requestOTP(
                identifier: normalizedEmail,
                purpose: .resetPassword
            )
            pendingPostResetLoginIdentifier = pendingIdentifier
            pendingIdentifier = normalizedEmail
            pendingContactValue = normalizedEmail
            pendingIdentifierKind = .email
            pendingOTPChallenge = challenge
            pendingOTPPurpose = .resetPassword
            pendingVerifiedResetOTPChallengeID = nil
            otpCodeInput = ""
            step = .otp
        } catch {
            authError = error.localizedDescription.isEmpty ? "Could not request OTP." : error.localizedDescription
        }
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
            try await environment.authRepository.resetPassword(
                identifier: pendingIdentifier,
                newPassword: trimmedPassword,
                challengeID: pendingVerifiedResetOTPChallengeID
            )
            let loginIdentifier = pendingPostResetLoginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? pendingIdentifier
                : pendingPostResetLoginIdentifier
            let user = try await environment.authRepository.logIn(identifier: loginIdentifier, password: trimmedPassword)
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
        if isAppleProfileCompletionFlow == false,
           pendingPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authError = "Create your password first."
            return
        }

        if let appleUserID = pendingAppleNewUserID {
            do {
                var appleUser = try await environment.authRepository.refreshUser(userID: appleUserID)
                appleUser.profile.displayName = trimmedDisplayName
                appleUser.profile.username = username
                appleUser.profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                appleUser.profile.birthday = birthDate
                appleUser.profile.email = normalizedEmail
                appleUser.profile.phoneNumber = nil
                let updatedUser = try await environment.authRepository.updateProfile(appleUser.profile, for: appleUserID)
                await finalizeAuthentication(with: updatedUser)
            } catch {
                authError = error.localizedDescription.isEmpty ? "Could not finish Apple setup." : error.localizedDescription
            }
            return
        }

        let methodType: IdentityMethodType = .email
        let contactValue = pendingContactValue.lowercased()

        do {
            let createdUser = try await environment.authRepository.signUp(
                displayName: trimmedDisplayName,
                username: username,
                password: pendingPassword,
                contactValue: contactValue,
                methodType: methodType,
                accountKind: mode.accountKind,
                otpChallengeID: mode == .guest ? nil : pendingVerifiedSignupOTPChallengeID,
                signupEmail: mode == .standard ? normalizedEmail : nil
            )

            var profile = createdUser.profile
            profile.displayName = trimmedDisplayName
            profile.username = username
            profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.status = mode == .offlineOnly ? "Offline only" : "Available"
            profile.birthday = birthDate
            profile.email = mode == .standard ? normalizedEmail : contactValue
            profile.phoneNumber = nil

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
                accountKind: .guest,
                otpChallengeID: nil,
                signupEmail: nil
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
            let available = try await environment.settingsRepository.isUsernameAvailable(normalized, for: pendingAppleNewUserID)
            usernameAvailability = available ? .available : .taken
        } catch {
            usernameAvailability = .unavailable
        }
    }

    @MainActor
    private func finalizeAuthentication(with user: User) async {
        pendingAppleNewUserID = nil
        await OnboardingProgressStore.shared.clear()
        let hasServerSession = await AuthSessionStore.shared.session(for: user.id) != nil
        appState.applyAuthenticatedUser(user, requiresServerSessionValidation: hasServerSession)
    }

    private func prepareAppleProfileCompletion(using user: User) {
        pendingAppleNewUserID = user.id
        mode = .standard
        step = .profile
        pendingLookup = AccountLookupResult(
            exists: true,
            accountKind: user.accountKind,
            displayName: user.profile.displayName
        )

        let normalizedEmail = user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedEmail, normalizedEmail.isEmpty == false {
            pendingIdentifier = normalizedEmail
            pendingContactValue = normalizedEmail
            pendingIdentifierKind = .email
            email = normalizedEmail
        } else {
            pendingIdentifier = user.profile.username
            pendingContactValue = "@\(user.profile.username)"
            pendingIdentifierKind = .username
            email = ""
        }

        displayName = user.profile.displayName
        username = appState.normalizedUsername(user.profile.username)
        bio = user.profile.bio
        birthDate = user.profile.birthday ?? (Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now)
        authError = ""
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
        } else if mode == .standard {
            email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private func clearPasswordDrafts() {
        passwordInput = ""
        confirmPasswordInput = ""
        otpCodeInput = ""
        pendingPassword = ""
        pendingAppleNewUserID = nil
        pendingOTPChallenge = nil
        pendingOTPPurpose = nil
        pendingVerifiedSignupOTPChallengeID = nil
        pendingVerifiedResetOTPChallengeID = nil
    }

    private func clearPendingLookupState() {
        pendingLookup = nil
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

        guard restoresPersistedDraft else {
            await OnboardingProgressStore.shared.clear()
            resetStateForFreshStart()
            return
        }

        guard let storedState = await OnboardingProgressStore.shared.load() else { return }

        mode = FlowMode(rawValue: storedState.modeRawValue) ?? .standard
        isContactSyncEnabled = storedState.isContactSyncEnabled ?? true
        selectedCountry = CountryDialCode.all.first(where: { $0.code == storedState.selectedCountryCode }) ?? .default
        localIdentifierInput = storedState.localIdentifierInput
        email = storedState.email
        displayName = storedState.displayName
        username = storedState.username
        bio = storedState.bio
        birthDate = storedState.birthDate
        pendingIdentifier = storedState.pendingIdentifier
        pendingContactValue = storedState.pendingContactValue
        pendingIdentifierKind = PendingIdentifierKind(rawValue: storedState.pendingIdentifierKindRawValue) ?? .email
        loginCredentialMode = LoginCredentialMode(rawValue: storedState.loginCredentialModeRawValue ?? "") ?? .password
        pendingLookup = storedState.pendingLookup.map {
            AccountLookupResult(
                exists: $0.exists,
                accountKind: $0.accountKindRawValue.flatMap(AccountKind.init(rawValue:)),
                displayName: $0.displayName
            )
        }

        var restoredStep = Step(rawValue: storedState.stepRawValue) ?? .entry
        let requiresResolvedIdentifier =
            restoredStep == .signupEmail
            || restoredStep == .otp
            || restoredStep == .password
            || restoredStep == .resetPasswordEmailOTP
            || restoredStep == .createPassword
            || restoredStep == .resetPassword
            || restoredStep == .profile
        if requiresResolvedIdentifier && pendingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restoredStep = .entry
        }
        if restoredStep == .otp
            || restoredStep == .password
            || restoredStep == .createPassword
            || restoredStep == .resetPasswordEmailOTP
            || restoredStep == .resetPassword {
            restoredStep = .entry
        }
        if restoredStep == .profile {
            restoredStep = .entry
        }
        if mode == .guest {
            restoredStep = .guestProfile
        }
        step = restoredStep
    }

    private func resetStateForFreshStart() {
        mode = .standard
        step = .entry
        selectedCountry = .default
        localIdentifierInput = ""
        usernameInput = ""
        useUsernameLogin = false
        email = ""
        displayName = ""
        username = ""
        bio = ""
        birthDate = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now
        pendingIdentifier = ""
        pendingPostResetLoginIdentifier = ""
        pendingContactValue = ""
        pendingIdentifierKind = .email
        clearPendingLookupState()
        authError = ""
        loginCredentialMode = .password
        usernameAvailability = .idle
        isContactSyncEnabled = true
        clearPasswordDrafts()
    }

    private func goBack() {
        authError = ""

        switch step {
        case .entry:
            mode = .standard
            pendingIdentifierKind = .email
            clearPendingLookupState()
            clearPasswordDrafts()
            useUsernameLogin = false
            usernameInput = ""
        case .otp:
            if pendingOTPPurpose == .resetPassword {
                step = .resetPasswordEmailOTP
            } else {
                step = .entry
            }
            pendingOTPChallenge = nil
            pendingOTPPurpose = nil
            otpCodeInput = ""
        case .signupEmail:
            step = .entry
            email = ""
        case .password, .createPassword:
            step = .entry
            pendingIdentifierKind = .email
            clearPendingLookupState()
            clearPasswordDrafts()
        case .resetPasswordEmailOTP:
            step = .password
            pendingOTPChallenge = nil
            pendingOTPPurpose = nil
            otpCodeInput = ""
        case .resetPassword:
            step = .resetPasswordEmailOTP
            passwordInput = ""
            confirmPasswordInput = ""
        case .profile:
            if isAppleProfileCompletionFlow {
                pendingAppleNewUserID = nil
                step = .entry
                pendingIdentifierKind = .email
                clearPendingLookupState()
                clearPasswordDrafts()
            } else {
                step = .createPassword
            }
        case .guestProfile:
            step = .entry
            mode = .standard
            pendingIdentifierKind = .email
            clearPendingLookupState()
            clearPasswordDrafts()
        }
    }

    private func otpMetaText(for challenge: OTPChallenge) -> String {
        let expires = RelativeDateTimeFormatter().localizedString(for: challenge.expiresAt, relativeTo: .now)
        if canResendOTP {
            return "Code expires \(expires). You can resend now."
        }
        let resend = RelativeDateTimeFormatter().localizedString(for: challenge.resendAvailableAt, relativeTo: .now)
        return "Code expires \(expires). Resend \(resend)."
    }
}
