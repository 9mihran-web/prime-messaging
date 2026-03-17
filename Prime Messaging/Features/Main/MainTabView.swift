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
    @ObservedObject private var internetCallManager = InternetCallManager.shared

    var body: some View {
        VStack(spacing: PrimeTheme.Spacing.large) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 42))
                .foregroundStyle(PrimeTheme.Colors.accent)

            Text("calls.placeholder.title".localized)
                .font(.title3.weight(.semibold))

            Text(callBodyText)
                .multilineTextAlignment(.center)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                .padding(.horizontal, PrimeTheme.Spacing.xLarge)

            if let activeCall = internetCallManager.activeCall {
                VStack(spacing: 10) {
                    Text(activeCall.user.profile.displayName.isEmpty ? activeCall.user.profile.username : activeCall.user.profile.displayName)
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(activeCall.state == .active ? "calls.state.active".localized : "calls.state.calling".localized)
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .padding(.horizontal, PrimeTheme.Spacing.large)
                .padding(.vertical, PrimeTheme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(PrimeTheme.Colors.elevated)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("tab.calls".localized)
    }

    private var callBodyText: String {
        if internetCallManager.activeCall != nil {
            return "calls.placeholder.body.active".localized
        }

        return "calls.placeholder.body.idle".localized
    }
}
