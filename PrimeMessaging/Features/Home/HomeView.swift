import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: PrimeTheme.Spacing.large) {
            ModeSelectorView(selectedMode: $appState.selectedMode)
            ChatListView(mode: appState.selectedMode)
        }
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .navigationTitle("app.title".localized)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape")
                }
            }
        }
    }
}

struct ModeSelectorView: View {
    @Binding var selectedMode: ChatMode

    var body: some View {
        HStack(spacing: PrimeTheme.Spacing.small) {
            ForEach(ChatMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                        Text(mode.titleKey.localized)
                            .font(.headline)
                        Text(mode.subtitleKey.localized)
                            .font(.caption)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PrimeTheme.Spacing.large)
                    .background(backgroundColor(for: mode))
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func backgroundColor(for mode: ChatMode) -> Color {
        if selectedMode == mode {
            return mode == .online ? PrimeTheme.Colors.accent.opacity(0.15) : PrimeTheme.Colors.offlineAccent.opacity(0.18)
        }

        return PrimeTheme.Colors.elevated
    }
}
