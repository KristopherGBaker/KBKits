import Foundation
// Apple platforms ship SQLite in the SDK as the `SQLite3` module. Nothing else does: the
// Android NDK exposes no public SQLite header or link target, even though the system carries
// the library. swift-toolchain-sqlite vendors the amalgamation for exactly this problem (it
// is what SwiftPM itself uses off Apple), so the C API below is identical either way and only
// the module providing it changes.
#if canImport(SQLite3)
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

/// The transient destructor: tells SQLite to copy a bound string rather than borrow
/// it, which it must, because the Swift buffer dies at the end of the bind call.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A column value, in the only four shapes an Anki collection uses.
enum SQLiteValue: Sendable, Hashable {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null

    var intValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        default: return nil
        }
    }
}

/// One materialised row, addressed by column name.
struct SQLiteRow: Sendable {
    private let values: [String: SQLiteValue]

    init(values: [String: SQLiteValue]) { self.values = values }

    subscript(column: String) -> SQLiteValue { values[column] ?? .null }
    func int(_ column: String) -> Int64? { self[column].intValue }
    func text(_ column: String) -> String? { self[column].textValue }
}

/// A deliberately small sqlite3 wrapper: open, execute, query, insert.
///
/// This package uses the platform SQLite rather than GRDB on purpose. GRDB is
/// KBDictionaryKit's, and Apple-only there (see Package.swift), so reaching it from
/// here would tie an Anki package to the Japanese dictionary's dependency and to Apple
/// platforms. Neither is worth it for the handful of statements below.
///
/// Queries MATERIALISE their rows. Decks are thousands of notes, not millions, and
/// a cursor whose body can throw fights typed throws for no gain at that size.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    /// How to open the file.
    enum Access {
        /// Create it if absent. Used when WRITING a package.
        case createOrOpen
        /// Open an existing file for read and write, never creating one.
        ///
        /// Read and write rather than read-only even though nothing is written: a
        /// WAL-mode database cannot be opened READONLY unless its `-wal` and `-shm`
        /// sidecars are present, and an extracted collection has neither. Anki uses
        /// WAL, so read-only fails on real decks and passes on every fixture written
        /// in rollback mode. Not creating keeps a missing file an error rather than
        /// an empty database that later reports "no such table".
        case openExisting
    }

    init(path: String, access: Access) throws(AnkiError) {
        var pointer: OpaquePointer?
        let flags = access == .createOrOpen
            ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let opened = pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            if pointer != nil { sqlite3_close(pointer) }
            throw AnkiError.databaseFailure(message)
        }
        // Registered BEFORE the first statement, and that order is the fix. SQLite parses
        // the whole schema on a connection's first statement; a schema naming a collation
        // the connection lacks then leaves any table that depends on it unreadable, and
        // registering afterwards does not help.
        guard Self.registerUnicase(on: opened) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close(opened)
            throw AnkiError.databaseFailure("could not register the unicase collation: \(message)")
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    /// Registers Anki's `unicase` collation on `connection`.
    ///
    /// A schema 18 collection declares names `COLLATE unicase`, a collation Anki registers
    /// itself. Most tables survive without it, but `fields` is `WITHOUT ROWID`: such a
    /// table IS its primary-key index and carries every column, so with `unicase` missing
    /// SQLite has no usable access path and `SELECT ... FROM fields` fails with "no query
    /// solution". That is every current deck, Kaishi 1.5k among them.
    ///
    /// Anki's collation is Rust's `unicase` crate, pinned at 2.6.0: each scalar mapped
    /// through the crate's own fold table, then an ordinal comparison of the folded
    /// scalars. `UnicaseFold` is that table, generated from the crate, so "Straße" and
    /// "STRASSE" are one name here as they are there, and the order agrees with Anki's for
    /// the unique `(name, ntid)` index the collection was written under.
    private static func registerUnicase(on connection: OpaquePointer) -> Int32 {
        sqlite3_create_collation_v2(
            connection, "unicase", SQLITE_UTF8, nil,
            { _, leftCount, left, rightCount, right in
                SQLiteDatabase.unicaseOrder(
                    SQLiteDatabase.string(left, count: leftCount),
                    SQLiteDatabase.string(right, count: rightCount))
            },
            nil)
    }

    /// The `unicase` order of two strings: negative, zero or positive, as SQLite expects.
    ///
    /// This is `UniCase::unicode` order and nothing else: no Foundation folding, which
    /// disagrees with the crate (it folds Cherokee U+13A0 to U+AB70, the crate leaves it),
    /// and no normalisation, which the crate does not do either.
    static func unicaseOrder(_ left: String, _ right: String) -> Int32 {
        let leftScalars = left.unicodeScalars.flatMap(UnicaseFold.fold)
        let rightScalars = right.unicodeScalars.flatMap(UnicaseFold.fold)
        if leftScalars == rightScalars { return 0 }
        return leftScalars.lexicographicallyPrecedes(rightScalars) ? -1 : 1
    }

    /// The text of a collation argument: `count` bytes of UTF-8, not NUL-terminated.
    private static func string(_ bytes: UnsafeRawPointer?, count: Int32) -> String {
        guard let bytes, count > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
    }

    private var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Run one or more statements for their effect (DDL, pragmas, transactions).
    func execute(_ sql: String) throws(AnkiError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw AnkiError.databaseFailure(lastMessage)
        }
    }

    /// Run `sql` and return every row.
    func rows(_ sql: String) throws(AnkiError) -> [SQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AnkiError.databaseFailure(lastMessage)
        }
        defer { sqlite3_finalize(statement) }

        var result: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                values[name] = Self.value(of: statement, at: index)
            }
            result.append(SQLiteRow(values: values))
        }
        return result
    }

    /// Run `sql` once with `values` bound to its `?` placeholders, in order.
    func run(_ sql: String, _ values: [SQLiteValue]) throws(AnkiError) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AnkiError.databaseFailure(lastMessage)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AnkiError.databaseFailure(lastMessage)
        }
    }

    /// Whether `table` exists, so a reader can tell the two collection schemas apart
    /// by what they hold rather than by a version number they may not carry.
    func hasTable(_ table: String) throws(AnkiError) -> Bool {
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(escaped)'"
        return try !rows(sql).isEmpty
    }

    private static func value(of statement: OpaquePointer?, at index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            guard let raw = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: raw))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .null }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default:
            return .null
        }
    }
}
