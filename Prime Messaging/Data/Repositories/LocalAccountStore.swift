import Foundation

actor LocalAccountStore {
    static let shared = LocalAccountStore()
    private static let defaultOTPCode = "000000"
    private static let guestLifetime: TimeInterval = 60 * 60 * 24 * 3
    private static let monthlyGuestLimit = 2

    private enum StorageKeys {
        static let records = "local_account_store.records"
        static let guestRegistrationHistory = "local_account_store.guest_registration_history"
    }

    private struct AccountRecord: Codable {
        var user: User
        var password: String
    }

    struct StoredCredentials: Hashable {
        let identifier: String
        let password: String
    }

    struct RemoteRecoveryAccount: Hashable {
        let user: User
        let password: String
        let loginIdentifiers: [String]
        let contactValue: String
        let methodType: IdentityMethodType
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
        methodType: IdentityMethodType,
        accountKind: AccountKind
    ) throws -> User {
        var records = loadRecords()
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = normalizeUsername(username)
        let normalizedContactValue = normalizeContactValue(contactValue, methodType: methodType)

        guard
            !trimmedDisplayName.isEmpty,
            !trimmedPassword.isEmpty,
            isValidUsername(normalizedUsername)
        else {
            throw LocalAuthError.invalidForm
        }

        guard isUsernameAvailable(normalizedUsername, excluding: nil) else {
            throw UsernameRepositoryError.usernameTaken
        }

        let now = Date.now
        var email: String?
        var phoneNumber: String?

        switch accountKind {
        case .standard:
            guard methodType == .phone, isValidPhoneNumber(normalizedContactValue) else {
                throw LocalAuthError.invalidPhoneNumber
            }
            guard phoneOwner(for: normalizedContactValue, excluding: nil) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
            phoneNumber = normalizedContactValue
        case .offlineOnly:
            guard methodType == .email, isValidEmail(normalizedContactValue) else {
                throw LocalAuthError.invalidEmail
            }
            guard emailOwner(for: normalizedContactValue, excluding: nil) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
            email = normalizedContactValue
        case .guest:
            guard methodType == .username else {
                throw LocalAuthError.invalidForm
            }
            guard canCreateGuestAccount(on: now) else {
                throw LocalAuthError.guestLimitReached
            }
        }

        let profile = Profile(
            displayName: trimmedDisplayName,
            username: normalizedUsername,
            bio: "Welcome to Prime Messaging.",
            status: "Available",
            birthday: nil,
            email: email,
            phoneNumber: phoneNumber,
            profilePhotoURL: nil,
            socialLink: nil
        )
        var privacySettings = PrivacySettings.defaultEmailOnly
        if accountKind == .guest {
            privacySettings.showEmail = false
            privacySettings.showPhoneNumber = false
        }
        let user = User(
            id: UUID(),
            profile: profile,
            identityMethods: identityMethods(for: profile),
            privacySettings: privacySettings,
            accountKind: accountKind,
            createdAt: now,
            guestExpiresAt: accountKind == .guest ? now.addingTimeInterval(Self.guestLifetime) : nil
        )

        records.append(AccountRecord(user: user, password: trimmedPassword))
        saveRecords(records)
        if accountKind == .guest {
            recordGuestRegistration(at: now)
        }
        return user
    }

    func authenticate(identifier: String, otpCode: String) throws -> User? {
        guard otpCode == Self.defaultOTPCode else {
            throw LocalAuthError.invalidOTPCode
        }

        let normalizedIdentifier = normalizeIdentifier(identifier)
        return loadRecords().first(where: { matchesIdentifier($0.user, identifier: normalizedIdentifier) })?.user
    }

    func lookupAccount(identifier: String) -> AccountLookupResult {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        guard let user = loadRecords().first(where: { matchesIdentifier($0.user, identifier: normalizedIdentifier) })?.user else {
            return AccountLookupResult(exists: false, accountKind: nil, displayName: nil)
        }

        let displayName = user.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountLookupResult(
            exists: true,
            accountKind: user.accountKind,
            displayName: displayName.isEmpty ? nil : displayName
        )
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

    func resetPassword(identifier: String, newPassword: String) throws {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.isEmpty == false else {
            throw LocalAuthError.invalidForm
        }

        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { matchesIdentifier($0.user, identifier: normalizedIdentifier) }) else {
            throw LocalAuthError.accountNotFound
        }

        records[recordIndex].password = trimmedPassword
        saveRecords(records)
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

        let currentUser = records[recordIndex].user
        let normalizedUsername = normalizeUsername(profile.username)
        let existingUsername = normalizeUsername(currentUser.profile.username)
        let isKeepingLegacyUsername = normalizedUsername == existingUsername && isValidUsername(normalizedUsername, minimumLength: 3)
        guard isKeepingLegacyUsername || isValidUsername(normalizedUsername) else {
            throw LocalAuthError.invalidUsername
        }
        guard isUsernameAvailable(normalizedUsername, excluding: userID) else {
            throw UsernameRepositoryError.usernameTaken
        }

        let normalizedEmail = normalizeOptionalEmail(profile.email)
        let normalizedPhoneNumber = normalizeOptionalPhoneNumber(profile.phoneNumber)

        if currentUser.accountKind == .guest {
            var limitedProfile = profile
            limitedProfile.username = currentUser.profile.username
            limitedProfile.email = currentUser.profile.email
            limitedProfile.phoneNumber = currentUser.profile.phoneNumber
            limitedProfile.birthday = currentUser.profile.birthday
            limitedProfile.profilePhotoURL = currentUser.profile.profilePhotoURL
            limitedProfile.socialLink = currentUser.profile.socialLink
            records[recordIndex].user.profile.displayName = limitedProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            records[recordIndex].user.profile.bio = limitedProfile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
            records[recordIndex].user.profile.status = limitedProfile.status.trimmingCharacters(in: .whitespacesAndNewlines)
            saveRecords(records)
            return records[recordIndex].user
        }

        if let normalizedEmail {
            guard isValidEmail(normalizedEmail) else {
                throw LocalAuthError.invalidEmail
            }
            guard emailOwner(for: normalizedEmail, excluding: userID) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
        }

        if let normalizedPhoneNumber {
            guard isValidPhoneNumber(normalizedPhoneNumber) else {
                throw LocalAuthError.invalidPhoneNumber
            }
            guard phoneOwner(for: normalizedPhoneNumber, excluding: userID) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
        }

        var updatedProfile = profile
        updatedProfile.username = normalizedUsername
        updatedProfile.displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedProfile.bio = profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedProfile.status = profile.status.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedProfile.email = normalizedEmail
        updatedProfile.phoneNumber = currentUser.accountKind == .offlineOnly ? nil : normalizedPhoneNumber

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
        guard records[recordIndex].user.canUploadAvatar else {
            throw LocalAuthError.guestLimitedProfile
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("PrimeMessagingAvatars", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let avatarURL = directoryURL.appendingPathComponent("\(userID.uuidString).jpg")
        try imageData.write(to: avatarURL, options: .atomic)

        records[recordIndex].user.profile.profilePhotoURL = avatarURL
        saveRecords(records)
        return records[recordIndex].user
    }

    func removeAvatar(for userID: UUID) throws -> User {
        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }

        records[recordIndex].user.profile.profilePhotoURL = nil
        saveRecords(records)
        return records[recordIndex].user
    }

    func updatePassword(_ password: String, for userID: UUID) throws {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.isEmpty == false else {
            throw LocalAuthError.invalidForm
        }

        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }
        guard records[recordIndex].user.isGuest == false else {
            throw LocalAuthError.guestLimitedProfile
        }

        records[recordIndex].password = trimmedPassword
        saveRecords(records)
    }

    func deleteAccount(userID: UUID) throws {
        var records = loadRecords()
        guard let recordIndex = records.firstIndex(where: { $0.user.id == userID }) else {
            throw LocalAuthError.accountNotFound
        }

        if let avatarURL = records[recordIndex].user.profile.profilePhotoURL {
            try? FileManager.default.removeItem(at: avatarURL)
        }

        records.remove(at: recordIndex)
        saveRecords(records)
    }

    func upsertRemoteAccount(_ user: User, password: String) {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.isEmpty == false else { return }

        var records = loadRecords()
        if let index = records.firstIndex(where: { $0.user.id == user.id }) {
            records[index].user = user
            records[index].password = trimmedPassword
        } else {
            records.append(AccountRecord(user: user, password: trimmedPassword))
        }
        saveRecords(records)
    }

    func upsertRemoteUser(_ user: User) {
        var records = loadRecords()
        if let index = records.firstIndex(where: { $0.user.id == user.id }) {
            records[index].user = user
            saveRecords(records)
        }
    }

    func credentials(for userID: UUID) -> StoredCredentials? {
        guard let record = loadRecords().first(where: { $0.user.id == userID }) else {
            return nil
        }

        let identifier = bestLoginIdentifier(for: record.user)
        guard identifier.isEmpty == false, record.password.isEmpty == false else {
            return nil
        }

        return StoredCredentials(identifier: identifier, password: record.password)
    }

    func remoteRecoveryAccount(for userID: UUID) -> RemoteRecoveryAccount? {
        guard let record = loadRecords().first(where: { $0.user.id == userID }) else {
            return nil
        }

        let password = record.password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.isEmpty == false else {
            return nil
        }

        let email = record.user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phone = record.user.profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let methodType: IdentityMethodType
        let contactValue: String

        if let email, email.isEmpty == false {
            methodType = .email
            contactValue = email
        } else if let phone, phone.isEmpty == false {
            methodType = .phone
            contactValue = phone
        } else {
            methodType = .username
            contactValue = record.user.profile.username
        }

        let loginIdentifiers = [
            email,
            phone,
            record.user.profile.username,
            "@\(record.user.profile.username)"
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return RemoteRecoveryAccount(
            user: record.user,
            password: password,
            loginIdentifiers: Array(NSOrderedSet(array: loginIdentifiers)) as? [String] ?? loginIdentifiers,
            contactValue: contactValue,
            methodType: methodType
        )
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
        guard isValidUsername(normalizedUsername) else { return false }

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
        guard records[recordIndex].user.isGuest == false else {
            throw LocalAuthError.guestLimitedProfile
        }

        let normalizedUsername = normalizeUsername(username)
        guard isValidUsername(normalizedUsername) else {
            throw LocalAuthError.invalidUsername
        }
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
        let lowered = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = lowered.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        return String(allowed.prefix(32))
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
        case .phone:
            return normalizePhoneNumber(trimmed)
        default:
            return trimmed.lowercased()
        }
    }

    private func loadRecords() -> [AccountRecord] {
        guard
            let data = defaults.data(forKey: StorageKeys.records),
            let records = try? decoder.decode([AccountRecord].self, from: data)
        else {
            return []
        }

        let filteredRecords = records.filter { accountRecord in
            guard accountRecord.user.isGuest, let guestExpiresAt = accountRecord.user.guestExpiresAt else {
                return true
            }
            return guestExpiresAt > .now
        }

        if filteredRecords.count != records.count {
            let removedRecords = records.filter { staleRecord in
                filteredRecords.contains(where: { $0.user.id == staleRecord.user.id }) == false
            }
            removedRecords.compactMap(\.user.profile.profilePhotoURL).forEach { avatarURL in
                try? FileManager.default.removeItem(at: avatarURL)
            }
            saveRecords(filteredRecords)
        }

        return filteredRecords
    }

    private func saveRecords(_ records: [AccountRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.records)
    }

    private func bestLoginIdentifier(for user: User) -> String {
        if let email = user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
            return email
        }

        if let phoneNumber = user.profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !phoneNumber.isEmpty {
            return phoneNumber
        }

        return user.profile.username
    }

    private func isValidUsername(_ username: String, minimumLength: Int = 5) -> Bool {
        guard username.count >= minimumLength, username.count <= 32 else { return false }
        return username.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return false }
        guard parts[0].isEmpty == false, parts[1].isEmpty == false else { return false }
        return parts[1].contains(".")
    }

    private func isValidPhoneNumber(_ phoneNumber: String) -> Bool {
        guard phoneNumber.hasPrefix("+") else { return false }
        let digits = phoneNumber.dropFirst()
        guard digits.count >= 7, digits.count <= 15 else { return false }
        return digits.allSatisfy(\.isNumber)
    }

    private func normalizePhoneNumber(_ phoneNumber: String) -> String {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        var result = ""
        for (index, character) in trimmed.enumerated() {
            if character == "+" && index == 0 {
                result.append(character)
            } else if character.isNumber {
                result.append(character)
            }
        }
        return result
    }

    private func normalizeOptionalEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeOptionalPhoneNumber(_ phoneNumber: String?) -> String? {
        guard let phoneNumber else { return nil }
        let normalized = normalizePhoneNumber(phoneNumber)
        return normalized.isEmpty ? nil : normalized
    }

    private func emailOwner(for email: String, excluding userID: UUID?) -> UUID? {
        loadRecords()
            .first(where: { record in
                guard let candidate = record.user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    return false
                }
                guard candidate == email else { return false }
                if let userID {
                    return record.user.id != userID
                }
                return true
            })?
            .user.id
    }

    private func phoneOwner(for phoneNumber: String, excluding userID: UUID?) -> UUID? {
        loadRecords()
            .first(where: { record in
                guard let candidate = record.user.profile.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                guard candidate == phoneNumber else { return false }
                if let userID {
                    return record.user.id != userID
                }
                return true
            })?
            .user.id
    }

    private func canCreateGuestAccount(on date: Date) -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        let history = guestRegistrationHistory().filter { entry in
            calendar.isDate(entry, equalTo: date, toGranularity: .month) &&
            calendar.isDate(entry, equalTo: date, toGranularity: .year)
        }
        return history.count < Self.monthlyGuestLimit
    }

    private func guestRegistrationHistory() -> [Date] {
        guard
            let data = defaults.data(forKey: StorageKeys.guestRegistrationHistory),
            let history = try? decoder.decode([Date].self, from: data)
        else {
            return []
        }
        return history
    }

    private func recordGuestRegistration(at date: Date) {
        var history = guestRegistrationHistory()
        history.append(date)
        let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .month, value: -2, to: date) ?? date
        history = history.filter { $0 >= cutoff }
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: StorageKeys.guestRegistrationHistory)
    }
}

enum LocalAuthError: LocalizedError {
    case invalidForm
    case accountAlreadyExists
    case invalidCredentials
    case accountNotFound
    case invalidOTPCode
    case invalidUsername
    case invalidEmail
    case invalidPhoneNumber
    case guestLimitReached
    case guestLimitedProfile

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
        case .invalidOTPCode:
            return "Use 000000 as the temporary OTP code."
        case .invalidUsername:
            return "Username must be 5-32 characters and use only a-z, 0-9, or _."
        case .invalidEmail:
            return "Enter a valid e-mail address."
        case .invalidPhoneNumber:
            return "Enter the phone number in international format, for example +37499111222."
        case .guestLimitReached:
            return "Guest Mode is available only twice per month on this device."
        case .guestLimitedProfile:
            return "Guest Mode supports only a limited profile."
        }
    }
}
