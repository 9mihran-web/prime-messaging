import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AuthRepositoryError: LocalizedError {
    case invalidCredentials
    case accountNotFound
    case usernameTaken
    case backendUnavailable
    case accountAlreadyExists
    case invalidOTPCode
    case invalidPhoneNumber
    case invalidEmail
    case guestLimitReached
    case guestLimitedProfile
    case accountBanned

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
        case .accountAlreadyExists:
            return "An account with this phone number or e-mail already exists."
        case .invalidOTPCode:
            return "Use 000000 as the temporary OTP code."
        case .invalidPhoneNumber:
            return "Enter the phone number in international format, for example +37499111222."
        case .invalidEmail:
            return "Enter a valid e-mail address."
        case .guestLimitReached:
            return "Guest Mode is available only twice per month on this device."
        case .guestLimitedProfile:
            return "Guest Mode supports only a limited profile."
        case .accountBanned:
            return "This account is temporarily banned."
        }
    }
}

struct BackendAuthRepository: AuthRepository {
    let fallback: AuthRepository
    private let decoder = BackendAuthRepository.makeDecoder()
    private let encoder = BackendAuthRepository.makeEncoder()

    func currentUser() async throws -> User {
        try await fallback.currentUser()
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType,
        accountKind: AccountKind
    ) async throws -> User {
        let body = SignUpRequest(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType.rawValue,
            accountKind: accountKind.rawValue
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
                    methodType: methodType,
                    accountKind: accountKind
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

    func lookupAccount(identifier: String) async throws -> AccountLookupResult {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = AccountLookupRequest(identifier: normalizedIdentifier)
        return try await request(
            path: "/auth/account-lookup",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.lookupAccount(identifier: normalizedIdentifier)
            }
        )
    }

    func authenticate(identifier: String, otpCode: String) async throws -> User? {
        let body = OTPLoginRequest(identifier: identifier, otpCode: otpCode)
        do {
            let payload: AuthenticatedSessionResponse = try await request(
                path: "/auth/otp-login",
                method: "POST",
                body: body,
                fallback: {
                    if let user = try await fallback.authenticate(identifier: identifier, otpCode: otpCode) {
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
                    throw AuthRepositoryError.accountNotFound
                }
            )
            if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
                await BackendRequestTransport.storeAuthenticatedSession(from: payload)
            }
            await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: otpCode)
            return payload.user
        } catch AuthRepositoryError.accountNotFound {
            return nil
        } catch {
            if let user = try await fallback.authenticate(identifier: identifier, otpCode: otpCode) {
                return user
            }
            throw error
        }
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

    func resetPassword(identifier: String, newPassword: String) async throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ResetPasswordRequest(identifier: normalizedIdentifier, password: trimmedPassword)

        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword)
            return
        }

        let bodyData = try encoder.encode(body)
        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/auth/reset-password",
                method: "POST",
                body: bodyData
            )
            try validate(response: response, data: data)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            try? await LocalAccountStore.shared.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword)
        } catch {
            try await fallback.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword)
        }
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

        return try await legacyFetchUser(baseURL: baseURL, userID: userID, viewerID: userID)
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

        return try await legacyFetchUser(
            baseURL: baseURL,
            userID: userID,
            viewerID: await currentAuthenticatedUserID()
        )
    }

    func updateProfile(_ profile: Profile, for userID: UUID) async throws -> User {
        let body = ProfileUpdateRequest(userID: userID, profile: profile)
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.updateProfile(profile, for: userID)
        }

        let bodyData = try encoder.encode(body)
        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/profile",
                method: "PATCH",
                body: bodyData,
                userID: userID
            )
            try validate(response: response)
            let updatedUser = mergeProfileFallbacks(
                into: try decoder.decode(User.self, from: data),
                submittedProfile: profile
            )
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
            let updatedUser = mergeProfileFallbacks(
                into: try decoder.decode(User.self, from: data),
                submittedProfile: profile
            )
            await LocalAccountStore.shared.upsertRemoteUser(updatedUser)
            return updatedUser
        }
    }

    func uploadAvatar(imageData: Data, for userID: UUID) async throws -> User {
        let body = AvatarUploadRequest(userID: userID.uuidString, imageBase64: imageData.base64EncodedString())
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.uploadAvatar(imageData: imageData, for: userID)
        }

        let bodyData = try encoder.encode(body)
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
            let bodyData = try encoder.encode(body)
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

        let bodyData = try encoder.encode(body)
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

    func deleteAccount(userID: UUID) async throws {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.deleteAccount(userID: userID)
            return
        }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)",
                method: "DELETE",
                userID: userID
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            await BackendRequestTransport.removeSession(for: userID)
            try? await LocalAccountStore.shared.deleteAccount(userID: userID)
        } catch {
            let body = AccountDeleteRequest(userID: userID.uuidString)
            let bodyData = try encoder.encode(body)
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)",
                method: "DELETE",
                body: bodyData
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            await BackendRequestTransport.removeSession(for: userID)
            try? await LocalAccountStore.shared.deleteAccount(userID: userID)
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
        applyDeviceHeaders(to: &request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRepositoryError.backendUnavailable
        }

        switch httpResponse.statusCode {
        case 200 ..< 300:
            return
        case 401:
            if let errorCode = backendErrorCode(from: data), errorCode == "invalid_otp" {
                throw AuthRepositoryError.invalidOTPCode
            }
            throw AuthRepositoryError.invalidCredentials
        case 403:
            switch backendErrorCode(from: data) {
            case "guest_limited_profile":
                throw AuthRepositoryError.guestLimitedProfile
            case "account_banned":
                throw AuthRepositoryError.accountBanned
            default:
                throw AuthRepositoryError.invalidCredentials
            }
        case 404:
            throw AuthRepositoryError.accountNotFound
        case 409:
            switch backendErrorCode(from: data) {
            case "username_taken":
                throw AuthRepositoryError.usernameTaken
            case "phone_taken", "email_taken", "user_id_taken":
                throw AuthRepositoryError.accountAlreadyExists
            case "invalid_phone_number":
                throw AuthRepositoryError.invalidPhoneNumber
            case "invalid_email":
                throw AuthRepositoryError.invalidEmail
            case "guest_limit_reached":
                throw AuthRepositoryError.guestLimitReached
            default:
                throw AuthRepositoryError.usernameTaken
            }
        default:
            throw AuthRepositoryError.backendUnavailable
        }
    }

    private func mergeProfileFallbacks(into user: User, submittedProfile: Profile) -> User {
        var mergedUser = user

        if mergedUser.profile.birthday == nil, let submittedBirthday = submittedProfile.birthday {
            mergedUser.profile.birthday = submittedBirthday
        }

        return mergedUser
    }

    private static func makeDecoder() -> JSONDecoder {
        BackendJSONDecoder.make()
    }

    private static func makeEncoder() -> JSONEncoder {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private func backendErrorCode(from data: Data?) -> String? {
        guard let data else { return nil }
        return (try? JSONDecoder().decode(BackendErrorPayload.self, from: data))?.error
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

    private func legacyFetchUser(baseURL: URL, userID: UUID, viewerID: UUID? = nil) async throws -> User {
        let (data, response) = try await legacyRequest(
            baseURL: baseURL,
            path: "/users/\(userID.uuidString)",
            method: "GET",
            queryItems: viewerID.map { [URLQueryItem(name: "viewer_id", value: $0.uuidString)] } ?? []
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
        request.timeoutInterval = 12
        request.httpMethod = method
        applyDeviceHeaders(to: &request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        return try await URLSession.shared.data(for: request)
    }

    private func applyDeviceHeaders(to request: inout URLRequest) {
        request.setValue(devicePlatform(), forHTTPHeaderField: "X-Prime-Platform")
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

    private func devicePlatform() -> String {
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
}

private struct BackendErrorPayload: Decodable {
    let error: String
}

private struct SignUpRequest: Encodable {
    let displayName: String
    let username: String
    let password: String
    let contactValue: String
    let methodType: String
    let accountKind: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case password
        case contactValue = "contact_value"
        case methodType = "method_type"
        case accountKind = "account_kind"
    }
}

private struct LoginRequest: Encodable {
    let identifier: String
    let password: String
}

private struct AccountLookupRequest: Encodable {
    let identifier: String
}

private struct ResetPasswordRequest: Encodable {
    let identifier: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case identifier
        case password = "new_password"
    }
}

private struct OTPLoginRequest: Encodable {
    let identifier: String
    let otpCode: String

    enum CodingKeys: String, CodingKey {
        case identifier
        case otpCode = "otp_code"
    }
}

private struct ProfileUpdateRequest: Encodable {
    let userID: String
    let displayName: String
    let username: String
    let bio: String
    let status: String
    let birthday: String?
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
        birthday = profile.birthday.map(Self.makeBirthdayString(from:))
        email = profile.email
        phoneNumber = profile.phoneNumber
        profilePhotoURL = profile.profilePhotoURL
        socialLink = profile.socialLink
    }

    nonisolated private static func makeBirthdayString(from date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case username
        case bio
        case status
        case birthday
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

private struct AccountDeleteRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private struct BackendOKResponse: Decodable {
    let ok: Bool
}
