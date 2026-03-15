import SwiftUI

struct OfflineModeInfoView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @State private var peers: [OfflinePeer] = []

    var body: some View {
        List {
            Section("offline.info".localized) {
                Text("offline.info.body".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("offline.nearby.peers".localized) {
                if peers.isEmpty {
                    Text("contact.bluetooth.empty".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                } else {
                    ForEach(peers) { peer in
                        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                            Text(peer.displayName)
                            Text("\(peer.alias) • RSSI \(peer.signalStrength)")
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("settings.offline.nearby".localized)
        .task(id: appState.currentUser.id.uuidString) {
            await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        }
        .task(id: refreshTaskID) {
            await environment.offlineTransport.startScanning()
            while !Task.isCancelled {
                peers = await environment.offlineTransport.discoveredPeers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var refreshTaskID: String {
        "\(appState.currentUser.id.uuidString)-\(appState.currentUser.profile.username)"
    }
}
