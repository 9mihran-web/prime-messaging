import Foundation
import Security

actor AuthSessionStore {
    static let shared = AuthSessionStore()

    private enum Constants {
        static let service = "miro.Prime-Messaging"
        static let account = "auth.sessions"
        static let appGroupIdentifier = "group.prime1.prime-Messaging.shared"
        static let rootDirectoryName = "IncomingShare"
        static let mirroredSessionsFileName = "auth-sessions.json"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func session(for userID: UUID) -> AuthSession? {
        loadSessions()[userID.uuidString]
    }

    func mostRecentSession() -> AuthSession? {
        loadSessions()
            .values
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    func allSessions() -> [AuthSession] {
        loadSessions()
            .values
            .sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func upsert(_ session: AuthSession) {
        var sessions = loadSessions()
        sessions[session.userID.uuidString] = session
        saveSessions(sessions)
    }

    func removeSession(for userID: UUID) {
        var sessions = loadSessions()
        sessions.removeValue(forKey: userID.uuidString)
        saveSessions(sessions)
    }

    func clearAllSessions() {
        saveSessions([:])
    }

    private func loadSessions() -> [String: AuthSession] {
        guard let data = readKeychainData() else {
            return [:]
        }

        guard let sessions = try? decoder.decode([String: AuthSession].self, from: data) else {
            return [:]
        }

        writeMirroredSessionData(data)

        return sessions
    }

    private func saveSessions(_ sessions: [String: AuthSession]) {
        guard let data = try? encoder.encode(sessions) else { return }
        writeKeychainData(data)
        writeMirroredSessionData(data)
    }

    private func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: Constants.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func writeKeychainData(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: Constants.account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insertQuery as CFDictionary, nil)
    }

    private func writeMirroredSessionData(_ data: Data) {
        guard let mirroredSessionsURL = mirroredSessionsURL() else { return }
        try? data.write(to: mirroredSessionsURL, options: .atomic)
    }

    private func mirroredSessionsURL() -> URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupIdentifier) else {
            return nil
        }
        let directory = containerURL.appendingPathComponent(Constants.rootDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Constants.mirroredSessionsFileName, isDirectory: false)
    }
}
