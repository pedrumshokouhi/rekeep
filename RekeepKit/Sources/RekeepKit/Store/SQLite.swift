import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// A result row. Column lookups are by name; rows are small and short-lived.
public struct SQLRow {
    fileprivate let columns: [String: Int]
    fileprivate let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let index = columns[name] else { return .null }
        return values[index]
    }

    public func string(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        default: nil
        }
    }

    public func int(_ name: String) -> Int64? {
        switch self[name] {
        case .int(let i): i
        case .double(let d): Int64(d)
        case .text(let s): Int64(s)
        default: nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch self[name] {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }

    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        return nil
    }

    public func date(_ name: String) -> Date? {
        double(name).map { Date(timeIntervalSince1970: $0) }
    }
}

/// A thin, serialised wrapper over one SQLite connection.
///
/// All access is funnelled through a recursive lock so the connection can be shared
/// across threads; SQLite itself runs in WAL mode so readers in other processes
/// (extensions) are not blocked by writers.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    /// An in-memory database, used by tests.
    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    deinit {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")).flatMap { $0 }.map(Int.init) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var transactionDepth = 0

    /// Runs `body` atomically. Nested calls become savepoints, so store methods compose freely.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            let depth = transactionDepth
            let savepoint = "sp\(depth)"
            try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
                return result
            } catch {
                if depth == 0 {
                    try? execute("ROLLBACK")
                } else {
                    try? execute("ROLLBACK TO \(savepoint)")
                    try? execute("RELEASE \(savepoint)")
                }
                throw error
            }
        }
    }

    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try withLock {
            if bindings.isEmpty, !sql.contains("?") {
                var error: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(handle, sql, nil, nil, &error)
                if rc != SQLITE_OK {
                    let message = error.map { String(cString: $0) } ?? "exec failed"
                    sqlite3_free(error)
                    throw SQLiteError(code: rc, message: message)
                }
                return
            }
            let statement = try prepare(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind(bindings, to: statement)
            var rc = sqlite3_step(statement)
            while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
            guard rc == SQLITE_DONE else { throw lastError(rc) }
        }
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        try withLock {
            let statement = try prepare(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind(bindings, to: statement)
            let count = sqlite3_column_count(statement)
            var columns: [String: Int] = [:]
            for i in 0..<count {
                columns[String(cString: sqlite3_column_name(statement, i))] = Int(i)
            }
            var rows: [SQLRow] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError(rc) }
                var values: [SQLValue] = []
                values.reserveCapacity(Int(count))
                for i in 0..<count {
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(statement, i)))
                    case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(statement, i)))
                    case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(statement, i))))
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_bytes(statement, i)
                        if let pointer = sqlite3_column_blob(statement, i), bytes > 0 {
                            values.append(.blob(Data(bytes: pointer, count: Int(bytes))))
                        } else {
                            values.append(.blob(Data()))
                        }
                    default: values.append(.null)
                    }
                }
                rows.append(SQLRow(columns: columns, values: values))
            }
            return rows
        }
    }

    public var changes: Int { withLock { Int(sqlite3_changes(handle)) } }

    // MARK: - Private

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] { return cached }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw lastError(rc) }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let i): rc = sqlite3_bind_int64(statement, index, i)
            case .double(let d): rc = sqlite3_bind_double(statement, index, d)
            case .text(let s): rc = sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let d):
                rc = d.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(statement, index, buffer.baseAddress, sqlite3_uint64(d.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

// MARK: - Convenience conversions

public extension SQLValue {
    init(_ string: String?) { self = string.map { .text($0) } ?? .null }
    init(_ date: Date?) { self = date.map { .double($0.timeIntervalSince1970) } ?? .null }
    init(_ int: Int?) { self = int.map { .int(Int64($0)) } ?? .null }
    init(_ int: Int64?) { self = int.map { .int($0) } ?? .null }
    init(_ bool: Bool) { self = .int(bool ? 1 : 0) }
}
