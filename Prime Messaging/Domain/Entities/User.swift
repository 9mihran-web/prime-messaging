import Foundation

struct User: Identifiable, Codable, Hashable {
    let id: UUID
    var profile: Profile
    var identityMethods: [IdentityMethod]
    var privacySettings: PrivacySettings
    var accountKind: AccountKind
    var createdAt: Date
    var guestExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profile
        case identityMethods
        case privacySettings
        case accountKind
        case createdAt
        case guestExpiresAt
    }

    init(
        id: UUID,
        profile: Profile,
        identityMethods: [IdentityMethod],
        privacySettings: PrivacySettings,
        accountKind: AccountKind = .standard,
        createdAt: Date = .now,
        guestExpiresAt: Date? = nil
    ) {
        self.id = id
        self.profile = profile
        self.identityMethods = identityMethods
        self.privacySettings = privacySettings
        self.accountKind = accountKind
        self.createdAt = createdAt
        self.guestExpiresAt = guestExpiresAt
    }

    static let mockCurrentUser = User(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        profile: Profile(
            displayName: "Prime User",
            username: "primeuser",
            bio: "Welcome to Prime Messaging.",
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

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profile = try container.decode(Profile.self, forKey: .profile)
        identityMethods = try container.decodeIfPresent([IdentityMethod].self, forKey: .identityMethods) ?? []
        privacySettings = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacySettings) ?? .defaultEmailOnly
        accountKind = try container.decodeIfPresent(AccountKind.self, forKey: .accountKind) ?? .standard
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        guestExpiresAt = try container.decodeIfPresent(Date.self, forKey: .guestExpiresAt)
    }

    var isGuest: Bool {
        accountKind == .guest
    }

    var isOfflineOnly: Bool {
        accountKind == .offlineOnly
    }

    var canUploadAvatar: Bool {
        accountKind != .guest
    }

    var canEditAdvancedProfile: Bool {
        accountKind != .guest
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

    init(
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

    init(from decoder: any Decoder) throws {
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

    enum CodingKeys: String, CodingKey {
        case showEmail
        case showPhoneNumber
        case allowLastSeen
        case allowProfilePhoto
        case allowCallsFromNonContacts
        case allowGroupInvitesFromNonContacts
        case allowForwardLinkToProfile
        case guestMessageRequests
    }

    init(
        showEmail: Bool,
        showPhoneNumber: Bool,
        allowLastSeen: Bool,
        allowProfilePhoto: Bool,
        allowCallsFromNonContacts: Bool,
        allowGroupInvitesFromNonContacts: Bool,
        allowForwardLinkToProfile: Bool,
        guestMessageRequests: GuestMessageRequestPolicy
    ) {
        self.showEmail = showEmail
        self.showPhoneNumber = showPhoneNumber
        self.allowLastSeen = allowLastSeen
        self.allowProfilePhoto = allowProfilePhoto
        self.allowCallsFromNonContacts = allowCallsFromNonContacts
        self.allowGroupInvitesFromNonContacts = allowGroupInvitesFromNonContacts
        self.allowForwardLinkToProfile = allowForwardLinkToProfile
        self.guestMessageRequests = guestMessageRequests
    }

    static let defaultEmailOnly = PrivacySettings(
        showEmail: true,
        showPhoneNumber: false,
        allowLastSeen: true,
        allowProfilePhoto: true,
        allowCallsFromNonContacts: false,
        allowGroupInvitesFromNonContacts: false,
        allowForwardLinkToProfile: false,
        guestMessageRequests: .approvalRequired
    )

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showEmail = try container.decodeIfPresent(Bool.self, forKey: .showEmail) ?? true
        showPhoneNumber = try container.decodeIfPresent(Bool.self, forKey: .showPhoneNumber) ?? false
        allowLastSeen = try container.decodeIfPresent(Bool.self, forKey: .allowLastSeen) ?? true
        allowProfilePhoto = try container.decodeIfPresent(Bool.self, forKey: .allowProfilePhoto) ?? true
        allowCallsFromNonContacts = try container.decodeIfPresent(Bool.self, forKey: .allowCallsFromNonContacts) ?? false
        allowGroupInvitesFromNonContacts = try container.decodeIfPresent(Bool.self, forKey: .allowGroupInvitesFromNonContacts) ?? false
        allowForwardLinkToProfile = try container.decodeIfPresent(Bool.self, forKey: .allowForwardLinkToProfile) ?? false
        guestMessageRequests = try container.decodeIfPresent(GuestMessageRequestPolicy.self, forKey: .guestMessageRequests) ?? .approvalRequired
    }
}
