import Foundation

struct MockAuthRepository: AuthRepository {
    func currentUser() async throws -> User {
        await LocalAccountStore.shared.currentUser() ?? .mockCurrentUser
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String?,
        appleUserID: String,
        email: String?,
        givenName: String?,
        familyName: String?
    ) async throws -> AppleSignInResult {
        try await LocalAccountStore.shared.signInWithApple(
            appleUserID: appleUserID,
            email: email,
            givenName: givenName,
            familyName: familyName
        )
    }

    func matchDeviceContacts(
        _ contacts: [DeviceContactCandidate],
        currentUserID: UUID
    ) async throws -> [MatchedDeviceContact] {
        await LocalAccountStore.shared.matchDeviceContacts(
            contacts,
            excluding: currentUserID
        )
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType,
        accountKind: AccountKind,
        otpChallengeID: String?,
        signupEmail: String?
    ) async throws -> User {
        try await LocalAccountStore.shared.signUp(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType,
            accountKind: accountKind,
            otpChallengeID: otpChallengeID,
            signupEmail: signupEmail
        )
    }

    func lookupAccount(identifier: String) async throws -> AccountLookupResult {
        await LocalAccountStore.shared.lookupAccount(identifier: identifier)
    }

    func requestOTP(identifier: String, purpose: OTPPurpose) async throws -> OTPChallenge {
        try await LocalAccountStore.shared.requestOTP(identifier: identifier, purpose: purpose)
    }

    func verifyOTPChallenge(challengeID: String, otpCode: String) async throws -> OTPChallenge {
        try await LocalAccountStore.shared.verifyOTPChallenge(challengeID: challengeID, otpCode: otpCode)
    }

    func authenticate(identifier: String, otpCode: String, challengeID: String?) async throws -> User? {
        try await LocalAccountStore.shared.authenticate(
            identifier: identifier,
            otpCode: otpCode,
            challengeID: challengeID
        )
    }

    func logIn(identifier: String, password: String) async throws -> User {
        try await LocalAccountStore.shared.logIn(identifier: identifier, password: password)
    }

    func resetPassword(identifier: String, newPassword: String, challengeID: String?) async throws {
        try await LocalAccountStore.shared.resetPassword(
            identifier: identifier,
            newPassword: newPassword,
            challengeID: challengeID
        )
    }

    func refreshUser(userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.refreshUser(userID: userID)
    }

    func userProfile(userID: UUID) async throws -> User {
        let user = try await LocalAccountStore.shared.refreshUser(userID: userID)
        let viewerID = await LocalAccountStore.shared.currentUser()?.id
        return visibleUser(user, for: viewerID)
    }

    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.updateProfile(profile, for: userID)
    }

    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.uploadAvatar(imageData: imageData, for: userID)
    }

    func removeAvatar(for userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.removeAvatar(for: userID)
    }

    func updatePassword(_ password: String, for userID: UUID) async throws {
        try await LocalAccountStore.shared.updatePassword(password, for: userID)
    }

    func updatePassword(currentPassword: String?, newPassword: String, for userID: UUID) async throws {
        if let currentPassword {
            let current = await LocalAccountStore.shared.currentUser()
            let identifier = current?.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? current?.profile.username
                ?? ""
            _ = try await LocalAccountStore.shared.logIn(
                identifier: identifier,
                password: currentPassword
            )
        }
        try await LocalAccountStore.shared.updatePassword(newPassword, for: userID)
    }

    func deleteAccount(userID: UUID) async throws {
        try await LocalAccountStore.shared.deleteAccount(userID: userID)
    }

    func searchUsers(query: String, excluding userID: UUID) async throws -> [User] {
        await LocalAccountStore.shared.searchUsers(query: query, excluding: userID)
            .map { visibleUser($0, for: userID) }
    }

    func fetchBlockedUsers(for userID: UUID) async throws -> [User] {
        await LocalAccountStore.shared.blockedUsers(for: userID)
            .map { visibleUser($0, for: userID) }
    }

    func blockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws {
        await LocalAccountStore.shared.blockUser(blockerUserID: blockerUserID, blockedUserID: blockedUserID)
    }

    func unblockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws {
        await LocalAccountStore.shared.unblockUser(blockerUserID: blockerUserID, blockedUserID: blockedUserID)
    }

    private func visibleUser(_ user: User, for viewerID: UUID?) -> User {
        guard viewerID != user.id else {
            return user
        }

        var visibleUser = user
        if visibleUser.privacySettings.showEmail == false {
            visibleUser.profile.email = nil
        }
        if visibleUser.privacySettings.showPhoneNumber == false {
            visibleUser.profile.phoneNumber = nil
        }
        if visibleUser.privacySettings.allowProfilePhoto == false {
            visibleUser.profile.profilePhotoURL = nil
        }
        return visibleUser
    }
}
