import SwiftUI
import OSLog
import UIKit

@main
@MainActor
struct PrimeMessagingApp: App {
    private static let minimumLaunchScreenDuration: Duration = .seconds(1.8)
    @UIApplicationDelegateAdaptor(PrimeMessagingAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState?
    @State private var environment: AppEnvironment?
    @State private var didScheduleEnvironmentInitialization = false
    @State private var isShowingLaunchOverlay = true
    @State private var didScheduleLaunchOverlayDismissal = false
    private let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "Startup")

    init() {
        let message = "PUSHTRACE app step=app.init main=\(Thread.isMainThread)"
        NSLog("%@", message)
        print(message)
    }

    private func logPushTrace(_ step: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        let message = "PUSHTRACE app step=\(step) main=\(Thread.isMainThread)\(suffix)"
        logger.error("\(message, privacy: .public)")
        NSLog("%@", message)
        print(message)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                SwiftUI.Group {
                    if let appState, let environment {
                        RootView()
                            .environmentObject(appState)
                            .environment(\.appEnvironment, environment)
                            .id(appState.selectedLanguage.rawValue)
                            .preferredColorScheme(nil)
                    } else {
                        Color.clear
                    }
                }
                if isShowingLaunchOverlay {
                    PrimeMessagingLaunchOverlay()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .task {
                guard didScheduleEnvironmentInitialization == false else { return }
                didScheduleEnvironmentInitialization = true
                scheduleLaunchOverlayDismissalIfNeeded()
                logPushTrace("appState.initialization.begin")
                let resolvedAppState = AppState()
                switch scenePhase {
                case .active:
                    resolvedAppState.markSceneBecameActive()
                case .background:
                    resolvedAppState.markSceneMovedToBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
                logPushTrace("appState.initialization.end")
                logPushTrace("environment.initialization.begin")
                let resolvedEnvironment = AppEnvironment.live()
                appState = resolvedAppState
                environment = resolvedEnvironment
                logPushTrace("environment.initialization.end")
            }
            .onChange(of: scenePhase) { newPhase in
                logPushTrace("scenePhase.changed", details: "phase=\(String(describing: newPhase))")
                switch newPhase {
                case .active:
                    appState?.markSceneBecameActive()
                    AppLockStore.shared.handleSceneBecameActive()
                case .inactive:
                    break
                case .background:
                    appState?.markSceneMovedToBackground()
                    AppLockStore.shared.handleSceneMovedToBackground()
                @unknown default:
                    break
                }
            }
        }
    }

    private func scheduleLaunchOverlayDismissalIfNeeded() {
        guard didScheduleLaunchOverlayDismissal == false else { return }
        didScheduleLaunchOverlayDismissal = true

        Task { @MainActor in
            try? await Task.sleep(for: Self.minimumLaunchScreenDuration)

            withAnimation(.easeOut(duration: 0.28)) {
                isShowingLaunchOverlay = false
            }
        }
    }
}

struct PrimeMessagingLaunchOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                launchBackgroundColor
                    .ignoresSafeArea()

                Image("SplashIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: min(proxy.size.width * 0.88, 396))
                .opacity(isAnimating ? 1 : 0.82)
                .scaleEffect(isAnimating ? 1 : 0.975)
                .animation(
                    .easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                    value: isAnimating
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
            }
        }
        .task {
            isAnimating = true
        }
    }

    private var launchBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}
