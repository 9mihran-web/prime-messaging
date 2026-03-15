import Combine
import CoreBluetooth
import Foundation

@MainActor
final class NearbyPermissionRequester: NSObject, ObservableObject {
    @Published private(set) var statusText = ""

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    func requestPermissions() {
        statusText = "settings.nearby.status.requested".localized

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
        )
    }
}

extension NearbyPermissionRequester: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if statusText.isEmpty {
                    statusText = "settings.nearby.status.waiting".localized
                }
            case .poweredOff:
                statusText = "settings.nearby.status.bluetooth.off".localized
            case .unauthorized:
                statusText = "settings.nearby.status.bluetooth.denied".localized
            case .unsupported:
                statusText = "settings.nearby.status.unsupported".localized
            case .unknown, .resetting:
                statusText = "settings.nearby.status.requested".localized
            @unknown default:
                statusText = "settings.nearby.status.requested".localized
            }
        }
    }
}

extension NearbyPermissionRequester: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                if statusText.isEmpty || statusText == "settings.nearby.status.requested".localized {
                    statusText = "settings.nearby.status.waiting".localized
                }
            case .poweredOff:
                statusText = "settings.nearby.status.bluetooth.off".localized
            case .unauthorized:
                statusText = "settings.nearby.status.bluetooth.denied".localized
            case .unsupported:
                statusText = "settings.nearby.status.unsupported".localized
            case .unknown, .resetting:
                statusText = "settings.nearby.status.requested".localized
            @unknown default:
                statusText = "settings.nearby.status.requested".localized
            }
        }
    }
}
