import Foundation

enum AuthRepositoryError: LocalizedError {
    case invalidCredentials
    case accountNotFound
    case usernameTaken
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "auth.error.invalid_credentials".localized
        case .accountNotFound:
            return "auth.error.account_not_found".localized
        case .usernameTaken:
            return "onboarding.username.taken".localized
        case .backendUnavailable:
            return "auth.server.unavailable".localized
        }
    }
}

struct BackendAuthRepository: AuthRepository {
    let fallback: AuthRepository
    private let decoder = BackendAuthRepository.makeDecoder()

    func currentUser() async throws -> User {
        try await fallback.currentUser()
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType
    ) async throws -> User {
        let body = SignUpRequest(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType.rawValue
        )
        let payload: AuthenticatedSessionResponse = try await request(
            path: "/auth/signup",
            method: "POST",
            body: body,
            fallback: {
                let user = try await fallback.signUp(
                    displayName: displayName,
                    username: username,
                    password: password,
                    contactValue: contactValue,
                    methodType: methodType
                )
                return AuthenticatedSessionResponse(
                    user: user,
                    session: AuthSessionPayload(
                        accessToken: "",
                        refreshToken: "",
                        accessTokenExpiresAt: .distantFuture,
                        refreshTokenExpiresAt: .distantFuture
                    )
                )
            }
        )
        if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
            await BackendRequestTransport.storeAuthenticatedSession(from: payload)
        }
        await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: password)
        return payload.user
    }

    func logIn(identifier: String, password: String) async throws -> User {
        let body = LoginRequest(identifier: identifier, password: password)
        let payload: AuthenticatedSessionResponse = try await request(
            path: "/auth/login",
            method: "POST",
            body: body,
            fallback: {
                let user = try await fallback.logIn(identifier: identifier, password: password)
                return AuthenticatedSessionResponse(
                    user: user,
                    session: AuthSessionPayload(
                        accessToken: "",
                        refreshToken: "",
                        accessTokenExpiresAt: .distantFuture,
                        refreshTokenExpiresAt: .distantFuture
                    )
                )
            }
        )
        if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
            await BackendRequestTransport.storeAuthenticatedSession(from: payload)
        }
        await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: password)
        return payload.user
    }

    func refreshUser(userID: UUID) async throws -> User {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.refreshUser(userID: userID)
        }

        if await hasStoredSession(for: userID) {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/auth/me",
                method: "GET",
                userID: userID
            )
            try validate(response: response)
            return try decoder.decode(User.self, from: data)
        }

        return try await legacyFetchUser(baseURL: baseURL, userID: userID)
    }

    func userProfile(userID: UUID) async throws -> User {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.userProfile(userID: userID)
        }

        if let currentUserID = await currentAuthenticatedUserID() {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)",
                method: "GET",
                userID: currentUserID
            )
            try validate(response: response)
            return try decoder.decode(User.self, from: data)
        }

        return try await legacyFetchUser(baseURL: baseURL, userID: userID)
    }

    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User {
        let body = ProfileUpdateRequest(userID: userID, profile: profile)
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.updateProfile(profile, for: userID)
        }

        let bodyData = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/profile",
                method: "PATCH",
                body: bodyData,
                userID: userID
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/profile",
                method: "PATCH",
                body: bodyData
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        }
    }

    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User {
        let body = AvatarUploadRequest(userID: userID.uuidString, imageBase64: imageData.base64EncodedString())
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.uploadAvatar(imageData: imageData, for: userID)
        }

        let bodyData = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/avatar",
                method: "POST",
                body: bodyData,
                userID: userID
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/avatar",
                method: "POST",
                body: bodyData
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        }
    }

    func removeAvatar(for userID: UUID) async throws -> User {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.removeAvatar(for: userID)
        }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/avatar",
                method: "DELETE",
                userID: userID
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        } catch {
            let body = AvatarDeleteRequest(userID: userID.uuidString)
            let bodyData = try JSONEncoder().encode(body)
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/avatar",
                method: "DELETE",
                body: bodyData
            )
            try validate(response: response)
            let updatedUser = try decoder.decode(User.self, from: data)
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        }
    }

    func updatePassword(_ password: String, for userID: UUID) async throws {
        let body = PasswordUpdateRequest(userID: userID.uuidString, password: password)
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.updatePassword(password, for: userID)
            return
        }

        let bodyData = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/password",
                method: "PATCH",
                body: bodyData,
                userID: userID
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            try? await LocalAccountStore.shared.updatePassword(password, for: userID)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/password",
                method: "PATCH",
                body: bodyData
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            try? await LocalAccountStore.shared.updatePassword(password, for: userID)
        }
    }

    func searchUsers(query: String, excluding userID: UUID) async throws -> [User] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.searchUsers(query: query, excluding: userID)
        }

        guard var components = URLComponents(url: baseURL.appending(path: "/users/search"), resolvingAgainstBaseURL: false) else {
            return try await fallback.searchUsers(query: query, excluding: userID)
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "exclude_user_id", value: userID.uuidString)
        ]

        let queryItems = components.queryItems ?? []
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/search",
                method: "GET",
                queryItems: queryItems,
                userID: userID
            )
            try validate(response: response)
            return try decoder.decode([User].self, from: data)
        } catch {
            if await hasStoredSession(for: userID) {
                throw error
            }
        }

        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/users/search",
            method: "GET",
            queryItems: queryItems
        )
        try validate(response: response)
        return try decoder.decode([User].self, from: data)
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        fallback: (() async throws -> Response)?
    ) async throws -> Response {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            if let fallback {
                return try await fallback()
            }
            throw AuthRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw AuthRepositoryError.invalidCredentials
        case 404:
            throw AuthRepositoryError.accountNotFound
        case 409:
            throw AuthRepositoryError.usernameTaken
        default:
            throw AuthRepositoryError.backendUnavailable
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        BackendJSONDecoder.make()
    }

    private func hasStoredSession(for userID: UUID) async -> Bool {
        await AuthSessionStore.shared.session(for: userID) != nil
    }

    private func currentAuthenticatedUserID(defaults: UserDefaults = .standard) async -> UUID? {
        if let data = defaults.data(forKey: "app_state.current_user"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }

        if let session = await AuthSessionStore.shared.mostRecentSession() {
            return session.userID
        }

        return nil
    }

    private func legacyFetchUser(baseURL: URL, userID: UUID) async throws -> User {
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/users/\(userID.uuidString)",
            method: "GET"
        )
        try validate(response: response)
        return try decoder.decode(User.self, from: data)
    }

    private func legacyRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> (Data, URLResponse) {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AuthRepositoryError.backendUnavailable
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw AuthRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        return try await URLSession.shared.data(for: request)
    }
}

private struct SignUpRequest: Encodable {
    let displayName: String
    let username: String
    let password: String
    let contactValue: String
    let methodType: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case password
        case contactValue = "contact_value"
        case methodType = "method_type"
    }
}

private struct LoginRequest: Encodable {
    let identifier: String
    let password: String
}

private struct ProfileUpdateRequest: Encodable {
    let userID: String
    let displayName: String
    let username: String
    let bio: String
    let status: String
    let email: String?
    let phoneNumber: String?
    let profilePhotoURL: URL?
    let socialLink: URL?

    init(userID: UUID, profile: Profile) {
        self.userID = userID.uuidString
        displayName = profile.displayName
        username = profile.username
        bio = profile.bio
        status = profile.status
        email = profile.email
        phoneNumber = profile.phoneNumber
        profilePhotoURL = profile.profilePhotoURL
        socialLink = profile.socialLink
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case username
        case bio
        case status
        case email
        case phoneNumber = "phone_number"
        case profilePhotoURL = "profile_photo_url"
        case socialLink = "social_link"
    }
}

private struct AvatarUploadRequest: Encodable {
    let userID: String
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case imageBase64 = "image_base64"
    }
}

private struct AvatarDeleteRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private struct PasswordUpdateRequest: Encodable {
    let userID: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case password
    }
}

private struct BackendOKResponse: Decodable {
    let ok: Bool
}
