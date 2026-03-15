import Foundation

struct BackendSettingsRepository: SettingsRepository {
    let fallback: SettingsRepository

    func fetchPrivacySettings() async throws -> PrivacySettings {
        try await fallback.fetchPrivacySettings()
    }

    func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        try await fallback.updatePrivacySettings(settings)
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
