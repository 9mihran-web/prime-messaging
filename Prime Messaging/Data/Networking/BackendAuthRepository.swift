import Foundation

struct BackendAuthRepository: AuthRepository {
    let fallback: AuthRepository

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
        let user: User = try await request(
            path: "/auth/signup",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.signUp(
                    displayName: displayName,
                    username: username,
                    password: password,
                    contactValue: contactValue,
                    methodType: methodType
                )
            }
        )
        return user
    }

    func logIn(identifier: String, password: String) async throws -> User {
        let body = LoginRequest(identifier: identifier, password: password)
        let user: User = try await request(
            path: "/auth/login",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.logIn(identifier: identifier, password: password)
            }
        )
        return user
    }

    func refreshUser(userID: UUID) async throws -> User {
        let user: User = try await request(
            path: "/users/\(userID.uuidString)",
            method: "GET",
            body: Optional<String>.none,
            fallback: {
                try await fallback.refreshUser(userID: userID)
            }
        )
        return user
    }

    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User {
        let body = ProfileUpdateRequest(profile: profile)
        let user: User = try await request(
            path: "/users/\(userID.uuidString)/profile",
            method: "PATCH",
            body: body,
            fallback: {
                try await fallback.updateProfile(profile, for: userID)
            }
        )
        return user
    }

    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User {
        let body = AvatarUploadRequest(imageBase64: imageData.base64EncodedString())
        let user: User = try await request(
            path: "/users/\(userID.uuidString)/avatar",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.uploadAvatar(imageData: imageData, for: userID)
            }
        )
        return user
    }

    func searchUsers(query: String, excluding userID: UUID) async throws -> [User] {
        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            var components = URLComponents(url: baseURL.appending(path: "/users/search"), resolvingAgainstBaseURL: false)
        else {
            return try await fallback.searchUsers(query: query, excluding: userID)
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "exclude_user_id", value: userID.uuidString)
        ]

        guard let url = components.url else {
            return try await fallback.searchUsers(query: query, excluding: userID)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response)
            return try JSONDecoder().decode([User].self, from: data)
        } catch {
            return try await fallback.searchUsers(query: query, excluding: userID)
        }
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
            throw UsernameRepositoryError.backendUnavailable
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
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            if let fallback {
                return try await fallback()
            }
            throw error
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
            throw UsernameRepositoryError.backendUnavailable
        }
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
    let displayName: String
    let username: String
    let bio: String
    let status: String
    let email: String?
    let phoneNumber: String?
    let profilePhotoURL: URL?
    let socialLink: URL?

    init(profile: Profile) {
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
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
    }
}
