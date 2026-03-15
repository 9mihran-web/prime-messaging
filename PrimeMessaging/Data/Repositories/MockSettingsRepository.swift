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
}
