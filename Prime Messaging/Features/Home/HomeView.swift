import SwiftUI

struct HomeView: View {
    private enum NearbySearchResult {
        case found(OfflinePeer)
        case none
    }

    @Environment(\.appEnvironment) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLockStore = AppLockStore.shared
    @State private var isOpeningNearbyChat = false
    @State private var isTransitioningMode = false
    @State private var isShowingNearbySearchFailureAlert = false
    @State private var modeTransitionError = ""
    @State private var nearbyPeers: [OfflinePeer] = []
    @State private var isSyncingEmergencyStatus = false
    @State private var showsHomeNearbyPeers = true
    @State private var nearbyPeersOfflineOnly = true
    @State private var isShowingCreateMenu = false
    @State private var selectedFeedCategory: ChatFeedCategoryFilter = .all
    @State private var showsClosedLockGlyph = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PrimeTheme.Spacing.large) {
                titleBlock
                emergencyLayer
                if shouldShowNearbyLayer {
                    nearbyLayer
                }

                ChatListView(
                    mode: appState.selectedMode,
                    categoryFilter: selectedFeedCategory,
                    embeddedInScroll: true
                )
                    .padding(.top, 6)
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            headerBar
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(
                    PrimeTheme.Colors.background
                        .opacity(0.96)
                        .ignoresSafeArea(edges: .top)
                )
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: nearbyLayerTaskID) {
            await refreshNearbyLayer()
        }
        .task(id: nearbyVisibilityTaskID) {
            await loadNearbyVisibilityPreferences()
        }
        .alert("home.offline.nearby.unavailable.title".localized, isPresented: $isShowingNearbySearchFailureAlert) {
            Button("common.try_again".localized) {
                Task {
                    await openNearestOfflineChat()
                }
            }
            Button("common.cancel".localized, role: .cancel) { }
        } message: {
            Text("home.offline.nearby.unavailable.message".localized)
        }
        .sheet(isPresented: $isShowingCreateMenu) {
            NavigationStack {
                QuickCreateSheet()
                    .environmentObject(appState)
                    .environment(\.appEnvironment, environment)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(for: Chat.self) { chat in
            ChatView(chat: chat)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { appState.routedChat != nil },
                set: { isPresented in
                    if isPresented == false {
                        if let routedChat = appState.routedChat {
                            let shouldKeepNotificationRoutePresented =
                                appState.pendingNotificationRoute?.chatID == routedChat.id
                                || appState.pendingResolvedNotificationChat?.id == routedChat.id
                                || appState.hasPendingNotificationLaunchRoute(for: routedChat.id)

                            if shouldKeepNotificationRoutePresented {
                                return
                            }
                        }
                        appState.clearRoutedChat()
                        appState.clearPendingNotificationRoute()
                    }
                }
            )
        ) {
            NotificationRouteChatDestinationView(routedChat: appState.routedChat)
        }
        .overlay {
            if appState.pendingNotificationRoute != nil, appState.routedChat == nil {
                NotificationRouteLoadingOverlayView()
            }
        }
        .onAppear {
            appState.setChatsRootReady(true)
            Task { @MainActor in
                await Task.yield()
                _ = appState.commitQueuedNotificationNavigationIfPossible()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
            Text("app.title".localized)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)

            Text(appState.selectedMode.subtitleKey.localized)
                .font(.subheadline)
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            if modeTransitionError.isEmpty == false {
                Text(modeTransitionError)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.warning)
            }

            feedCategoryTabs
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var feedCategoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChatFeedCategoryFilter.allCases) { category in
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82, blendDuration: 0.1)) {
                            selectedFeedCategory = category
                        }
                    } label: {
                        Text(category.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                selectedFeedCategory == category
                                    ? Color.white
                                    : PrimeTheme.Colors.textSecondary
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        selectedFeedCategory == category
                                            ? PrimeTheme.Colors.accent.opacity(0.9)
                                            : PrimeTheme.Colors.glassTint.opacity(0.8)
                                    )
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        selectedFeedCategory == category
                                            ? Color.white.opacity(colorScheme == .dark ? 0.14 : 0.26)
                                            : PrimeTheme.Colors.bubbleIncomingBorder.opacity(colorScheme == .dark ? 0.72 : 0.96),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var emergencyLayer: some View {
        if appState.isEmergencyModeAvailable, appState.isEmergencyModeEnabled {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cross.case.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(PrimeTheme.Colors.warning)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Emergency Mode")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        Text("Low-noise mode with faster nearby readiness and quick safety statuses.")
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }

                    Spacer(minLength: 8)

                    if isSyncingEmergencyStatus {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(PrimeTheme.Colors.warning)
                    }
                }

                HStack(spacing: 10) {
                    ForEach(EmergencyModeStatus.allCases, id: \.rawValue) { status in
                        Button {
                            Task {
                                await setEmergencyStatus(status)
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: status.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(status.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                            }
                            .foregroundStyle(appState.emergencyModeStatus == status ? Color.white : PrimeTheme.Colors.warning)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(
                                                appState.emergencyModeStatus == status
                                                    ? PrimeTheme.Colors.warning.opacity(0.9)
                                                    : PrimeTheme.Colors.glassTint
                                            )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    Task {
                        await openNearestOfflineChat()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Find nearby help")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.footnote.weight(.bold))
                    }
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PrimeTheme.Colors.warning.opacity(0.92))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isOpeningNearbyChat)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(PrimeTheme.Colors.glassTint.opacity(0.78))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 10)
        }
    }

    private var nearbyLayer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("offline.nearby.peers".localized, systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)

                Spacer(minLength: 8)

                Text("\(nearbyPeers.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.offlineAccent.opacity(0.88))
                    )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(nearbyPeers.prefix(6)) { peer in
                        Button {
                            Task {
                                try? await openNearbyChat(with: peer)
                            }
                        } label: {
                            NearbyPeerChip(peer: peer)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(PrimeTheme.Colors.glassTint.opacity(0.82))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 18, y: 10)
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            NavigationLink(destination: GlobalChatSearchView(mode: appState.selectedMode)) {
                HeaderCircleButton(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)

            if appLockStore.isEnabled {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                        showsClosedLockGlyph = true
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(170))
                        await MainActor.run {
                            appLockStore.lockFromUserAction()
                        }
                        try? await Task.sleep(for: .milliseconds(220))
                        await MainActor.run {
                            showsClosedLockGlyph = false
                        }
                    }
                } label: {
                    HeaderCircleButton(
                        systemName: showsClosedLockGlyph ? "lock.fill" : "lock.open",
                        tint: PrimeTheme.Colors.accent
                    )
                    .scaleEffect(showsClosedLockGlyph ? 0.94 : 1)
                }
                .buttonStyle(.plain)
            }

            ModeSelectorView(
                availableModes: appState.availableModes,
                selectedMode: appState.selectedMode,
                isBusy: isTransitioningMode
            ) { mode, preserveChatsOnTransition in
                requestModeSelection(mode, preserveChatsOnTransition: preserveChatsOnTransition)
            }
            .frame(maxWidth: .infinity)

            if appState.isEmergencyModeAvailable {
                Button {
                    Task {
                        await toggleEmergencyMode()
                    }
                } label: {
                    HeaderCircleButton(
                        systemName: appState.isEmergencyModeEnabled ? "cross.case.fill" : "cross.case",
                        tint: appState.isEmergencyModeEnabled ? Color.white : PrimeTheme.Colors.warning,
                        glassFill: appState.isEmergencyModeEnabled ? PrimeTheme.Colors.warning.opacity(0.88) : PrimeTheme.Colors.glassTint
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                isShowingCreateMenu = true
            } label: {
                HeaderCircleButton(systemName: "plus", tint: PrimeTheme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var activeTransitionChat: Chat? {
        appState.routedChat
    }

    private var shouldShowNearbyLayer: Bool {
        guard showsHomeNearbyPeers, nearbyPeers.isEmpty == false else { return false }
        if nearbyPeersOfflineOnly {
            return appState.selectedMode == .offline
        }
        return appState.selectedMode != .online || (appState.isEmergencyModeAvailable && appState.isEmergencyModeEnabled)
    }

    private var nearbyLayerTaskID: String {
        "\(appState.currentUser.id.uuidString)-\(appState.selectedMode.rawValue)-\(appState.isEmergencyModeEnabled)-\(showsHomeNearbyPeers)-\(nearbyPeersOfflineOnly)"
    }

    private var nearbyVisibilityTaskID: String {
        "\(appState.currentUser.id.uuidString)-nearby-visibility"
    }

    private func requestModeSelection(_ mode: ChatMode, preserveChatsOnTransition: Bool = false) {
        guard appState.availableModes.contains(mode) else { return }
        guard mode != appState.selectedMode else { return }
        guard isTransitioningMode == false else { return }

        if mode == .offline, preserveChatsOnTransition == false {
            continueToOfflineWithoutSaving()
            return
        }

        Task {
            await applyModeSelection(mode, preserveChatsOnTransition: preserveChatsOnTransition)
        }
    }

    @MainActor
    private func continueToOfflineWithoutSaving() {
        appState.updateSelectedMode(.offline)
        modeTransitionError = ""
    }

    @MainActor
    private func applyModeSelection(_ mode: ChatMode, preserveChatsOnTransition: Bool = false) async {
        guard mode != appState.selectedMode else { return }
        guard isTransitioningMode == false else { return }

        if mode == .offline {
            if preserveChatsOnTransition == false {
                continueToOfflineWithoutSaving()
                return
            }

            let request = ChatModeTransitionRequest(
                fromMode: appState.selectedMode,
                toMode: mode,
                currentUser: appState.currentUser,
                activeChat: activeTransitionChat
            )
            appState.updateSelectedMode(.offline)
            modeTransitionError = ""

            Task(priority: .utility) {
                do {
                    _ = try await environment.chatRepository.prepareModeTransition(request)
                } catch {
                    await MainActor.run {
                        modeTransitionError = error.localizedDescription.isEmpty
                            ? "home.mode.transition.failed".localized
                            : error.localizedDescription
                    }
                }
            }
            return
        }

        if mode == .online, NetworkUsagePolicy.isActuallyOffline() {
            appState.updateSelectedMode(.online)
            modeTransitionError = ""
            return
        }

        if isFastModeSwitch(from: appState.selectedMode, to: mode) {
            let request = ChatModeTransitionRequest(
                fromMode: appState.selectedMode,
                toMode: mode,
                currentUser: appState.currentUser,
                activeChat: activeTransitionChat
            )
            appState.updateSelectedMode(mode)
            modeTransitionError = ""

            Task(priority: .utility) {
                do {
                    let transition = try await environment.chatRepository.prepareModeTransition(request)
                    if let routedChat = transition.routedChat {
                        await MainActor.run {
                            appState.routeToChatAfterCurrentTransition(routedChat)
                        }
                    }
                } catch {
                    await MainActor.run {
                        modeTransitionError = ""
                    }
                }
            }
            return
        }

        isTransitioningMode = true
        defer {
            isTransitioningMode = false
        }

        do {
            let transition = try await environment.chatRepository.prepareModeTransition(
                ChatModeTransitionRequest(
                    fromMode: appState.selectedMode,
                    toMode: mode,
                    currentUser: appState.currentUser,
                    activeChat: activeTransitionChat
                )
            )
            appState.updateSelectedMode(mode)
            modeTransitionError = ""

            if mode != .offline, let routedChat = transition.routedChat {
                appState.routeToChatAfterCurrentTransition(routedChat)
            }
        } catch {
            modeTransitionError = error.localizedDescription.isEmpty
                ? "home.mode.transition.failed".localized
                : error.localizedDescription
        }
    }

    @MainActor
    private func openNearestOfflineChat() async {
        guard isOpeningNearbyChat == false else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            isOpeningNearbyChat = true
        }
        defer {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOpeningNearbyChat = false
            }
        }

        await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        await environment.offlineTransport.startScanning()

        let deadline = Date().addingTimeInterval(6)
        var searchResult: NearbySearchResult = .none

        while Date() < deadline {
            let peers = await environment.offlineTransport.discoveredPeers()
            if let peer = peers.first {
                searchResult = .found(peer)
                break
            }
            try? await Task.sleep(for: .milliseconds(260))
        }

        guard case let .found(nearestPeer) = searchResult else {
            isShowingNearbySearchFailureAlert = true
            return
        }

        do {
            try await openNearbyChat(with: nearestPeer)
        } catch {
            return
        }
    }

    @MainActor
    private func openNearbyChat(with peer: OfflinePeer) async throws {
        let chat = try await environment.chatRepository.createNearbyChat(
            with: peer,
            currentUser: appState.currentUser
        )
        appState.routeToChat(chat)
    }

    @MainActor
    private func refreshNearbyLayer() async {
        guard showsHomeNearbyPeers else {
            nearbyPeers = []
            return
        }

        if nearbyPeersOfflineOnly, appState.selectedMode != .offline {
            nearbyPeers = []
            return
        }

        guard appState.selectedMode != .online || appState.isEmergencyModeEnabled else {
            nearbyPeers = []
            return
        }

        await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        await environment.offlineTransport.startScanning()

        while Task.isCancelled == false, appState.selectedMode != .online || appState.isEmergencyModeEnabled {
            nearbyPeers = await environment.offlineTransport.discoveredPeers()
                .filter { $0.id != appState.currentUser.id }
            try? await Task.sleep(for: .seconds(appState.isEmergencyModeEnabled ? 1 : 2))
        }
    }

    @MainActor
    private func loadNearbyVisibilityPreferences() async {
        let preferences = await NearbyPeersVisibilityStore.shared.preferences(ownerUserID: appState.currentUser.id)
        showsHomeNearbyPeers = preferences.showHomeCard
        nearbyPeersOfflineOnly = preferences.offlineOnly
    }

    @MainActor
    private func toggleEmergencyMode() async {
        guard appState.isEmergencyModeAvailable else { return }
        let nextValue = !appState.isEmergencyModeEnabled
        appState.setEmergencyModeEnabled(nextValue)
        if nextValue {
            await syncEmergencyStatusIfPossible()
        }
    }

    @MainActor
    private func setEmergencyStatus(_ status: EmergencyModeStatus) async {
        appState.updateEmergencyModeStatus(status)
        await syncEmergencyStatusIfPossible()
    }

    @MainActor
    private func syncEmergencyStatusIfPossible() async {
        guard NetworkUsagePolicy.hasReachableNetwork() else { return }
        guard appState.currentUser.isGuest == false else { return }
        guard isSyncingEmergencyStatus == false else { return }

        isSyncingEmergencyStatus = true
        defer { isSyncingEmergencyStatus = false }

        do {
            let updatedUser = try await environment.authRepository.updateProfile(
                appState.currentUser.profile,
                for: appState.currentUser.id
            )
            appState.refreshCurrentUserPreservingNavigation(updatedUser)
        } catch {
            // Keep the local emergency state even if the server sync is not available yet.
        }
    }

    private func isFastModeSwitch(from currentMode: ChatMode, to newMode: ChatMode) -> Bool {
        switch (currentMode, newMode) {
        case (.smart, .online), (.online, .smart):
            return true
        default:
            return false
        }
    }
}

private struct NotificationRouteChatDestinationView: View {
    let routedChat: Chat?

    var body: some View {
        if let routedChat {
            ChatView(chat: routedChat)
        } else {
            NotificationRouteLoadingOverlayView()
        }
    }
}

private struct NotificationRouteLoadingOverlayView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Opening chat…")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            PrimeTheme.Colors.background
                .opacity(0.35)
                .ignoresSafeArea()
        )
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

struct ModeSelectorView: View {
    let availableModes: [ChatMode]
    let selectedMode: ChatMode
    var isBusy = false
    let onSelectMode: (ChatMode, Bool) -> Void
    @Namespace private var selectionAnimationNamespace
    @State private var expandingMode: ChatMode?
    @State private var collapsingMode: ChatMode?
    @State private var transitionTask: Task<Void, Never>?
    @State private var lastObservedSelectedMode: ChatMode?
    @State private var longPressTriggeredMode: ChatMode?

    private let offlineSaveHoldDuration: Double = 2.0

    var body: some View {
        GeometryReader { geometry in
            let layout = layoutMetrics(for: geometry.size.width)

            HStack(spacing: layout.spacing) {
                ForEach(availableModes, id: \.self) { mode in
                    modeButton(mode, width: width(for: mode, layout: layout))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.12), value: selectedMode)
        }
        .frame(height: 48)
        .onAppear {
            lastObservedSelectedMode = selectedMode
        }
        .onChange(of: selectedMode) { newValue in
            let oldValue = lastObservedSelectedMode ?? newValue
            lastObservedSelectedMode = newValue
            guard oldValue != newValue else { return }
            animateModeTransition(from: oldValue, to: newValue)
        }
        .onDisappear {
            transitionTask?.cancel()
        }
    }

    private func modeButton(_ mode: ChatMode, width: CGFloat) -> some View {
        Button {
            let consumedByLongPress = longPressTriggeredMode == mode
            longPressTriggeredMode = nil
            guard consumedByLongPress == false else { return }
            onSelectMode(mode, false)
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.glassTint)
                    )
                if mode == selectedMode {
                    Capsule(style: .continuous)
                        .fill(selectedFillColor(for: mode).opacity(0.9))
                        .matchedGeometryEffect(id: "mode-selector-fill", in: selectionAnimationNamespace)
                }
                Capsule(style: .continuous)
                    .stroke(mode == selectedMode ? Color.white.opacity(0.1) : PrimeTheme.Colors.glassStroke, lineWidth: 1)

                HStack(spacing: 6) {
                    if isBusy && mode == selectedMode {
                        ProgressView()
                            .tint(Color.white.opacity(0.92))
                            .scaleEffect(0.82)
                    }

                    Text(mode == selectedMode ? mode.titleKey.localized : collapsedTitle(for: mode))
                        .font(.system(size: mode == selectedMode ? 16 : 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(mode == selectedMode ? Color.white : PrimeTheme.Colors.accent)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: width, height: 48)
            .scaleEffect(buttonScale(for: mode))
            .offset(y: buttonVerticalOffset(for: mode))
            .shadow(color: Color.black.opacity(mode == selectedMode ? 0.12 : 0.06), radius: 12, y: 7)
            .zIndex(zIndex(for: mode))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onLongPressGesture(minimumDuration: offlineSaveHoldDuration, maximumDistance: 18) {
            guard mode == .offline else { return }
            guard isBusy == false else { return }
            longPressTriggeredMode = mode
            onSelectMode(mode, true)
        }
    }

    private func collapsedTitle(for mode: ChatMode) -> String {
        switch mode {
        case .smart:
            return "S"
        case .online:
            return "ON"
        case .offline:
            return "OFF"
        }
    }

    private func layoutMetrics(for availableWidth: CGFloat) -> (expandedWidth: CGFloat, collapsedWidth: CGFloat, spacing: CGFloat) {
        let spacing: CGFloat = 8
        switch availableModes.count {
        case 0, 1:
            return (availableWidth, availableWidth, 0)
        case 2:
            let collapsedWidth = max(48, min(58, floor((availableWidth - spacing) * 0.34)))
            let expandedWidth = max(108, availableWidth - spacing - collapsedWidth)
            return (expandedWidth, collapsedWidth, spacing)
        default:
            let minimumExpandedWidth: CGFloat = 92
            let collapsedWidth = max(40, min(48, floor((availableWidth - spacing * 2 - minimumExpandedWidth) / 2)))
            let expandedWidth = max(minimumExpandedWidth, availableWidth - spacing * 2 - collapsedWidth * 2)
            return (expandedWidth, collapsedWidth, spacing)
        }
    }

    private func width(
        for mode: ChatMode,
        layout: (expandedWidth: CGFloat, collapsedWidth: CGFloat, spacing: CGFloat)
    ) -> CGFloat {
        mode == selectedMode ? layout.expandedWidth : layout.collapsedWidth
    }

    private func selectedFillColor(for mode: ChatMode) -> Color {
        switch mode {
        case .smart:
            return PrimeTheme.Colors.smartAccent
        case .online:
            return PrimeTheme.Colors.accent
        case .offline:
            return PrimeTheme.Colors.offlineAccent
        }
    }

    private func buttonScale(for mode: ChatMode) -> CGFloat {
        if expandingMode == mode {
            return 1.08
        }
        if collapsingMode == mode {
            return 0.92
        }
        return mode == selectedMode ? 1.0 : 0.98
    }

    private func buttonVerticalOffset(for mode: ChatMode) -> CGFloat {
        if expandingMode == mode {
            return -2
        }
        if collapsingMode == mode {
            return 2
        }
        return 0
    }

    private func zIndex(for mode: ChatMode) -> Double {
        if expandingMode == mode {
            return 3
        }
        if mode == selectedMode {
            return 2
        }
        if collapsingMode == mode {
            return 1
        }
        return 0
    }

    private func animateModeTransition(from oldMode: ChatMode, to newMode: ChatMode) {
        transitionTask?.cancel()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.7, blendDuration: 0.08)) {
            collapsingMode = oldMode
            expandingMode = newMode
        }

        transitionTask = Task {
            try? await Task.sleep(for: .milliseconds(230))
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84, blendDuration: 0.12)) {
                    collapsingMode = nil
                    expandingMode = nil
                }
            }
        }
    }
}

private struct HeaderCircleButton: View {
    enum AnimationStyle {
        case standard
        case antenna
    }

    let systemName: String
    var tint: Color = PrimeTheme.Colors.accent
    var glassFill: Color = PrimeTheme.Colors.glassTint
    var isPulsing = false
    var animationStyle: AnimationStyle = .standard
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
            Circle()
                .fill(glassFill)
                .frame(width: size, height: size)
            Circle()
                .stroke(PrimeTheme.Colors.glassStroke, lineWidth: 1)
                .frame(width: size, height: size)
            if animationStyle == .antenna, isPulsing {
                antennaTravelingWave(direction: -1, delay: 0)
                antennaTravelingWave(direction: 1, delay: 0)
                antennaTravelingWave(direction: -1, delay: 0.42)
                antennaTravelingWave(direction: 1, delay: 0.42)
            }
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .scaleEffect(animationStyle == .antenna && isPulsing ? 1.04 : 1)
                .animation(
                    .easeInOut(duration: 0.62).repeatForever(autoreverses: true),
                    value: isPulsing
                )
        }
        .shadow(color: Color.black.opacity(0.1), radius: 14, y: 8)
    }

    private func antennaTravelingWave(direction: CGFloat, delay: Double) -> some View {
        HStack(spacing: 2) {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.26))
                .frame(width: 2.2, height: 8)
            Capsule(style: .continuous)
                .fill(tint.opacity(0.4))
                .frame(width: 2.6, height: 12)
            Capsule(style: .continuous)
                .fill(tint.opacity(0.56))
                .frame(width: 3, height: 16)
        }
        .scaleEffect(x: direction < 0 ? -1 : 1, y: 1, anchor: .center)
        .offset(x: isPulsing ? direction * 17 : direction * 4)
        .opacity(isPulsing ? 0 : 0.94)
        .blur(radius: isPulsing ? 0.3 : 0)
        .animation(
            .easeOut(duration: 1.05)
                .repeatForever(autoreverses: false)
                .delay(delay),
            value: isPulsing
        )
    }
}

private struct NearbyPeerChip: View {
    let peer: OfflinePeer

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(PrimeTheme.Colors.offlineAccent.opacity(0.2))
                    .frame(width: 34, height: 34)
                Text(initials(for: peer.displayName))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.offlineAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(peer.alias.isEmpty ? "Nearby" : "@\(peer.alias)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Image(systemName: peer.signalStrength >= -70 ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrimeTheme.Colors.offlineAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func initials(for value: String) -> String {
        let parts = value
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
        let result = parts.compactMap { $0.first }.map { String($0) }.joined()
        return result.isEmpty ? "N" : result.uppercased()
    }
}

private struct QuickCreateSheet: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var contacts: [ContactAliasStore.StoredContact] = []
    @State private var errorText = ""

    private var isOfflineMode: Bool {
        appState.selectedMode == .offline
    }

    var body: some View {
        List {
            Section {
                Text("quickcreate.subtitle".localized)
                    .font(.footnote)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Section("common.create".localized) {
                NavigationLink {
                    if isOfflineMode {
                        AddContactView()
                    } else {
                        GlobalChatSearchView(mode: appState.selectedMode)
                    }
                } label: {
                    quickActionRow(title: "quickcreate.new_contact.title".localized, subtitle: "quickcreate.new_contact.subtitle".localized, systemName: "person.badge.plus")
                }

                NavigationLink {
                    NewGroupView(initialCommunityKind: .group)
                } label: {
                    quickActionRow(title: "quickcreate.new_group.title".localized, subtitle: "quickcreate.new_group.subtitle".localized, systemName: "person.3.fill")
                }

                if isOfflineMode == false {
                    NavigationLink {
                        NewGroupView(initialCommunityKind: .channel)
                    } label: {
                        quickActionRow(title: "quickcreate.new_channel.title".localized, subtitle: "quickcreate.new_channel.subtitle".localized, systemName: "megaphone.fill")
                    }

                    NavigationLink {
                        NewGroupView(initialCommunityKind: .community)
                    } label: {
                        quickActionRow(title: "quickcreate.new_community.title".localized, subtitle: "quickcreate.new_community.subtitle".localized, systemName: "bubble.left.and.bubble.right.fill")
                    }

                    NavigationLink {
                        NewGroupView(initialCommunityKind: .supergroup)
                    } label: {
                        quickActionRow(title: "quickcreate.new_supergroup.title".localized, subtitle: "quickcreate.new_supergroup.subtitle".localized, systemName: "person.3.sequence.fill")
                    }
                } else {
                    Text("quickcreate.offline_only_groups".localized)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }

            Section("quickcreate.saved_contacts".localized) {
                if contacts.isEmpty {
                    Text("quickcreate.saved_contacts.empty".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                } else {
                    ForEach(contacts) { contact in
                        Button {
                            Task {
                                await openChat(with: contact)
                            }
                        } label: {
                            HStack(spacing: PrimeTheme.Spacing.medium) {
                                Circle()
                                    .fill(PrimeTheme.Colors.accent.opacity(0.9))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Text(String(contact.localDisplayName.prefix(1)).uppercased())
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(Color.white)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(contact.localDisplayName)
                                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                    Text("@\(contact.remoteUsername)")
                                        .font(.caption)
                                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("common.create".localized)
        .task(id: appState.currentUser.id) {
            contacts = await ContactAliasStore.shared.contacts(ownerUserID: appState.currentUser.id)
        }
    }

    @ViewBuilder
    private func quickActionRow(title: String, subtitle: String, systemName: String) -> some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.14))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PrimeTheme.Colors.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
    }

    @MainActor
    private func openChat(with contact: ContactAliasStore.StoredContact) async {
        do {
            let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode
            var chat = try await environment.chatRepository.createDirectChat(
                with: contact.remoteUserID,
                currentUserID: appState.currentUser.id,
                mode: preferredMode
            )
            chat.title = contact.localDisplayName
            chat.subtitle = "@\(contact.remoteUsername)"
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "quickcreate.open_failed".localized : error.localizedDescription
        }
    }
}
