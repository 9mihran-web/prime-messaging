import SwiftUI
import UIKit

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var settingsTapCount = 0
    @State private var isShowingHiddenAdminConsole = false

    var body: some View {
        TabView(selection: $appState.selectedMainTab) {
            NavigationStack {
                ContactsView()
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
                CallsView()
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
        .background(
            SettingsTabTapObserver { tappedTab in
                handleTabTap(tappedTab)
            }
        )
        .sheet(isPresented: $isShowingHiddenAdminConsole) {
            NavigationStack {
                AdminConsoleView()
            }
            .environmentObject(appState)
        }
        .onChange(of: appState.currentUser.id) { _ in
            settingsTapCount = 0
            isShowingHiddenAdminConsole = false
        }
    }

    private func handleTabTap(_ tappedTab: MainTab) {
        guard AdminConsoleAccessControl.isAllowed(appState.currentUser.profile.username) else {
            settingsTapCount = 0
            return
        }

        guard tappedTab == .settings else {
            settingsTapCount = 0
            return
        }

        settingsTapCount += 1

        guard settingsTapCount >= 10 else { return }
        settingsTapCount = 0
        isShowingHiddenAdminConsole = true
    }
}

private struct SettingsTabTapObserver: UIViewControllerRepresentable {
    let onTap: (MainTab) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverViewController, context: Context) {
        uiViewController.coordinator = context.coordinator
        uiViewController.attachIfNeeded()
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        private let orderedTabs: [MainTab] = [.contacts, .chats, .calls, .settings]
        private let onTap: (MainTab) -> Void
        private weak var tabBar: UITabBar?
        private var observedControls: [UIControl] = []

        init(onTap: @escaping (MainTab) -> Void) {
            self.onTap = onTap
        }

        func attach(to tabBarController: UITabBarController?) {
            guard let tabBar = tabBarController?.tabBar else { return }

            if self.tabBar !== tabBar {
                detach()
                self.tabBar = tabBar
                wireTabBarControls(in: tabBar)
                return
            }

            wireTabBarControls(in: tabBar)
        }

        private func wireTabBarControls(in tabBar: UITabBar) {
            let controls = tabBar.subviews
                .compactMap { $0 as? UIControl }
                .sorted { lhs, rhs in
                    lhs.frame.minX < rhs.frame.minX
                }

            guard controls.isEmpty == false else { return }

            if observedControls == controls {
                return
            }

            detach()
            observedControls = Array(controls.prefix(orderedTabs.count))

            for (index, control) in observedControls.enumerated() where orderedTabs.indices.contains(index) {
                control.tag = index
                control.addTarget(self, action: #selector(handleTabControlTap(_:)), for: .touchUpInside)
            }
        }

        private func detach() {
            for control in observedControls {
                control.removeTarget(self, action: #selector(handleTabControlTap(_:)), for: .touchUpInside)
            }
            observedControls.removeAll()
        }

        @objc
        private func handleTabControlTap(_ sender: UIControl) {
            guard orderedTabs.indices.contains(sender.tag) else { return }
            onTap(orderedTabs[sender.tag])
        }
    }
}

private final class ObserverViewController: UIViewController {
    weak var coordinator: SettingsTabTapObserver.Coordinator?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        coordinator?.attach(to: tabBarController)
    }
}

private struct CallsView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var internetCallManager = InternetCallManager.shared
    @State private var callHistory: [InternetCall] = []
    @State private var errorText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: PrimeTheme.Spacing.large) {
                if let activeCall = internetCallManager.activeCall {
                    activeCallCard(activeCall)
                }

                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                        .padding(.horizontal, PrimeTheme.Spacing.large)
                }

                if visibleHistory.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: PrimeTheme.Spacing.small) {
                        ForEach(visibleHistory) { call in
                            callRow(call)
                        }
                    }
                }
            }
            .padding(.horizontal, PrimeTheme.Spacing.large)
            .padding(.vertical, PrimeTheme.Spacing.large)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("tab.calls".localized)
        .task(id: appState.currentUser.id) {
            await refreshLoop()
        }
    }

    private var visibleHistory: [InternetCall] {
        let activeCallID = internetCallManager.activeCall?.id
        return callHistory.filter { $0.id != activeCallID }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: PrimeTheme.Spacing.medium) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 42))
                .foregroundStyle(PrimeTheme.Colors.accent)

            Text("calls.placeholder.title".localized)
                .font(.title3.weight(.semibold))

            Text("calls.history.empty".localized)
                .multilineTextAlignment(.center)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                .padding(.horizontal, PrimeTheme.Spacing.xLarge)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PrimeTheme.Spacing.xLarge)
    }

    @ViewBuilder
    private func activeCallCard(_ call: InternetCall) -> some View {
        VStack(spacing: 10) {
            Text(call.displayName(for: appState.currentUser.id))
                .font(.headline)
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
            Text(callStateText(for: call))
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            Button("calls.return".localized) {
                internetCallManager.presentCallUI()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PrimeTheme.Spacing.large)
        .padding(.vertical, PrimeTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
    }

    @ViewBuilder
    private func callRow(_ call: InternetCall) -> some View {
        let direction = call.direction(for: appState.currentUser.id)
        let effectiveState = call.effectiveState(for: appState.currentUser.id)

        HStack(spacing: PrimeTheme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(callIconBackground(for: effectiveState).opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: callIconName(direction: direction, state: effectiveState))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(callIconBackground(for: effectiveState))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(call.displayName(for: appState.currentUser.id))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text(callStateText(for: call))
                    if let subtitle = callSubtitle(for: call), !subtitle.isEmpty {
                        Text("•")
                        Text(subtitle)
                    }
                }
                .font(.footnote)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Spacer()

            Text(call.activityDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, PrimeTheme.Spacing.medium)
        .padding(.vertical, PrimeTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.22), lineWidth: 1)
        )
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshHistory()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @MainActor
    private func refreshHistory() async {
        do {
            callHistory = try await environment.callRepository.fetchCallHistory(for: appState.currentUser.id)
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "calls.history.failed".localized : error.localizedDescription
        }
    }

    private func callStateText(for call: InternetCall) -> String {
        switch call.effectiveState(for: appState.currentUser.id) {
        case .ringing:
            return call.direction(for: appState.currentUser.id) == .incoming
                ? "calls.state.incoming".localized
                : "calls.state.calling".localized
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

    private func callIconName(direction: InternetCallDirection, state: InternetCallState) -> String {
        switch state {
        case .missed, .rejected:
            return "phone.down"
        case .ended, .cancelled, .active:
            return direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right"
        case .ringing:
            return direction == .incoming ? "phone.badge.plus" : "phone"
        }
    }

    private func callIconBackground(for state: InternetCallState) -> Color {
        switch state {
        case .missed, .rejected:
            return PrimeTheme.Colors.warning
        case .active:
            return PrimeTheme.Colors.accent
        case .ended, .cancelled, .ringing:
            return PrimeTheme.Colors.textSecondary
        }
    }

    private func callSubtitle(for call: InternetCall) -> String? {
        let effectiveState = call.effectiveState(for: appState.currentUser.id)
        guard effectiveState == .active || effectiveState == .ended else {
            return nil
        }

        guard let answeredAt = call.answeredAt else {
            return nil
        }

        let endDate = call.endedAt ?? Date.now
        let duration = max(Int(endDate.timeIntervalSince(answeredAt)), 0)
        let minutes = duration / 60
        let seconds = duration % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}
