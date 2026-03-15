import Foundation

struct MockPushNotificationService: PushNotificationService {
    func registerForRemoteNotifications() async { }
    func syncDeviceToken(_ token: Data) async { }
}
