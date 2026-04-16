import Foundation

actor ContactAliasStore {
    static let shared = ContactAliasStore()

    struct StoredContact: Identifiable, Hashable {
        let ownerUserID: UUID
        let remoteUserID: UUID
        let remoteUsername: String
        let localDisplayName: String

        var id: String {
            "\(ownerUserID.uuidString)-\(remoteUserID.uuidString)-\(remoteUsername)"
        }
    }

    private enum StorageKeys {
        static let aliases = "contacts.aliases"
    }

    private struct AliasRecord: Codable, Hashable {
        let ownerUserID: UUID
        let remoteUserID: UUID
        let remoteUsername: String
        var localDisplayName: String
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveAlias(ownerUserID: UUID, remoteUserID: UUID, remoteUsername: String, localDisplayName: String) {
        let normalizedUsername = remoteUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUsername.isEmpty == false, normalizedDisplayName.isEmpty == false else { return }

        var aliases = loadAliases()
        if let index = aliases.firstIndex(where: {
            $0.ownerUserID == ownerUserID && ($0.remoteUserID == remoteUserID || $0.remoteUsername == normalizedUsername)
        }) {
            aliases[index].localDisplayName = normalizedDisplayName
            aliases[index].updatedAt = .now
        } else {
            aliases.append(
                AliasRecord(
                    ownerUserID: ownerUserID,
                    remoteUserID: remoteUserID,
                    remoteUsername: normalizedUsername,
                    localDisplayName: normalizedDisplayName,
                    updatedAt: .now
                )
            )
        }

        persistAliases(aliases)
    }

    func alias(ownerUserID: UUID, remoteUserID: UUID?, username: String?) -> String? {
        let normalizedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return loadAliases()
            .filter { $0.ownerUserID == ownerUserID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first(where: { record in
                if let remoteUserID, record.remoteUserID == remoteUserID {
                    return true
                }
                if let normalizedUsername, normalizedUsername.isEmpty == false {
                    return record.remoteUsername == normalizedUsername
                }
                return false
            })?
            .localDisplayName
    }

    func hasAlias(ownerUserID: UUID, remoteUserID: UUID?, username: String?) -> Bool {
        alias(ownerUserID: ownerUserID, remoteUserID: remoteUserID, username: username) != nil
    }

    func contacts(ownerUserID: UUID) -> [StoredContact] {
        loadAliases()
            .filter { $0.ownerUserID == ownerUserID }
            .sorted { lhs, rhs in
                if lhs.localDisplayName.caseInsensitiveCompare(rhs.localDisplayName) == .orderedSame {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.localDisplayName.localizedCaseInsensitiveCompare(rhs.localDisplayName) == .orderedAscending
            }
            .map { record in
                StoredContact(
                    ownerUserID: record.ownerUserID,
                    remoteUserID: record.remoteUserID,
                    remoteUsername: record.remoteUsername,
                    localDisplayName: record.localDisplayName
                )
            }
    }

    func removeAlias(ownerUserID: UUID, remoteUserID: UUID?, username: String?) {
        let normalizedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = loadAliases().filter { record in
            guard record.ownerUserID == ownerUserID else { return true }
            if let remoteUserID, record.remoteUserID == remoteUserID {
                return false
            }
            if let normalizedUsername, normalizedUsername.isEmpty == false, record.remoteUsername == normalizedUsername {
                return false
            }
            return true
        }
        persistAliases(filtered)
    }

    func applyAlias(to chat: Chat, currentUserID: UUID, messages: [Message] = []) -> Chat {
        guard chat.type == .direct else { return chat }

        var chat = chat
        let otherUserID = chat.participantIDs.first(where: { $0 != currentUserID }) ?? messages.last(where: { $0.senderID != currentUserID })?.senderID
        let otherParticipant = chat.directParticipant(for: currentUserID)
        let subtitleUsername = subtitleUsername(from: chat.subtitle)
        let participantUsername = otherParticipant?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteUsername = participantUsername.isEmpty == false ? participantUsername : subtitleUsername
        let inferredMessageName = messages
            .last(where: { $0.senderID != currentUserID })?
            .senderDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localAlias = alias(ownerUserID: currentUserID, remoteUserID: otherUserID, username: remoteUsername)

        if let otherUserID {
            var participants = chat.participants.filter { $0.id != otherUserID }
            participants.append(
                ChatParticipant(
                    id: otherUserID,
                    username: remoteUsername ?? "",
                    displayName: localAlias ?? preferredDisplayName(
                        participant: otherParticipant,
                        inferredMessageName: inferredMessageName,
                        fallbackTitle: chat.title
                    )
                )
            )
            chat.participants = participants
        }

        if let localAlias, localAlias.isEmpty == false {
            chat.title = localAlias
            if let remoteUsername, remoteUsername.isEmpty == false {
                chat.subtitle = "@\(remoteUsername)"
            }
            return chat
        }

        if let preferredTitle = preferredDisplayName(
            participant: otherParticipant,
            inferredMessageName: inferredMessageName,
            fallbackTitle: chat.title
        ) {
            chat.title = preferredTitle
        } else if let remoteUsername, remoteUsername.isEmpty == false {
            chat.title = remoteUsername
        }

        if let remoteUsername, remoteUsername.isEmpty == false {
            chat.subtitle = "@\(remoteUsername)"
        }

        return chat
    }

    private func preferredDisplayName(
        participant: ChatParticipant?,
        inferredMessageName: String?,
        fallbackTitle: String
    ) -> String? {
        let participantDisplayName = participant?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if participantDisplayName.isEmpty == false {
            return participantDisplayName
        }

        let participantUsername = participant?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if participantUsername.isEmpty == false {
            return participantUsername
        }

        if let inferredMessageName, inferredMessageName.isEmpty == false, inferredMessageName.caseInsensitiveCompare("Unknown user") != .orderedSame {
            return inferredMessageName
        }

        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedFallbackTitle.isEmpty == false else { return nil }
        guard trimmedFallbackTitle.caseInsensitiveCompare("Chat") != .orderedSame else { return nil }
        guard trimmedFallbackTitle.caseInsensitiveCompare("Direct Chat") != .orderedSame else { return nil }
        guard trimmedFallbackTitle.caseInsensitiveCompare("Missing User") != .orderedSame else { return nil }
        return trimmedFallbackTitle
    }

    private func subtitleUsername(from subtitle: String) -> String? {
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSubtitle.hasPrefix("@") else { return nil }
        let value = String(trimmedSubtitle.dropFirst())
        return value.isEmpty ? nil : value
    }

    private func loadAliases() -> [AliasRecord] {
        guard let data = defaults.data(forKey: StorageKeys.aliases) else { return [] }
        return (try? decoder.decode([AliasRecord].self, from: data)) ?? []
    }

    private func persistAliases(_ aliases: [AliasRecord]) {
        guard let data = try? encoder.encode(aliases) else { return }
        defaults.set(data, forKey: StorageKeys.aliases)
    }
}
