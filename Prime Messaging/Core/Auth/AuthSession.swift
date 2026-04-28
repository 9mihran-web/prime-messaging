import Foundation

struct AuthSession: Codable, Hashable {
    let userID: UUID
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date
    var refreshTokenExpiresAt: Date
    var updatedAt: Date

    var shouldRefreshAccessToken: Bool {
        accessTokenExpiresAt <= Date().addingTimeInterval(60)
    }

    var isRefreshTokenValid: Bool {
        refreshTokenExpiresAt > Date().addingTimeInterval(60)
    }
}

struct AuthSessionPayload: Codable, Hashable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresAt: Date
    let refreshTokenExpiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessTokenExpiresAt = "access_token_expires_at"
        case refreshTokenExpiresAt = "refresh_token_expires_at"
    }
}

struct AuthenticatedSessionResponse: Decodable {
    let user: User
    let session: AuthSessionPayload?
    let isNewUser: Bool?

    enum CodingKeys: String, CodingKey {
        case user
        case session
        case isNewUser = "is_new_user"
    }

    init(user: User, session: AuthSessionPayload?, isNewUser: Bool? = nil) {
        self.user = user
        self.session = session
        self.isNewUser = isNewUser
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.user) {
            user = try container.decode(User.self, forKey: .user)
            session = try container.decodeIfPresent(AuthSessionPayload.self, forKey: .session)
            isNewUser = try container.decodeIfPresent(Bool.self, forKey: .isNewUser)
            return
        }

        user = try User(from: decoder)
        session = nil
        isNewUser = nil
    }

    func authSession() -> AuthSession? {
        guard let session else { return nil }
        return AuthSession(
            userID: user.id,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            accessTokenExpiresAt: session.accessTokenExpiresAt,
            refreshTokenExpiresAt: session.refreshTokenExpiresAt,
            updatedAt: .now
        )
    }
}
