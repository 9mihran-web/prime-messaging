import Foundation

enum OfflineTransportPath: String, Codable, CaseIterable, Hashable {
    case bluetooth
    case localNetwork
    case meshRelay

    nonisolated var priority: Int {
        switch self {
        case .localNetwork:
            return 0
        case .bluetooth:
            return 1
        case .meshRelay:
            return 2
        }
    }
}

struct OfflinePeer: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var alias: String
    var signalStrength: Int
    var isReachable: Bool
    var availablePaths: [OfflineTransportPath] = [.bluetooth]
    var relayCapable: Bool = false
}

struct BluetoothSession: Identifiable, Codable, Hashable {
    let id: UUID
    var peerID: UUID
    var state: BluetoothSessionState
    var negotiatedMTU: Int
    var lastActivityAt: Date
}
