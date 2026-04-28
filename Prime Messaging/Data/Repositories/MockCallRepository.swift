import Foundation

enum CallRepositoryError: LocalizedError {
    case backendUnavailable
    case groupCallsNotSupported
    case callNotFound
    case userNotFound
    case callPermissionDenied
    case callRequiresSavedContact
    case invalidOperation

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "calls.error.backend_unavailable".localized
        case .groupCallsNotSupported:
            return "calls.error.group_calls_not_supported".localized
        case .callNotFound:
            return "calls.error.call_not_found".localized
        case .userNotFound:
            return "calls.error.user_not_found".localized
        case .callPermissionDenied:
            return "calls.error.permission_denied".localized
        case .callRequiresSavedContact:
            return "calls.unavailable.privacy".localized
        case .invalidOperation:
            return "calls.error.invalid_operation".localized
        }
    }
}

actor MockCallStore {
    static let shared = MockCallStore()

    private var calls: [UUID: InternetCall] = [:]
    private var callEvents: [UUID: [InternetCallEvent]] = [:]

    func activeCalls(for userID: UUID) -> [InternetCall] {
        calls.values
            .filter { $0.participants.contains(where: { $0.id == userID }) }
            .filter { [.ringing, .active].contains($0.state) }
            .filter { $0.isGroupCall == false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func historyCalls(for userID: UUID) -> [InternetCall] {
        calls.values
            .filter { $0.participants.contains(where: { $0.id == userID }) }
            .sorted { $0.activityDate > $1.activityDate }
    }

    func call(_ callID: UUID) -> InternetCall? {
        calls[callID]
    }

    func activeGroupCall(chatID: UUID, userID: UUID) -> InternetCall? {
        calls.values
            .filter { $0.chatID == chatID && $0.isGroupCall }
            .filter { $0.participants.contains(where: { $0.id == userID }) }
            .filter { [.ringing, .active].contains($0.state) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func createCall(calleeID: UUID, caller: User) -> InternetCall {
        let remoteUser = User(
            id: calleeID,
            profile: Profile(
                displayName: "Prime Contact",
                username: "contact",
                bio: "",
                status: "Available",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: nil,
                socialLink: nil
            ),
            identityMethods: [],
            privacySettings: .defaultEmailOnly
        )
        let call = makeCall(caller: caller, callee: remoteUser)
        calls[call.id] = call
        callEvents[call.id] = [makeEvent(for: call.id, sequence: 1, type: .created, senderID: caller.id)]
        return call
    }

    func createGroupCall(chatID: UUID, caller: User) -> InternetCall {
        let participants = [
            InternetCallParticipant(
                id: caller.id,
                username: caller.profile.username,
                displayName: caller.profile.displayName,
                profilePhotoURL: caller.profile.profilePhotoURL
            ),
            InternetCallParticipant(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
                username: "groupmate.one",
                displayName: "Group Mate One",
                profilePhotoURL: nil
            ),
            InternetCallParticipant(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
                username: "groupmate.two",
                displayName: "Group Mate Two",
                profilePhotoURL: nil
            )
        ]

        let call = InternetCall(
            id: UUID(),
            mode: .online,
            kind: .audio,
            state: .active,
            chatID: chatID,
            callerID: caller.id,
            calleeID: caller.id,
            participants: participants,
            joinedParticipantIDs: [caller.id],
            createdAt: .now,
            answeredAt: .now,
            endedAt: nil,
            lastEventSequence: 1,
            latestRemoteOfferSDP: nil,
            latestRemoteOfferSequence: nil
        )
        calls[call.id] = call
        callEvents[call.id] = [makeEvent(for: call.id, sequence: 1, type: .created, senderID: caller.id)]
        return call
    }

    func updateGroupMembership(callID: UUID, userID: UUID, join: Bool) throws -> InternetCall {
        guard var call = calls[callID] else { throw CallRepositoryError.callNotFound }
        guard call.participants.contains(where: { $0.id == userID }) else {
            throw CallRepositoryError.callPermissionDenied
        }

        var joinedIDs = Set(call.joinedParticipantIDs ?? [])
        if join {
            joinedIDs.insert(userID)
            call.state = .active
            call.answeredAt = call.answeredAt ?? .now
        } else {
            joinedIDs.remove(userID)
            if joinedIDs.isEmpty {
                call.state = .ended
                call.endedAt = .now
            }
        }
        call.joinedParticipantIDs = Array(joinedIDs)
        call.lastEventSequence += 1
        calls[callID] = call

        var events = callEvents[callID] ?? []
        events.append(
            makeEvent(
                for: callID,
                sequence: call.lastEventSequence,
                type: join ? .accepted : .ended,
                senderID: userID
            )
        )
        callEvents[callID] = events
        return call
    }

    func updateState(callID: UUID, userID: UUID, state: InternetCallState) throws -> InternetCall {
        guard var call = calls[callID] else { throw CallRepositoryError.callNotFound }
        guard call.participants.contains(where: { $0.id == userID }) else { throw CallRepositoryError.callPermissionDenied }

        call.state = state
        switch state {
        case .active:
            call.answeredAt = .now
        case .ended, .rejected, .cancelled, .missed:
            call.endedAt = .now
        case .ringing:
            break
        }
        call.lastEventSequence += 1
        calls[callID] = call
        let eventType: InternetCallEventType
        switch state {
        case .active:
            eventType = .accepted
        case .rejected, .missed:
            eventType = .rejected
        case .ended, .cancelled:
            eventType = .ended
        case .ringing:
            eventType = .created
        }
        var events = callEvents[callID] ?? []
        events.append(makeEvent(for: callID, sequence: call.lastEventSequence, type: eventType, senderID: userID))
        callEvents[callID] = events
        return call
    }

    func events(for callID: UUID, since sequence: Int) -> [InternetCallEvent] {
        (callEvents[callID] ?? []).filter { $0.sequence > sequence }
    }

    func appendEvent(
        callID: UUID,
        userID: UUID,
        type: InternetCallEventType,
        sdp: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil,
        targetUserID: UUID? = nil,
        isMuted: Bool? = nil,
        isVideoEnabled: Bool? = nil
    ) throws -> InternetCallEvent {
        guard var call = calls[callID] else { throw CallRepositoryError.callNotFound }
        guard call.participants.contains(where: { $0.id == userID }) else { throw CallRepositoryError.callPermissionDenied }

        call.lastEventSequence += 1
        calls[callID] = call
        let event = InternetCallEvent(
            id: UUID(),
            callID: callID,
            sequence: call.lastEventSequence,
            type: type,
            senderID: userID,
            targetUserID: targetUserID,
            sdp: sdp,
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex,
            isMuted: isMuted,
            isVideoEnabled: isVideoEnabled,
            createdAt: .now
        )
        var events = callEvents[callID] ?? []
        events.append(event)
        callEvents[callID] = events
        return event
    }

    private func makeCall(caller: User, callee: User) -> InternetCall {
        InternetCall(
            id: UUID(),
            mode: .online,
            kind: .audio,
            state: .ringing,
            chatID: nil,
            callerID: caller.id,
            calleeID: callee.id,
            participants: [
                InternetCallParticipant(
                    id: caller.id,
                    username: caller.profile.username,
                    displayName: caller.profile.displayName,
                    profilePhotoURL: caller.profile.profilePhotoURL
                ),
                InternetCallParticipant(
                    id: callee.id,
                    username: callee.profile.username,
                    displayName: callee.profile.displayName,
                    profilePhotoURL: callee.profile.profilePhotoURL
                )
            ],
            joinedParticipantIDs: nil,
            createdAt: .now,
            answeredAt: nil,
            endedAt: nil,
            lastEventSequence: 1,
            latestRemoteOfferSDP: nil,
            latestRemoteOfferSequence: nil
        )
    }

    private func makeEvent(for callID: UUID, sequence: Int, type: InternetCallEventType, senderID: UUID?) -> InternetCallEvent {
        InternetCallEvent(
            id: UUID(),
            callID: callID,
            sequence: sequence,
            type: type,
            senderID: senderID,
            targetUserID: nil,
            sdp: nil,
            candidate: nil,
            sdpMid: nil,
            sdpMLineIndex: nil,
            isMuted: nil,
            isVideoEnabled: nil,
            createdAt: .now
        )
    }
}

struct MockCallRepository: CallRepository {
    func fetchActiveCalls(for userID: UUID) async throws -> [InternetCall] {
        await MockCallStore.shared.activeCalls(for: userID)
    }

    func fetchCallHistory(for userID: UUID) async throws -> [InternetCall] {
        await MockCallStore.shared.historyCalls(for: userID)
    }

    func fetchCall(_ callID: UUID, for userID: UUID) async throws -> InternetCall {
        guard let call = await MockCallStore.shared.call(callID) else {
            throw CallRepositoryError.callNotFound
        }
        guard call.participants.contains(where: { $0.id == userID }) else {
            throw CallRepositoryError.callPermissionDenied
        }
        return call
    }

    func startAudioCall(with calleeID: UUID, from callerID: UUID) async throws -> InternetCall {
        let caller = User(
            id: callerID,
            profile: Profile(
                displayName: "Prime User",
                username: "primeuser",
                bio: "",
                status: "Available",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: nil,
                socialLink: nil
            ),
            identityMethods: [],
            privacySettings: .defaultEmailOnly
        )
        return await MockCallStore.shared.createCall(calleeID: calleeID, caller: caller)
    }

    func fetchActiveGroupCall(in chatID: UUID, userID: UUID) async throws -> InternetCall? {
        await MockCallStore.shared.activeGroupCall(chatID: chatID, userID: userID)
    }

    func fetchGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        let call = try await fetchCall(callID, for: userID)
        guard call.isGroupCall else {
            throw CallRepositoryError.callNotFound
        }
        return call
    }

    func startGroupAudioCall(in chatID: UUID, from callerID: UUID) async throws -> InternetCall {
        let caller = User(
            id: callerID,
            profile: Profile(
                displayName: "Prime User",
                username: "primeuser",
                bio: "",
                status: "Available",
                birthday: nil,
                email: nil,
                phoneNumber: nil,
                profilePhotoURL: nil,
                socialLink: nil
            ),
            identityMethods: [],
            privacySettings: .defaultEmailOnly
        )
        return await MockCallStore.shared.createGroupCall(chatID: chatID, caller: caller)
    }

    func joinGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await MockCallStore.shared.updateGroupMembership(callID: callID, userID: userID, join: true)
    }

    func leaveGroupCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await MockCallStore.shared.updateGroupMembership(callID: callID, userID: userID, join: false)
    }

    func answerCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await MockCallStore.shared.updateState(callID: callID, userID: userID, state: .active)
    }

    func rejectCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await MockCallStore.shared.updateState(callID: callID, userID: userID, state: .rejected)
    }

    func endCall(_ callID: UUID, userID: UUID) async throws -> InternetCall {
        try await MockCallStore.shared.updateState(callID: callID, userID: userID, state: .ended)
    }

    func fetchEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent] {
        _ = try await fetchCall(callID, for: userID)
        return await MockCallStore.shared.events(for: callID, since: sinceSequence)
    }

    func fetchGroupEvents(callID: UUID, userID: UUID, sinceSequence: Int) async throws -> [InternetCallEvent] {
        _ = try await fetchGroupCall(callID, userID: userID)
        return await MockCallStore.shared.events(for: callID, since: sinceSequence)
    }

    func sendOffer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(callID: callID, userID: userID, type: .offer, sdp: sdp)
    }

    func sendGroupOffer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .offer,
            sdp: sdp,
            targetUserID: targetUserID
        )
    }

    func sendAnswer(_ sdp: String, in callID: UUID, userID: UUID) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(callID: callID, userID: userID, type: .answer, sdp: sdp)
    }

    func sendGroupAnswer(
        _ sdp: String,
        to targetUserID: UUID,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .answer,
            sdp: sdp,
            targetUserID: targetUserID
        )
    }

    func sendICECandidate(
        _ candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .ice,
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
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
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .ice,
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex,
            targetUserID: targetUserID
        )
    }

    func sendMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .mediaState,
            isMuted: isMuted,
            isVideoEnabled: isVideoEnabled
        )
    }

    func sendGroupMediaState(
        isMuted: Bool,
        isVideoEnabled: Bool,
        in callID: UUID,
        userID: UUID
    ) async throws -> InternetCallEvent {
        try await MockCallStore.shared.appendEvent(
            callID: callID,
            userID: userID,
            type: .mediaState,
            isMuted: isMuted,
            isVideoEnabled: isVideoEnabled
        )
    }
}
