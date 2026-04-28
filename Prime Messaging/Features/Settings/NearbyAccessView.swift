import SwiftUI
import UIKit

struct NearbyAccessView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    @StateObject private var permissionRequester = NearbyPermissionRequester()
    @State private var statusText = ""
    @State private var isRequestingAccess = false
    @State private var showsHomeNearbyPeers = true
    @State private var nearbyPeersOfflineOnly = true

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

            Section("settings.nearby.visibility".localized) {
                Toggle("settings.nearby.visibility.show_home".localized, isOn: Binding(
                    get: { showsHomeNearbyPeers },
                    set: { newValue in
                        showsHomeNearbyPeers = newValue
                        Task {
                            await NearbyPeersVisibilityStore.shared.setShowHomeCard(newValue, ownerUserID: appState.currentUser.id)
                        }
                    }
                ))

                Toggle("settings.nearby.visibility.offline_only".localized, isOn: Binding(
                    get: { nearbyPeersOfflineOnly },
                    set: { newValue in
                        nearbyPeersOfflineOnly = newValue
                        Task {
                            await NearbyPeersVisibilityStore.shared.setOfflineOnly(newValue, ownerUserID: appState.currentUser.id)
                        }
                    }
                ))
                .disabled(showsHomeNearbyPeers == false)

                Text("settings.nearby.visibility.footer".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
        .navigationTitle("settings.nearby.access".localized)
        .task(id: appState.currentUser.id) {
            let preferences = await NearbyPeersVisibilityStore.shared.preferences(ownerUserID: appState.currentUser.id)
            showsHomeNearbyPeers = preferences.showHomeCard
            nearbyPeersOfflineOnly = preferences.offlineOnly
        }
        .onDisappear {
            guard appState.selectedMode == .online, appState.isEmergencyModeEnabled == false else { return }
            Task {
                await environment.offlineTransport.stopScanning()
            }
        }
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
