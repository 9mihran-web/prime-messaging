import Foundation

struct BackendPresenceRepository: PresenceRepository {
    let fallback: PresenceRepository
    private let decoder = BackendJSONDecoder.make()

    func fetchPresence(for userID: UUID) async throws -> Presence {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchPresence(for: userID)
        }

        guard let activeUserID = await currentAuthenticatedUserID() else {
            return try await fallback.fetchPresence(for: userID)
        }

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/presence/\(userID.uuidString)",
            method: "GET",
            userID: activeUserID
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        return try decoder.decode(Presence.self, from: data)
    }

    private func currentAuthenticatedUserID(defaults: UserDefaults = .standard) async -> UUID? {
        if let data = defaults.data(forKey: "app_state.current_user"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }

        return await AuthSessionStore.shared.mostRecentSession()?.userID
    }
}
