import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedMainTab) {
            NavigationStack {
                AddContactView()
            }
            .tabItem {
                Label("tab.contacts".localized, systemImage: "person.2")
            }
            .tag(MainTab.contacts)

            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("tab.chats".localized, systemImage: "bubble.left.and.bubble.right")
            }
            .tag(MainTab.chats)

            NavigationStack {
                CallsPlaceholderView()
            }
            .tabItem {
                Label("tab.calls".localized, systemImage: "phone")
            }
            .tag(MainTab.calls)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("tab.settings".localized, systemImage: "gearshape")
            }
            .tag(MainTab.settings)
        }
    }
}

private struct CallsPlaceholderView: View {
    var body: some View {
        VStack(spacing: PrimeTheme.Spacing.large) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 42))
                .foregroundStyle(PrimeTheme.Colors.accent)

            Text("calls.placeholder.title".localized)
                .font(.title3.weight(.semibold))

            Text("calls.placeholder.body".localized)
                .multilineTextAlignment(.center)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                .padding(.horizontal, PrimeTheme.Spacing.xLarge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("tab.calls".localized)
    }
}
