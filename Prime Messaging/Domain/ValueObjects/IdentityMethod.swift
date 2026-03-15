import Foundation

struct IdentityMethod: Identifiable, Codable, Hashable {
    let id: UUID
    let type: IdentityMethodType
    let value: String
    let isVerified: Bool
    let isPubliclyDiscoverable: Bool

    init(
        id: UUID = UUID(),
        type: IdentityMethodType,
        value: String,
        isVerified: Bool,
        isPubliclyDiscoverable: Bool
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.isVerified = isVerified
        self.isPubliclyDiscoverable = isPubliclyDiscoverable
    }
}
