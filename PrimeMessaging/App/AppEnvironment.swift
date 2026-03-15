import Foundation
import SwiftUI

struct AppEnvironment {
    let authRepository: AuthRepository
    let chatRepository: ChatRepository
    let presenceRepository: PresenceRepository
    let settingsRepository: SettingsRepository
    let localStore: LocalStore
    let pushNotificationService: PushNotificationService
    let offlineTransport: OfflineTransporting

    static func mock() -> AppEnvironment {
        let store = InMemoryLocalStore()
        return AppEnvironment(
            authRepository: MockAuthRepository(),
            chatRepository: MockChatRepository(localStore: store),
            presenceRepository: MockPresenceRepository(),
            settingsRepository: MockSettingsRepository(localStore: store),
            localStore: store,
            pushNotificationService: MockPushNotificationService(),
            offlineTransport: MockOfflineTransport()
        )
    }

    static func live() -> AppEnvironment {
        let store = InMemoryLocalStore()
        return AppEnvironment(
            authRepository: MockAuthRepository(),
            chatRepository: MockChatRepository(localStore: store),
            presenceRepository: MockPresenceRepository(),
            settingsRepository: MockSettingsRepository(localStore: store),
            localStore: store,
            pushNotificationService: MockPushNotificationService(),
            offlineTransport: MockOfflineTransport()
        )
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.mock()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
