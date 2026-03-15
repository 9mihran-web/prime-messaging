import SwiftUI
import UIKit

struct NotificationsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.openURL) private var openURL

    @State private var status: PushAuthorizationStatus = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        List {
            Section("settings.notifications.push".localized) {
                Text("settings.notifications.body".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                LabeledContent("settings.notifications.status".localized, value: status.localizationKey.localized)

                Text("settings.notifications.typing".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                Button("settings.notifications.request".localized) {
                    Task {
                        await requestNotifications()
                    }
                }
                .disabled(isRequesting)

                Button("settings.notifications.open".localized) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }
        .navigationTitle("settings.notifications.push".localized)
        .task {
            await refreshStatus()
        }
    }

    @MainActor
    private func requestNotifications() async {
        isRequesting = true
        defer { isRequesting = false }

        await environment.pushNotificationService.registerForRemoteNotifications()
        try? await Task.sleep(for: .milliseconds(400))
        await refreshStatus()
    }

    @MainActor
    private func refreshStatus() async {
        status = await environment.pushNotificationService.authorizationStatus()
    }
}
