import Foundation

actor LocalAccountStore {
    static let shared = LocalAccountStore()
    private static let defaultOTPCode = "000000"
    private static let otpTTL: TimeInterval = 5 * 60
    private static let otpResendCooldown: TimeInterval = 30
    private static let otpAttemptLimit = 5
    private static let guestLifetime: TimeInterval = 60 * 60 * 24 * 3
    private static let monthlyGuestLimit = 2

    private enum StorageKeys {
        static let records = "local_account_store.records"
        static let guestRegistrationHistory = "local_account_store.guest_registration_history"
        static let blockedRelations = "local_account_store.blocked_relations"
        static let appleIdentityLinks = "local_account_store.apple_identity_links"
    }

    private struct AccountRecord: Codable {
        var user: User
        var password: String
    }

    private struct BlockRelation: Codable, Hashable {
        var blockerUserID: UUID
        var blockedUserID: UUID
        var createdAt: Date
    }

    private struct AppleIdentityLink: Codable, Hashable {
        var appleUserID: String
        var userID: UUID
        var updatedAt: Date
    }

    struct StoredCredentials: Hashable {
        let identifier: String
        let password: String
    }

    struct RemoteRecoveryAccount: Equatable {
        let user: User
        let password: String
        let loginIdentifiers: [String]
        let contactValue: String
        let methodType: IdentityMethodType
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private struct OTPChallengeRecord {
        var id: String
        var identifier: String
        var purpose: OTPPurpose
        var code: String
        var expiresAt: Date
        var resendAvailableAt: Date
        var attemptLimit: Int
        var attemptsUsed: Int
        var channel: String
        var destinationMasked: String
        var verifiedAt: Date?
        var consumedAt: Date?
    }
    private var otpChallengesByID: [String: OTPChallengeRecord] = [:]
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
        accountKind: AccountKind,
        otpChallengeID: String?,
        signupEmail: String?
    ) throws -> User {
        var records = loadRecords()
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = normalizeUsername(username)
        let normalizedContactValue = normalizeContactValue(contactValue, methodType: methodType)
        purgeExpiredOTPChallenges()

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
            guard methodType == .email, isValidEmail(normalizedContactValue) else {
                throw LocalAuthError.invalidEmail
            }
            guard emailOwner(for: normalizedContactValue, excluding: nil) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
            phoneNumber = nil
            email = normalizedContactValue
            try validateSignupOTPIfRequired(
                challengeID: otpChallengeID,
                identifier: normalizedContactValue
            )
        case .offlineOnly:
            guard methodType == .email, isValidEmail(normalizedContactValue) else {
                throw LocalAuthError.invalidEmail
            }
            guard emailOwner(for: normalizedContactValue, excluding: nil) == nil else {
                throw LocalAuthError.accountAlreadyExists
            }
            email = normalizedContactValue
            try validateSignupOTPIfRequired(
                challengeID: otpChallengeID,
                identifier: normalizedContactValue
            )
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
            bio: "",
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

    func requestOTP(identifier: String, purpose: OTPPurpose) throws -> OTPChallenge {
        purgeExpiredOTPChallenges()

        let normalizedIdentifier = normalizeIdentifier(identifier)
        guard normalizedIdentifier.isEmpty == false else {
            throw LocalAuthError.invalidForm
        }

        if let latestChallenge = otpChallengesByID.values
            .filter({ $0.identifier == normalizedIdentifier && $0.purpose == purpose && $0.consumedAt == nil })
            .sorted(by: { $0.expiresAt > $1.expiresAt })
            .first,
           latestChallenge.resendAvailableAt > .now {
            return OTPChallenge(
                challengeID: latestChallenge.id,
                expiresAt: latestChallenge.expiresAt,
                resendAvailableAt: latestChallenge.resendAvailableAt,
                attemptLimit: latestChallenge.attemptLimit,
                remainingAttempts: max(0, latestChallenge.attemptLimit - latestChallenge.attemptsUsed),
                channel: latestChallenge.channel,
                destinationMasked: latestChallenge.destinationMasked
            )
        }

        let now = Date.now
        let channel = normalizedIdentifier.contains("@") ? "email" : "sms"
        let challenge = OTPChallengeRecord(
            id: UUID().uuidString.lowercased(),
            identifier: normalizedIdentifier,
            purpose: purpose,
            code: Self.defaultOTPCode,
            expiresAt: now.addingTimeInterval(Self.otpTTL),
            resendAvailableAt: now.addingTimeInterval(Self.otpResendCooldown),
            attemptLimit: Self.otpAttemptLimit,
            attemptsUsed: 0,
            channel: channel,
            destinationMasked: maskIdentifier(normalizedIdentifier),
            verifiedAt: nil,
            consumedAt: nil
        )
        otpChallengesByID[challenge.id] = challenge

        return OTPChallenge(
            challengeID: challenge.id,
            expiresAt: challenge.expiresAt,
            resendAvailableAt: challenge.resendAvailableAt,
            attemptLimit: challenge.attemptLimit,
            remainingAttempts: challenge.attemptLimit,
            channel: challenge.channel,
            destinationMasked: challenge.destinationMasked
        )
    }

    func verifyOTPChallenge(challengeID: String, otpCode: String) throws -> OTPChallenge {
        purgeExpiredOTPChallenges()
        let normalizedID = challengeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedCode = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var challenge = otpChallengesByID[normalizedID] else {
            throw LocalAuthError.accountNotFound
        }
        guard challenge.consumedAt == nil else {
            throw LocalAuthError.invalidOTPCode
        }
        guard challenge.expiresAt > .now else {
            otpChallengesByID.removeValue(forKey: normalizedID)
            throw LocalAuthError.invalidOTPCode
        }
        if challenge.attemptsUsed >= challenge.attemptLimit {
            throw LocalAuthError.invalidOTPCode
        }

        challenge.attemptsUsed += 1
        guard challenge.code == trimmedCode else {
            otpChallengesByID[normalizedID] = challenge
            throw LocalAuthError.invalidOTPCode
        }

        challenge.verifiedAt = .now
        otpChallengesByID[normalizedID] = challenge
        return OTPChallenge(
            challengeID: challenge.id,
            expiresAt: challenge.expiresAt,
            resendAvailableAt: challenge.resendAvailableAt,
            attemptLimit: challenge.attemptLimit,
            remainingAttempts: max(0, challenge.attemptLimit - challenge.attemptsUsed),
            channel: challenge.channel,
            destinationMasked: challenge.destinationMasked
        )
    }

    func authenticate(identifier: String, otpCode: String, challengeID: String?) throws -> User? {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        if let challengeID {
            let verifiedChallenge = try verifyOTPChallenge(challengeID: challengeID, otpCode: otpCode)
            guard let challengeRecord = otpChallengesByID[verifiedChallenge.challengeID],
                  challengeRecord.identifier == normalizedIdentifier else {
                throw LocalAuthError.invalidOTPCode
            }
        } else if otpCode != Self.defaultOTPCode {
            throw LocalAuthError.invalidOTPCode
        }

        let records = loadRecords()
        return resolvedRecord(
            for: identifier,
            in: records,
            requiredPassword: nil
        )?.user
    }

    func lookupAccount(identifier: String) -> AccountLookupResult {
        let records = loadRecords()
        guard let user = resolvedRecord(
            for: identifier,
            in: records,
            requiredPassword: nil
        )?.user else {
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
        let records = loadRecords()

        guard let record = resolvedRecord(
            for: identifier,
            in: records,
            requiredPassword: password
        ) else {
            throw LocalAuthError.invalidCredentials
        }

        return record.user
    }

    func resetPassword(identifier: String, newPassword: String, challengeID: String?) throws {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.isEmpty == false else {
            throw LocalAuthError.invalidForm
        }

        try validatePasswordResetOTPIfRequired(challengeID: challengeID, identifier: normalizedIdentifier)

        var records = loadRecords()
        guard let recordIndex = resolvedRecordIndex(
            for: identifier,
            in: records,
            requiredPassword: nil
        ) else {
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

        if let previousAvatarURL = records[recordIndex].user.profile.profilePhotoURL {
            try? FileManager.default.removeItem(at: previousAvatarURL)
        }

        let avatarURL = directoryURL.appendingPathComponent("\(userID.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
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
        removeBlockRelations(for: userID)
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

    func signInWithApple(
        appleUserID: String,
        email: String?,
        givenName: String?,
        familyName: String?
    ) throws -> AppleSignInResult {
        let normalizedAppleUserID = appleUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAppleUserID.isEmpty == false else {
            throw LocalAuthError.invalidForm
        }

        var records = loadRecords()
        var appleLinks = loadAppleIdentityLinks()
        let normalizedEmail = normalizeOptionalEmail(email)
        let displayName = buildAppleDisplayName(
            givenName: givenName,
            familyName: familyName,
            email: normalizedEmail
        )

        if let existingLink = appleLinks.first(where: { $0.appleUserID == normalizedAppleUserID }),
           let recordIndex = records.firstIndex(where: { $0.user.id == existingLink.userID }) {
            if let normalizedEmail,
               records[recordIndex].user.profile.email?.lowercased() != normalizedEmail {
                records[recordIndex].user.profile.email = normalizedEmail
                records[recordIndex].user.identityMethods = identityMethods(for: records[recordIndex].user.profile)
                saveRecords(records)
            }
            return AppleSignInResult(user: records[recordIndex].user, isNewUser: false)
        }

        if let normalizedEmail,
           let recordIndex = records.firstIndex(where: {
               $0.user.profile.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedEmail
           }) {
            appleLinks.removeAll(where: { $0.appleUserID == normalizedAppleUserID || $0.userID == records[recordIndex].user.id })
            appleLinks.append(
                AppleIdentityLink(
                    appleUserID: normalizedAppleUserID,
                    userID: records[recordIndex].user.id,
                    updatedAt: .now
                )
            )
            saveAppleIdentityLinks(appleLinks)
            return AppleSignInResult(user: records[recordIndex].user, isNewUser: false)
        }

        let username = nextAvailableUsername(
            seed: appleUsernameSeed(
                givenName: givenName,
                email: normalizedEmail,
                appleUserID: normalizedAppleUserID
            ),
            excluding: nil,
            records: records
        )
        let now = Date.now
        let profile = Profile(
            displayName: displayName,
            username: username,
            bio: "",
            status: "Available",
            birthday: nil,
            email: normalizedEmail,
            phoneNumber: nil,
            profilePhotoURL: nil,
            socialLink: nil
        )
        let user = User(
            id: UUID(),
            profile: profile,
            identityMethods: identityMethods(for: profile),
            privacySettings: .defaultEmailOnly,
            accountKind: .standard,
            createdAt: now,
            guestExpiresAt: nil
        )
        let syntheticPassword = "apple-\(UUID().uuidString.lowercased())"
        records.append(AccountRecord(user: user, password: syntheticPassword))
        saveRecords(records)

        appleLinks.removeAll(where: { $0.appleUserID == normalizedAppleUserID || $0.userID == user.id })
        appleLinks.append(
            AppleIdentityLink(
                appleUserID: normalizedAppleUserID,
                userID: user.id,
                updatedAt: now
            )
        )
        saveAppleIdentityLinks(appleLinks)

        return AppleSignInResult(user: user, isNewUser: true)
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
        let blockRelations = loadBlockRelations()

        return loadRecords()
            .map(\.user)
            .filter { user in
                user.id != userID &&
                isBlockedBetween(userID, user.id, relations: blockRelations) == false &&
                (
                    user.profile.username.localizedCaseInsensitiveContains(normalizedQuery) ||
                    user.profile.displayName.localizedCaseInsensitiveContains(normalizedQuery) ||
                    (user.profile.email?.localizedCaseInsensitiveContains(normalizedQuery) ?? false) ||
                    (user.profile.phoneNumber?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                )
            }
    }

    func matchDeviceContacts(
        _ contacts: [DeviceContactCandidate],
        excluding userID: UUID
    ) -> [MatchedDeviceContact] {
        guard contacts.isEmpty == false else { return [] }

        let records = loadRecords()
        let blockRelations = loadBlockRelations()

        let visibleUsers = records
            .map(\.user)
            .filter { candidate in
                candidate.id != userID && isBlockedBetween(userID, candidate.id, relations: blockRelations) == false
            }

        var usersByEmail: [String: User] = [:]
        var usersByPhone: [String: User] = [:]
        for user in visibleUsers {
            if let email = normalizeOptionalEmail(user.profile.email), usersByEmail[email] == nil {
                usersByEmail[email] = user
            }
            if let phone = normalizeOptionalPhoneNumber(user.profile.phoneNumber), usersByPhone[phone] == nil {
                usersByPhone[phone] = user
            }
        }

        var matches: [MatchedDeviceContact] = []
        var consumedUserIDs: Set<UUID> = []
        for contact in contacts {
            let normalizedContactID = contact.localContactID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedContactID.isEmpty == false else { continue }

            let normalizedEmails = contact.emails.compactMap(normalizeOptionalEmail)
            let normalizedPhones = contact.phones.compactMap(normalizeOptionalPhoneNumber)

            var matchedUser: User?
            var matchedBy = ""

            for email in normalizedEmails {
                if let user = usersByEmail[email], consumedUserIDs.contains(user.id) == false {
                    matchedUser = user
                    matchedBy = "email"
                    break
                }
            }

            if matchedUser == nil {
                for phone in normalizedPhones {
                    if let user = usersByPhone[phone], consumedUserIDs.contains(user.id) == false {
                        matchedUser = user
                        matchedBy = "phone"
                        break
                    }
                }
            }

            if let matchedUser {
                consumedUserIDs.insert(matchedUser.id)
                matches.append(
                    MatchedDeviceContact(
                        localContactID: normalizedContactID,
                        user: matchedUser,
                        matchedBy: matchedBy
                    )
                )
            }
        }

        return matches
    }

    func blockedUsers(for userID: UUID) -> [User] {
        let usersByID = Dictionary(uniqueKeysWithValues: loadRecords().map { ($0.user.id, $0.user) })
        return loadBlockRelations()
            .filter { $0.blockerUserID == userID }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { usersByID[$0.blockedUserID] }
    }

    func blockUser(blockerUserID: UUID, blockedUserID: UUID) {
        guard blockerUserID != blockedUserID else { return }
        let userIDs = Set(loadRecords().map(\.user.id))
        guard userIDs.contains(blockerUserID), userIDs.contains(blockedUserID) else { return }

        var relations = loadBlockRelations()
        let alreadyBlocked = relations.contains {
            $0.blockerUserID == blockerUserID && $0.blockedUserID == blockedUserID
        }
        guard alreadyBlocked == false else { return }

        relations.append(
            BlockRelation(
                blockerUserID: blockerUserID,
                blockedUserID: blockedUserID,
                createdAt: .now
            )
        )
        saveBlockRelations(relations)
    }

    func unblockUser(blockerUserID: UUID, blockedUserID: UUID) {
        var relations = loadBlockRelations()
        relations.removeAll {
            $0.blockerUserID == blockerUserID && $0.blockedUserID == blockedUserID
        }
        saveBlockRelations(relations)
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
        if normalizeIdentifier(user.profile.username) == normalizedIdentifier {
            return true
        }
        if normalizeIdentifier("@\(user.profile.username)") == normalizedIdentifier {
            return true
        }
        if normalizeIdentifier(user.profile.email ?? "") == normalizedIdentifier {
            return true
        }

        let normalizedPhoneIdentifier = normalizePhoneNumber(identifier)
        if normalizedPhoneIdentifier.isEmpty == false,
           normalizePhoneNumber(user.profile.phoneNumber ?? "") == normalizedPhoneIdentifier {
            return true
        }

        return false
    }

    private func resolvedRecord(
        for identifier: String,
        in records: [AccountRecord],
        requiredPassword: String?
    ) -> AccountRecord? {
        guard let index = resolvedRecordIndex(for: identifier, in: records, requiredPassword: requiredPassword) else {
            return nil
        }
        return records[index]
    }

    private func resolvedRecordIndex(
        for identifier: String,
        in records: [AccountRecord],
        requiredPassword: String?
    ) -> Int? {
        let normalizedIdentifier = normalizeIdentifier(identifier)
        let normalizedPhoneIdentifier = normalizePhoneNumber(identifier)
        let rawIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isExplicitUsername = rawIdentifier.hasPrefix("@")
        let isEmailIdentifier = rawIdentifier.contains("@") && rawIdentifier.contains(".")
        let isPhoneIdentifier = normalizedPhoneIdentifier.isEmpty == false && isEmailIdentifier == false

        var candidates: [(index: Int, rank: Int, createdAt: Date)] = []

        for (index, record) in records.enumerated() {
            if let requiredPassword, record.password != requiredPassword {
                continue
            }
            guard matchesIdentifier(record.user, identifier: normalizedIdentifier) else {
                continue
            }

            let profile = record.user.profile
            let username = normalizeUsername(profile.username)
            let email = normalizeOptionalEmail(profile.email)
            let phone = normalizeOptionalPhoneNumber(profile.phoneNumber)
            let normalizedUsernameInput = normalizeUsername(rawIdentifier.replacingOccurrences(of: "@", with: ""))

            var rank = 90

            if username == normalizedUsernameInput {
                rank = min(rank, isExplicitUsername ? 0 : 30)
            }
            if let email, email == rawIdentifier {
                rank = min(rank, isEmailIdentifier ? 5 : 35)
            }
            if let phone, phone == normalizedPhoneIdentifier {
                rank = min(rank, isPhoneIdentifier ? 10 : 40)
            }

            candidates.append((index: index, rank: rank, createdAt: record.user.createdAt))
        }

        guard candidates.isEmpty == false else {
            return nil
        }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.createdAt > rhs.createdAt
        }
        return sorted.first?.index
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

    private func appleUsernameSeed(givenName: String?, email: String?, appleUserID: String) -> String {
        let fromName = normalizeUsername(givenName ?? "")
        if fromName.count >= 5 {
            return fromName
        }

        if let email {
            let localPart = normalizeUsername(email.split(separator: "@").first.map(String.init) ?? "")
            if localPart.count >= 5 {
                return localPart
            }
        }

        let suffix = normalizeUsername(String(appleUserID.lowercased().prefix(12)))
        let candidate = "apple\(suffix)"
        return candidate.count >= 5 ? candidate : "appleuser"
    }

    private func nextAvailableUsername(seed: String, excluding userID: UUID?, records: [AccountRecord]) -> String {
        let normalizedSeed = normalizeUsername(seed)
        let baseRaw = normalizedSeed.isEmpty ? "appleuser" : normalizedSeed
        let base = baseRaw.count >= 5 ? String(baseRaw.prefix(20)) : "apple\(baseRaw)"

        func isTaken(_ candidate: String) -> Bool {
            if let reservedOwner = reservedUsernames[candidate], reservedOwner != userID {
                return true
            }
            return records.contains { record in
                guard record.user.profile.username == candidate else { return false }
                if let userID {
                    return record.user.id != userID
                }
                return true
            }
        }

        if isValidUsername(base), isTaken(base) == false {
            return base
        }

        for attempt in 0 ..< 1000 {
            let suffix = String(attempt)
            let limit = max(5, 32 - suffix.count)
            let prefix = String(base.prefix(limit))
            let candidate = "\(prefix)\(suffix)"
            if isValidUsername(candidate), isTaken(candidate) == false {
                return candidate
            }
        }

        let fallback = "apple\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10))"
        return String(fallback.prefix(32))
    }

    private func buildAppleDisplayName(givenName: String?, familyName: String?, email: String?) -> String {
        let trimmedGiven = givenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedFamily = familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullName = [trimmedGiven, trimmedFamily]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fullName.isEmpty == false {
            return fullName
        }

        if let email {
            let localPart = email.split(separator: "@").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if localPart.isEmpty == false {
                return localPart
            }
        }

        return "Apple User"
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
            let removedUserIDs = removedRecords.map(\.user.id)
            if removedUserIDs.isEmpty == false {
                removeBlockRelations(for: removedUserIDs)
            }
            saveRecords(filteredRecords)
        }

        return filteredRecords
    }

    private func saveRecords(_ records: [AccountRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: StorageKeys.records)
    }

    private func loadBlockRelations() -> [BlockRelation] {
        guard
            let data = defaults.data(forKey: StorageKeys.blockedRelations),
            let relations = try? decoder.decode([BlockRelation].self, from: data)
        else {
            return []
        }
        return relations
    }

    private func saveBlockRelations(_ relations: [BlockRelation]) {
        guard let data = try? encoder.encode(relations) else { return }
        defaults.set(data, forKey: StorageKeys.blockedRelations)
    }

    private func loadAppleIdentityLinks() -> [AppleIdentityLink] {
        guard
            let data = defaults.data(forKey: StorageKeys.appleIdentityLinks),
            let links = try? decoder.decode([AppleIdentityLink].self, from: data)
        else {
            return []
        }
        return links
    }

    private func saveAppleIdentityLinks(_ links: [AppleIdentityLink]) {
        guard let data = try? encoder.encode(links) else { return }
        defaults.set(data, forKey: StorageKeys.appleIdentityLinks)
    }

    private func removeBlockRelations(for userID: UUID) {
        removeBlockRelations(for: [userID])
    }

    private func removeBlockRelations(for userIDs: [UUID]) {
        guard userIDs.isEmpty == false else { return }
        let userIDSet = Set(userIDs)
        var relations = loadBlockRelations()
        relations.removeAll {
            userIDSet.contains($0.blockerUserID) || userIDSet.contains($0.blockedUserID)
        }
        saveBlockRelations(relations)
    }

    private func isBlockedBetween(_ lhs: UUID, _ rhs: UUID, relations: [BlockRelation]? = nil) -> Bool {
        let scope = relations ?? loadBlockRelations()
        return scope.contains {
            ($0.blockerUserID == lhs && $0.blockedUserID == rhs) ||
                ($0.blockerUserID == rhs && $0.blockedUserID == lhs)
        }
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

    private func purgeExpiredOTPChallenges() {
        let now = Date.now
        otpChallengesByID = otpChallengesByID.filter { _, record in
            if record.consumedAt != nil {
                return false
            }
            return record.expiresAt > now
        }
    }

    private func validateSignupOTPIfRequired(challengeID: String?, identifier: String) throws {
        guard let challengeID = challengeID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              challengeID.isEmpty == false else {
            throw LocalAuthError.otpRequired
        }
        guard var challenge = otpChallengesByID[challengeID] else {
            throw LocalAuthError.otpRequired
        }
        guard challenge.purpose == .signup else {
            throw LocalAuthError.otpRequired
        }
        guard challenge.identifier == normalizeIdentifier(identifier) else {
            throw LocalAuthError.invalidOTPCode
        }
        guard challenge.verifiedAt != nil, challenge.expiresAt > .now, challenge.consumedAt == nil else {
            throw LocalAuthError.invalidOTPCode
        }
        challenge.consumedAt = .now
        otpChallengesByID[challengeID] = challenge
    }

    private func validatePasswordResetOTPIfRequired(challengeID: String?, identifier: String) throws {
        guard let challengeID = challengeID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              challengeID.isEmpty == false else {
            throw LocalAuthError.otpRequired
        }
        guard var challenge = otpChallengesByID[challengeID] else {
            throw LocalAuthError.otpRequired
        }
        guard challenge.purpose == .resetPassword else {
            throw LocalAuthError.otpRequired
        }
        guard challenge.identifier == normalizeIdentifier(identifier) else {
            throw LocalAuthError.invalidOTPCode
        }
        guard challenge.verifiedAt != nil, challenge.expiresAt > .now, challenge.consumedAt == nil else {
            throw LocalAuthError.invalidOTPCode
        }
        challenge.consumedAt = .now
        otpChallengesByID[challengeID] = challenge
    }

    private func maskIdentifier(_ identifier: String) -> String {
        if identifier.contains("@") {
            let parts = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "***" }
            let prefix = String(parts[0].prefix(2))
            return "\(prefix)***@\(parts[1])"
        }
        if identifier.hasPrefix("+"), identifier.count > 4 {
            let prefix = String(identifier.prefix(3))
            let suffix = String(identifier.suffix(2))
            return "\(prefix)***\(suffix)"
        }
        return "***"
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
    case otpRequired
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
        case .otpRequired:
            return "OTP verification is required."
        case .guestLimitReached:
            return "Guest Mode is available only twice per month on this device."
        case .guestLimitedProfile:
            return "Guest Mode supports only a limited profile."
        }
    }
}
