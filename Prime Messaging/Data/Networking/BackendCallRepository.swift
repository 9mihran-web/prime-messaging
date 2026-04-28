import Foundation

struct BackendCallRepository: CallRepository {
    let fallback: CallRepository
    private let decoder = BackendJSONDecoder.make()

    func fetchActiveCalls(for userID: UUID) async throws -> [InternetCall] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchActiveCalls(for: userID)
        }

        let queryItems = [URLQueryItem(name: "user_id", value: userID.uuidString)]

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/calls",
            method: "GET",
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: "/calls")
        return try decoder.decode([InternetCall].self, from: data)
    }

    func fetchCallHistory(for userID: UUID) async throws -> [InternetCall] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchCallHistory(for: userID)
        }

        let queryItems = [URLQueryItem(name: "user_id", value: userID.uuidString)]

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/calls/history",
            method: "GET",
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: "/calls/history")
        return try decoder.decode([InternetCall].self, from: data)
    }

    func fetchCall(_ callID: UUID, for userID: UUID) async throws -> InternetCall {
        try await request(
            path: "/calls/\(callID.uuidString)",
            method: "GET",
            body: OptionalRequestBody.none,
            userID: userID,
            queryItems: [URLQueryItem(name: "user_id", value: userID.uuidString)]
        )
    }

    func startAudioCall(with calleeID: UUID, from callerID: UUID) async throws -> InternetCall {
        let body = StartCallRequest(
            callerID: callerID.uuidString,
            calleeID: calleeID.uuidString,
            chatID: nil,
            mode: ChatMode.online.rawValue,
            kind: InternetCallKind.audio.rawValue
        )
        return try await request(
            path: "/calls",
            method: "POST",
            body: body,
            userID: callerID
        )
    }

    func fetchActiveGroupCall(in chatID: UUID, userID: UUID) async throws -> InternetCall? {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchActiveGroupCall(in: chatID, userID: userID)
        }

        let queryItems = [
            URLQueryItem(name: "chat_id", value: chatID.uuidString),
            URLQueryItem(name: "user_id", value: userID.uuidString)
        ]

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/group-calls/active",
            method: "GET",
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: "/group-calls/active")
        return try decoder.decode(InternetCall?.self, from: data)
    }

    func fetchGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await request(
            path: "/group-calls/\(callID.uuidString)",
            method: "GET",
            body: OptionalRequestBody.none,
            userID: userID,
            queryItems: [URLQueryItem(name: "user_id", value: userID.uuidString)]
        )
    }

    func startGroupAudioCall(in chatID: UUID, from callerID: UUID) async throws -> InternetCall {
        let body = StartCallRequest(
            callerID: callerID.uuidString,
            calleeID: nil,
            chatID: chatID.uuidString,
            mode: ChatMode.online.rawValue,
            kind: InternetCallKind.audio.rawValue
        )
        return try await request(
            path: "/group-calls",
            method: "POST",
            body: body,
            userID: callerID
        )
    }

    func joinGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let body = CallActionRequest(userID: userID.uuidString)
        return try await request(
            path: "/group-calls/\(callID.uuidString)/join",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    func leaveGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let body = CallActionRequest(userID: userID.uuidString)
        return try await request(
            path: "/group-calls/\(callID.uuidString)/leave",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    func answerCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let body = CallActionRequest(userID: userID.uuidString)
        return try await request(
            path: "/calls/\(callID.uuidString)/accept",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    func rejectCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let body = CallActionRequest(userID: userID.uuidString)
        return try await request(
            path: "/calls/\(callID.uuidString)/reject",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    func endCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let body = CallActionRequest(userID: userID.uuidString)
        return try await request(
            path: "/calls/\(callID.uuidString)/hangup",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    func fetchEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchEvents(callID: callID, userID: userID, sinceSequence: sinceSequence)
        }

        let queryItems = [
            URLQueryItem(name: "user_id", value: userID.uuidString),
            URLQueryItem(name: "since", value: String(sinceSequence))
        ]

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/calls/\(callID.uuidString)/events",
            method: "GET",
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: "/calls/\(callID.uuidString)/events")
        return try decoder.decode([InternetCallEvent].self, from: data)
    }

    func fetchGroupEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchGroupEvents(callID: callID, userID: userID, sinceSequence: sinceSequence)
        }

        let queryItems = [
            URLQueryItem(name: "user_id", value: userID.uuidString),
            URLQueryItem(name: "since", value: String(sinceSequence))
        ]

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: "/group-calls/\(callID.uuidString)/events",
            method: "GET",
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: "/group-calls/\(callID.uuidString)/events")
        return try decoder.decode([InternetCallEvent].self, from: data)
    }

    func sendOffer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "offer",
            callID: callID,
            userID: userID,
            targetUserID: nil,
            body: CallSDPRequest(userID: userID.uuidString, sdp: sdp, targetUserID: nil)
        )
    }

    func sendGroupOffer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "offer",
            callID: callID,
            userID: userID,
            targetUserID: targetUserID,
            body: CallSDPRequest(
                userID: userID.uuidString,
                sdp: sdp,
                targetUserID: targetUserID.uuidString
            ),
            pathPrefix: "/group-calls"
        )
    }

    func sendAnswer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "answer",
            callID: callID,
            userID: userID,
            targetUserID: nil,
            body: CallSDPRequest(userID: userID.uuidString, sdp: sdp, targetUserID: nil)
        )
    }

    func sendGroupAnswer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "answer",
            callID: callID,
            userID: userID,
            targetUserID: targetUserID,
            body: CallSDPRequest(
                userID: userID.uuidString,
                sdp: sdp,
                targetUserID: targetUserID.uuidString
            ),
            pathPrefix: "/group-calls"
        )
    }

    func sendICECandidate(
        _ candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "ice",
            callID: callID,
            userID: userID,
            targetUserID: nil,
            body: CallICERequest(
                userID: userID.uuidString,
                candidate: candidate,
                sdpMid: sdpMid,
                sdpMLineIndex: sdpMLineIndex,
                targetUserID: nil
            )
        )
    }

    func sendGroupICECandidate(
        _ candidate: String,
        to targetUserID: UUID,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "ice",
            callID: callID,
            userID: userID,
            targetUserID: targetUserID,
            body: CallICERequest(
                userID: userID.uuidString,
                candidate: candidate,
                sdpMid: sdpMid,
                sdpMLineIndex: sdpMLineIndex,
                targetUserID: targetUserID.uuidString
            ),
            pathPrefix: "/group-calls"
        )
    }

    func sendMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "media-state",
            callID: callID,
            userID: userID,
            targetUserID: nil,
            body: CallMediaStateRequest(
                userID: userID.uuidString,
                isMuted: isMuted,
                isVideoEnabled: isVideoEnabled
            )
        )
    }

    func sendGroupMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "media-state",
            callID: callID,
            userID: userID,
            targetUserID: nil,
            body: CallMediaStateRequest(
                userID: userID.uuidString,
                isMuted: isMuted,
                isVideoEnabled: isVideoEnabled
            ),
            pathPrefix: "/group-calls"
        )
    }

    private func sendSignal<Body: Encodable>(
        typePath: String,
        callID: UUID,
        userID: UUID,
        targetUserID: UUID?,
        body: Body,
        pathPrefix: String = "/calls"
    ) async throws -> InternetCallEvent {
        _ = targetUserID
        return try await request(
            path: "\(pathPrefix)/\(callID.uuidString)/\(typePath)",
            method: "POST",
            body: body,
            userID: userID
        )
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        userID: UUID?,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            throw CallRepositoryError.backendUnavailable
        }

        let bodyData = body is OptionalRequestBody ? nil : try JSONEncoder().encode(body)

        let (data, response) = try await BackendRequestTransport.authorizedRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: bodyData,
            queryItems: queryItems,
            userID: userID
        )
        try validate(response: response, data: data, path: path)
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data, path: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CallRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw mappedError(statusCode: httpResponse.statusCode, data: data, path: path)
        }
    }

    private func mappedError(statusCode: Int, data: Data, path: String) -> Error {
        let serverError = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error
        let isGroupCallPath = path.hasPrefix("/group-calls")

        switch (statusCode, serverError) {
        case (401, _):
            return AuthRepositoryError.invalidCredentials
        case (404, "not_found") where isGroupCallPath:
            return CallRepositoryError.groupCallsNotSupported
        case (405, _) where isGroupCallPath:
            return CallRepositoryError.groupCallsNotSupported
        case (501, _) where isGroupCallPath:
            return CallRepositoryError.groupCallsNotSupported
        case (403, "call_requires_saved_contact"):
            return CallRepositoryError.callRequiresSavedContact
        case (404, "call_not_found"):
            return CallRepositoryError.callNotFound
        case (404, "user_not_found"):
            return CallRepositoryError.userNotFound
        case (403, "call_permission_denied"):
            return CallRepositoryError.callPermissionDenied
        case (409, "invalid_call_operation"):
            return CallRepositoryError.invalidOperation
        default:
            return CallRepositoryError.backendUnavailable
        }
    }

}

private struct OptionalRequestBody: Encodable {
    static let none = OptionalRequestBody()
}

private struct StartCallRequest: Encodable {
    let callerID: String
    let calleeID: String?
    let chatID: String?
    let mode: String
    let kind: String

    enum CodingKeys: String, CodingKey {
        case callerID = "caller_id"
        case calleeID = "callee_id"
        case chatID = "chat_id"
        case mode
        case kind
    }
}

private struct CallActionRequest: Encodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

private struct CallSDPRequest: Encodable {
    let userID: String
    let sdp: String
    let targetUserID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sdp
        case targetUserID = "target_user_id"
    }
}

private struct CallICERequest: Encodable {
    let userID: String
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
    let targetUserID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
        case targetUserID = "target_user_id"
    }
}

private struct CallMediaStateRequest: Encodable {
    let userID: String
    let isMuted: Bool
    let isVideoEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case isMuted = "is_muted"
        case isVideoEnabled = "is_video_enabled"
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}
