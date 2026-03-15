import SwiftUI

@main
struct PrimeMessagingApp: App {
    @StateObject private var appState = AppState()
    private let environment = AppEnvironment.mock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environment(\.appEnvironment, environment)
                .preferredColorScheme(nil)
        }
    }
}
