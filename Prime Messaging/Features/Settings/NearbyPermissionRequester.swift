import Combine
import CoreBluetooth
import Foundation

@MainActor
final class NearbyPermissionRequester: NSObject, ObservableObject {
    @Published private(set) var statusText = ""

    private var centralManager: CBCentralManager?
    private var serviceBrowser: NetServiceBrowser?

    func requestPermissions() {
        statusText = "settings.nearby.status.requested".localized

        let browser = NetServiceBrowser()
        browser.delegate = self
        serviceBrowser = browser
        browser.searchForServices(ofType: "_prmsgchat._tcp.", inDomain: "local.")

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
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

extension NearbyPermissionRequester: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            statusText = "settings.nearby.status.waiting".localized
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        Task { @MainActor in
            statusText = "settings.nearby.status.localnetwork.denied".localized
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            statusText = "settings.nearby.status.waiting".localized
        }
    }
}
