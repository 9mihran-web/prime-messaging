import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

enum BackendRequestTransport {
    private static let decoder = BackendJSONDecoder.make()
    private static let logger = Logger(subsystem: "mirowin.Prime-Messaging", category: "BackendRequestTransport")
    private static let requestTimeout: TimeInterval = 12
    private static let uploadRequestTimeout: TimeInterval = 180
    private static let stableDeviceIdentifierDefaultsKey = "push.device_identifier"

    static func authorizedRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = [],
        userID: UUID?,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .general,
        additionalHeaders: [String: String] = [:]
    ) async throws -> (Data, URLResponse) {
        let resolvedUserID = try await resolveUserID(explicitUserID: userID)
        let session = try await validSession(for: resolvedUserID, baseURL: baseURL)
        return try await performAuthorizedRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            contentType: body == nil ? nil : "application/json",
            queryItems: queryItems,
            accessToken: session.accessToken,
            userID: resolvedUserID,
            networkAccessKind: networkAccessKind,
            additionalHeaders: additionalHeaders
        )
    }

    static func authorizedUploadRequest(
        baseURL: URL,
        path: String,
        sourceFileURL: URL,
        method: String = "POST",
        queryItems: [URLQueryItem] = [],
        userID: UUID?,
        networkAccessKind: NetworkUsagePolicy.AccessKind = .mediaUploads,
        contentType: String,
        additionalHeaders: [String: String] = [:]
    ) async throws -> (Data, URLResponse) {
        let resolvedUserID = try await resolveUserID(explicitUserID: userID)
        let session = try await validSession(for: resolvedUserID, baseURL: baseURL)
        return try await performAuthorizedUploadRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            sourceFileURL: sourceFileURL,
            queryItems: queryItems,
            accessToken: session.accessToken,
            userID: resolvedUserID,
            networkAccessKind: networkAccessKind,
            contentType: contentType,
            additionalHeaders: additionalHeaders
        )
    }

    static func storeAuthenticatedSession(from response: AuthenticatedSessionResponse) async {
        guard let session = response.authSession() else { return }
        await AuthSessionStore.shared.upsert(session)
    }

    static func removeSession(for userID: UUID) async {
        await AuthSessionStore.shared.removeSession(for: userID)
    }

    private static func performAuthorizedRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        queryItems: [URLQueryItem],
        accessToken: String,
        userID: UUID,
        networkAccessKind: NetworkUsagePolicy.AccessKind,
        additionalHeaders: [String: String]
    ) async throws -> (Data, URLResponse) {
        let request = try makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            queryItems: queryItems,
            accessToken: accessToken,
            networkAccessKind: networkAccessKind,
            additionalHeaders: additionalHeaders,
            timeoutInterval: requestTimeout
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        guard httpResponse.statusCode == 401 else {
            return (data, response)
        }

        let refreshedSession = try await refreshSession(for: userID, baseURL: baseURL)
        let retryRequest = try makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            queryItems: queryItems,
            accessToken: refreshedSession.accessToken,
            networkAccessKind: networkAccessKind,
            additionalHeaders: additionalHeaders,
            timeoutInterval: requestTimeout
        )

        return try await URLSession.shared.data(for: retryRequest)
    }

    private static func performAuthorizedUploadRequest(
        baseURL: URL,
        path: String,
        method: String,
        sourceFileURL: URL,
        queryItems: [URLQueryItem],
        accessToken: String,
        userID: UUID,
        networkAccessKind: NetworkUsagePolicy.AccessKind,
        contentType: String,
        additionalHeaders: [String: String]
    ) async throws -> (Data, URLResponse) {
        let request = try makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: nil,
            contentType: contentType,
            queryItems: queryItems,
            accessToken: accessToken,
            networkAccessKind: networkAccessKind,
            additionalHeaders: additionalHeaders,
            timeoutInterval: uploadRequestTimeout
        )

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: sourceFileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        guard httpResponse.statusCode == 401 else {
            return (data, response)
        }

        let refreshedSession = try await refreshSession(for: userID, baseURL: baseURL)
        let retryRequest = try makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: nil,
            contentType: contentType,
            queryItems: queryItems,
            accessToken: refreshedSession.accessToken,
            networkAccessKind: networkAccessKind,
            additionalHeaders: additionalHeaders,
            timeoutInterval: uploadRequestTimeout
        )

        return try await URLSession.shared.upload(for: retryRequest, fromFile: sourceFileURL)
    }

    private static func makeRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        queryItems: [URLQueryItem],
        accessToken: String,
        networkAccessKind: NetworkUsagePolicy.AccessKind,
        additionalHeaders: [String: String],
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
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
        request.timeoutInterval = timeoutInterval
        request.allowsCellularAccess = NetworkUsagePolicy.allowsCellularAccess(for: networkAccessKind)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        applyDeviceHeaders(to: &request)
        for (header, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }
        return request
    }

    private static func validSession(for userID: UUID, baseURL: URL) async throws -> AuthSession {
        guard let session = await AuthSessionStore.shared.session(for: userID) else {
            if let restoredSession = try await restoreSessionIfPossible(for: userID, baseURL: baseURL) {
                return restoredSession
            }
            throw AuthRepositoryError.invalidCredentials
        }

        if session.shouldRefreshAccessToken {
            do {
                return try await refreshSession(for: userID, baseURL: baseURL)
            } catch let error as AuthRepositoryError {
                switch error {
                case .invalidCredentials, .accountNotFound:
                    break
                default:
                    throw error
                }
                if let restoredSession = try await restoreSessionIfPossible(for: userID, baseURL: baseURL) {
                    return restoredSession
                }
                if session.accessToken.isEmpty == false {
                    logger.error("auth.session.refresh_failed_preserving_local_session user=\(userID.uuidString, privacy: .public)")
                    return session
                }
                throw error
            } catch {
                logger.error("auth.session.refresh_temporarily_unavailable user=\(userID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return session
            }
        }

        return session
    }

    private static func refreshSession(for userID: UUID, baseURL: URL) async throws -> AuthSession {
        guard let session = await AuthSessionStore.shared.session(for: userID), session.isRefreshTokenValid else {
            throw AuthRepositoryError.invalidCredentials
        }

        let requestBody = RefreshSessionRequest(refreshToken: session.refreshToken)
        var request = URLRequest(url: baseURL.appending(path: "/auth/refresh"))
        request.timeoutInterval = requestTimeout
        request.allowsCellularAccess = true
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyDeviceHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            switch httpResponse.statusCode {
            case 401:
                throw AuthRepositoryError.invalidCredentials
            case 404:
                throw AuthRepositoryError.accountNotFound
            default:
                throw AuthRepositoryError.backendUnavailable
            }
        }

        let payload = try decoder.decode(AuthenticatedSessionResponse.self, from: data)
        guard let updatedSession = payload.authSession() else {
            throw AuthRepositoryError.invalidCredentials
        }
        guard updatedSession.userID == userID else {
            logger.error(
                "auth.refresh.identity_mismatch expected=\(userID.uuidString, privacy: .public) actual=\(updatedSession.userID.uuidString, privacy: .public)"
            )
            throw AuthRepositoryError.invalidCredentials
        }
        await AuthSessionStore.shared.upsert(updatedSession)
        return updatedSession
    }

    private static func resolveUserID(explicitUserID: UUID?) async throws -> UUID {
        if let explicitUserID {
            return explicitUserID
        }

        if let storedUserID = storedCurrentUserID() {
            return storedUserID
        }

        let sessions = await AuthSessionStore.shared.allSessions()
        if sessions.count == 1, let session = sessions.first {
            return session.userID
        }
        if sessions.count > 1 {
            logger.error("auth.resolve_user_id.ambiguous_sessions count=\(sessions.count, privacy: .public)")
        }

        throw AuthRepositoryError.invalidCredentials
    }

    private static func restoreSessionIfPossible(for userID: UUID, baseURL: URL) async throws -> AuthSession? {
        guard let recoveryAccount = await LocalAccountStore.shared.remoteRecoveryAccount(for: userID) else {
            return nil
        }

        for identifier in recoveryAccount.loginIdentifiers {
            let request = try makeJSONRequest(
                url: baseURL.appending(path: "/auth/login"),
                method: "POST",
                body: LoginRestoreRequest(
                    identifier: identifier,
                    password: recoveryAccount.password
                )
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthRepositoryError.backendUnavailable
            }

            switch httpResponse.statusCode {
            case 200 ..< 300:
                let payload = try decoder.decode(AuthenticatedSessionResponse.self, from: data)
                guard let restoredSession = payload.authSession() else {
                    continue
                }
                guard payload.user.id == userID, restoredSession.userID == userID else {
                    logger.error(
                        "auth.restore.identity_mismatch expected=\(userID.uuidString, privacy: .public) actual=\(payload.user.id.uuidString, privacy: .public)"
                    )
                    continue
                }
                await AuthSessionStore.shared.upsert(restoredSession)
                await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: recoveryAccount.password)
                return restoredSession
            case 401:
                throw AuthRepositoryError.invalidCredentials
            case 404:
                continue
            default:
                throw AuthRepositoryError.backendUnavailable
            }
        }

        let signUpRequest = SignUpRestoreRequest(
            userID: recoveryAccount.user.id,
            displayName: recoveryAccount.user.profile.displayName,
            username: recoveryAccount.user.profile.username,
            password: recoveryAccount.password,
            contactValue: recoveryAccount.contactValue,
            methodType: recoveryAccount.methodType.rawValue,
            accountKind: recoveryAccount.user.accountKind.rawValue
        )
        let request = try makeJSONRequest(
            url: baseURL.appending(path: "/auth/signup"),
            method: "POST",
            body: signUpRequest
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            switch httpResponse.statusCode {
            case 401:
                throw AuthRepositoryError.invalidCredentials
            case 404:
                throw AuthRepositoryError.accountNotFound
            default:
                throw AuthRepositoryError.backendUnavailable
            }
        }

        let payload = try decoder.decode(AuthenticatedSessionResponse.self, from: data)
        guard let restoredSession = payload.authSession() else {
            return nil
        }
        guard payload.user.id == userID, restoredSession.userID == userID else {
            logger.error(
                "auth.restore.signup.identity_mismatch expected=\(userID.uuidString, privacy: .public) actual=\(payload.user.id.uuidString, privacy: .public)"
            )
            throw AuthRepositoryError.invalidCredentials
        }
        await AuthSessionStore.shared.upsert(restoredSession)
        await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: recoveryAccount.password)
        return restoredSession
    }

    private static func makeJSONRequest<Body: Encodable>(url: URL, method: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.allowsCellularAccess = true
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyDeviceHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func applyDeviceHeaders(to request: inout URLRequest) {
        request.setValue(platformHeaderValue(), forHTTPHeaderField: "X-Prime-Platform")
        request.setValue(stableDeviceIdentifier(), forHTTPHeaderField: "X-Prime-Device-ID")
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            request.setValue(appVersion, forHTTPHeaderField: "X-Prime-App-Version")
        }
        #if canImport(UIKit)
        request.setValue(UIDevice.current.name, forHTTPHeaderField: "X-Prime-Device-Name")
        request.setValue(UIDevice.current.model, forHTTPHeaderField: "X-Prime-Device-Model")
        request.setValue(UIDevice.current.systemName, forHTTPHeaderField: "X-Prime-OS-Name")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Prime-OS-Version")
        #else
        request.setValue("Apple OS", forHTTPHeaderField: "X-Prime-OS-Name")
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Prime-OS-Version")
        #endif
    }

    private static func platformHeaderValue() -> String {
        #if os(tvOS)
        return "tvos"
        #elseif os(iOS)
        return "ios"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    private static func stableDeviceIdentifier(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: stableDeviceIdentifierDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            existing.isEmpty == false {
            return existing
        }

        let fallback = UUID().uuidString
        #if canImport(UIKit)
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? fallback
        #else
        let generated = fallback
        #endif
        defaults.set(generated, forKey: stableDeviceIdentifierDefaultsKey)
        return generated
    }

    private static func storedCurrentUserID(defaults: UserDefaults = .standard) -> UUID? {
        guard let data = defaults.data(forKey: "app_state.current_user") else {
            return nil
        }

        return try? JSONDecoder().decode(User.self, from: data).id
    }
}

private struct RefreshSessionRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct LoginRestoreRequest: Encodable {
    let identifier: String
    let password: String
}

private struct SignUpRestoreRequest: Encodable {
    let userID: UUID
    let displayName: String
    let username: String
    let password: String
    let contactValue: String
    let methodType: String
    let accountKind: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case username
        case password
        case contactValue = "contact_value"
        case methodType = "method_type"
        case accountKind = "account_kind"
    }
}
