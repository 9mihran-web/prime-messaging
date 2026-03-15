import Foundation

struct OfflinePeer: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var alias: String
    var signalStrength: Int
    var isReachable: Bool
}

struct BluetoothSession: Identifiable, Codable, Hashable {
    let id: UUID
    var peerID: UUID
    var state: BluetoothSessionState
    var negotiatedMTU: Int
    var lastActivityAt: Date
}
