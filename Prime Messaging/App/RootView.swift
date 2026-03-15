import SwiftUI

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            if appState.hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .tint(PrimeTheme.Colors.accent)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .sheet(
            isPresented: Binding(
                get: { appState.hasCompletedOnboarding && appState.isShowingAccountAuth },
                set: { isPresented in
                    if !isPresented {
                        appState.cancelAddingAccount()
                    }
                }
            )
        ) {
            NavigationStack {
                OnboardingView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("common.cancel".localized) {
                                appState.cancelAddingAccount()
                            }
                        }
                    }
            }
        }
        .task(id: rootTaskID) {
            if appState.hasCompletedOnboarding {
                await environment.offlineTransport.updateCurrentUser(appState.currentUser)
                await environment.offlineTransport.startScanning()
            } else {
                await environment.offlineTransport.stopScanning()
            }
        }
    }

    private var rootTaskID: String {
        "\(appState.hasCompletedOnboarding)-\(appState.currentUser.id.uuidString)-\(appState.currentUser.profile.username)"
    }
}
