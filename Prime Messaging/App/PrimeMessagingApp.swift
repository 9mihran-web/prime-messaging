import SwiftUI

@main
@MainActor
struct PrimeMessagingApp: App {
    @UIApplicationDelegateAdaptor(PrimeMessagingAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    private let environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environment(\.appEnvironment, environment)
                .id(appState.selectedLanguage.rawValue)
                .preferredColorScheme(nil)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        appState.markSceneBecameActive()
                    case .inactive, .background:
                        appState.markSceneMovedToBackground()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
