import Foundation

struct MockOfflineTransport: OfflineTransporting {
    func startScanning() async { }
    func stopScanning() async { }

    func discoveredPeers() async -> [OfflinePeer] {
        [
            OfflinePeer(id: UUID(), displayName: "Mariam's iPhone", alias: "mariam.nearby", signalStrength: -54, isReachable: true),
            OfflinePeer(id: UUID(), displayName: "Prime Lab Device", alias: "lab-peer", signalStrength: -68, isReachable: true)
        ]
    }

    func connect(to peer: OfflinePeer) async throws -> BluetoothSession {
        BluetoothSession(id: UUID(), peerID: peer.id, state: .connected, negotiatedMTU: 180, lastActivityAt: .now)
    }
}
