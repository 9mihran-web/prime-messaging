import SwiftUI
import UIKit

struct NearbyAccessView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    @StateObject private var permissionRequester = NearbyPermissionRequester()
    @State private var statusText = ""
    @State private var isRequestingAccess = false

    var body: some View {
        List {
            Section("settings.nearby.access".localized) {
                Text("settings.nearby.access.body".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                Button("settings.nearby.request".localized) {
                    Task {
                        await requestNearbyAccess()
                    }
                }
                .disabled(isRequestingAccess)

                Button("settings.nearby.open".localized) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }
        .navigationTitle("settings.nearby.access".localized)
    }

    @MainActor
    private func requestNearbyAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }

        permissionRequester.requestPermissions()
        await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        await environment.offlineTransport.startScanning()

        try? await Task.sleep(for: .seconds(2))
        let peers = await environment.offlineTransport.discoveredPeers()

        if peers.isEmpty {
            statusText = permissionRequester.statusText.isEmpty
                ? "settings.nearby.status.waiting".localized
                : permissionRequester.statusText
        } else {
            statusText = String(format: "settings.nearby.status.found".localized, peers.count)
        }
    }
}
