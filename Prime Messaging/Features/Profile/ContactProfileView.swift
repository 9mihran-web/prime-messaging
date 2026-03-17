import SwiftUI

struct ContactProfileView: View {
    let user: User

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var internetCallManager = InternetCallManager.shared
    @State private var localContactName = ""
    @State private var isContactAdded = false
    @State private var isSavingContact = false
    @State private var callStatusMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar

                VStack(spacing: 8) {
                    AvatarBadgeView(profile: user.profile, size: 104)
                    Text(displayName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text(statusLine)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                actionRow

                if !callStatusMessage.isEmpty {
                    Text(callStatusMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }

                if user.id != appState.currentUser.id {
                    contactCard
                }

                VStack(spacing: 12) {
                    if visiblePhone != nil {
                        infoCard(title: "Phone Number", value: visiblePhone ?? "Private")
                    }

                    if visibleEmail != nil {
                        infoCard(title: "E-mail", value: visibleEmail ?? "Private")
                    }

                    infoCard(title: "Username", value: "@\(user.profile.username)")
                }

                infoPills
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(PrimeTheme.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: user.id) {
            await loadContactState()
        }
    }

    private var headerBar: some View {
        HStack {
            profileCircleButton(systemName: "chevron.left") {
                dismiss()
            }

            Spacer()

            Button {
            } label: {
                Text("More")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(PrimeTheme.Colors.elevated)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            profileActionButton(title: "Call", systemName: "phone.fill", action: startCall)
            profileActionButton(title: "Sound", systemName: "bell.fill")
            profileActionButton(title: "Search", systemName: "magnifyingglass")
            profileActionButton(title: "More", systemName: "ellipsis")
        }
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("contact.profile.add".localized)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)

            TextField("contact.profile.alias.placeholder".localized, text: $localContactName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(PrimeTheme.Colors.background)
                )

            Button {
                Task {
                    await saveContact()
                }
            } label: {
                HStack {
                    if isSavingContact {
                        ProgressView()
                            .tint(Color.white)
                    }
                    Text(isContactAdded ? "contact.profile.added".localized : "contact.profile.add".localized)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(isContactAdded ? PrimeTheme.Colors.textSecondary.opacity(0.55) : PrimeTheme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingContact || isContactAdded || trimmedLocalContactName.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    private var infoPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Media", "Files", "Music", "Voices", "Links"], id: \.self) { item in
                    Text(item)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(PrimeTheme.Colors.elevated)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var displayName: String {
        let trimmed = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.profile.username : trimmed
    }

    private var statusLine: String {
        let status = user.profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Last seen recently" : status
    }

    private var visiblePhone: String? {
        user.privacySettings.showPhoneNumber ? user.profile.phoneNumber : nil
    }

    private var visibleEmail: String? {
        user.privacySettings.showEmail ? user.profile.email : nil
    }

    private var trimmedLocalContactName: String {
        localContactName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCallUser: Bool {
        guard user.id != appState.currentUser.id else { return false }
        return isContactAdded || user.privacySettings.allowCallsFromNonContacts
    }

    @MainActor
    private func loadContactState() async {
        let existingAlias = await ContactAliasStore.shared.alias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            username: user.profile.username
        )
        if let existingAlias, existingAlias.isEmpty == false {
            localContactName = existingAlias
            isContactAdded = true
            return
        }

        localContactName = displayName
        isContactAdded = false
    }

    @MainActor
    private func saveContact() async {
        let trimmedName = trimmedLocalContactName
        guard trimmedName.isEmpty == false else { return }

        isSavingContact = true
        defer { isSavingContact = false }

        await ContactAliasStore.shared.saveAlias(
            ownerUserID: appState.currentUser.id,
            remoteUserID: user.id,
            remoteUsername: user.profile.username,
            localDisplayName: trimmedName
        )
        isContactAdded = true
        callStatusMessage = ""
    }

    private func startCall() {
        guard canCallUser else {
            callStatusMessage = "calls.unavailable.privacy".localized
            return
        }

        callStatusMessage = ""
        Task {
            do {
                try await internetCallManager.startOutgoingCall(to: user)
            } catch {
                callStatusMessage = (error as? LocalizedError)?.errorDescription ?? "calls.unavailable.start".localized
            }
        }
    }

    @ViewBuilder
    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textSecondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(PrimeTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PrimeTheme.Colors.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func profileActionButton(title: String, systemName: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(PrimeTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PrimeTheme.Colors.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PrimeTheme.Colors.separator.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func profileCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(PrimeTheme.Colors.elevated)
                    .frame(width: 42, height: 42)
                Circle()
                    .stroke(PrimeTheme.Colors.separator.opacity(0.35), lineWidth: 1)
                    .frame(width: 42, height: 42)
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }
}
