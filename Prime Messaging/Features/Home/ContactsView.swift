import SwiftUI
#if canImport(Contacts)
import Contacts
#endif
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(UIKit)
import UIKit
#endif

struct ContactsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var legacyContacts: [ContactAliasStore.StoredContact] = []
    @State private var errorText = ""
    @State private var isLoadingContacts = false
    @State private var isMatchingPrimeContacts = false
    @State private var lastLoadedUserID: UUID?

    #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
    private static let maxRenderedContactsPerSection = 250
    private static let maxScannedDeviceContacts = 3000
    private static let maxEmailsPerContact = 2
    private static let maxPhonesPerContact = 2
    private static let inviteLandingURL = "https://primemsg.site/download"

    @State private var contactsAccessState: DeviceContactsAccessState = Self.initialContactsAccessState()
    @State private var isRequestingContactsAccess = false
    @State private var didAttemptContactsSync = false
    @State private var primeContacts: [PrimeContactEntry] = []
    @State private var inviteContacts: [DeviceContactEntry] = []
    @State private var contactsMatchTask: Task<Void, Never>?
    @State private var invitePayload: InvitePayload?
    #endif

    var body: some View {
        List {
            Section {
                TextField("contacts.search".localized, text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }

            contactsSections
        }
        .navigationTitle("tab.contacts".localized)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if appState.selectedMode == .offline {
                        AddContactView()
                    } else {
                        GlobalChatSearchView(mode: appState.selectedMode)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear {
            Task {
                await loadContactsIfNeeded()
            }
        }
        .onChange(of: appState.currentUser.id) { _ in
            Task {
                await loadContactsIfNeeded(force: true)
            }
        }
        .onDisappear {
            #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
            contactsMatchTask?.cancel()
            contactsMatchTask = nil
            isMatchingPrimeContacts = false
            #endif
        }
        #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
        .sheet(item: $invitePayload) { payload in
            InviteMessageComposerSheet(payload: payload)
        }
        #endif
    }

    @ViewBuilder
    private var contactsSections: some View {
        #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
        if isLoadingContacts {
            Section {
                HStack(spacing: PrimeTheme.Spacing.small) {
                    ProgressView()
                    Text("contacts.syncing".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }
        }

        switch contactsAccessState {
        case .unknown:
            Section {
                Text("contacts.access.prompt".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                Button("contacts.access.allow".localized) {
                    Task {
                        await requestContactsPermissionAndLoad()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PrimeTheme.Colors.accent)
                .disabled(isRequestingContactsAccess)
            }
        case .denied, .restricted:
            Section {
                Text("contacts.access.disabled".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                Button("common.open_settings".localized) {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)
            }
        case .granted:
            if isLoadingContacts && primeContacts.isEmpty && inviteContacts.isEmpty {
                Section {
                    HStack(spacing: PrimeTheme.Spacing.small) {
                        ProgressView()
                        Text("contacts.syncing".localized)
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }
            } else if filteredPrimeContacts.isEmpty, filteredInviteContacts.isEmpty, didAttemptContactsSync {
                Section {
                    Text("contacts.empty".localized)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                if filteredPrimeContacts.isEmpty == false {
                    Section("contacts.on_prime".localized) {
                        ForEach(displayedPrimeContacts) { contact in
                            Button {
                                Task {
                                    await openChat(with: contact)
                                }
                            } label: {
                                primeContactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                        if hasHiddenPrimeContacts {
                            Text(String(format: "contacts.showing_first".localized, Self.maxRenderedContactsPerSection))
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                }

                if filteredInviteContacts.isEmpty == false {
                    Section("contacts.invite_to_prime".localized) {
                        ForEach(displayedInviteContacts) { contact in
                            inviteContactRow(contact)
                        }
                        if hasHiddenInviteContacts {
                            Text(String(format: "contacts.showing_first".localized, Self.maxRenderedContactsPerSection))
                                .font(.caption)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                }

                if isMatchingPrimeContacts {
                    Section {
                        HStack(spacing: PrimeTheme.Spacing.small) {
                            ProgressView()
                            Text("contacts.updating_matches".localized)
                                .foregroundStyle(PrimeTheme.Colors.textSecondary)
                        }
                    }
                }
            }
        case .unavailable:
            Section {
                Text("contacts.unavailable".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        }
        #else
        if filteredLegacyContacts.isEmpty {
            Section {
                Text("contacts.saved_empty".localized)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }
        } else {
            Section {
                ForEach(filteredLegacyContacts) { contact in
                    Button {
                        Task {
                            await openChat(with: contact)
                        }
                    } label: {
                        HStack(spacing: PrimeTheme.Spacing.medium) {
                            Circle()
                                .fill(PrimeTheme.Colors.accent.opacity(0.9))
                                .frame(width: 46, height: 46)
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
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        #endif
    }

    private var filteredLegacyContacts: [ContactAliasStore.StoredContact] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return legacyContacts }

        return legacyContacts.filter { contact in
            contact.localDisplayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.remoteUsername.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
    private var filteredPrimeContacts: [PrimeContactEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return primeContacts }

        return primeContacts.filter { contact in
            contact.deviceContact.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.user.profile.username.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.user.profile.displayName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredInviteContacts: [DeviceContactEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return inviteContacts }

        return inviteContacts.filter { contact in
            contact.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.emails.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) })
                || contact.phones.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) })
        }
    }

    private var displayedPrimeContacts: [PrimeContactEntry] {
        Array(filteredPrimeContacts.prefix(Self.maxRenderedContactsPerSection))
    }

    private var displayedInviteContacts: [DeviceContactEntry] {
        Array(filteredInviteContacts.prefix(Self.maxRenderedContactsPerSection))
    }

    private var hasHiddenPrimeContacts: Bool {
        filteredPrimeContacts.count > Self.maxRenderedContactsPerSection
    }

    private var hasHiddenInviteContacts: Bool {
        filteredInviteContacts.count > Self.maxRenderedContactsPerSection
    }
    #endif

    @MainActor
    private func loadContacts() async {
        #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
        await loadDeviceContacts()
        #else
        legacyContacts = await ContactAliasStore.shared.contacts(ownerUserID: appState.currentUser.id)
        #endif
    }

    @MainActor
    private func loadContactsIfNeeded(force: Bool = false) async {
        let currentUserID = appState.currentUser.id
        guard force || lastLoadedUserID != currentUserID else { return }
        lastLoadedUserID = currentUserID
        await loadContacts()
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
            errorText = error.localizedDescription.isEmpty ? "Could not open this contact." : error.localizedDescription
        }
    }

    #if canImport(Contacts) && !os(tvOS) && !os(watchOS)
    @MainActor
    private func loadDeviceContacts() async {
        contactsMatchTask?.cancel()
        contactsMatchTask = nil
        isMatchingPrimeContacts = false

        let status = CNContactStore.authorizationStatus(for: .contacts)
        if isContactsStatusGranted(status) {
            contactsAccessState = .granted
        } else {
            switch status {
            case .authorized, .limited:
                contactsAccessState = .granted
            case .notDetermined:
                contactsAccessState = .unknown
            case .denied:
                contactsAccessState = .denied
            case .restricted:
                contactsAccessState = .restricted
            @unknown default:
                contactsAccessState = .unavailable
            }
        }

        guard contactsAccessState == .granted else {
            didAttemptContactsSync = true
            primeContacts = []
            inviteContacts = []
            return
        }

        guard isLoadingContacts == false else { return }
        isLoadingContacts = true
        defer {
            isLoadingContacts = false
        }

        do {
            let startedAt = Date()
            let deviceContacts = try await fetchDeviceContactsAsync()
            debugContactsLog("Fetched \(deviceContacts.count) device contacts in \(Date().timeIntervalSince(startedAt))s")

            let candidateStartedAt = Date()
            let candidates = await Task.detached(priority: .utility) {
                ContactsView.buildMatchCandidates(from: deviceContacts)
            }.value
            debugContactsLog("Prepared \(candidates.count) match candidates in \(Date().timeIntervalSince(candidateStartedAt))s")

            // Show device contacts immediately so Contacts screen stays responsive
            // even if backend matching is slow/unavailable.
            primeContacts = []
            inviteContacts = deviceContacts.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            didAttemptContactsSync = true
            debugContactsLog("Contacts sync completed in \(Date().timeIntervalSince(startedAt))s")
            errorText = ""

            guard candidates.isEmpty == false else { return }

            let currentUserID = appState.currentUser.id
            isMatchingPrimeContacts = true
            contactsMatchTask = Task {
                let matchStartedAt = Date()
                do {
                    let matched = try await matchPrimeContactsWithTimeout(
                        candidates: candidates,
                        currentUserID: currentUserID,
                        timeoutSeconds: 12
                    )
                    if Task.isCancelled { return }
                    debugContactsLog("Matched \(matched.count) contacts on backend in \(Date().timeIntervalSince(matchStartedAt))s")
                    await MainActor.run {
                        applyMatchedContacts(matched, against: deviceContacts)
                        isMatchingPrimeContacts = false
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        isMatchingPrimeContacts = false
                        debugContactsLog("Prime match failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            didAttemptContactsSync = true
            primeContacts = []
            inviteContacts = []
            errorText = error.localizedDescription.isEmpty ? "Could not sync contacts right now." : error.localizedDescription
        }
    }

    @MainActor
    private func requestContactsPermissionAndLoad() async {
        guard isRequestingContactsAccess == false else { return }

        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if isContactsStatusGranted(status) {
            await loadDeviceContacts()
            return
        }
        if status == .denied || status == .restricted {
            contactsAccessState = status == .denied ? .denied : .restricted
            return
        }

        isRequestingContactsAccess = true
        isLoadingContacts = true
        let granted = await requestContactsAccess(store: store)
        isLoadingContacts = false
        isRequestingContactsAccess = false

        contactsAccessState = granted ? .granted : .denied
        if granted {
            await loadDeviceContacts()
        } else {
            primeContacts = []
            inviteContacts = []
        }
    }

    private func requestContactsAccess(store: CNContactStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func fetchDeviceContactsAsync() async throws -> [DeviceContactEntry] {
        try await Task.detached(priority: .userInitiated) {
            try ContactsView.fetchDeviceContactsFromSystem()
        }.value
    }

    nonisolated private static func fetchDeviceContactsFromSystem() throws -> [DeviceContactEntry] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true

        var result: [DeviceContactEntry] = []
        var seenContactIDs: Set<String> = []
        try store.enumerateContacts(with: request) { contact, stop in
            if result.count >= Self.maxScannedDeviceContacts {
                stop.pointee = true
                return
            }

            guard seenContactIDs.insert(contact.identifier).inserted else { return }

            let displayName = formattedDisplayName(from: contact)
            let emails = contact.emailAddresses
                .map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.isEmpty == false }
                .prefix(Self.maxEmailsPerContact)
                .map { $0 }
            let phones = contact.phoneNumbers
                .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .prefix(Self.maxPhonesPerContact)
                .map { $0 }

            result.append(
                DeviceContactEntry(
                    id: contact.identifier,
                    displayName: displayName,
                    emails: emails,
                    phones: phones
                )
            )
        }
        return result
    }

    nonisolated private static func buildMatchCandidates(from deviceContacts: [DeviceContactEntry]) -> [DeviceContactCandidate] {
        var candidates: [DeviceContactCandidate] = []
        candidates.reserveCapacity(min(deviceContacts.count, 1200))

        for contact in deviceContacts {
            let uniqueEmails = Array(Set(contact.emails)).sorted()
            let uniquePhones = Array(Set(contact.phones)).sorted()
            guard uniqueEmails.isEmpty == false || uniquePhones.isEmpty == false else { continue }

            candidates.append(
                DeviceContactCandidate(
                    localContactID: contact.id,
                    displayName: contact.displayName,
                    emails: uniqueEmails,
                    phones: uniquePhones
                )
            )
            if candidates.count >= 1200 {
                break
            }
        }

        return candidates
    }

    @MainActor
    private func applyMatchedContacts(_ matched: [MatchedDeviceContact], against deviceContacts: [DeviceContactEntry]) {
        var matchedByContactID: [String: MatchedDeviceContact] = [:]
        for match in matched where matchedByContactID[match.localContactID] == nil {
            matchedByContactID[match.localContactID] = match
        }

        var prime: [PrimeContactEntry] = []
        var invite: [DeviceContactEntry] = []
        for contact in deviceContacts {
            if let matchedContact = matchedByContactID[contact.id] {
                prime.append(
                    PrimeContactEntry(
                        deviceContact: contact,
                        user: matchedContact.user,
                        matchedBy: matchedContact.matchedBy
                    )
                )
            } else {
                invite.append(contact)
            }
        }

        primeContacts = prime.sorted {
            $0.deviceContact.displayName.localizedCaseInsensitiveCompare($1.deviceContact.displayName) == .orderedAscending
        }
        inviteContacts = invite.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func matchPrimeContactsWithTimeout(
        candidates: [DeviceContactCandidate],
        currentUserID: UUID,
        timeoutSeconds: UInt64
    ) async throws -> [MatchedDeviceContact] {
        try await withThrowingTaskGroup(of: [MatchedDeviceContact].self) { group in
            group.addTask {
                try await environment.authRepository.matchDeviceContacts(
                    candidates,
                    currentUserID: currentUserID
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw CancellationError()
            }

            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private func debugContactsLog(_ message: String) {
        #if DEBUG
        print("[ContactsView] \(message)")
        #endif
    }

    private func isContactsStatusGranted(_ status: CNAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }
        if #available(iOS 18.0, *), status == .limited {
            return true
        }
        return false
    }

    private static func initialContactsAccessState() -> DeviceContactsAccessState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }

    nonisolated private static func formattedDisplayName(from contact: CNContact) -> String {
        let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let middle = contact.middleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let manualName = [given, middle, family]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if manualName.isEmpty == false {
            return manualName
        }

        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty == false {
            return nickname
        }

        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if organization.isEmpty == false {
            return organization
        }

        return "Unknown Contact"
    }

    @ViewBuilder
    private func primeContactRow(_ contact: PrimeContactEntry) -> some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.9))
                .frame(width: 46, height: 46)
                .overlay(
                    Text(String(contact.deviceContact.displayName.prefix(1)).uppercased())
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.deviceContact.displayName)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                Text("@\(contact.user.profile.username)")
                    .font(.caption)
                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
            }

            Spacer()

            Text("On Prime")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimeTheme.Colors.accent)
        }
    }

    @ViewBuilder
    private func inviteContactRow(_ contact: DeviceContactEntry) -> some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(PrimeTheme.Colors.elevated)
                .frame(width: 46, height: 46)
                .overlay(
                    Text(String(contact.displayName.prefix(1)).uppercased())
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                if let contactHint = contact.primaryHint {
                    Text(contactHint)
                        .font(.caption)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            }

            Spacer()

            Button("Invite To Prime") {
                invitePayload = InvitePayload(
                    recipients: preferredInviteRecipients(for: contact),
                    messageBody: inviteMessageBody()
                )
            }
            .buttonStyle(.bordered)
            .tint(PrimeTheme.Colors.accent)
        }
    }

    @MainActor
    private func openChat(with contact: PrimeContactEntry) async {
        do {
            let preferredMode: ChatMode = appState.selectedMode == .offline ? .smart : appState.selectedMode
            var chat = try await environment.chatRepository.createDirectChat(
                with: contact.user.id,
                currentUserID: appState.currentUser.id,
                mode: preferredMode
            )
            await ContactAliasStore.shared.saveAlias(
                ownerUserID: appState.currentUser.id,
                remoteUserID: contact.user.id,
                remoteUsername: contact.user.profile.username,
                localDisplayName: contact.deviceContact.displayName
            )
            chat.title = contact.deviceContact.displayName
            chat.subtitle = "@\(contact.user.profile.username)"
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this contact." : error.localizedDescription
        }
    }

    private func preferredInviteRecipients(for contact: DeviceContactEntry) -> [String] {
        if let firstPhone = contact.phones.first, firstPhone.isEmpty == false {
            return [firstPhone]
        }
        if let firstEmail = contact.emails.first, firstEmail.isEmpty == false {
            return [firstEmail]
        }
        return []
    }

    private func inviteMessageBody() -> String {
        "Let's connect on Prime Messaging — fast, simple, and secure messaging and calling for free. Cross-platform on Apple, online and offline in one messenger. This invite expires soon.\n\(Self.inviteLandingURL)"
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
    #endif
}

#if canImport(Contacts) && !os(tvOS) && !os(watchOS)
private enum DeviceContactsAccessState {
    case unknown
    case denied
    case restricted
    case granted
    case unavailable
}

private struct DeviceContactEntry: Identifiable, Sendable {
    let id: String
    let displayName: String
    let emails: [String]
    let phones: [String]

    var primaryHint: String? {
        if let firstEmail = emails.first, firstEmail.isEmpty == false {
            return firstEmail
        }
        if let firstPhone = phones.first, firstPhone.isEmpty == false {
            return firstPhone
        }
        return nil
    }
}

private struct PrimeContactEntry: Identifiable, Sendable {
    let deviceContact: DeviceContactEntry
    let user: User
    let matchedBy: String

    var id: String {
        "\(deviceContact.id)-\(user.id.uuidString)"
    }
}

private struct InvitePayload: Identifiable {
    let id = UUID()
    let recipients: [String]
    let messageBody: String
}

#if canImport(UIKit) && canImport(MessageUI)
private struct InviteMessageComposerSheet: UIViewControllerRepresentable {
    let payload: InvitePayload

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard MFMessageComposeViewController.canSendText() else {
            let fallbackItems: [Any] = [payload.messageBody]
            return UIActivityViewController(activityItems: fallbackItems, applicationActivities: nil)
        }

        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = payload.recipients
        controller.body = payload.messageBody
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
        }
    }
}
#elseif canImport(UIKit)
private struct InviteMessageComposerSheet: UIViewControllerRepresentable {
    let payload: InvitePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [payload.messageBody], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
#endif
#endif

struct GlobalChatSearchView: View {
    let mode: ChatMode

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var chats: [Chat] = []
    @State private var contacts: [ContactAliasStore.StoredContact] = []
    @State private var users: [User] = []
    @State private var discoverableChats: [Chat] = []
    @State private var nearbyPeers: [OfflinePeer] = []
    @State private var errorText = ""
    @State private var recentSearches: [String] = []
    @State private var isSearchingRemotely = false
    @State private var pendingJoinRequestChat: Chat?
    @State private var joinRequestAnswers: [String] = []
    @State private var isSubmittingJoinRequest = false

    var body: some View {
        List {
            Section {
                TextField("People, chats, channels, communities", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task {
                            await persistQueryIfNeeded()
                        }
                    }
            }

            if isSearchingRemotely {
                Section {
                    HStack(spacing: PrimeTheme.Spacing.small) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                    }
                }
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(PrimeTheme.Colors.warning)
                }
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               recentSearches.isEmpty == false {
                Section("Recent searches") {
                    ForEach(recentSearches, id: \.self) { recentQuery in
                        Button {
                            query = recentQuery
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                Text(recentQuery)
                                    .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if contacts.isEmpty == false {
                    Section("Saved contacts") {
                        ForEach(contacts.prefix(6)) { contact in
                            Button {
                                Task {
                                    await openChat(with: contact)
                                }
                            } label: {
                                savedContactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if chats.isEmpty == false {
                    Section("Recent chats") {
                        ForEach(chats.prefix(8)) { chat in
                            Button {
                                dismiss()
                                appState.routeToChatAfterCurrentTransition(chat)
                            } label: {
                                ChatRowView(chat: chat, currentUserID: appState.currentUser.id, visibleMode: chat.mode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if hasVisibleResults == false {
                Section {
                    Text(mode == .offline ? "No nearby peers or local chats matched that search." : "No people, chats, or public spaces matched that search.")
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
            } else {
                if filteredChats.isEmpty == false {
                    Section("Chats") {
                        ForEach(filteredChats) { chat in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                }
                                dismiss()
                                appState.routeToChatAfterCurrentTransition(chat)
                            } label: {
                                ChatRowView(chat: chat, currentUserID: appState.currentUser.id, visibleMode: chat.mode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredContacts.isEmpty == false {
                    Section("Saved contacts") {
                        ForEach(filteredContacts) { contact in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openChat(with: contact)
                                }
                            } label: {
                                savedContactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if users.isEmpty == false {
                    Section("People") {
                        ForEach(users) { user in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
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
                            .buttonStyle(.plain)
                        }
                    }
                }

                if discoverableChats.isEmpty == false {
                    Section("Channels & Communities") {
                        ForEach(discoverableChats) { chat in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openDiscoverableChat(chat)
                                }
                            } label: {
                                HStack(spacing: PrimeTheme.Spacing.medium) {
                                    Circle()
                                        .fill(PrimeTheme.Colors.accent.opacity(0.14))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: chat.communityDetails?.symbolName ?? "megaphone.fill")
                                                .foregroundStyle(PrimeTheme.Colors.accent)
                                        )

                                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                        HStack(spacing: 6) {
                                            Text(chat.displayTitle(for: appState.currentUser.id))
                                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                            if chat.communityDetails?.isOfficial == true {
                                                Image(systemName: "checkmark.seal.fill")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(PrimeTheme.Colors.accent)
                                            }
                                        }
                                        Text(chat.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }

                                    Spacer()

                                    Text(discoverableChatActionTitle(chat))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredNearbyPeers.isEmpty == false {
                    Section("Nearby") {
                        ForEach(filteredNearbyPeers) { peer in
                            Button {
                                Task {
                                    await persistQueryIfNeeded()
                                    await openNearbyChat(with: peer)
                                }
                            } label: {
                                HStack(spacing: PrimeTheme.Spacing.medium) {
                                    Circle()
                                        .fill(PrimeTheme.Colors.offlineAccent.opacity(0.14))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                                .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                        )

                                    VStack(alignment: .leading, spacing: PrimeTheme.Spacing.xSmall) {
                                        Text(peer.displayName)
                                            .foregroundStyle(PrimeTheme.Colors.textPrimary)
                                        Text(peer.alias.isEmpty ? "Nearby peer" : "@\(peer.alias)")
                                            .font(.caption)
                                            .foregroundStyle(PrimeTheme.Colors.textSecondary)
                                    }

                                    Spacer()

                                    Text("Open")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PrimeTheme.Colors.offlineAccent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Discover")
        .task(id: "\(mode.rawValue)-\(appState.currentUser.id.uuidString)") {
            await loadDiscoveryContext()
        }
        .task(id: searchTaskID) {
            await refreshSearchResults()
        }
        .sheet(item: $pendingJoinRequestChat) { chat in
            NavigationStack {
                joinRequestSheet(for: chat)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var searchTaskID: String {
        "\(mode.rawValue)-\(appState.currentUser.id.uuidString)-\(query)"
    }

    private var filteredChats: [Chat] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return chats.filter { chat in
            chat.displayTitle(for: appState.currentUser.id).localizedCaseInsensitiveContains(trimmedQuery)
                || chat.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
                || (chat.lastMessagePreview?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    private var filteredContacts: [ContactAliasStore.StoredContact] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return contacts.filter { contact in
            contact.localDisplayName.localizedCaseInsensitiveContains(trimmedQuery)
                || contact.remoteUsername.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredNearbyPeers: [OfflinePeer] {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return [] }

        return nearbyPeers.filter { peer in
            peer.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || peer.alias.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var hasVisibleResults: Bool {
        filteredChats.isEmpty == false
            || filteredContacts.isEmpty == false
            || users.isEmpty == false
            || discoverableChats.isEmpty == false
            || filteredNearbyPeers.isEmpty == false
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func savedContactRow(_ contact: ContactAliasStore.StoredContact) -> some View {
        HStack(spacing: PrimeTheme.Spacing.medium) {
            Circle()
                .fill(PrimeTheme.Colors.accent.opacity(0.9))
                .frame(width: 46, height: 46)
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
        }
    }

    @MainActor
    private func loadDiscoveryContext() async {
        recentSearches = await ChatNavigationStateStore.shared.recentGlobalSearches(ownerUserID: appState.currentUser.id)
        contacts = await ContactAliasStore.shared.contacts(ownerUserID: appState.currentUser.id)
        nearbyPeers = await environment.offlineTransport.discoveredPeers()
        await loadChats()
    }

    @MainActor
    private func refreshSearchResults() async {
        let trimmedQuery = normalizedQuery
        isSearchingRemotely = false

        if mode == .offline {
            users = []
            discoverableChats = []
            nearbyPeers = await environment.offlineTransport.discoveredPeers()
            errorText = ""
            return
        }

        guard trimmedQuery.isEmpty == false else {
            users = []
            discoverableChats = []
            errorText = ""
            return
        }

        isSearchingRemotely = true
        defer { isSearchingRemotely = false }
        do {
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }

            async let foundUsers = environment.authRepository.searchUsers(query: trimmedQuery, excluding: appState.currentUser.id)
            async let foundDiscoverableChats = environment.chatRepository.searchDiscoverableChats(
                query: trimmedQuery,
                mode: mode == .smart ? .smart : .online,
                currentUserID: appState.currentUser.id
            )

            let fetchedUsers = try await foundUsers
            let fetchedDiscoverableChats = try await foundDiscoverableChats
            guard Task.isCancelled == false, trimmedQuery == normalizedQuery else { return }

            users = fetchedUsers
            discoverableChats = fetchedDiscoverableChats
            errorText = ""
        } catch {
            guard Task.isCancelled == false else { return }
            users = []
            discoverableChats = []
            errorText = error.localizedDescription.isEmpty ? "Could not search right now." : error.localizedDescription
        }
    }

    @MainActor
    private func loadChats() async {
        let cachedChats = await environment.chatRepository.cachedChats(mode: mode, for: appState.currentUser.id)
        if cachedChats.isEmpty == false {
            chats = await cachedChats.asyncMap { chat in
                await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            }
        }

        do {
            let fetchedChats = try await environment.chatRepository.fetchChats(mode: mode, for: appState.currentUser.id)
            chats = await fetchedChats.asyncMap { chat in
                await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            }
            if normalizedQuery.isEmpty {
                errorText = ""
            }
        } catch {
            if chats.isEmpty {
                errorText = error.localizedDescription.isEmpty ? "Could not load chats." : error.localizedDescription
            }
        }
    }

    @MainActor
    private func openChat(with contact: ContactAliasStore.StoredContact) async {
        do {
            let preferredMode: ChatMode = mode == .offline ? .smart : mode
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
            errorText = error.localizedDescription.isEmpty ? "Could not open this contact." : error.localizedDescription
        }
    }

    @MainActor
    private func openOnlineChat(with user: User) async {
        do {
            var chat = try await environment.chatRepository.createDirectChat(
                with: user.id,
                currentUserID: appState.currentUser.id,
                mode: mode == .smart ? .smart : .online
            )
            let otherDisplayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.title = otherDisplayName.isEmpty ? user.profile.username : otherDisplayName
            chat.subtitle = "@\(user.profile.username)"
            chat.participants = [
                ChatParticipant(
                    id: appState.currentUser.id,
                    username: appState.currentUser.profile.username,
                    displayName: appState.currentUser.profile.displayName
                ),
                ChatParticipant(
                    id: user.id,
                    username: user.profile.username,
                    displayName: user.profile.displayName
                )
            ]
            chat = await ContactAliasStore.shared.applyAlias(to: chat, currentUserID: appState.currentUser.id)
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
        }
    }

    @MainActor
    private func openNearbyChat(with peer: OfflinePeer) async {
        do {
            let chat = try await environment.chatRepository.createNearbyChat(
                with: peer,
                currentUser: appState.currentUser
            )
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(chat)
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
        }
    }

    @MainActor
    private func openDiscoverableChat(_ chat: Chat) async {
        if shouldRequestApprovalBeforeJoin(chat) {
            beginJoinRequest(for: chat)
            return
        }

        do {
            let resolvedChat: Chat
            if chat.participantIDs.contains(appState.currentUser.id) {
                resolvedChat = chat
            } else {
                resolvedChat = try await environment.chatRepository.joinDiscoverableChat(
                    chat,
                    requesterID: appState.currentUser.id
                )
            }
            errorText = ""
            dismiss()
            appState.routeToChatAfterCurrentTransition(resolvedChat)
        } catch {
            if let repositoryError = error as? ChatRepositoryError,
               case .joinApprovalRequired = repositoryError {
                beginJoinRequest(for: chat)
                return
            }
            errorText = error.localizedDescription.isEmpty ? "Could not open this chat." : error.localizedDescription
        }
    }

    private func discoverableChatActionTitle(_ chat: Chat) -> String {
        if chat.participantIDs.contains(appState.currentUser.id) {
            return "Open"
        }
        if shouldRequestApprovalBeforeJoin(chat) {
            return "Request"
        }
        return "Join"
    }

    private func shouldRequestApprovalBeforeJoin(_ chat: Chat) -> Bool {
        chat.participantIDs.contains(appState.currentUser.id) == false
            && chat.moderationSettings?.requiresJoinApproval == true
    }

    @MainActor
    private func beginJoinRequest(for chat: Chat) {
        pendingJoinRequestChat = chat
        let questions = chat.moderationSettings?.normalizedEntryQuestions ?? []
        joinRequestAnswers = Array(repeating: "", count: questions.count)
        errorText = ""
    }

    @MainActor
    private func submitJoinRequest(for chat: Chat) async {
        isSubmittingJoinRequest = true
        defer { isSubmittingJoinRequest = false }

        let normalizedAnswers = joinRequestAnswers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        do {
            try await environment.chatRepository.submitJoinRequest(
                for: chat,
                requesterID: appState.currentUser.id,
                answers: normalizedAnswers
            )
            pendingJoinRequestChat = nil
            joinRequestAnswers = []
            errorText = "Join request sent."
        } catch {
            errorText = error.localizedDescription.isEmpty ? "Could not submit the join request." : error.localizedDescription
        }
    }

    @ViewBuilder
    private func joinRequestSheet(for chat: Chat) -> some View {
        let entryQuestions = chat.moderationSettings?.normalizedEntryQuestions ?? []

        List {
            Section {
                VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                    Text(chat.displayTitle(for: appState.currentUser.id))
                        .font(.headline)
                        .foregroundStyle(PrimeTheme.Colors.textPrimary)
                    Text("This chat requires approval before joining.")
                        .font(.subheadline)
                        .foregroundStyle(PrimeTheme.Colors.textSecondary)
                }
                .padding(.vertical, 4)
            }

            if entryQuestions.isEmpty == false {
                Section("Entry questions") {
                    ForEach(Array(entryQuestions.enumerated()), id: \.offset) { index, question in
                        VStack(alignment: .leading, spacing: PrimeTheme.Spacing.small) {
                            Text(question)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PrimeTheme.Colors.textPrimary)
                            TextField("Your answer", text: joinRequestAnswerBinding(at: index), axis: .vertical)
                                .lineLimit(2 ... 4)
                                #if os(tvOS)
                                .textFieldStyle(.automatic)
                                #else
                                .textFieldStyle(.roundedBorder)
                                #endif
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Button {
                    Task {
                        await submitJoinRequest(for: chat)
                    }
                } label: {
                    HStack {
                        if isSubmittingJoinRequest {
                            ProgressView()
                        }
                        Text(isSubmittingJoinRequest ? "Sending..." : "Send join request")
                    }
                }
                .disabled(isSubmittingJoinRequest)
            }
        }
        .navigationTitle("Join Request")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    pendingJoinRequestChat = nil
                    joinRequestAnswers = []
                }
            }
        }
    }

    private func joinRequestAnswerBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard joinRequestAnswers.indices.contains(index) else { return "" }
                return joinRequestAnswers[index]
            },
            set: { newValue in
                guard joinRequestAnswers.indices.contains(index) else { return }
                joinRequestAnswers[index] = newValue
            }
        )
    }

    private func persistQueryIfNeeded() async {
        let trimmedQuery = normalizedQuery
        guard trimmedQuery.isEmpty == false else { return }
        await ChatNavigationStateStore.shared.saveGlobalSearch(trimmedQuery, ownerUserID: appState.currentUser.id)
        recentSearches = await ChatNavigationStateStore.shared.recentGlobalSearches(ownerUserID: appState.currentUser.id)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)

        for element in self {
            results.append(await transform(element))
        }

        return results
    }
}
