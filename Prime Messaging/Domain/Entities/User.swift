import Foundation

struct User: Identifiable, Codable, Equatable {
    let id: UUID
    var profile: Profile
    var identityMethods: [IdentityMethod]
    var privacySettings: PrivacySettings
    var accountKind: AccountKind
    var primePremium: PrimePremiumAccess
    var createdAt: Date
    var guestExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profile
        case identityMethods
        case privacySettings
        case accountKind
        case primePremium
        case createdAt
        case guestExpiresAt
    }

    nonisolated init(
        id: UUID,
        profile: Profile,
        identityMethods: [IdentityMethod],
        privacySettings: PrivacySettings,
        accountKind: AccountKind = .standard,
        primePremium: PrimePremiumAccess = .disabled,
        createdAt: Date = .now,
        guestExpiresAt: Date? = nil
    ) {
        self.id = id
        self.profile = profile
        self.identityMethods = identityMethods
        self.privacySettings = privacySettings
        self.accountKind = accountKind
        self.primePremium = primePremium
        self.createdAt = createdAt
        self.guestExpiresAt = guestExpiresAt
    }

    nonisolated static let mockCurrentUser = User(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        profile: Profile(
            displayName: "Prime User",
            username: "primeuser",
            bio: "",
            status: "Available",
            birthday: nil,
            email: nil,
            phoneNumber: nil,
            profilePhotoURL: nil,
            socialLink: nil
        ),
        identityMethods: [
            IdentityMethod(type: .username, value: "@primeuser", isVerified: true, isPubliclyDiscoverable: true)
        ],
        privacySettings: .defaultEmailOnly,
        accountKind: .standard
    )

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profile = try container.decode(Profile.self, forKey: .profile)
        identityMethods = try container.decodeIfPresent([IdentityMethod].self, forKey: .identityMethods) ?? []
        privacySettings = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacySettings) ?? .defaultEmailOnly
        accountKind = try container.decodeIfPresent(AccountKind.self, forKey: .accountKind) ?? .standard
        primePremium = try container.decodeIfPresent(PrimePremiumAccess.self, forKey: .primePremium) ?? .disabled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        guestExpiresAt = try container.decodeIfPresent(Date.self, forKey: .guestExpiresAt)
    }

    nonisolated var isGuest: Bool {
        accountKind == .guest
    }

    nonisolated var isOfflineOnly: Bool {
        accountKind == .offlineOnly
    }

    nonisolated var canUploadAvatar: Bool {
        accountKind != .guest
    }

    nonisolated var canEditAdvancedProfile: Bool {
        accountKind != .guest
    }

    nonisolated static func == (lhs: User, rhs: User) -> Bool {
        lhs.id == rhs.id
            && lhs.profile.displayName == rhs.profile.displayName
            && lhs.profile.username == rhs.profile.username
            && lhs.profile.bio == rhs.profile.bio
            && lhs.profile.status == rhs.profile.status
            && lhs.profile.birthday == rhs.profile.birthday
            && lhs.profile.email == rhs.profile.email
            && lhs.profile.phoneNumber == rhs.profile.phoneNumber
            && lhs.profile.profilePhotoURL == rhs.profile.profilePhotoURL
            && lhs.profile.socialLink == rhs.profile.socialLink
            && lhs.identityMethods.map(\.id) == rhs.identityMethods.map(\.id)
            && lhs.identityMethods.map(\.type) == rhs.identityMethods.map(\.type)
            && lhs.identityMethods.map(\.value) == rhs.identityMethods.map(\.value)
            && lhs.identityMethods.map(\.isVerified) == rhs.identityMethods.map(\.isVerified)
            && lhs.identityMethods.map(\.isPubliclyDiscoverable) == rhs.identityMethods.map(\.isPubliclyDiscoverable)
            && lhs.privacySettings.showEmail == rhs.privacySettings.showEmail
            && lhs.privacySettings.showPhoneNumber == rhs.privacySettings.showPhoneNumber
            && lhs.privacySettings.allowLastSeen == rhs.privacySettings.allowLastSeen
            && lhs.privacySettings.allowProfilePhoto == rhs.privacySettings.allowProfilePhoto
            && lhs.privacySettings.allowCallsFromNonContacts == rhs.privacySettings.allowCallsFromNonContacts
            && lhs.privacySettings.allowGroupInvitesFromNonContacts == rhs.privacySettings.allowGroupInvitesFromNonContacts
            && lhs.privacySettings.allowForwardLinkToProfile == rhs.privacySettings.allowForwardLinkToProfile
            && lhs.privacySettings.guestMessageRequests == rhs.privacySettings.guestMessageRequests
            && lhs.privacySettings.shareTypingStatus == rhs.privacySettings.shareTypingStatus
            && lhs.accountKind == rhs.accountKind
            && lhs.primePremium == rhs.primePremium
            && lhs.createdAt == rhs.createdAt
            && lhs.guestExpiresAt == rhs.guestExpiresAt
    }

}

struct PrimePremiumAccess: Codable, Equatable, Hashable, Sendable {
    var isEnabled: Bool
    var source: String?
    var grantedAt: Date?

    nonisolated static let disabled = PrimePremiumAccess(isEnabled: false, source: nil, grantedAt: nil)

    nonisolated static func == (lhs: PrimePremiumAccess, rhs: PrimePremiumAccess) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && lhs.source == rhs.source
            && lhs.grantedAt == rhs.grantedAt
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(isEnabled)
        hasher.combine(source)
        hasher.combine(grantedAt)
    }
}

struct Profile: Codable, Hashable {
    var displayName: String
    var username: String
    var bio: String
    var status: String
    var birthday: Date?
    var email: String?
    var phoneNumber: String?
    var profilePhotoURL: URL?
    var socialLink: URL?

    enum CodingKeys: String, CodingKey {
        case displayName
        case username
        case bio
        case status
        case birthday
        case email
        case phoneNumber
        case profilePhotoURL
        case socialLink
    }

    nonisolated init(
        displayName: String,
        username: String,
        bio: String,
        status: String,
        birthday: Date?,
        email: String?,
        phoneNumber: String?,
        profilePhotoURL: URL?,
        socialLink: URL?
    ) {
        self.displayName = displayName
        self.username = username
        self.bio = bio
        self.status = status
        self.birthday = birthday
        self.email = email
        self.phoneNumber = phoneNumber
        self.profilePhotoURL = profilePhotoURL
        self.socialLink = socialLink
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        username = try container.decode(String.self, forKey: .username)
        bio = try container.decode(String.self, forKey: .bio)
        status = try container.decode(String.self, forKey: .status)
        birthday = try container.decodeIfPresent(Date.self, forKey: .birthday)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phoneNumber = try container.decodeIfPresent(String.self, forKey: .phoneNumber)
        profilePhotoURL = container.decodeLossyURLIfPresent(forKey: .profilePhotoURL)
        socialLink = container.decodeLossyURLIfPresent(forKey: .socialLink)
    }

    nonisolated static func == (lhs: Profile, rhs: Profile) -> Bool {
        lhs.displayName == rhs.displayName
            && lhs.username == rhs.username
            && lhs.bio == rhs.bio
            && lhs.status == rhs.status
            && lhs.birthday == rhs.birthday
            && lhs.email == rhs.email
            && lhs.phoneNumber == rhs.phoneNumber
            && lhs.profilePhotoURL == rhs.profilePhotoURL
            && lhs.socialLink == rhs.socialLink
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(displayName)
        hasher.combine(username)
        hasher.combine(bio)
        hasher.combine(status)
        hasher.combine(birthday)
        hasher.combine(email)
        hasher.combine(phoneNumber)
        hasher.combine(profilePhotoURL)
        hasher.combine(socialLink)
    }
}

struct PrivacySettings: Codable, Hashable {
    var showEmail: Bool
    var showPhoneNumber: Bool
    var allowLastSeen: Bool
    var allowProfilePhoto: Bool
    var allowCallsFromNonContacts: Bool
    var allowGroupInvitesFromNonContacts: Bool
    var allowForwardLinkToProfile: Bool
    var guestMessageRequests: GuestMessageRequestPolicy
    var shareTypingStatus: Bool

    enum CodingKeys: String, CodingKey {
        case showEmail
        case showPhoneNumber
        case allowLastSeen
        case allowProfilePhoto
        case allowCallsFromNonContacts
        case allowGroupInvitesFromNonContacts
        case allowForwardLinkToProfile
        case guestMessageRequests
        case shareTypingStatus
    }

    nonisolated init(
        showEmail: Bool,
        showPhoneNumber: Bool,
        allowLastSeen: Bool,
        allowProfilePhoto: Bool,
        allowCallsFromNonContacts: Bool,
        allowGroupInvitesFromNonContacts: Bool,
        allowForwardLinkToProfile: Bool,
        guestMessageRequests: GuestMessageRequestPolicy,
        shareTypingStatus: Bool
    ) {
        self.showEmail = showEmail
        self.showPhoneNumber = showPhoneNumber
        self.allowLastSeen = allowLastSeen
        self.allowProfilePhoto = allowProfilePhoto
        self.allowCallsFromNonContacts = allowCallsFromNonContacts
        self.allowGroupInvitesFromNonContacts = allowGroupInvitesFromNonContacts
        self.allowForwardLinkToProfile = allowForwardLinkToProfile
        self.guestMessageRequests = guestMessageRequests
        self.shareTypingStatus = shareTypingStatus
    }

    nonisolated static let defaultEmailOnly = PrivacySettings(
        showEmail: true,
        showPhoneNumber: false,
        allowLastSeen: true,
        allowProfilePhoto: true,
        allowCallsFromNonContacts: false,
        allowGroupInvitesFromNonContacts: false,
        allowForwardLinkToProfile: false,
        guestMessageRequests: .approvalRequired,
        shareTypingStatus: true
    )

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showEmail = try container.decodeIfPresent(Bool.self, forKey: .showEmail) ?? true
        showPhoneNumber = try container.decodeIfPresent(Bool.self, forKey: .showPhoneNumber) ?? false
        allowLastSeen = try container.decodeIfPresent(Bool.self, forKey: .allowLastSeen) ?? true
        allowProfilePhoto = try container.decodeIfPresent(Bool.self, forKey: .allowProfilePhoto) ?? true
        allowCallsFromNonContacts = try container.decodeIfPresent(Bool.self, forKey: .allowCallsFromNonContacts) ?? false
        allowGroupInvitesFromNonContacts = try container.decodeIfPresent(Bool.self, forKey: .allowGroupInvitesFromNonContacts) ?? false
        allowForwardLinkToProfile = try container.decodeIfPresent(Bool.self, forKey: .allowForwardLinkToProfile) ?? false
        guestMessageRequests = try container.decodeIfPresent(GuestMessageRequestPolicy.self, forKey: .guestMessageRequests) ?? .approvalRequired
        shareTypingStatus = try container.decodeIfPresent(Bool.self, forKey: .shareTypingStatus) ?? true
    }

    nonisolated static func == (lhs: PrivacySettings, rhs: PrivacySettings) -> Bool {
        lhs.showEmail == rhs.showEmail
            && lhs.showPhoneNumber == rhs.showPhoneNumber
            && lhs.allowLastSeen == rhs.allowLastSeen
            && lhs.allowProfilePhoto == rhs.allowProfilePhoto
            && lhs.allowCallsFromNonContacts == rhs.allowCallsFromNonContacts
            && lhs.allowGroupInvitesFromNonContacts == rhs.allowGroupInvitesFromNonContacts
            && lhs.allowForwardLinkToProfile == rhs.allowForwardLinkToProfile
            && lhs.guestMessageRequests == rhs.guestMessageRequests
            && lhs.shareTypingStatus == rhs.shareTypingStatus
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(showEmail)
        hasher.combine(showPhoneNumber)
        hasher.combine(allowLastSeen)
        hasher.combine(allowProfilePhoto)
        hasher.combine(allowCallsFromNonContacts)
        hasher.combine(allowGroupInvitesFromNonContacts)
        hasher.combine(allowForwardLinkToProfile)
        hasher.combine(guestMessageRequests)
        hasher.combine(shareTypingStatus)
    }
}
