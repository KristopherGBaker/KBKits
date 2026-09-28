public import Foundation

// GRDB is declared `.when(platforms:)` for the Apple platforms in Package.swift, because it
// cannot build for Android under any configuration. This whole file goes with it, and
// `JMDictStore` falls back to `EmptyJMDictStorage` where it is absent.
#if canImport(GRDB)
import GRDB
// Diagnostics go to the unified log, never to stdout: a dictionary lookup carries what a
// person is reading and a database path carries their home directory, and a `print` puts
// both in every consuming app's console in release. `os` is Apple-only, and so (by
// necessity, see the note above) is GRDB, so it lives under the same roof; the
// `canImport` guard is also what `make check-portability` looks for.
#if canImport(os)
import os
#endif

/// `JMDictStorage` over the read-only SQLite built by `Tools/build-jmdict.swift`.
///
/// Thread-safe via GRDB's `DatabaseQueue`. Opening is failable in practice rather than by
/// signature: a database that cannot be opened, OR whose schema is not the one these queries
/// are written against, produces a storage that is simply not ready, which is the same shape
/// as a missing one and keeps the failure out of every call site.
public final class SQLiteJMDictStorage: JMDictStorage {
    private static let log = Logger(subsystem: "com.krisbaker.KBDictionaryKit",
                                    category: "SQLiteJMDictStorage")

    private let queue: DatabaseQueue?
    /// Whether the opened dictionary has the `gloss_eng` column (the katakana→English
    /// gloss). Older full dictionaries built before it degrade to no glosses instead of
    /// erroring on every query.
    private let hasGlossColumn: Bool
    /// Whether the opened dictionary has the `furigana` table (JmdictFurigana per-kanji
    /// segmentation). Older databases built before it degrade to no segments instead of
    /// erroring on every query.
    private let hasFuriganaTable: Bool

    /// The tables and columns every query in this file is written against. A file that opens
    /// as SQLite but does not have these is NOT a dictionary: it is a stray database, a
    /// truncated download, or a build that failed halfway, and treating it as ready made
    /// `isReady` report a working lookup that then failed on every single word. Validated
    /// once at open, so a caller never has to.
    ///
    /// `gloss_eng` and the `furigana` table are deliberately absent: those are genuine
    /// version differences an older full dictionary is allowed to have, and each already
    /// degrades to "no glosses" / "no segments" rather than to an error.
    static let requiredSchema: [(table: String, columns: [String])] = [
        (table: "entry", columns: ["id", "senses_json"]),
        (table: "entry_form", columns: ["entry_id", "form", "is_kanji"])
    ]

    /// Opens the database at `url`, or produces a not-ready storage when `url` is nil, cannot
    /// be opened, or does not carry the schema these queries need.
    public init(url: URL?) {
        guard let url else {
            self.queue = nil
            self.hasGlossColumn = false
            self.hasFuriganaTable = false
            return
        }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            guard try queue.read({ try Self.hasRequiredSchema($0) }) else {
                Self.log.error("""
                    dictionary at \(url.path, privacy: .private) is missing an expected table \
                    or column; treating it as unavailable
                    """)
                self.queue = nil
                self.hasGlossColumn = false
                self.hasFuriganaTable = false
                return
            }
            self.queue = queue
            self.hasGlossColumn = (try? queue.read { db in
                try db.columns(in: "entry").contains { $0.name == "gloss_eng" }
            }) ?? false
            self.hasFuriganaTable = (try? queue.read { db in
                try db.tableExists("furigana")
            }) ?? false
        } catch {
            Self.log.error("""
                failed to open the dictionary at \(url.path, privacy: .private): \
                \(String(describing: error), privacy: .private)
                """)
            self.queue = nil
            self.hasGlossColumn = false
            self.hasFuriganaTable = false
        }
    }

    /// Whether `db` carries every table and column in ``requiredSchema``.
    static func hasRequiredSchema(_ db: Database) throws -> Bool {
        for entry in requiredSchema {
            guard try db.tableExists(entry.table) else { return false }
            let present = Set(try db.columns(in: entry.table).map(\.name))
            guard entry.columns.allSatisfy(present.contains) else { return false }
        }
        return true
    }

    /// A failed query, recorded without the term that was looked up.
    ///
    /// The term is what the person is reading, and the only thing it could tell a maintainer
    /// is which query broke, which `query` already says. So it is not redacted, it is simply
    /// not collected: a reading a learner looked up is not diagnostics.
    private static func logQueryFailure(_ query: String, _ error: any Error) {
        log.error("""
            \(query, privacy: .public) failed: \
            \(String(describing: error), privacy: .private)
            """)
    }

    public var isReady: Bool { queue != nil }

    public func entries(matchingForm form: String, limit: Int) -> [JMDictEntry] {
        guard let queue, !form.isEmpty else { return [] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT e.id, e.senses_json
                    FROM entry e
                    JOIN entry_form ef ON ef.entry_id = e.id
                    WHERE ef.form = ?
                    LIMIT ?
                    """, arguments: [form, limit])
                return try rows.compactMap { row in try Self.materialize(row: row, in: db) }
            }
        } catch {
            Self.logQueryFailure("entries(matchingForm:limit:)", error)
            return []
        }
    }

    public func englishGloss(forKatakana form: String) -> String? {
        guard let queue, hasGlossColumn, !form.isEmpty else { return nil }
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT e.gloss_eng
                    FROM entry e
                    JOIN entry_form ef ON ef.entry_id = e.id
                    WHERE ef.form = ? AND e.gloss_eng IS NOT NULL
                    LIMIT 1
                    """, arguments: [form])
            }
        } catch {
            Self.logQueryFailure("englishGloss(forKatakana:)", error)
            return nil
        }
    }

    /// ONE indexed self-join, no senses-JSON decode: `entries(matchingForm:)` materializes
    /// entries, and the reading validator only needs the kana and calls this per kanji token
    /// during reader builds, so it has to stay cheap.
    public func kanaReadings(forForm form: String) -> [String] {
        guard let queue, !form.isEmpty else { return [] }
        do {
            return try queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT ef2.form
                    FROM entry_form ef
                    JOIN entry_form ef2 ON ef2.entry_id = ef.entry_id
                    WHERE ef.form = ? AND ef2.is_kanji = 0
                    """, arguments: [form])
            }
        } catch {
            Self.logQueryFailure("kanaReadings(forForm:)", error)
            return []
        }
    }

    /// The prefix scan behind the "can the ordinary dictionary account for our reading?" gate.
    ///
    /// A RANGE over the indexed `form` column, not `LIKE 'x%'`: SQLite uses `idx_entry_form_form`
    /// for a range and (with the default BINARY collation and no `case_sensitive_like`) will not
    /// reliably use it for LIKE. The upper bound appends U+10FFFF, the largest scalar, so every
    /// form beginning with `prefix` sorts below it in UTF-8 byte order and nothing real is
    /// excluded.
    public func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String] {
        guard let queue, !prefix.isEmpty else { return [] }
        do {
            return try queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT r.form
                    FROM entry_form k
                    JOIN entry_form r ON r.entry_id = k.entry_id AND r.is_kanji = 0
                    WHERE k.is_kanji = 1 AND k.form >= ? AND k.form < ?
                    LIMIT ?
                    """, arguments: [prefix, prefix + "\u{10FFFF}", limit])
            }
        } catch {
            Self.logQueryFailure("kanaReadings(forKanjiFormsStartingWith:limit:)", error)
            return []
        }
    }

    public func furiganaSegmentation(form: String, reading: String) -> String? {
        guard let queue, hasFuriganaTable, !form.isEmpty, !reading.isEmpty else { return nil }
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT segmentation FROM furigana WHERE form = ? AND reading = ? LIMIT 1
                    """, arguments: [form, reading])
            }
        } catch {
            Self.logQueryFailure("furiganaSegmentation(form:reading:)", error)
            return nil
        }
    }

    private static func materialize(row: Row, in db: Database) throws -> JMDictEntry? {
        let id: Int = row["id"]
        guard let json: String = row["senses_json"],
              let data = json.data(using: .utf8) else { return nil }
        let senses = (try? JSONDecoder().decode([JMDictSense].self, from: data)) ?? []

        let forms = try Row.fetchAll(db, sql: """
            SELECT form, is_kanji FROM entry_form WHERE entry_id = ?
            """, arguments: [id])
        var kanji: [String] = []
        var kana: [String] = []
        for row in forms {
            let form: String = row["form"]
            let isKanji: Int = row["is_kanji"]
            if isKanji == 1 { kanji.append(form) } else { kana.append(form) }
        }
        return JMDictEntry(id: id, kanjiForms: kanji, kanaForms: kana, senses: senses)
    }
}
#endif
