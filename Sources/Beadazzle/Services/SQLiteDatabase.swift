import CSQLite
import Foundation

enum SQLiteDatabase {
    static func open(url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map(lastError) ?? "Unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw BeadError.sqliteOpen(message)
        }
        return database
    }

    static func applyReadPragmas(_ database: OpaquePointer?) {
        let pragmas = [
            "PRAGMA busy_timeout = 5000",
            "PRAGMA cache_size = -64000",
            "PRAGMA mmap_size = 268435456",
            "PRAGMA temp_store = MEMORY",
            "PRAGMA query_only = ON"
        ]
        for pragma in pragmas {
            _ = sqlite3_exec(database, pragma, nil, nil, nil)
        }
    }

    static func tableExists(_ name: String, in database: OpaquePointer?) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    static func columnExists(_ name: String, in table: String, database: OpaquePointer?) -> Bool {
        columns(in: table, database: database).contains(name)
    }

    static func columns(in table: String, database: OpaquePointer?) -> Set<String> {
        let sql = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, 1).lowercased())
        }
        return columns
    }

    static func lastError(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }

    static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }

    static func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = text(statement, index)
        return value.isEmpty ? nil : value
    }

    static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int {
        Int(sqlite3_column_int(statement, index))
    }
}
