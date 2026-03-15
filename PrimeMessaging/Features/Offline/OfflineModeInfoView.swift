import SwiftUI

struct OfflineModeInfoView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var peers: [OfflinePeer] = []

    var body: some View {
        List {
            Section("offline.info".localized) {
                Text("offline.info.body".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("offline.nearby.peers".localized) {
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
        .navigationTitle("settings.offline.nearby".localized)
        .task {
            await environment.offlineTransport.startScanning()
            peers = await environment.offlineTransport.discoveredPeers()
        }
    }
}
