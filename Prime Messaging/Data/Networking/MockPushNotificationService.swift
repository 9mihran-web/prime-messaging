import Foundation

@MainActor
final class MockPushNotificationService: PushNotificationService {
    func registerForRemoteNotifications() async { }
    func syncDeviceToken(_ token: Data) async { }
    func authorizationStatus() async -> PushAuthorizationStatus { .notDetermined }
    func startMonitoring(currentUser: User, chatRepository: ChatRepository) async { }
    func stopMonitoring() async { }
    func updateActiveChat(_ chat: Chat?) async { }
}
