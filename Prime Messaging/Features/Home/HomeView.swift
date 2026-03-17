import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: PrimeTheme.Spacing.large) {
            headerBar

            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                Text("app.title".localized)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Text(appState.selectedMode == .online ? "home.online.subtitle".localized : "home.offline.subtitle".localized)
                    .font(.subheadline)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ModeSelectorView(
                selectedMode: Binding(
                    get: { appState.selectedMode },
                    set: { appState.updateSelectedMode($0) }
                )
            )

            ChatListView(mode: appState.selectedMode)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            NavigationLink(destination: AddContactView()) {
                HeaderCircleButton(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: PrimeTheme.Spacing.medium) {
                NavigationLink(destination: AddContactView()) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                }
                .buttonStyle(.plain)

                if appState.selectedMode == .online {
                    NavigationLink(destination: NewGroupView()) {
                        Image(systemName: "person.2.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(PrimeTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
            )
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
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                        Text(mode.subtitleKey.localized)
                            .font(.caption)
                            .foregroundStyle(mode == selectedMode ? Color.white.opacity(0.76) : PrimeTheme.Colors.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PrimeTheme.Spacing.large)
                    .padding(.vertical, 18)
                    .background(backgroundColor(for: mode))
                    .clipShape(RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: PrimeTheme.Radius.card, style: .continuous)
                            .stroke(borderColor(for: mode), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func backgroundColor(for mode: ChatMode) -> Color {
        if selectedMode == mode {
            return mode == .online ? PrimeTheme.Colors.accent : PrimeTheme.Colors.offlineAccent
        }

        return PrimeTheme.Colors.elevated
    }

    private func borderColor(for mode: ChatMode) -> Color {
        if selectedMode == mode {
            return Color.white.opacity(0.08)
        }

        return PrimeTheme.Colors.separator.opacity(0.25)
    }
}

private struct HeaderCircleButton: View {
    let systemName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(PrimeTheme.Colors.elevated)
                .frame(width: 50, height: 50)
            Circle()
                .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                .frame(width: 50, height: 50)
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)
        }
    }
}
