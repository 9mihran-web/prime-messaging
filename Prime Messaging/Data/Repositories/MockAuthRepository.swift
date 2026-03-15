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
        methodType: IdentityMethodType
    ) async throws -> User {
        try await LocalAccountStore.shared.signUp(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType
        )
    }

    func logIn(identifier: String, password: String) async throws -> User {
        try await LocalAccountStore.shared.logIn(identifier: identifier, password: password)
    }

    func refreshUser(userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.refreshUser(userID: userID)
    }

    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.updateProfile(profile, for: userID)
    }

    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User {
        try await LocalAccountStore.shared.uploadAvatar(imageData: imageData, for: userID)
    }

    func searchUsers(query: String, excluding userID: UUID) async throws -> [User] {
        await LocalAccountStore.shared.searchUsers(query: query, excluding: userID)
    }
}
