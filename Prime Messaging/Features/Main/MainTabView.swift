import SwiftUI
import UIKit

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
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
        .onAppear {
            applyLiquidGlassTabBarAppearance(for: colorScheme)
        }
        .onChange(of: colorScheme) { newValue in
            applyLiquidGlassTabBarAppearance(for: newValue)
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

    private func applyLiquidGlassTabBarAppearance(for scheme: ColorScheme) {
        #if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(
            style: scheme == .dark ? .systemChromeMaterialDark : .systemUltraThinMaterialLight
        )
        appearance.backgroundColor = scheme == .dark
            ? UIColor.black.withAlphaComponent(0.22)
            : UIColor.white.withAlphaComponent(0.40)
        appearance.shadowColor = UIColor.white.withAlphaComponent(scheme == .dark ? 0.08 : 0.22)

        let selectedColor = UIColor(PrimeTheme.Colors.accent)
        let unselectedColor = UIColor.secondaryLabel.withAlphaComponent(scheme == .dark ? 0.86 : 0.72)

        for itemAppearance in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            itemAppearance.normal.iconColor = unselectedColor
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: unselectedColor]
            itemAppearance.selected.iconColor = selectedColor
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
        }

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.tintColor = selectedColor
        tabBar.unselectedItemTintColor = unselectedColor
        tabBar.isTranslucent = true
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
        #endif
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
    @State private var selectedCallForActions: InternetCall?
    @State private var selectedCallForRedial: InternetCall?
    @State private var presentedProfileUser: User?

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
        .confirmationDialog(
            "Call actions",
            isPresented: Binding(
                get: { selectedCallForActions != nil },
                set: { isPresented in
                    if isPresented == false {
                        selectedCallForActions = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let call = selectedCallForActions {
                if call.isGroupCall == false {
                    Button("Open profile") {
                        Task {
                            await openProfile(for: call)
                        }
                    }
                }
                Button("Open chat") {
                    Task {
                        await openChat(for: call)
                    }
                }
                Button(call.isGroupCall ? "Open group call" : "Redial") {
                    selectedCallForActions = nil
                    selectedCallForRedial = call
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        }
        .confirmationDialog(
            "Redial",
            isPresented: Binding(
                get: { selectedCallForRedial != nil },
                set: { isPresented in
                    if isPresented == false {
                        selectedCallForRedial = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let call = selectedCallForRedial {
                if call.isGroupCall {
                    Button("Open group call") {
                        Task {
                            await redialAudio(for: call)
                        }
                    }
                } else {
                    Button("Audio call") {
                        Task {
                            await redialAudio(for: call)
                        }
                    }
                    Button("Video call") {
                        Task {
                            await redialVideo(for: call)
                        }
                    }
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        }
        .sheet(item: $presentedProfileUser) { user in
            NavigationStack {
                ContactProfileView(user: user)
                    .environmentObject(appState)
            }
            .presentationDetents([.large])
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
        CallHistorySwipeRow(
            onTap: {
                selectedCallForActions = call
            },
            onSwipeLeft: {
                Task {
                    await openChat(for: call)
                }
            },
            onSwipeRight: {
                Task {
                    await redialAudio(for: call)
                }
            }
        ) {
            callRowContent(call)
        }
    }

    @ViewBuilder
    private func callRowContent(_ call: InternetCall) -> some View {
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

    @MainActor
    private func openProfile(for call: InternetCall) async {
        defer { selectedCallForActions = nil }
        guard let participant = call.otherParticipant(for: appState.currentUser.id) else {
            errorText = "Could not open profile."
            return
        }

        if let resolvedUser = try? await environment.authRepository.userProfile(userID: participant.id) {
            presentedProfileUser = resolvedUser
            errorText = ""
            return
        }

        presentedProfileUser = fallbackUser(from: participant)
        errorText = ""
    }

    @MainActor
    private func openChat(for call: InternetCall) async {
        defer { selectedCallForActions = nil }
        if call.isGroupCall {
            guard let chat = await resolveExistingChat(for: call) else {
                errorText = "Could not open chat."
                return
            }
            errorText = ""
            appState.routeToChat(chat)
            return
        }

        guard let participantID = call.otherParticipant(for: appState.currentUser.id)?.id else {
            errorText = "Could not open chat."
            return
        }

        do {
            let chat = try await environment.chatRepository.createDirectChat(
                with: participantID,
                currentUserID: appState.currentUser.id,
                mode: .online
            )
            errorText = ""
            appState.routeToChat(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
        }
    }

    @MainActor
    private func redialAudio(for call: InternetCall) async {
        defer {
            selectedCallForActions = nil
            selectedCallForRedial = nil
        }

        if call.isGroupCall {
            guard let chat = await resolveExistingChat(for: call) else {
                errorText = "calls.unavailable.start".localized
                return
            }
            appState.routeToChat(chat)
            errorText = ""
            return
        }

        guard let participantID = call.otherParticipant(for: appState.currentUser.id)?.id else {
            errorText = "calls.unavailable.start".localized
            return
        }

        do {
            try await internetCallManager.startOutgoingCall(to: participantID)
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "calls.unavailable.start".localized : error.localizedDescription
        }
    }

    @MainActor
    private func redialVideo(for call: InternetCall) async {
        defer {
            selectedCallForActions = nil
            selectedCallForRedial = nil
        }

        guard call.isGroupCall == false else {
            errorText = "Group calls are audio-only right now."
            return
        }

        guard let participantID = call.otherParticipant(for: appState.currentUser.id)?.id else {
            errorText = "calls.unavailable.start".localized
            return
        }

        do {
            try await internetCallManager.startOutgoingCall(to: participantID)
            internetCallManager.presentCallUI()
            try? await Task.sleep(for: .milliseconds(180))
            internetCallManager.toggleVideo()
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "calls.unavailable.start".localized : error.localizedDescription
        }
    }

    private func fallbackUser(from participant: InternetCallParticipant) -> User {
        let displayName = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = (displayName?.isEmpty == false ? displayName : participant.username) ?? participant.username

        return User(
            id: participant.id,
            profile: Profile(
                displayName: resolvedDisplayName,
                username: participant.username,
                bio: "",
                status: "Last seen recently",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: participant.profilePhotoURL,
                socialLink: nil
            ),
            identityMethods: [
                IdentityMethod(type: .username, value: "@\(participant.username)", isVerified: true, isPubliclyDiscoverable: true)
            ],
            privacySettings: .defaultEmailOnly
        )
    }

    @MainActor
    private func resolveExistingChat(for call: InternetCall) async -> Chat? {
        guard let chatID = call.chatID else { return nil }
        let cached = await environment.chatRepository.cachedChats(mode: call.mode, for: appState.currentUser.id)
        if let matchedCached = cached.first(where: { $0.id == chatID }) {
            return matchedCached
        }
        if let fetched = try? await environment.chatRepository.fetchChats(mode: call.mode, for: appState.currentUser.id) {
            return fetched.first(where: { $0.id == chatID })
        }
        return nil
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
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}

private struct CallHistorySwipeRow<Content: View>: View {
    let onTap: () -> Void
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0

    private let actionTriggerThreshold: CGFloat = 86
    private let maxOffset: CGFloat = 78

    var body: some View {
        ZStack {
            swipeBackground
            content()
                .contentShape(Rectangle())
                .offset(x: offsetX)
        }
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(dragGesture)
        .onTapGesture {
            onTap()
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: offsetX)
    }

    private var swipeBackground: some View {
        HStack(spacing: 10) {
            swipeBadge(title: "Audio call", systemName: "phone.fill", tint: PrimeTheme.Colors.accent)
            Spacer(minLength: 0)
            swipeBadge(title: "Open chat", systemName: "bubble.left.and.bubble.right.fill", tint: PrimeTheme.Colors.smartAccent)
        }
        .padding(.horizontal, 10)
        .background(PrimeTheme.Colors.elevated.opacity(0.9))
    }

    private func swipeBadge(title: String, systemName: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.92))
        )
    }

    private var dragGesture: some Gesture {
        #if os(tvOS)
        TapGesture()
        #else
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                guard shouldTrackSwipe(translation: value.translation) else { return }
                offsetX = min(max(value.translation.width * 0.45, -maxOffset), maxOffset)
            }
            .onEnded { value in
                guard shouldTrackSwipe(translation: value.translation) else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        offsetX = 0
                    }
                    return
                }

                if value.translation.width >= actionTriggerThreshold {
                    onSwipeRight()
                } else if value.translation.width <= -actionTriggerThreshold {
                    onSwipeLeft()
                }

                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    offsetX = 0
                }
            }
        #endif
    }

    private func shouldTrackSwipe(translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal > 14 else { return false }
        return horizontal > vertical * 1.5
    }
}
