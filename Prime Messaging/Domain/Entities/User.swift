import Foundation

struct User: Identifiable, Codable, Hashable {
    let id: UUID
    var profile: Profile
    var identityMethods: [IdentityMethod]
    var privacySettings: PrivacySettings

    static let mockCurrentUser = User(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
        profile: Profile(
            displayName: "Prime User",
            username: "primeuser",
            bio: "Welcome to Prime Messaging.",
            status: "Available",
            email: nil,
            phoneNumber: nil,
            profilePhotoURL: nil,
            socialLink: nil
        ),
        identityMethods: [
            IdentityMethod(type: .username, value: "@primeuser", isVerified: true, isPubliclyDiscoverable: true)
        ],
        privacySettings: .defaultEmailOnly
    )
}

struct Profile: Codable, Hashable {
    var displayName: String
    var username: String
    var bio: String
    var status: String
    var email: String?
    var phoneNumber: String?
    var profilePhotoURL: URL?
    var socialLink: URL?
}

struct PrivacySettings: Codable, Hashable {
    var showEmail: Bool
    var showPhoneNumber: Bool
    var allowLastSeen: Bool
    var allowProfilePhoto: Bool
    var allowCallsFromNonContacts: Bool
    var allowGroupInvitesFromNonContacts: Bool
    var allowForwardLinkToProfile: Bool

    static let defaultEmailOnly = PrivacySettings(
        showEmail: true,
        showPhoneNumber: false,
        allowLastSeen: true,
        allowProfilePhoto: true,
        allowCallsFromNonContacts: false,
        allowGroupInvitesFromNonContacts: false,
        allowForwardLinkToProfile: false
    )
}
