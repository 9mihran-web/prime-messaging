#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
private typealias ProfilePhotoPickerItem = PhotosPickerItem
#else
private struct ProfilePhotoPickerItem: Hashable {}
#endif
#if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
import AuthenticationServices
#endif
import SwiftUI

struct ProfileView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var editedFirstName = ""
    @State private var editedLastName = ""
    @State private var editedDisplayName = ""
    @State private var editedStatus = ""
    @State private var editedBio = ""
    @State private var editedBirthday = Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now

    @State private var selectedPhotoItem: ProfilePhotoPickerItem?
    @State private var avatarError = ""
    @State private var profileMessage = ""
    @State private var isSavingProfile = false
    @State private var didSaveProfileSucceed = false

    private let legacyDefaultBio = "Welcome to Prime Messaging."

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    AvatarBadgeView(profile: appState.currentUser.profile, size: 44)
                        .frame(maxWidth: .infinity)

                    #if canImport(PhotosUI) && !os(tvOS)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Text("profile.avatar.button".localized)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(PrimeTheme.Colors.smartAccent)
                    }
                    .buttonStyle(.plain)
                    #endif

                    if appState.currentUser.canUploadAvatar, appState.currentUser.profile.profilePhotoURL != nil {
                        Button("profile.photo.delete".localized, role: .destructive) {
                            Task {
                                await removeAvatar()
                            }
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .buttonStyle(.plain)
                    }

                    if avatarError.isEmpty == false {
                        Text(avatarError)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("profile.first_name".localized, text: $editedFirstName)
                TextField("profile.last_name".localized, text: $editedLastName)
                Text("profile.name_hint".localized)
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            Section {
                NavigationLink {
                    ProfileBioSettingsView(
                        editedStatus: $editedStatus,
                        editedBio: $editedBio,
                        isSaving: isSavingProfile,
                        onSave: {
                            await saveProfile()
                        }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("profile.biography".localized) {
                            Text(
                                editedStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "profile.biography.none_status".localized
                                    : editedStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                        Text(
                            editedBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "profile.biography.placeholder".localized
                                : editedBio.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            Section {
                #if !os(tvOS)
                DatePicker("profile.birthday".localized, selection: $editedBirthday, in: ...Date.now, displayedComponents: .date)
                #else
                LabeledContent("profile.birthday".localized, value: editedBirthday.formatted(date: .abbreviated, time: .omitted))
                #endif
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            Section {
                NavigationLink {
                    ProfileEmailSettingsView()
                } label: {
                    LabeledContent("profile.email".localized) {
                        Text(currentEmailLabel)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }

                NavigationLink {
                    ProfileUsernameSettingsView()
                } label: {
                    LabeledContent("profile.username".localized) {
                        Text("@\(appState.currentUser.profile.username)")
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }

                NavigationLink {
                    ProfilePasswordSettingsView()
                } label: {
                    Text("settings.admin_console.password".localized)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                }
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            Section {
                Button("settings.account.add".localized) {
                    appState.beginAddingAccount()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            Section {
                Button("settings.account.logout".localized, role: .destructive) {
                    appState.logOutCurrentAccount()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(PrimeTheme.Colors.elevated.opacity(0.92))

            if profileMessage.isEmpty == false {
                Section {
                    Text(profileMessage)
                        .font(.footnote)
                        .foregroundStyle(profileMessageColor)
                }
            }

        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(brandEditBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("common.cancel".localized) {
                    synchronizeForm()
                    dismiss()
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.45), in: Capsule(style: .continuous))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSavingProfile ? "common.saving".localized : "common.done".localized) {
                    Task {
                        await saveProfile()
                        if didSaveProfileSucceed {
                            dismiss()
                        }
                    }
                }
                .disabled(isSavingProfile || composedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.45), in: Capsule(style: .continuous))
            }
        }
        .task(id: appState.currentUser.id) {
            synchronizeForm()
        }
        .task(id: selectedPhotoItem) {
            await uploadSelectedPhoto()
        }
    }

    private var profileMessageColor: Color {
        didSaveProfileSucceed ? PrimeTheme.Colors.success : PrimeTheme.Colors.warning
    }

    private func synchronizeForm() {
        let parts = appState.currentUser.profile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
            .map(String.init)
        editedFirstName = parts.first ?? ""
        editedLastName = parts.count > 1 ? parts[1] : ""
        editedDisplayName = appState.currentUser.profile.displayName
        editedStatus = appState.currentUser.profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBio = appState.currentUser.profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        editedBio = rawBio == legacyDefaultBio ? "" : rawBio
        editedBirthday = appState.currentUser.profile.birthday ?? (Calendar.autoupdatingCurrent.date(byAdding: .year, value: -18, to: .now) ?? .now)
        profileMessage = ""
        didSaveProfileSucceed = false
    }

    @MainActor
    private func saveProfile() async {
        isSavingProfile = true
        defer { isSavingProfile = false }

        var profile = appState.currentUser.profile
        profile.displayName = composedDisplayName
        profile.status = editedStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.bio = editedBio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.birthday = editedBirthday
        profile.phoneNumber = nil

        do {
            var user = try await environment.authRepository.updateProfile(profile, for: appState.currentUser.id)
            if user.profile.birthday == nil {
                user.profile.birthday = profile.birthday
            }
            appState.refreshCurrentUserPreservingNavigation(user)
            synchronizeForm()
            profileMessage = "profile.updated".localized
            didSaveProfileSucceed = true
        } catch {
            profileMessage = error.localizedDescription.isEmpty ? "profile.update_failed".localized : error.localizedDescription
            didSaveProfileSucceed = false
        }
    }

    @MainActor
    private func uploadSelectedPhoto() async {
        #if canImport(PhotosUI) && !os(tvOS)
        guard let selectedPhotoItem else { return }
        defer { self.selectedPhotoItem = nil }

        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
            let updatedUser = try await environment.authRepository.uploadAvatar(imageData: data, for: appState.currentUser.id)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
            synchronizeForm()
            avatarError = ""
            profileMessage = "Profile updated."
        } catch {
            avatarError = "profile.avatar.failed".localized
        }
        #else
        avatarError = "Avatar upload is unavailable on Apple TV."
        #endif
    }

    @MainActor
    private func removeAvatar() async {
        do {
            let updatedUser = try await environment.authRepository.removeAvatar(for: appState.currentUser.id)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
            synchronizeForm()
            avatarError = ""
            profileMessage = "Profile updated."
        } catch {
            avatarError = error.localizedDescription.isEmpty ? "Could not remove avatar." : error.localizedDescription
        }
    }

    private var composedDisplayName: String {
        let first = editedFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = editedLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = [first, last].filter { $0.isEmpty == false }.joined(separator: " ")
        return merged.isEmpty ? editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) : merged
    }

    private var currentEmailLabel: String {
        if let email = appState.currentUser.profile.email, email.isEmpty == false {
            return email
        }
        return "Not set"
    }

    private var brandEditBackground: some View {
        ZStack {
            PrimeTheme.Colors.background
            LinearGradient(
                colors: [
                    PrimeTheme.Colors.accent.opacity(0.22),
                    PrimeTheme.Colors.accentSoft.opacity(0.12),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct ProfileBioSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var editedStatus: String
    @Binding var editedBio: String
    let isSaving: Bool
    let onSave: @MainActor () async -> Void

    var body: some View {
        Form {
            Section("profile.status".localized) {
                TextField("profile.status".localized, text: $editedStatus)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
            }

            Section("profile.biography".localized) {
                TextField("profile.biography.about_placeholder".localized, text: $editedBio, axis: .vertical)
                    .lineLimit(4 ... 8)
                Text("profile.biography.visibility_hint".localized)
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
        .navigationTitle("profile.biography".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "common.saving".localized : "common.save".localized) {
                    Task {
                        await onSave()
                        dismiss()
                    }
                }
                .disabled(isSaving)
            }
        }
    }
}

private struct ProfileEmailSettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var emailInput = ""
    @State private var otpCode = ""
    @State private var challenge: OTPChallenge?
    @State private var verifiedChallengeID: String?
    @State private var isLoading = false
    @State private var isLinkingApple = false
    @State private var statusMessage = ""

    private var normalizedInputEmail: String {
        emailInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var currentEmail: String {
        appState.currentUser.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private var isCurrentEmail: Bool {
        normalizedInputEmail == currentEmail
    }

    var body: some View {
        Form {
            Section("E-mail") {
                TextField("E-mail", text: $emailInput)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(isLoading ? "Sending..." : "Send OTP") {
                    Task { await sendOTP() }
                }
                .disabled(isLoading || appState.isValidEmail(normalizedInputEmail) == false)
            }

            if challenge != nil {
                Section("OTP") {
                    if let challenge {
                        Text("Code sent to \(challenge.destinationMasked)")
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
            }

            Section {
                Button(isLoading ? "Saving..." : "Save E-mail") {
                    Task { await saveEmail() }
                }
                .disabled(isLoading || appState.isValidEmail(normalizedInputEmail) == false || (isCurrentEmail == false && verifiedChallengeID == nil))
            }

            #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
            Section("Apple ID") {
                SignInWithAppleButton(
                    .continue,
                    onRequest: configureAppleLinkRequest,
                    onCompletion: handleAppleLinkResult
                )
                .signInWithAppleButtonStyle(.black)
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isLoading || isLinkingApple)

                if isLinkingApple {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Linking Apple ID…")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                } else {
                    Text("Link this Prime account with your Apple ID.")
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
            #endif

            if statusMessage.isEmpty == false {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("profile.email".localized)
        .onAppear {
            if emailInput.isEmpty {
                emailInput = appState.currentUser.profile.email ?? ""
            }
        }
    }

    @MainActor
    private func sendOTP() async {
        guard appState.isValidEmail(normalizedInputEmail) else {
            statusMessage = "Enter a valid e-mail."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            challenge = try await environment.authRepository.requestOTP(identifier: normalizedInputEmail, purpose: .signup)
            otpCode = ""
            verifiedChallengeID = nil
            statusMessage = "OTP sent."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not send OTP." : error.localizedDescription
        }
    }

    @MainActor
    private func verifyOTP() async {
        guard let challengeID = challenge?.challengeID else {
            statusMessage = "Request OTP first."
            return
        }

        let code = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.isEmpty == false else {
            statusMessage = "Enter OTP code."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await environment.authRepository.verifyOTPChallenge(challengeID: challengeID, otpCode: code)
            verifiedChallengeID = challengeID
            statusMessage = "OTP verified."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "OTP verification failed." : error.localizedDescription
        }
    }

    @MainActor
    private func saveEmail() async {
        guard appState.isValidEmail(normalizedInputEmail) else {
            statusMessage = "Enter a valid e-mail."
            return
        }
        if isCurrentEmail == false, verifiedChallengeID == nil {
            statusMessage = "Verify OTP before saving this e-mail."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            var profile = appState.currentUser.profile
            profile.email = normalizedInputEmail
            profile.phoneNumber = nil
            let updatedUser = try await environment.authRepository.updateProfile(profile, for: appState.currentUser.id)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)

            challenge = nil
            otpCode = ""
            verifiedChallengeID = nil
            emailInput = updatedUser.profile.email ?? normalizedInputEmail
            statusMessage = "E-mail saved."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not save e-mail." : error.localizedDescription
        }
    }

    #if canImport(AuthenticationServices) && !os(tvOS) && !os(watchOS)
    private func configureAppleLinkRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handleAppleLinkResult(_ result: Result<ASAuthorization, Error>) {
        Task {
            await submitAppleLink(result)
        }
    }

    @MainActor
    private func submitAppleLink(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
                return
            }
            statusMessage = error.localizedDescription.isEmpty ? "Could not link Apple ID." : error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                statusMessage = "Could not read Apple credential."
                return
            }
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  identityToken.isEmpty == false else {
                statusMessage = "Could not read Apple identity token."
                return
            }

            await linkAppleIdentity(
                identityToken: identityToken,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                appleUserID: credential.user,
                email: credential.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                givenName: credential.fullName?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines),
                familyName: credential.fullName?.familyName?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    @MainActor
    private func linkAppleIdentity(
        identityToken: String,
        authorizationCode: String?,
        appleUserID: String,
        email: String?,
        givenName: String?,
        familyName: String?
    ) async {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            statusMessage = "Server URL is not configured."
            return
        }

        isLinkingApple = true
        defer { isLinkingApple = false }

        do {
            let payload = AppleLinkRequestPayload(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                appleUserID: appleUserID,
                email: email,
                givenName: givenName,
                familyName: familyName
            )
            let bodyData = try JSONEncoder().encode(payload)
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/auth/apple-link",
                method: "POST",
                body: bodyData,
                userID: appState.currentUser.id
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                statusMessage = "Could not link Apple ID."
                return
            }
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                if let backendError = try? JSONDecoder().decode(BackendErrorPayload.self, from: data) {
                    switch backendError.error {
                    case "apple_identity_taken":
                        statusMessage = "This Apple ID is already linked to another Prime account."
                    case "apple_token_invalid", "apple_token_expired", "apple_signin_failed":
                        statusMessage = "Apple authorization is invalid. Please try again."
                    default:
                        statusMessage = "Could not link Apple ID."
                    }
                } else {
                    statusMessage = "Could not link Apple ID."
                }
                return
            }

            let updatedUser = try BackendJSONDecoder.make().decode(User.self, from: data)
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
            if emailInput.isEmpty {
                emailInput = updatedUser.profile.email ?? ""
            }
            statusMessage = "Apple ID linked successfully."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not link Apple ID." : error.localizedDescription
        }
    }
    #endif
}

private struct ProfileUsernameSettingsView: View {
    private enum AvailabilityState {
        case idle
        case checking
        case available
        case taken
        case saved
        case invalid
        case unavailable
    }

    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var usernameInput = ""
    @State private var state: AvailabilityState = .idle
    @State private var statusMessage = ""
    @State private var isSaving = false
    @State private var debounceTask: Task<Void, Never>?

    private var normalizedUsername: String {
        appState
            .normalizedUsername(
                usernameInput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "@", with: "")
            )
    }

    private var currentUsername: String {
        appState.currentUser.profile.username
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "Use 5-32 characters with only a-z, 0-9, or _."
        case .checking:
            return "onboarding.username.checking".localized
        case .available:
            return "onboarding.username.available".localized
        case .taken:
            return "onboarding.username.taken".localized
        case .saved:
            return "profile.username.saved".localized
        case .invalid:
            return "Use 5-32 characters with only a-z, 0-9, or _."
        case .unavailable:
            return "auth.server.unavailable".localized
        }
    }

    private var statusColor: Color {
        switch state {
        case .available, .saved:
            return PrimeTheme.Colors.success
        case .taken, .invalid, .unavailable:
            return PrimeTheme.Colors.warning
        case .idle, .checking:
            return PrimeTheme.Colors.textSecondary
        }
    }

    private var isSaveDisabled: Bool {
        isSaving || normalizedUsername.isEmpty || appState.isValidUsername(normalizedUsername) == false || normalizedUsername == currentUsername
    }

    var body: some View {
        Form {
            Section("profile.username".localized) {
                TextField("@username", text: $usernameInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: usernameInput) { _ in
                        scheduleAvailabilityCheck()
                    }

                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(statusColor)

                Button(isSaving ? "Saving..." : "profile.username.save".localized) {
                    Task { await saveUsername() }
                }
                .disabled(isSaveDisabled)
            }

            if statusMessage.isEmpty == false {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("profile.username".localized)
        .onAppear {
            if usernameInput.isEmpty {
                usernameInput = currentUsername
                state = .saved
            } else {
                scheduleAvailabilityCheck()
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    private func scheduleAvailabilityCheck() {
        let normalized = normalizedUsername
        if normalized != usernameInput {
            usernameInput = normalized
            return
        }

        statusMessage = ""
        debounceTask?.cancel()

        guard normalized.isEmpty == false else {
            state = .idle
            return
        }
        if normalized == currentUsername {
            state = appState.isValidLegacyUsername(normalized) ? .saved : .invalid
            return
        }
        guard appState.isValidUsername(normalized) else {
            state = .invalid
            return
        }

        state = .checking
        let candidate = normalized
        let userID = appState.currentUser.id
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard Task.isCancelled == false else { return }
            await checkAvailability(candidate, userID: userID)
        }
    }

    @MainActor
    private func checkAvailability(_ candidate: String, userID: UUID) async {
        guard candidate == normalizedUsername else { return }
        do {
            let available = try await environment.settingsRepository.isUsernameAvailable(candidate, for: userID)
            guard candidate == normalizedUsername else { return }
            state = available ? .available : .taken
        } catch {
            guard candidate == normalizedUsername else { return }
            state = .unavailable
        }
    }

    @MainActor
    private func saveUsername() async {
        let candidate = normalizedUsername
        guard appState.isValidUsername(candidate), candidate != currentUsername else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await environment.settingsRepository.claimUsername(candidate, for: appState.currentUser.id)
            appState.updateCurrentUsername(candidate)
            usernameInput = candidate
            state = .saved
            statusMessage = "profile.username.saved".localized
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not save username." : error.localizedDescription
            state = .unavailable
        }
    }
}

private struct ProfilePasswordSettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section("Change Password") {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(.newPassword)

                Button(isLoading ? "Saving..." : "Change Password") {
                    Task { await updatePasswordDirectly() }
                }
                .disabled(
                    isLoading
                    || currentPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Section("Recovery") {
                NavigationLink("Request password change") {
                    ProfilePasswordRecoveryView()
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
        .navigationTitle("settings.admin_console.password".localized)
    }

    @MainActor
    private func updatePasswordDirectly() async {
        let trimmedCurrent = currentPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCurrent.isEmpty == false else {
            statusMessage = "Enter current password."
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
        guard trimmedCurrent != trimmedPassword else {
            statusMessage = "New password must be different."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await environment.authRepository.updatePassword(
                currentPassword: trimmedCurrent,
                newPassword: trimmedPassword,
                for: appState.currentUser.id
            )
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            statusMessage = "Password changed successfully."
        } catch {
            statusMessage = error.localizedDescription.isEmpty ? "Could not change password." : error.localizedDescription
        }
    }
}

private struct AppleLinkRequestPayload: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let appleUserID: String
    let email: String?
    let givenName: String?
    let familyName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case appleUserID = "apple_user_id"
        case email
        case givenName = "given_name"
        case familyName = "family_name"
    }
}

private struct BackendErrorPayload: Decodable {
    let error: String
    let reason: String?
}

private struct ProfilePasswordRecoveryView: View {
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
