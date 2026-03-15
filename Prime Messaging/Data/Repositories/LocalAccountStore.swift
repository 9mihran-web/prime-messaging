import Foundation

actor LocalAccountStore {
    static let shared = LocalAccountStore()

    private enum StorageKeys {
        static let records = "local_account_store.records"
    }

    private struct AccountRecord: Codable {
        var user: User
        var password: String
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let reservedUsernames: [String: UUID] = [
        "admin": UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") ?? UUID(),
        "support": UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb") ?? UUID(),
        "mihran": UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc") ?? UUID(),
        "mgcollective": UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd") ?? UUID()
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentUser() -> User? {
        loadRecords().last?.user
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType
    ) throws -> User {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = normalizeUsername(username)
        let normalizedContactValue = normalizeContactValue(contactValue, methodType: methodType)

        guard
            !trimmedDisplayName.isEmpty,
            !normalizedUsername.isEmpty,
            !password.isEmpty,
            !normalizedContactValue.isEmpty
        else {
            throw LocalAuthError.invalidForm
        }

        guard isUsernameAvailable(normalizedUsername, excluding: nil) else {
            throw UsernameRepositoryError.usernameTaken
        }

        var records = loadRecords()
        if records.contains(where: { matchesIdentifier($0.user, identifier: normalizedContactValue) }) {
            throw LocalAuthError.accountAlreadyExists
        }

        let profile = Profile(
            displayName: trimmedDisplayName,
            username: normalizedUsername,
            bio: "Welcome to Prime Messaging.",
            status: "Available",
            email: methodType == .email ? normalizedContactValue : nil,
            phoneNumber: methodType == .phone ? normalizedContactValue : nil,
            profilePhotoURL: nil,
            socialLink: nil
        )
        let user = User(
            id: UUID(),
            profile: profile,
            identityMethods: identityMethods(for: profile),
            privacySettings: .defaultEmailOnly
        )

        records.append(AccountRecord(user: user, password: password))
        saveRecords(records)
        return user
    }

    func logIn(identifier: String, password: String) throws -> User {
        let normalizedIdentifier = normalizeIdentifier(identifier)

        guard
            let record = loadRecords().first(where: { matchesIdentifier($0.user, identifier: normalizedIdentifier) }),
            record.password == password
        else {
            throw LocalAuthError.invalidCredentials
        }

        return record.user
    }

    func refreshUser(userID: UUID) throws -> User {
        guard let user = loadRecords().first(where: { $0.user.id == userID })?.user else {
            throw LocalAuthError.accountNotFound
        }

        return user
    }

    func updateProfile(_ profile: Profile, for userID: UUID) throws -> User {
        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }

        let normalizedUsername = normalizeUsername(profile.username)
        guard isUsernameAvailable(normalizedUsername, excluding: userID) else {
            throw UsernameRepositoryError.usernameTaken
        }

        var updatedProfile = profile
        updatedProfile.username = normalizedUsername
        updatedProfile.email = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updatedProfile.phoneNumber = profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        records[recordIndex].user.profile = updatedProfile
        records[recordIndex].user.identityMethods = identityMethods(for: updatedProfile)
        saveRecords(records)
        return records[recordIndex].user
    }

    func uploadAvatar(imageData: Data, for userID: UUID) throws -> User {
        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("PrimeMessagingAvatars", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let avatarURL = directoryURL.appendingPathComponent("\(userID.uuidString).jpg")
        try imageData.write(to: avatarURL, options: .atomic)

        records[recordIndex].user.profile.profilePhotoURL = avatarURL
        saveRecords(records)
        return records[recordIndex].user
    }

    func searchUsers(query: String, excluding userID: UUID) -> [User] {
        let normalizedQuery = normalizeIdentifier(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return loadRecords()
            .map(\.user)
            .filter { user in
                user.id != userID &&
                (
                    user.profile.username.localizedCaseInsensitiveContains(normalizedQuery) ||
                    user.profile.displayName.localizedCaseInsensitiveContains(normalizedQuery) ||
                    (user.profile.email?.localizedCaseInsensitiveContains(normalizedQuery) ?? false) ||
                    (user.profile.phoneNumber?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                )
            }
    }

    func isUsernameAvailable(_ username: String, excluding userID: UUID?) -> Bool {
        let normalizedUsername = normalizeUsername(username)
        guard !normalizedUsername.isEmpty else { return false }

        if let reservedOwner = reservedUsernames[normalizedUsername], reservedOwner != userID {
            return false
        }

        return loadRecords().contains(where: { record in
            guard record.user.profile.username == normalizedUsername else {
                return false
            }

            if let userID {
                return record.user.id != userID
            }

            return true
        }) == false
    }

    func claimUsername(_ username: String, for userID: UUID) throws {
        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }

        let normalizedUsername = normalizeUsername(username)
        guard isUsernameAvailable(normalizedUsername, excluding: userID) else {
            throw UsernameRepositoryError.usernameTaken
        }

        records[recordIndex].user.profile.username = normalizedUsername
        records[recordIndex].user.identityMethods = identityMethods(for: records[recordIndex].user.profile)
        saveRecords(records)
    }

    private func matchesIdentifier(_ user: User, identifier: String) -> Bool {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        let candidates = [
            normalizeIdentifier(user.profile.username),
            normalizeIdentifier("@\(user.profile.username)"),
            normalizeIdentifier(user.profile.email ?? ""),
            normalizeIdentifier(user.profile.phoneNumber ?? "")
        ]

        return candidates.contains(normalizedIdentifier)
    }

    private func identityMethods(for profile: Profile) -> [IdentityMethod] {
        var methods: [IdentityMethod] = [
            IdentityMethod(type: .username, value: "@\(profile.username)", isVerified: true, isPubliclyDiscoverable: true)
        ]

        if let email = profile.email, !email.isEmpty {
            methods.append(
                IdentityMethod(type: .email, value: email, isVerified: true, isPubliclyDiscoverable: true)
            )
        }

        if let phoneNumber = profile.phoneNumber, !phoneNumber.isEmpty {
            methods.append(
                IdentityMethod(type: .phone, value: phoneNumber, isVerified: true, isPubliclyDiscoverable: true)
            )
        }

        return methods
    }

    private func normalizeUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func normalizeContactValue(_ contactValue: String, methodType: IdentityMethodType) -> String {
        let trimmed = contactValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch methodType {
        case .email:
            return trimmed.lowercased()
        default:
            return trimmed
        }
    }

    private func loadRecords() -> [AccountRecord] {
        guard
            let data = defaults.data(forKey: StorageKeys.records),
            let records = try? decoder.decode([AccountRecord].self, from: data)
        else {
            return []
        }

        return records
    }

    private func saveRecords(_ records: [AccountRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.records)
    }
}

enum LocalAuthError: LocalizedError {
    case invalidForm
    case accountAlreadyExists
    case invalidCredentials
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .invalidForm:
            return "Fill in all required fields."
        case .accountAlreadyExists:
            return "An account with this phone number or e-mail already exists."
        case .invalidCredentials:
            return "Incorrect username, phone, e-mail, or password."
        case .accountNotFound:
            return "Account not found."
        }
    }
}
