import Foundation
import SQLite3

actor ChatMessagePageStore {
    static let shared = ChatMessagePageStore()
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let db: OpaquePointer?

    init(directoryName: String = "PrimeMessagingPagedMessages", databaseName: String = "messages.sqlite3") {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dbURL = directoryURL.appendingPathComponent(databaseName, isDirectory: false)

        var openedDB: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &openedDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = openedDB
            Self.configureDatabase(openedDB)
        } else {
            db = nil
            if let openedDB {
                sqlite3_close(openedDB)
            }
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func replaceMessages(_ messages: [Message], chatID: UUID, userID: UUID, mode: ChatMode) {
        guard let db else { return }
        beginTransaction()
        defer { commitTransaction() }

        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "DELETE FROM paged_messages WHERE user_id = ? AND mode = ? AND chat_id = ?;",
            -1,
            &deleteStatement,
            nil
        ) == SQLITE_OK {
            bind(deleteStatement, index: 1, text: userID.uuidString)
            bind(deleteStatement, index: 2, text: mode.rawValue)
            bind(deleteStatement, index: 3, text: chatID.uuidString)
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)

        insertMessages(
            messages,
            chatID: chatID,
            userID: userID,
            mode: mode,
            wrapInTransaction: false
        )
    }

    func upsertMessages(_ messages: [Message], chatID: UUID, userID: UUID, mode: ChatMode) {
        insertMessages(
            messages,
            chatID: chatID,
            userID: userID,
            mode: mode,
            wrapInTransaction: true
        )
    }

    func latestPage(chatID: UUID, userID: UUID, mode: ChatMode, limit: Int) -> [Message] {
        let sql = """
        SELECT payload
        FROM paged_messages
        WHERE user_id = ? AND mode = ? AND chat_id = ?
        ORDER BY created_at DESC, message_id DESC
        LIMIT ?;
        """
        return fetchMessages(sql: sql) { statement in
            bind(statement, index: 1, text: userID.uuidString)
            bind(statement, index: 2, text: mode.rawValue)
            bind(statement, index: 3, text: chatID.uuidString)
            sqlite3_bind_int(statement, 4, Int32(limit))
        }
        .reversed()
    }

    func page(before anchor: Message, chatID: UUID, userID: UUID, mode: ChatMode, limit: Int) -> [Message] {
        let sql = """
        SELECT payload
        FROM paged_messages
        WHERE user_id = ? AND mode = ? AND chat_id = ?
          AND (created_at < ? OR (created_at = ? AND message_id < ?))
        ORDER BY created_at DESC, message_id DESC
        LIMIT ?;
        """
        return fetchMessages(sql: sql) { statement in
            bind(statement, index: 1, text: userID.uuidString)
            bind(statement, index: 2, text: mode.rawValue)
            bind(statement, index: 3, text: chatID.uuidString)
            sqlite3_bind_double(statement, 4, anchor.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, anchor.createdAt.timeIntervalSince1970)
            bind(statement, index: 6, text: anchor.id.uuidString)
            sqlite3_bind_int(statement, 7, Int32(limit))
        }
        .reversed()
    }

    func hasMessages(before anchor: Message, chatID: UUID, userID: UUID, mode: ChatMode) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        let sql = """
        SELECT 1
        FROM paged_messages
        WHERE user_id = ? AND mode = ? AND chat_id = ?
          AND (created_at < ? OR (created_at = ? AND message_id < ?))
        LIMIT 1;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }

        bind(statement, index: 1, text: userID.uuidString)
        bind(statement, index: 2, text: mode.rawValue)
        bind(statement, index: 3, text: chatID.uuidString)
        sqlite3_bind_double(statement, 4, anchor.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, anchor.createdAt.timeIntervalSince1970)
        bind(statement, index: 6, text: anchor.id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func purgeChats(_ chatIDs: Set<UUID>, userID: UUID) {
        guard let db else { return }
        guard chatIDs.isEmpty == false else { return }

        let sql = """
        DELETE FROM paged_messages
        WHERE user_id = ? AND chat_id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        withOptionalTransaction(enabled: true) {
            for chatID in chatIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: userID.uuidString)
                bind(statement, index: 2, text: chatID.uuidString)
                sqlite3_step(statement)
            }
        }
    }

    private static func configureDatabase(_ db: OpaquePointer?) {
        guard let db else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS paged_messages (
                user_id TEXT NOT NULL,
                mode TEXT NOT NULL,
                chat_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                client_message_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (user_id, mode, chat_id, message_id)
            );
            """,
            nil,
            nil,
            nil
        )
        sqlite3_exec(
            db,
            """
            CREATE INDEX IF NOT EXISTS idx_paged_messages_lookup
            ON paged_messages (user_id, mode, chat_id, created_at DESC, message_id DESC);
            """,
            nil,
            nil,
            nil
        )
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func beginTransaction() {
        execute("BEGIN IMMEDIATE TRANSACTION;")
    }

    private func commitTransaction() {
        execute("COMMIT;")
    }

    private func insertMessages(
        _ messages: [Message],
        chatID: UUID,
        userID: UUID,
        mode: ChatMode,
        wrapInTransaction: Bool
    ) {
        guard let db, messages.isEmpty == false else { return }
        let sql = """
        INSERT OR REPLACE INTO paged_messages
        (user_id, mode, chat_id, message_id, client_message_id, created_at, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        withOptionalTransaction(enabled: wrapInTransaction) {
            for message in messages.sorted(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }) {
                guard let payload = try? encoder.encode(message) else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: userID.uuidString)
                bind(statement, index: 2, text: mode.rawValue)
                bind(statement, index: 3, text: chatID.uuidString)
                bind(statement, index: 4, text: message.id.uuidString)
                bind(statement, index: 5, text: message.clientMessageID.uuidString)
                sqlite3_bind_double(statement, 6, message.createdAt.timeIntervalSince1970)
                _ = payload.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 7, buffer.baseAddress, Int32(buffer.count), Self.sqliteTransient)
                }
                sqlite3_step(statement)
            }
        }
    }

    private func fetchMessages(sql: String, bindValues: (OpaquePointer?) -> Void) -> [Message] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        bindValues(statement)
        var messages: [Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: length)
            if let message = try? decoder.decode(Message.self, from: data) {
                messages.append(message)
            }
        }
        return messages
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, text: String) {
        sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
    }

    private func withOptionalTransaction(enabled: Bool, _ operation: () -> Void) {
        guard enabled else {
            operation()
            return
        }

        beginTransaction()
        operation()
        commitTransaction()
    }
}
