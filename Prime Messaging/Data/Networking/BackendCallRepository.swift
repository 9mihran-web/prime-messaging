import Foundation

struct BackendCallRepository: CallRepository {
    let fallback: CallRepository
    private let decoder = BackendJSONDecoder.make()

    func fetchActiveCalls(for userID: UUID) async throws -> [InternetCall] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchActiveCalls(for: userID)
        }

        let queryItems = [URLQueryItem(name: "user_id", value: userID.uuidString)]

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/calls",
                method: "GET",
                queryItems: queryItems,
                userID: userID
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCall].self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/calls",
                method: "GET",
                queryItems: queryItems
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCall].self, from: data)
        }
    }

    func fetchCallHistory(for userID: UUID) async throws -> [InternetCall] {
        guard let baseURL = BackendConfiguration.currentBaseURL else {
            return try await fallback.fetchCallHistory(for: userID)
        }

        let queryItems = [URLQueryItem(name: "user_id", value: userID.uuidString)]

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/calls/history",
                method: "GET",
                queryItems: queryItems,
                userID: userID
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCall].self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/calls/history",
                method: "GET",
                queryItems: queryItems
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCall].self, from: data)
        }
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

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: "/calls/\(callID.uuidString)/events",
                method: "GET",
                queryItems: queryItems,
                userID: userID
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCallEvent].self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: "/calls/\(callID.uuidString)/events",
                method: "GET",
                queryItems: queryItems
            )
            try validate(response: response, data: data)
            return try decoder.decode([InternetCallEvent].self, from: data)
        }
    }

    func sendOffer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "offer",
            callID: callID,
            userID: userID,
            body: CallSDPRequest(userID: userID.uuidString, sdp: sdp)
        )
    }

    func sendAnswer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await sendSignal(
            typePath: "answer",
            callID: callID,
            userID: userID,
            body: CallSDPRequest(userID: userID.uuidString, sdp: sdp)
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
            body: CallICERequest(
                userID: userID.uuidString,
                candidate: candidate,
                sdpMid: sdpMid,
                sdpMLineIndex: sdpMLineIndex
            )
        )
    }

    private func sendSignal<Body: Encodable>(
        typePath: String,
        callID: UUID,
        userID: UUID,
        body: Body
    ) async throws -> InternetCallEvent {
        try await request(
            path: "/calls/\(callID.uuidString)/\(typePath)",
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

        do {
            let (data, response) = try await BackendRequestTransport.authorizedRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData,
                queryItems: queryItems,
                userID: userID
            )
            try validate(response: response, data: data)
            return try decoder.decode(Response.self, from: data)
        } catch {
            let (data, response) = try await legacyRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                body: bodyData,
                queryItems: queryItems
            )
            try validate(response: response, data: data)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CallRepositoryError.backendUnavailable
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw mappedError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    private func mappedError(statusCode: Int, data: Data) -> Error {
        let serverError = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?.error

        switch (statusCode, serverError) {
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

    private func legacyRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> (Data, URLResponse) {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw CallRepositoryError.backendUnavailable
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw CallRepositoryError.backendUnavailable
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

private struct OptionalRequestBody: Encodable {
    static let none = OptionalRequestBody()
}

private struct StartCallRequest: Encodable {
    let callerID: String
    let calleeID: String
    let mode: String
    let kind: String

    enum CodingKeys: String, CodingKey {
        case callerID = "caller_id"
        case calleeID = "callee_id"
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

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sdp
    }
}

private struct CallICERequest: Encodable {
    let userID: String
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}
