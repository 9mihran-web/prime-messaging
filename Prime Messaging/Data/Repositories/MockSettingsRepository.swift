import Foundation

struct MockSettingsRepository: SettingsRepository {
    let localStore: LocalStore
    private static var settings = PrivacySettings.defaultEmailOnly

    func fetchPrivacySettings() async throws -> PrivacySettings {
        Self.settings
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        Self.settings = settings
    }

    func isUsernameAvailable(_ username: String, for userID: UUID?) async throws -> Bool {
        await LocalAccountStore.shared.isUsernameAvailable(username, excluding: userID)
    }

    func claimUsername(_ username: String, for userID: UUID) async throws {
        try await LocalAccountStore.shared.claimUsername(username, for: userID)
    }
}

enum UsernameRepositoryError: LocalizedError {
    case usernameTaken
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .usernameTaken:
            return "Username is already taken."
        case .backendUnavailable:
            return "Username service is unavailable."
        }
    }
}
