import Foundation

struct MockAuthRepository: AuthRepository {
    func currentUser() async throws -> User {
        await LocalAccountStore.shared.currentUser() ?? .mockCurrentUser
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType,
        accountKind: AccountKind
    ) async throws -> User {
        try await LocalAccountStore.shared.signUp(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType,
            accountKind: accountKind
        )
    }

    func lookupAccount(identifier: String) async throws -> AccountLookupResult {
        await LocalAccountStore.shared.lookupAccount(identifier: identifier)
    }

    func authenticate(identifier: String, otpCode: String) async throws -> User? {
        try await LocalAccountStore.shared.authenticate(identifier: identifier, otpCode: otpCode)
    }

    func logIn(identifier: String, password: String) async throws -> User {
        try await LocalAccountStore.shared.logIn(identifier: identifier, password: password)
    }

    func resetPassword(identifier: String, newPassword: String) async throws {
        try await LocalAccountStore.shared.resetPassword(identifier: identifier, newPassword: newPassword)
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

    func deleteAccount(userID: UUID) async throws {
        try await LocalAccountStore.shared.deleteAccount(userID: userID)
    }

    func searchUsers(query: String, excluding userID: UUID) async throws -> [User] {
        await LocalAccountStore.shared.searchUsers(query: query, excluding: userID)
            .map { visibleUser($0, for: userID) }
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
