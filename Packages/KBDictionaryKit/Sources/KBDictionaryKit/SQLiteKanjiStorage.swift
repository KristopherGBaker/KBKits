public import Foundation

// GRDB is declared `.when(platforms:)` for the Apple platforms in Package.swift, because it
// cannot build for Android under any configuration. This whole file goes with it, and
// `KanjiStore` falls back to `EmptyKanjiStorage` where it is absent - the same arrangement
// `SQLiteJMDictStorage` has.
#if canImport(GRDB)
import GRDB
// The unified log rather than stdout, and for the same reason as in
// `SQLiteJMDictStorage`: a database path carries the user's home directory.
#if canImport(os)
import os
#endif

/// `KanjiStorage` over the read-only SQLite built by `Tools/build-kanjidic.swift`.
///
/// Opening is failable in practice rather than by signature: a database that cannot be
/// opened, OR whose schema is not the one this query is written against, produces a storage
/// that is simply not ready, which is the same shape as a missing one and keeps the failure
/// out of every call site.
public final class SQLiteKanjiStorage: KanjiStorage {
    private static let log = Logger(subsystem: "com.krisbaker.KBDictionaryKit",
                                    category: "SQLiteKanjiStorage")

    private let queue: DatabaseQueue?

    /// The one table and the seven columns `entry(for:)` selects. A file that opens as SQLite
    /// without them is not a KANJIDIC, and reporting it ready produced kanji cards that were
    /// blank for every character in the language.
    static let requiredColumns = ["character", "on_readings", "kun_readings", "meanings",
                                  "stroke_count", "grade", "frequency"]

    public init(url: URL?) {
        guard let url else { self.queue = nil; return }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            guard try queue.read({ try Self.hasRequiredSchema($0) }) else {
                Self.log.error("""
                    the kanji database at \(url.path, privacy: .private) is missing the kanji \
                    table or one of its columns; treating it as unavailable
                    """)
                self.queue = nil
                return
            }
            self.queue = queue
        } catch {
            Self.log.error("""
                failed to open the kanji database at \(url.path, privacy: .private): \
                \(String(describing: error), privacy: .private)
                """)
            self.queue = nil
        }
    }

    /// Whether `db` carries the `kanji` table with every column in ``requiredColumns``.
    static func hasRequiredSchema(_ db: Database) throws -> Bool {
        guard try db.tableExists("kanji") else { return false }
        let present = Set(try db.columns(in: "kanji").map(\.name))
        return requiredColumns.allSatisfy(present.contains)
    }

    public var isReady: Bool { queue != nil }

    public func entry(for character: String) -> KanjiEntry? {
        guard let queue else { return nil }
        return try? queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT character, on_readings, kun_readings, meanings,
                           stroke_count, grade, frequency
                    FROM kanji WHERE character = ?
                    """,
                arguments: [character])
            else { return nil }
            return KanjiEntry(
                character: row["character"],
                onReadings: Self.list(row["on_readings"]),
                kunReadings: Self.list(row["kun_readings"]),
                meanings: Self.list(row["meanings"]),
                strokeCount: row["stroke_count"],
                grade: row["grade"],
                frequency: row["frequency"])
        }
    }

    /// The three list columns are JSON arrays. A malformed one reads as empty rather than
    /// throwing: a card missing its kun readings is worth showing, a lookup that fails is not.
    private static func list(_ value: String?) -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
#endif
