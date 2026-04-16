import Foundation
import SwiftUI

struct AppEnvironment {
    let authRepository: AuthRepository
    let chatRepository: ChatRepository
    let presenceRepository: PresenceRepository
    let callRepository: CallRepository
    let settingsRepository: SettingsRepository
    let localStore: LocalStore
    let pushNotificationService: PushNotificationService
    let offlineTransport: OfflineTransporting

    static func mock() -> AppEnvironment {
        let store = DiskLocalStore(directoryName: "PrimeMessagingMockLocalStore")
        let settingsRepository = MockSettingsRepository(localStore: store)
        let offlineTransport = MockOfflineTransport()
        return AppEnvironment(
            authRepository: MockAuthRepository(),
            chatRepository: AppChatRepository(
                onlineRepository: MockChatRepository(localStore: store),
                offlineTransport: offlineTransport
            ),
            presenceRepository: MockPresenceRepository(),
            callRepository: MockCallRepository(),
            settingsRepository: settingsRepository,
            localStore: store,
            pushNotificationService: MockPushNotificationService(),
            offlineTransport: offlineTransport
        )
    }

    @MainActor
    static func live() -> AppEnvironment {
        let store = DiskLocalStore()
        let mockAuth = MockAuthRepository()
        let onlineChat = BackendChatRepository(fallback: MockChatRepository(localStore: store))
        let mockSettings = MockSettingsRepository(localStore: store)
        let mockPresence = MockPresenceRepository()
        let offlineTransport = NearbyOfflineTransport()
        return AppEnvironment(
            authRepository: BackendAuthRepository(fallback: mockAuth),
            chatRepository: AppChatRepository(
                onlineRepository: onlineChat,
                offlineTransport: offlineTransport
            ),
            presenceRepository: BackendPresenceRepository(fallback: mockPresence),
            callRepository: BackendCallRepository(fallback: MockCallRepository()),
            settingsRepository: BackendSettingsRepository(
                fallback: mockSettings
            ),
            localStore: store,
            pushNotificationService: LocalPushNotificationService.shared,
            offlineTransport: offlineTransport
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
