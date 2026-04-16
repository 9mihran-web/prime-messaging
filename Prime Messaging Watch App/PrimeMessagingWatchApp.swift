import SwiftUI

@main
struct PrimeMessagingWatchApp: App {
    @StateObject private var syncStore = PrimeWatchSyncStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(syncStore)
        }
    }
}
