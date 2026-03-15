import SwiftUI

struct AddContactView: View {
    @Environment(\.appEnvironment) private var environment
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var users: [User] = []
    @State private var nearbyPeers: [OfflinePeer] = []
    @State private var createdChat: Chat?
    @State private var errorText = ""

    var body: some View {
        List {
            if appState.selectedMode == .online {
                Section("contact.search.section".localized) {
                    TextField("contact.search.placeholder".localized, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(PrimeTheme.Colors.warning)
                    }

                    if users.isEmpty && errorText.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("contact.search.empty".localized)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    } else {
                        ForEach(users) { user in
                            Button {
                                Task {
                                    await openOnlineChat(with: user)
                                }
                            } label: {
                                HStack(spacing: PrimeTheme.Spacing.medium) {
                                    AvatarBadgeView(profile: user.profile, size: 44)
                                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                        Text(user.profile.displayName)
                                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        Text("@\(user.profile.username)")
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Section("contact.search.section".localized) {
                    Text("contact.search.offline".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            Section("contact.bluetooth.section".localized) {
                if nearbyPeers.isEmpty {
                    Text("contact.bluetooth.empty".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                } else {
                    ForEach(nearbyPeers) { peer in
                        Button {
                            Task {
                                await openNearbyChat(with: peer)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                Text(peer.displayName)
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                Text("\(peer.alias) • RSSI \(peer.signalStrength)")
                                    .font(.caption)
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("contact.add.title".localized)
        .navigationDestination(item: $createdChat) { chat in
            ChatView(chat: chat)
        }
        .task(id: appState.currentUser.id.uuidString) {
            await environment.offlineTransport.updateCurrentUser(appState.currentUser)
        }
        .task(id: refreshTaskID) {
            await environment.offlineTransport.startScanning()
            while !Task.isCancelled {
                nearbyPeers = await environment.offlineTransport.discoveredPeers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: query + appState.selectedMode.rawValue) {
            if appState.selectedMode == .online {
                await searchUsers()
            } else {
                users = []
                errorText = ""
            }
        }
    }

    private var refreshTaskID: String {
        "\(appState.selectedMode.rawValue)-\(appState.currentUser.id.uuidString)"
    }

    @MainActor
    private func searchUsers() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            users = []
            errorText = ""
            return
        }

        do {
            users = try await environment.authRepository.searchUsers(query: trimmed, excluding: appState.currentUser.id)
            errorText = ""
        } catch {
            users = []
            errorText = error.localizedDescription.isEmpty ? "contact.search.failed".localized : error.localizedDescription
        }
    }

    @MainActor
    private func openOnlineChat(with user: User) async {
        do {
            var chat = try await environment.chatRepository.createDirectChat(
                with: user.id,
                currentUserID: appState.currentUser.id,
                mode: appState.selectedMode
            )
            chat.title = user.profile.displayName
            chat.subtitle = "@\(user.profile.username)"
            createdChat = chat
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
        }
    }

    @MainActor
    private func openNearbyChat(with peer: OfflinePeer) async {
        do {
            createdChat = try await environment.chatRepository.createNearbyChat(
                with: peer,
                currentUser: appState.currentUser
            )
            errorText = ""
        } catch {
            errorText = error.localizedDescription.isEmpty ? "contact.chat.failed".localized : error.localizedDescription
        }
    }
}

struct AvatarBadgeView: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        if let url = profile.profilePhotoURL {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            placeholder
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(PrimeTheme.Colors.accent.opacity(0.85))
            .overlay(
                Text(String(profile.displayName.prefix(1)))
                    .font(.headline)
                    .foregroundStyle(Color.white)
            )
    }
}
