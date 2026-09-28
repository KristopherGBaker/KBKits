// These build their own SQLite fixtures with GRDB, so they cannot merely skip where GRDB is
// absent: they would not compile. Same arrangement as `BundledFuriganaTests`.
#if canImport(GRDB)
import Foundation
import GRDB
import Testing
@testable import KBDictionaryKit

/// A file that opens as SQLite is not a dictionary. Before this, any such file reported
/// `isReady` and then answered nothing for every word in the language, so the caller offered
/// a lookup and told the person their word had no entry. The schema is checked at open, once,
/// and a database that fails is treated exactly like an absent one.
@Suite("Malformed dictionary databases are not ready")
struct MalformedDatabaseTests {

    private func fixture(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
    }

    private func build(_ url: URL, _ statements: [String]) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            for sql in statements { try db.execute(sql: sql) }
        }
        try queue.close()
    }

    // MARK: JMdict

    /// The shape a usable JMdict has. Each test below drops exactly one piece of it.
    private var wholeJMDict: [String] {
        ["CREATE TABLE entry (id INTEGER PRIMARY KEY, senses_json TEXT NOT NULL)",
         """
         CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL,
                                  is_kanji INTEGER NOT NULL)
         """,
         "INSERT INTO entry (id, senses_json) VALUES (1, '[]')",
         "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (1, '本', 1)"]
    }

    @Test("the control: the whole schema IS ready, so the checks below mean something")
    func wholeSchemaIsReady() throws {
        let url = fixture("jmdict-whole")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, wholeJMDict)
        #expect(SQLiteJMDictStorage(url: url).isReady)
    }

    @Test("a JMdict missing the entry_form table is not ready")
    func jmdictMissingATableIsNotReady() throws {
        let url = fixture("jmdict-no-entry-form")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE entry (id INTEGER PRIMARY KEY, senses_json TEXT NOT NULL)",
                        "INSERT INTO entry (id, senses_json) VALUES (1, '[]')"])
        #expect(!SQLiteJMDictStorage(url: url).isReady)
    }

    @Test("a JMdict missing the entry table is not ready")
    func jmdictMissingTheEntryTableIsNotReady() throws {
        let url = fixture("jmdict-no-entry")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["""
            CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL,
                                     is_kanji INTEGER NOT NULL)
            """])
        #expect(!SQLiteJMDictStorage(url: url).isReady)
    }

    /// A COLUMN, not a table: the tables can all be there and the queries still fail, which is
    /// what a half-finished schema migration leaves behind.
    @Test("a JMdict whose entry_form has no is_kanji column is not ready")
    func jmdictMissingAColumnIsNotReady() throws {
        let url = fixture("jmdict-no-is-kanji")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE entry (id INTEGER PRIMARY KEY, senses_json TEXT NOT NULL)",
                        "CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL)"])
        #expect(!SQLiteJMDictStorage(url: url).isReady)
    }

    @Test("a JMdict whose entry has no senses_json column is not ready")
    func jmdictMissingSensesColumnIsNotReady() throws {
        let url = fixture("jmdict-no-senses")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE entry (id INTEGER PRIMARY KEY)",
                        """
                        CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL,
                                                 is_kanji INTEGER NOT NULL)
                        """])
        #expect(!SQLiteJMDictStorage(url: url).isReady)
    }

    @Test("a file that is not SQLite at all is not ready")
    func jmdictNonDatabaseIsNotReady() throws {
        let url = fixture("jmdict-garbage")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x7f, count: 4096).write(to: url)
        #expect(!SQLiteJMDictStorage(url: url).isReady)
    }

    @Test("a malformed full dictionary falls back to the bundled seed",
          .enabled(if: DictionaryTestSupport.seedIsAvailable))
    func malformedFullDictionaryFallsBackToTheSeed() throws {
        let url = fixture("jmdict-empty-schema")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE unrelated (x INTEGER)"])

        let store = JMDictStore(databaseURL: url)
        #expect(store.isReady)
        #expect(store.isUsingBundledSeed)
        // And it is really the seed: a word the seed carries resolves.
        #expect(!store.lookup(form: "読む").isEmpty)
    }

    // MARK: KANJIDIC

    private var wholeKanjiDic: [String] {
        ["""
         CREATE TABLE kanji (character TEXT PRIMARY KEY, on_readings TEXT, kun_readings TEXT,
                             meanings TEXT, stroke_count INTEGER, grade INTEGER,
                             frequency INTEGER)
         """,
         """
         INSERT INTO kanji (character, on_readings, kun_readings, meanings, stroke_count,
                            grade, frequency)
         VALUES ('学', '["ガク"]', '["まな.ぶ"]', '["study"]', 8, 1, 63)
         """]
    }

    @Test("the control: the whole kanji schema IS ready")
    func wholeKanjiSchemaIsReady() throws {
        let url = fixture("kanjidic-whole")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, wholeKanjiDic)
        let storage = SQLiteKanjiStorage(url: url)
        #expect(storage.isReady)
        #expect(storage.entry(for: "学")?.strokeCount == 8)
    }

    @Test("a kanji database missing the kanji table is not ready")
    func kanjiMissingTheTableIsNotReady() throws {
        let url = fixture("kanjidic-no-table")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE characters (character TEXT PRIMARY KEY)"])
        #expect(!SQLiteKanjiStorage(url: url).isReady)
    }

    @Test("a kanji database missing the stroke_count column is not ready")
    func kanjiMissingAColumnIsNotReady() throws {
        let url = fixture("kanjidic-no-strokes")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["""
            CREATE TABLE kanji (character TEXT PRIMARY KEY, on_readings TEXT, kun_readings TEXT,
                                meanings TEXT, grade INTEGER, frequency INTEGER)
            """])
        #expect(!SQLiteKanjiStorage(url: url).isReady)
    }

    @Test("a malformed kanji override falls back to the bundled database")
    func malformedKanjiOverrideFallsBackToTheBundle() throws {
        let url = fixture("kanjidic-empty-schema")
        defer { try? FileManager.default.removeItem(at: url) }
        try build(url, ["CREATE TABLE unrelated (x INTEGER)"])

        let store = KanjiStore(databaseURL: url)
        #expect(store.isReady)
        #expect(store.entry(for: "学")?.onReadings == ["ガク"])
    }
}

/// Both bundled databases must be findable through a lookup that does NOT name the enclosing
/// package: this target is copied verbatim into a package called `KBKits`, and a resource
/// lookup keyed to `KBDictionaryKit_KBDictionaryKit` would come back nil there with nothing
/// to say so. The locator's own suffix matching is unit-tested in KBCore.
@Suite("Bundled databases are found without naming the package")
struct BundledResourceLookupTests {

    @Test("the JMdict seed resolves and opens")
    func seedResolves() throws {
        let url = try #require(JMDictStore.bundledSeedURL, "the bundled jmdict seed is missing")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(JMDictStore(databaseURL: url).isReady)
    }

    @Test("the bundled KANJIDIC resolves and opens")
    func kanjidicResolves() throws {
        let url = try #require(KanjiStore.bundledURL, "the bundled kanjidic is missing")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(KanjiStore(databaseURL: url).isReady)
    }

    /// Neither path spells the package out. `Bundle.module` is compiler-generated, so the only
    /// place a package name could be written down is the off-Apple locator call, and it now
    /// takes a target name.
    @Test("no bundled path is derived from the package name")
    func noPackageNameInTheResolvedPaths() throws {
        let seed = try #require(JMDictStore.bundledSeedURL)
        let kanji = try #require(KanjiStore.bundledURL)
        // The resource FILE names are what the code asks for; the bundle around them is
        // whatever the build produced.
        #expect(seed.lastPathComponent == "jmdict-seed.sqlite")
        #expect(kanji.lastPathComponent == "kanjidic.sqlite")
    }
}
#endif
