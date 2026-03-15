import Combine
import Foundation

final class AppState: ObservableObject {
    private enum StorageKeys {
        static let selectedMode = "app_state.selected_mode"
        static let currentUser = "app_state.current_user"
        static let accounts = "app_state.accounts"
        static let hasCompletedOnboarding = "app_state.has_completed_onboarding"
        static let selectedLanguage = "selected_app_language"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published var selectedMode: ChatMode = .online
    @Published var selectedChat: Chat?
    @Published var currentUser: User = .mockCurrentUser
    @Published private(set) var accounts: [User] = []
    @Published var hasCompletedOnboarding = false
    @Published var selectedLanguage: AppLanguage = .english
    @Published var isShowingAccountAuth = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawMode = defaults.string(forKey: StorageKeys.selectedMode), let mode = ChatMode(rawValue: rawMode) {
            selectedMode = mode
        }

        if let rawLanguage = defaults.string(forKey: StorageKeys.selectedLanguage), let language = AppLanguage(rawValue: rawLanguage) {
            selectedLanguage = language
        } else {
            defaults.set(AppLanguage.english.rawValue, forKey: StorageKeys.selectedLanguage)
        }

        if let data = defaults.data(forKey: StorageKeys.currentUser), let user = try? decoder.decode(User.self, from: data) {
            currentUser = user
        }

        if let data = defaults.data(forKey: StorageKeys.accounts), let storedAccounts = try? decoder.decode([User].self, from: data) {
            accounts = storedAccounts
        } else if defaults.data(forKey: StorageKeys.currentUser) != nil {
            accounts = [currentUser]
        }

        hasCompletedOnboarding = defaults.bool(forKey: StorageKeys.hasCompletedOnboarding)
    }

    func completeOnboarding(name: String, username: String, contactValue: String, methodType: IdentityMethodType) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = normalizedUsername(username)
        let trimmedContact = contactValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmedName.isEmpty,
            !trimmedContact.isEmpty,
            isValidUsername(trimmedUsername)
        else { return }

        currentUser.profile.displayName = trimmedName
        currentUser.profile.username = trimmedUsername
        currentUser.profile.status = "Ready to connect"
        currentUser.profile.email = methodType == .email ? trimmedContact : nil
        currentUser.profile.phoneNumber = methodType == .phone ? trimmedContact : nil
        currentUser.identityMethods = [
            IdentityMethod(type: methodType, value: trimmedContact, isVerified: true, isPubliclyDiscoverable: true),
            IdentityMethod(type: .username, value: "@\(trimmedUsername)", isVerified: true, isPubliclyDiscoverable: true)
        ]
        hasCompletedOnboarding = true
        persistState()
    }

    func applyAuthenticatedUser(_ user: User) {
        currentUser = user
        hasCompletedOnboarding = true
        isShowingAccountAuth = false
        upsertAccount(user)
        persistState()
    }

    func updateCurrentUsername(_ username: String) {
        let normalized = normalizedUsername(username)
        guard isValidUsername(normalized) else { return }

        currentUser.profile.username = normalized

        if let usernameIndex = currentUser.identityMethods.firstIndex(where: { $0.type == .username }) {
            currentUser.identityMethods[usernameIndex] = IdentityMethod(
                id: currentUser.identityMethods[usernameIndex].id,
                type: .username,
                value: "@\(normalized)",
                isVerified: currentUser.identityMethods[usernameIndex].isVerified,
                isPubliclyDiscoverable: currentUser.identityMethods[usernameIndex].isPubliclyDiscoverable
            )
        } else {
            currentUser.identityMethods.append(
                IdentityMethod(type: .username, value: "@\(normalized)", isVerified: true, isPubliclyDiscoverable: true)
            )
        }

        upsertAccount(currentUser)
        persistState()
    }

    func updateSelectedMode(_ mode: ChatMode) {
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: StorageKeys.selectedMode)
    }

    func updateLanguage(_ language: AppLanguage) {
        selectedLanguage = language
        defaults.set(language.rawValue, forKey: StorageKeys.selectedLanguage)
        objectWillChange.send()
    }

    func beginAddingAccount() {
        isShowingAccountAuth = true
    }

    func cancelAddingAccount() {
        isShowingAccountAuth = false
    }

    func switchToAccount(_ accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        currentUser = account
        hasCompletedOnboarding = true
        persistState()
    }

    func logOutCurrentAccount() {
        let currentAccountID = currentUser.id
        accounts.removeAll(where: { $0.id == currentAccountID })

        if let nextAccount = accounts.first {
            currentUser = nextAccount
            hasCompletedOnboarding = true
        } else {
            currentUser = .mockCurrentUser
            hasCompletedOnboarding = false
            selectedMode = .online
        }

        isShowingAccountAuth = false
        persistState()
    }

    func removeAccount(_ accountID: UUID) {
        if accountID == currentUser.id {
            logOutCurrentAccount()
            return
        }

        accounts.removeAll(where: { $0.id == accountID })
        persistState()
    }

    func normalizedUsername(_ username: String) -> String {
        let lowered = username.lowercased()
        let allowed = lowered.filter { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        return String(allowed.prefix(13))
    }

    func isValidUsername(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= 13 else { return false }
        return username.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
    }

    private func persistState() {
        defaults.set(hasCompletedOnboarding, forKey: StorageKeys.hasCompletedOnboarding)
        defaults.set(selectedMode.rawValue, forKey: StorageKeys.selectedMode)
        defaults.set(selectedLanguage.rawValue, forKey: StorageKeys.selectedLanguage)

        if let data = try? encoder.encode(currentUser) {
            defaults.set(data, forKey: StorageKeys.currentUser)
        }

        if let data = try? encoder.encode(accounts) {
            defaults.set(data, forKey: StorageKeys.accounts)
        }
    }

    private func upsertAccount(_ user: User) {
        if let existingIndex = accounts.firstIndex(where: { $0.id == user.id }) {
            accounts[existingIndex] = user
        } else {
            accounts.insert(user, at: 0)
        }
    }
}
