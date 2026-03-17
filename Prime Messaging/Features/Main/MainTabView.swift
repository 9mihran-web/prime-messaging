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
    @EnvironmentObject private var appState: AppState
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
                    Text(activeCall.displayName(for: appState.currentUser.id))
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(callStateText(for: activeCall))
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)

                    Button("calls.return".localized) {
                        internetCallManager.presentCallUI()
                    }
                    .buttonStyle(.borderedProminent)
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

    private func callStateText(for call: InternetCall) -> String {
        switch call.state {
        case .ringing:
            return "calls.state.calling".localized
        case .active:
            return "calls.state.active".localized
        case .ended:
            return "calls.state.ended".localized
        case .rejected:
            return "calls.state.rejected".localized
        case .cancelled:
            return "calls.state.cancelled".localized
        case .missed:
            return "calls.state.missed".localized
        }
    }
}
