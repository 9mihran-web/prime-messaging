import SwiftUI

struct RootView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notificationRouteStore = NotificationRouteStore.shared
    @ObservedObject private var internetCallManager = InternetCallManager.shared

    var body: some View {
        SwiftUI.Group {
            if appState.isBootstrappingSession {
                ProgressView()
            } else if appState.hasCompletedOnboarding {
                MainTabView()
            } else {
                NavigationStack {
                    OnboardingView()
                }
            }
        }
        .tint(PrimeTheme.Colors.accent)
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .task {
            await bootstrapPersistedSessionIfNeeded()
            consumePendingNotificationRouteIfNeeded()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingOpenChat)) { notification in
            guard let userInfo = notification.userInfo, let route = NotificationChatRoute(userInfo: userInfo) else {
                return
            }
            appState.queueNotificationRoute(route)
        }
        .onChange(of: notificationRouteStore.pendingRoute) { _, newValue in
            guard let newValue else { return }
            appState.queueNotificationRoute(newValue)
            _ = notificationRouteStore.consume()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primeMessagingDidRegisterDeviceToken)) { notification in
            guard let token = notification.object as? Data else { return }
            Task {
                await environment.pushNotificationService.syncDeviceToken(token)
            }
        }
        .task(id: rootTaskID) {
            guard appState.isBootstrappingSession == false else { return }
            if appState.hasCompletedOnboarding {
                let isValidSession = await validateCurrentServerSessionIfNeeded()
                guard isValidSession, appState.hasCompletedOnboarding else { return }

                await environment.pushNotificationService.registerForRemoteNotifications()
                await environment.pushNotificationService.startMonitoring(
                    currentUser: appState.currentUser,
                    chatRepository: environment.chatRepository
                )
                await environment.offlineTransport.updateCurrentUser(appState.currentUser)
                await environment.offlineTransport.startScanning()
            } else {
                await environment.pushNotificationService.stopMonitoring()
                await environment.offlineTransport.stopScanning()
            }
        }
        .task(id: appState.selectedChat?.id.uuidString ?? "no-active-chat") {
            await environment.pushNotificationService.updateActiveChat(appState.selectedChat)
        }
        .fullScreenCover(item: Binding(
            get: { internetCallManager.activeCall },
            set: { newValue in
                if newValue == nil {
                    internetCallManager.endCall()
                }
            }
        )) { call in
            InternetCallView(call: call)
        }
    }

    private var rootTaskID: String {
        "\(appState.isBootstrappingSession)-\(appState.hasCompletedOnboarding)-\(appState.currentUser.id.uuidString)-\(appState.currentUser.profile.username)"
    }

    @MainActor
    private func consumePendingNotificationRouteIfNeeded() {
        guard let route = notificationRouteStore.consume() else { return }
        appState.queueNotificationRoute(route)
    }

    @MainActor
    private func bootstrapPersistedSessionIfNeeded() async {
        defer {
            appState.finishSessionBootstrap()
        }

        guard BackendConfiguration.currentBaseURL != nil else { return }

        let storedSessions = await AuthSessionStore.shared.allSessions()

        if appState.hasCompletedOnboarding {
            guard storedSessions.contains(where: { $0.userID == appState.currentUser.id }) else {
                if let restoredUser = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id) {
                    appState.markCurrentServerSessionValidated(with: restoredUser)
                    return
                }
                appState.applyAuthenticatedUser(appState.currentUser, requiresServerSessionValidation: false)
                return
            }

            do {
                let user = try await environment.authRepository.refreshUser(userID: appState.currentUser.id)
                appState.markCurrentServerSessionValidated(with: user)
            } catch AuthRepositoryError.invalidCredentials, AuthRepositoryError.accountNotFound {
                if storedSessions.contains(where: { $0.userID == appState.currentUser.id }) {
                    await BackendRequestTransport.removeSession(for: appState.currentUser.id)
                }
                appState.logOutCurrentAccount()
            } catch { }
            return
        }

        for session in storedSessions {
            do {
                let user = try await environment.authRepository.refreshUser(userID: session.userID)
                appState.markCurrentServerSessionValidated(with: user)
                return
            } catch AuthRepositoryError.invalidCredentials, AuthRepositoryError.accountNotFound {
                await BackendRequestTransport.removeSession(for: session.userID)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func validateCurrentServerSessionIfNeeded() async -> Bool {
        guard appState.hasCompletedOnboarding else { return false }
        guard appState.requiresServerSessionValidation else { return true }
        guard BackendConfiguration.currentBaseURL != nil else { return true }

        let storedSessions = await AuthSessionStore.shared.allSessions()
        guard storedSessions.contains(where: { $0.userID == appState.currentUser.id }) else {
            if let restoredUser = await restoreSessionSilentlyIfPossible(for: appState.currentUser.id) {
                appState.markCurrentServerSessionValidated(with: restoredUser)
                return true
            }
            appState.applyAuthenticatedUser(appState.currentUser, requiresServerSessionValidation: false)
            return true
        }

        do {
            let refreshedUser = try await environment.authRepository.refreshUser(userID: appState.currentUser.id)
            appState.markCurrentServerSessionValidated(with: refreshedUser)
            return true
        } catch AuthRepositoryError.accountNotFound {
            await BackendRequestTransport.removeSession(for: appState.currentUser.id)
            appState.logOutCurrentAccount()
            return false
        } catch AuthRepositoryError.invalidCredentials {
            await BackendRequestTransport.removeSession(for: appState.currentUser.id)
            appState.logOutCurrentAccount()
            return false
        } catch {
            return true
        }
    }

    @MainActor
    private func restoreSessionSilentlyIfPossible(for userID: UUID) async -> User? {
        guard let credentials = await LocalAccountStore.shared.credentials(for: userID) else {
            return nil
        }

        do {
            return try await environment.authRepository.logIn(
                identifier: credentials.identifier,
                password: credentials.password
            )
        } catch {
            return nil
        }
    }
}
