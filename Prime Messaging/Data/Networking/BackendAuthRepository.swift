import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AuthRepositoryError: LocalizedError {
    case invalidCredentials
    case accountNotFound
    case usernameTaken
    case invalidUsername
    case backendUnavailable
    case accountAlreadyExists
    case invalidOTPCode
    case invalidPhoneNumber
    case invalidEmail
    case otpRequired
    case otpExpired
    case otpAttemptsExceeded
    case otpResendCooldown(seconds: Int)
    case otpDeliveryFailed(reason: String?)
    case guestLimitReached
    case guestLimitedProfile
    case accountBanned
    case appleSignInFailed
    case appleIdentityTaken
    case currentPasswordRequired

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "auth.error.invalid_credentials".localized
        case .accountNotFound:
            return "auth.error.account_not_found".localized
        case .usernameTaken:
            return "onboarding.username.taken".localized
        case .invalidUsername:
            return "Current username format is invalid. Update username in Profile."
        case .backendUnavailable:
            return "auth.server.unavailable".localized
        case .accountAlreadyExists:
            return "An account with this e-mail already exists."
        case .invalidOTPCode:
            return "Use 000000 as the temporary OTP code."
        case .invalidPhoneNumber:
            return "Enter the phone number in international format, for example +37499111222."
        case .invalidEmail:
            return "Enter a valid e-mail address."
        case .otpRequired:
            return "OTP verification is required."
        case .otpExpired:
            return "OTP code expired. Request a new one."
        case .otpAttemptsExceeded:
            return "Too many OTP attempts. Request a new code."
        case .otpResendCooldown(let seconds):
            return "Please wait \(max(1, seconds))s before requesting a new OTP."
        case .otpDeliveryFailed(let reason):
            switch reason {
            case "sendgrid_sender_not_verified":
                return "OTP sender e-mail is not verified in SendGrid. Verify sender identity and try again."
            case "sendgrid_auth_failed":
                return "SendGrid authorization failed. Check API key and Mail Send permission."
            case "sendgrid_rate_limited":
                return "OTP provider is rate limited right now. Please retry in a minute."
            case "sendgrid_unavailable":
                return "SendGrid is temporarily unavailable. Please retry shortly."
            case "otp_provider_not_configured":
                return "OTP provider is not configured on the server."
            case "httpx_not_installed":
                return "Server is missing OTP transport dependency."
            case "otp_channel_not_supported":
                return "OTP channel is not supported for this identifier."
            default:
                return "OTP delivery failed. Please try again in a minute."
            }
        case .guestLimitReached:
            return "Guest Mode is available only twice per month on this device."
        case .guestLimitedProfile:
            return "Guest Mode supports only a limited profile."
        case .accountBanned:
            return "This account is temporarily banned."
        case .appleSignInFailed:
            return "Sign in with Apple failed. Please try again."
        case .appleIdentityTaken:
            return "This Apple ID is already linked to another Prime account."
        case .currentPasswordRequired:
            return "Enter current password."
        }
    }
}

struct BackendAuthRepository: AuthRepository {
    let fallback: AuthRepository
    private let decoder = BackendAuthRepository.makeDecoder()
    private let encoder = BackendAuthRepository.makeEncoder()
    private let stableDeviceIdentifierDefaultsKey = "push.device_identifier"

    func currentUser() async throws -> User {
        try await fallback.currentUser()
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String?,
        appleUserID: String,
        email: String?,
        givenName: String?,
        familyName: String?
    ) async throws -> AppleSignInResult {
        let body = AppleSignInRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            appleUserID: appleUserID,
            email: email,
            givenName: givenName,
            familyName: familyName
        )
        let payload: AuthenticatedSessionResponse = try await request(
            path: "/auth/apple-signin",
            method: "POST",
            body: body,
            fallback: {
                let result = try await fallback.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    appleUserID: appleUserID,
                    email: email,
                    givenName: givenName,
                    familyName: familyName
                )
                return AuthenticatedSessionResponse(
                    user: result.user,
                    session: AuthSessionPayload(
                        accessToken: "",
                        refreshToken: "",
                        accessTokenExpiresAt: .distantFuture,
                        refreshTokenExpiresAt: .distantFuture
                    ),
                    isNewUser: result.isNewUser
                )
            }
        )
        if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
            await BackendRequestTransport.storeAuthenticatedSession(from: payload)
        }
        let preservedPassword = await LocalAccountStore.shared.credentials(for: payload.user.id)?.password
            ?? "apple-signin-\(UUID().uuidString.lowercased())"
        await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: preservedPassword)
        return AppleSignInResult(user: payload.user, isNewUser: payload.isNewUser ?? false)
    }

    func matchDeviceContacts(
        _ contacts: [DeviceContactCandidate],
        currentUserID: UUID
    ) async throws -> [MatchedDeviceContact] {
        guard contacts.isEmpty == false else { return [] }
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.matchDeviceContacts(contacts, currentUserID: currentUserID)
        }

        let chunkSize = 250
        var allMatches: [MatchedDeviceContact] = []
        var start = 0

        while start < contacts.count {
            let end = min(start + chunkSize, contacts.count)
            let chunk = Array(contacts[start..<end])
            start = end

            let body = ContactsMatchRequest(contacts: chunk)
            let bodyData = try await Self.encodeContactsMatchRequest(body)

            do {
                let (data, response) = try await BackendRequestTransport.authorizedRequest(
                    baseURL: baseURL,
                    path: "/contacts/match",
                    method: "POST",
                    body: bodyData,
                    userID: currentUserID
                )
                try validate(response: response, data: data)
                let payload = try decoder.decode(ContactsMatchResponse.self, from: data)
                allMatches.append(contentsOf: payload.matches)
            } catch {
                if await hasStoredSession(for: currentUserID) {
                    throw error
                }
                return try await fallback.matchDeviceContacts(contacts, currentUserID: currentUserID)
            }
        }

        var deduped: [String: MatchedDeviceContact] = [:]
        for match in allMatches where deduped[match.localContactID] == nil {
            deduped[match.localContactID] = match
        }
        return Array(deduped.values)
    }

    private static func encodeContactsMatchRequest(_ request: ContactsMatchRequest) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(request)
    }

    func signUp(
        displayName: String,
        username: String,
        password: String,
        contactValue: String,
        methodType: IdentityMethodType,
        accountKind: AccountKind,
        otpChallengeID: String?,
        signupEmail: String?
    ) async throws -> User {
        let body = SignUpRequest(
            displayName: displayName,
            username: username,
            password: password,
            contactValue: contactValue,
            methodType: methodType.rawValue,
            accountKind: accountKind.rawValue,
            otpChallengeID: otpChallengeID,
            signupEmail: signupEmail
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
                    accountKind: accountKind,
                    otpChallengeID: otpChallengeID,
                    signupEmail: signupEmail
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

    func requestOTP(identifier: String, purpose: OTPPurpose) async throws -> OTPChallenge {
        let body = OTPRequestPayload(identifier: identifier, purpose: purpose.rawValue)
        return try await request(
            path: "/auth/otp/request",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.requestOTP(identifier: identifier, purpose: purpose)
            }
        )
    }

    func verifyOTPChallenge(challengeID: String, otpCode: String) async throws -> OTPChallenge {
        let body = OTPVerifyPayload(challengeID: challengeID, otpCode: otpCode)
        return try await request(
            path: "/auth/otp/verify",
            method: "POST",
            body: body,
            fallback: {
                try await fallback.verifyOTPChallenge(challengeID: challengeID, otpCode: otpCode)
            }
        )
    }

    func authenticate(identifier: String, otpCode: String, challengeID: String?) async throws -> User? {
        let body = OTPLoginRequest(identifier: identifier, otpCode: otpCode, challengeID: challengeID)
        do {
            let payload: AuthenticatedSessionResponse = try await request(
                path: "/auth/otp-login",
                method: "POST",
                body: body,
                fallback: {
                    if let user = try await fallback.authenticate(
                        identifier: identifier,
                        otpCode: otpCode,
                        challengeID: challengeID
                    ) {
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
            try validateAuthenticatedIdentity(payload.user, for: identifier)
            if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
                await BackendRequestTransport.storeAuthenticatedSession(from: payload)
            }
            let preservedPassword = await LocalAccountStore.shared.credentials(for: payload.user.id)?.password ?? otpCode
            await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: preservedPassword)
            return payload.user
        } catch AuthRepositoryError.accountNotFound {
            return nil
        } catch {
            if let user = try await fallback.authenticate(
                identifier: identifier,
                otpCode: otpCode,
                challengeID: challengeID
            ) {
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
        try validateAuthenticatedIdentity(payload.user, for: identifier)
        if BackendConfiguration.currentBaseURL != nil, payload.session != nil {
            await BackendRequestTransport.storeAuthenticatedSession(from: payload)
        }
        await LocalAccountStore.shared.upsertRemoteAccount(payload.user, password: password)
        return payload.user
    }

    func resetPassword(identifier: String, newPassword: String, challengeID: String?) async throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ResetPasswordRequest(
            identifier: normalizedIdentifier,
            password: trimmedPassword,
            challengeID: challengeID
        )

        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword, challengeID: challengeID)
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
            try? await LocalAccountStore.shared.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword, challengeID: challengeID)
        } catch {
            try await fallback.resetPassword(identifier: normalizedIdentifier, newPassword: trimmedPassword, challengeID: challengeID)
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
            if error is AuthRepositoryError {
                throw error
            }
            if await hasStoredSession(for: userID) {
                throw error
            }
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
        try await updatePassword(currentPassword: nil, newPassword: password, for: userID)
    }

    func updatePassword(currentPassword: String?, newPassword: String, for userID: UUID) async throws {
        let body = PasswordUpdateRequest(
            userID: userID.uuidString,
            password: newPassword,
            oldPassword: currentPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.updatePassword(currentPassword: currentPassword, newPassword: newPassword, for: userID)
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
            try? await LocalAccountStore.shared.updatePassword(newPassword, for: userID)
        } catch {
            if error is AuthRepositoryError {
                throw error
            }
            if await hasStoredSession(for: userID) {
                throw error
            }
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/\(userID.uuidString)/password",
                method: "PATCH",
                body: bodyData
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            try? await LocalAccountStore.shared.updatePassword(newPassword, for: userID)
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
        } catch let error as AuthRepositoryError {
            switch error {
            case .invalidCredentials, .accountNotFound, .backendUnavailable:
                break
            default:
                if await hasStoredSession(for: userID) {
                    throw error
                }
            }
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

    func fetchBlockedUsers(for userID: UUID) async throws -> [User] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchBlockedUsers(for: userID)
        }

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/users/blocked",
                method: "GET",
                userID: userID
            )
            try validate(response: response)
            return try decoder.decode([User].self, from: data)
        } catch {
            if await hasStoredSession(for: userID) {
                throw error
            }
        }

        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/users/blocked",
                method: "GET",
                queryItems: [URLQueryItem(name: "user_id", value: userID.uuidString)]
            )
            try validate(response: response)
            return try decoder.decode([User].self, from: data)
        } catch {
            return try await fallback.fetchBlockedUsers(for: userID)
        }
    }

    func blockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.blockUser(blockedUserID, for: blockerUserID)
            return
        }

        let body = BlockMutationRequest(userID: blockerUserID.uuidString)
        let bodyData = try encoder.encode(body)
        let path = "/users/\(blockedUserID.uuidString)/block"

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: bodyData,
                userID: blockerUserID
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            return
        } catch {
            if await hasStoredSession(for: blockerUserID) {
                throw error
            }
        }

        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: bodyData
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
        } catch {
            try await fallback.blockUser(blockedUserID, for: blockerUserID)
        }
    }

    func unblockUser(_ blockedUserID: UUID, for blockerUserID: UUID) async throws {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            try await fallback.unblockUser(blockedUserID, for: blockerUserID)
            return
        }

        let body = BlockMutationRequest(userID: blockerUserID.uuidString)
        let bodyData = try encoder.encode(body)
        let path = "/users/\(blockedUserID.uuidString)/unblock"

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: bodyData,
                userID: blockerUserID
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
            return
        } catch {
            if await hasStoredSession(for: blockerUserID) {
                throw error
            }
        }

        do {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: bodyData
            )
            try validate(response: response)
            _ = try decoder.decode(BackendOKResponse.self, from: data)
        } catch {
            try await fallback.unblockUser(blockedUserID, for: blockerUserID)
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
            if let errorCode = backendErrorCode(from: data) {
                switch errorCode {
                case "apple_token_invalid", "apple_token_expired", "apple_signin_failed":
                    throw AuthRepositoryError.appleSignInFailed
                case "invalid_otp":
                    throw AuthRepositoryError.invalidOTPCode
                case "otp_expired":
                    throw AuthRepositoryError.otpExpired
                case "otp_attempt_limit_exceeded":
                    throw AuthRepositoryError.otpAttemptsExceeded
                default:
                    break
                }
            }
            throw AuthRepositoryError.invalidCredentials
        case 429:
            if let data,
               let cooldown = (try? decoder.decode(OTPCooldownPayload.self, from: data))?.retryAfterSeconds {
                throw AuthRepositoryError.otpResendCooldown(seconds: cooldown)
            }
            throw AuthRepositoryError.backendUnavailable
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
        case 503:
            if backendErrorCode(from: data) == "otp_delivery_failed" {
                throw AuthRepositoryError.otpDeliveryFailed(reason: backendErrorReason(from: data))
            }
            throw AuthRepositoryError.backendUnavailable
        case 409:
            switch backendErrorCode(from: data) {
            case "apple_token_invalid", "apple_token_expired", "apple_signin_failed":
                throw AuthRepositoryError.appleSignInFailed
            case "username_taken":
                throw AuthRepositoryError.usernameTaken
            case "invalid_username":
                throw AuthRepositoryError.invalidUsername
            case "otp_required", "otp_not_verified":
                throw AuthRepositoryError.otpRequired
            case "otp_expired":
                throw AuthRepositoryError.otpExpired
            case "otp_attempt_limit_exceeded":
                throw AuthRepositoryError.otpAttemptsExceeded
            case "phone_taken", "email_taken", "user_id_taken":
                throw AuthRepositoryError.accountAlreadyExists
            case "invalid_phone_number":
                throw AuthRepositoryError.invalidPhoneNumber
            case "invalid_email":
                throw AuthRepositoryError.invalidEmail
            case "guest_limit_reached":
                throw AuthRepositoryError.guestLimitReached
            case "apple_identity_taken":
                throw AuthRepositoryError.appleIdentityTaken
            case "current_password_required":
                throw AuthRepositoryError.currentPasswordRequired
            default:
                throw AuthRepositoryError.backendUnavailable
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

    private func validateAuthenticatedIdentity(_ user: User, for identifier: String) throws {
        guard userMatchesIdentifier(user, identifier: identifier) else {
            throw AuthRepositoryError.invalidCredentials
        }
    }

    private func userMatchesIdentifier(_ user: User, identifier: String) -> Bool {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.isEmpty == false else { return false }

        let normalizedUsernameInput = raw.replacingOccurrences(of: "@", with: "")
        let normalizedUserUsername = user.profile.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let normalizedEmailInput = raw
        let normalizedUserEmail = user.profile.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let normalizedPhoneInput = normalizePhoneNumber(identifier)
        let normalizedUserPhone = normalizePhoneNumber(user.profile.phoneNumber ?? "")

        let isEmailIdentifier = raw.contains("@") && raw.contains(".")
        let isUsernameIdentifier = raw.hasPrefix("@")

        if isUsernameIdentifier {
            return normalizedUsernameInput == normalizedUserUsername
        }

        if isEmailIdentifier {
            return normalizedUserEmail == normalizedEmailInput
        }

        if normalizedPhoneInput.isEmpty == false, normalizedPhoneInput == normalizedUserPhone {
            return true
        }

        if normalizedUsernameInput == normalizedUserUsername {
            return true
        }

        if let normalizedUserEmail, normalizedUserEmail == normalizedEmailInput {
            return true
        }

        return false
    }

    private func normalizePhoneNumber(_ phoneNumber: String) -> String {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        var normalized = ""
        for (index, character) in trimmed.enumerated() {
            if character == "+", index == 0 {
                normalized.append(character)
            } else if character.isNumber {
                normalized.append(character)
            }
        }
        return normalized
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

    private func backendErrorReason(from data: Data?) -> String? {
        guard let data else { return nil }
        return (try? JSONDecoder().decode(BackendErrorPayload.self, from: data))?.reason
    }

    private func hasStoredSession(for userID: UUID) async -> Bool {
        await AuthSessionStore.shared.session(for: userID) != nil
    }

    private func currentAuthenticatedUserID(defaults: UserDefaults = .standard) async -> UUID? {
        if let data = defaults.data(forKey: "app_state.current_user"),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user.id
        }

        let sessions = await AuthSessionStore.shared.allSessions()
        if sessions.count == 1, let session = sessions.first {
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

    private func stableDeviceIdentifier(defaults: UserDefaults = .standard) -> String {
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
}

private struct BackendErrorPayload: Decodable {
    let error: String
    let reason: String?
}

private struct SignUpRequest: Encodable {
    let displayName: String
    let username: String
    let password: String
    let contactValue: String
    let methodType: String
    let accountKind: String
    let otpChallengeID: String?
    let signupEmail: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case password
        case contactValue = "contact_value"
        case methodType = "method_type"
        case accountKind = "account_kind"
        case otpChallengeID = "otp_challenge_id"
        case signupEmail = "signup_email"
    }
}

private struct LoginRequest: Encodable {
    let identifier: String
    let password: String
}

private struct AppleSignInRequest: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let appleUserID: String
    let email: String?
    let givenName: String?
    let familyName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case appleUserID = "apple_user_id"
        case email
        case givenName = "given_name"
        case familyName = "family_name"
    }
}

private struct AccountLookupRequest: Encodable {
    let identifier: String
}

private struct ContactsMatchRequest: Encodable, Sendable {
    let contacts: [DeviceContactCandidate]

    enum CodingKeys: String, CodingKey {
        case contacts
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contacts, forKey: .contacts)
    }
}

private struct ContactsMatchResponse: Decodable {
    let matches: [MatchedDeviceContact]
}

private struct ResetPasswordRequest: Encodable {
    let identifier: String
    let password: String
    let challengeID: String?

    enum CodingKeys: String, CodingKey {
        case identifier
        case password = "new_password"
        case challengeID = "challenge_id"
    }
}

private struct OTPLoginRequest: Encodable {
    let identifier: String
    let otpCode: String
    let challengeID: String?

    enum CodingKeys: String, CodingKey {
        case identifier
        case otpCode = "otp_code"
        case challengeID = "challenge_id"
    }
}

private struct OTPRequestPayload: Encodable {
    let identifier: String
    let purpose: String
}

private struct OTPVerifyPayload: Encodable {
    let challengeID: String
    let otpCode: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case otpCode = "otp_code"
    }
}

private struct OTPCooldownPayload: Decodable {
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case retryAfterSeconds = "retry_after_seconds"
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
    let oldPassword: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case password
        case oldPassword = "old_password"
    }
}

private struct AccountDeleteRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private struct BlockMutationRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private struct BackendOKResponse: Decodable {
    let ok: Bool
}
