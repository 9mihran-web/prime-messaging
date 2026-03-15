import SwiftUI

struct RootView: View {
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
    }
}
