import Foundation

struct IdentityMethod: Identifiable, Codable, Hashable {
    let id: UUID
    let type: IdentityMethodType
    let value: String
    let isVerified: Bool
    let isPubliclyDiscoverable: Bool

    nonisolated init(
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

    nonisolated static func == (lhs: IdentityMethod, rhs: IdentityMethod) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.value == rhs.value
            && lhs.isVerified == rhs.isVerified
            && lhs.isPubliclyDiscoverable == rhs.isPubliclyDiscoverable
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(value)
        hasher.combine(isVerified)
        hasher.combine(isPubliclyDiscoverable)
    }
}
