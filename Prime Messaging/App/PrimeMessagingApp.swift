import SwiftUI

@main
@MainActor
struct PrimeMessagingApp: App {
    @StateObject private var appState = AppState()
    private let environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environment(\.appEnvironment, environment)
                .id(appState.selectedLanguage.rawValue)
                .preferredColorScheme(nil)
        }
    }
}
