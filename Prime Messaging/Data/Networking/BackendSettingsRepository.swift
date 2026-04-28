import Foundation

struct BackendSettingsRepository: SettingsRepository {
    let fallback: SettingsRepository

    func fetchPrivacySettings() async throws -> PrivacySettings {
        guard let baseURL = BackendConfiguration.currentBaseURL, let currentUserID = await resolvedCurrentUserID() else {
            return try await fallback.fetchPrivacySettings()
        }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(currentUserID.uuidString)/privacy",
                method: "GET",
                userID: currentUserID
            )
            try validatePrivacy(response: response)
            return try JSONDecoder().decode(PrivacySettings.self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(currentUserID.uuidString)/privacy",
                method: "GET",
                queryItems: [URLQueryItem(name: "user_id", value: currentUserID.uuidString)]
            )
            try validatePrivacy(response: response)
            return try JSONDecoder().decode(PrivacySettings.self, from: data)
        }
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        guard let baseURL = BackendConfiguration.currentBaseURL, let currentUserID = await resolvedCurrentUserID() else {
            try await fallback.updatePrivacySettings(settings)
            return
        }

        let body = PrivacySettingsUpdateRequest(userID: currentUserID.uuidString, privacySettings: settings)
        let bodyData = try JSONEncoder().encode(body)

        do {
            let (_, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(currentUserID.uuidString)/privacy",
                method: "PATCH",
                body: bodyData,
                userID: currentUserID
            )
            try validatePrivacy(response: response)
        } catch {
            let (_, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(currentUserID.uuidString)/privacy",
                method: "PATCH",
                body: bodyData
            )
            try validatePrivacy(response: response)
        }
    }

    func isUsernameAvailable(_ username: String, for userID: UUID?) async throws -> Bool {
        guard
            let baseURL = BackendConfiguration.currentBaseURL,
            var components = URLComponents(url: baseURL.appending(path: "/usernames/check"), resolvingAgainstBaseURL: false)
        else {
            return try await fallback.isUsernameAvailable(username, for: userID)
        }

        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "user_id", value: userID?.uuidString)
        ]

        guard let url = components.url else {
            return try await fallback.isUsernameAvailable(username, for: userID)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response)
            let payload = try JSONDecoder().decode(UsernameAvailabilityResponse.self, from: data)
            return payload.available
        } catch {
            return try await fallback.isUsernameAvailable(username, for: userID)
        }
    }

    func claimUsername(_ username: String, for userID: UUID) async throws {
        let requestBody = UsernameClaimRequest(userID: userID.uuidString, username: username)
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.claimUsername(username, for: userID)
            return
        }

        var request = URLRequest(url: baseURL.appending(path: "/usernames/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
        } catch {
            try await fallback.claimUsername(username, for: userID)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsernameRepositoryError.backendUnavailable
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            return
        case 409:
            throw UsernameRepositoryError.usernameTaken
        default:
            throw UsernameRepositoryError.backendUnavailable
        }
    }

    private func validatePrivacy(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsernameRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw UsernameRepositoryError.backendUnavailable
        }
    }

    private func legacyRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> (Data, URLResponse) {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw UsernameRepositoryError.backendUnavailable
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw UsernameRepositoryError.backendUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await URLSession.shared.data(for: request)
    }

    private func resolvedCurrentUserID(defaults: UserDefaults = .standard) async -> UUID? {
        if let data = defaults.data(forKey: "app_state.current_user"),
           let currentUser = try? JSONDecoder().decode(User.self, from: data) {
            return currentUser.id
        }

        let sessions = await AuthSessionStore.shared.allSessions()
        if sessions.count == 1, let session = sessions.first {
            return session.userID
        }

        return nil
    }
}

private struct UsernameAvailabilityResponse: Decodable {
    let available: Bool
}

private struct UsernameClaimRequest: Encodable {
    let userID: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
    }
}

private struct PrivacySettingsUpdateRequest: Encodable {
    let userID: String
    let privacySettings: PrivacySettings

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case privacySettings = "privacy_settings"
    }
}
