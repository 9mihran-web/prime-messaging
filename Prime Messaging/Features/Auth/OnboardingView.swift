import SwiftUI

struct OnboardingView: View {
    enum AuthMode: String, CaseIterable, Identifiable {
        case signUp
        case logIn

        var id: String { rawValue }
    }

    enum UsernameAvailability {
        case idle
        case checking
        case available
        case taken
        case unavailable
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var authMode: AuthMode = .signUp
    @State private var selectedMethod: IdentityMethodType = .phone
    @State private var fullName = ""
    @State private var username = ""
    @State private var contactValue = ""
    @State private var identifier = ""
    @State private var password = ""
    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var authError = ""
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xLarge) {
                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.medium) {
                    Text("app.title".localized)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("auth.subtitle".localized)
                        .font(.title3)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Picker("auth.mode".localized, selection: $authMode) {
                    Text("auth.signup".localized).tag(AuthMode.signUp)
                    Text("auth.login".localized).tag(AuthMode.logIn)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.medium) {
                    if authMode == .signUp {
                        Picker("onboarding.method".localized, selection: $selectedMethod) {
                            Text("onboarding.method.phone".localized).tag(IdentityMethodType.phone)
                            Text("onboarding.method.email".localized).tag(IdentityMethodType.email)
                        }
                        .pickerStyle(.segmented)

                        TextField("onboarding.name.placeholder".localized, text: $fullName)
                            .textContentType(.name)
                            .padding(PrimeTheme.Spacing.large)
                            .background(PrimeTheme.Colors.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                        TextField("onboarding.username.placeholder".localized, text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(PrimeTheme.Spacing.large)
                            .background(PrimeTheme.Colors.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                            .onChange(of: username) { _, newValue in
                                let normalized = appState.normalizedUsername(newValue)
                                if normalized != newValue {
                                    username = normalized
                                }
                            }

                        Text(usernameStatusText)
                            .font(.footnote)
                            .foregroundStyle(usernameStatusColor)

                        TextField(contactPlaceholder, text: $contactValue)
                            .textContentType(selectedMethod == .phone ? .telephoneNumber : .emailAddress)
                            .keyboardType(selectedMethod == .phone ? .phonePad : .emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(PrimeTheme.Spacing.large)
                            .background(PrimeTheme.Colors.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                    } else {
                        TextField("auth.identifier.placeholder".localized, text: $identifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(PrimeTheme.Spacing.large)
                            .background(PrimeTheme.Colors.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                    }

                    SecureField("auth.password.placeholder".localized, text: $password)
                        .textContentType(.password)
                        .padding(PrimeTheme.Spacing.large)
                        .background(PrimeTheme.Colors.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))

                    if !authError.isEmpty {
                        Text(authError)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }
                }

                Button(primaryButtonTitle) {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimeTheme.Colors.accent)
                .disabled(isSubmitDisabled)
            }
            .padding(PrimeTheme.Spacing.xLarge)
        }
        .background(PrimeTheme.Colors.background)
        .task(id: normalizedUsername + authMode.rawValue) {
            await refreshUsernameAvailability()
        }
    }

    private var primaryButtonTitle: String {
        authMode == .signUp ? "auth.signup".localized : "auth.login".localized
    }

    private var contactPlaceholder: String {
        selectedMethod == .phone ? "onboarding.phone.placeholder".localized : "onboarding.email.placeholder".localized
    }

    private var normalizedUsername: String {
        appState.normalizedUsername(username)
    }

    private var usernameStatusText: String {
        if authMode != .signUp {
            return ""
        }

        if normalizedUsername.isEmpty {
            return "onboarding.username.hint".localized
        }

        if !appState.isValidUsername(normalizedUsername) {
            return "onboarding.username.invalid".localized
        }

        switch usernameAvailability {
        case .idle, .checking:
            return "onboarding.username.checking".localized
        case .available:
            return "onboarding.username.available".localized
        case .taken:
            return "onboarding.username.taken".localized
        case .unavailable:
            return "auth.server.unavailable".localized
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

    private var isSubmitDisabled: Bool {
        if isSubmitting || password.isEmpty {
            return true
        }

        switch authMode {
        case .signUp:
            return fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                contactValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                usernameAvailability != .available
        case .logIn:
            return identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @MainActor
    private func refreshUsernameAvailability() async {
        guard authMode == .signUp else {
            usernameAvailability = .idle
            return
        }

        let normalized = normalizedUsername
        guard !normalized.isEmpty else {
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
    private func submit() async {
        isSubmitting = true
        authError = ""
        defer { isSubmitting = false }

        do {
            switch authMode {
            case .signUp:
                let user = try await environment.authRepository.signUp(
                    displayName: fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                    username: normalizedUsername,
                    password: password,
                    contactValue: contactValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    methodType: selectedMethod
                )
                appState.applyAuthenticatedUser(user)
            case .logIn:
                let user = try await environment.authRepository.logIn(
                    identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                appState.applyAuthenticatedUser(user)
            }
        } catch {
            authError = error.localizedDescription.isEmpty ? "auth.error.generic".localized : error.localizedDescription
        }
    }
}
