import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import SwiftToolchainCSQLite
#endif
@testable import KBAnkiKit

/// A schema 18 collection names Anki's own `unicase` collation, and a reader that does not
/// register it cannot read the `fields` table at all.
///
/// The fixture copies the shape of a real collection rather than a convenient one: `fields`
/// is `WITHOUT ROWID` with `name ... COLLATE unicase` and the unique `(name, ntid)` index, as
/// Anki writes it. A WITHOUT ROWID table IS its primary-key index and carries every column,
/// so without the collation SQLite has no access path and reports "no query solution". The
/// earlier fixtures declared a plain rowid `fields` table, which is why they all passed while
/// every real deck failed.
@Suite("Anki's unicase collation")
struct AnkiUnicaseCollationTests {
    /// Anki's own DDL for the tables the reader touches, trimmed to the columns it reads
    /// plus the ones that make each table's shape real.
    private static let schema = """
        CREATE TABLE notetypes (
            id integer NOT NULL PRIMARY KEY,
            name text NOT NULL COLLATE unicase,
            mtime_secs integer NOT NULL,
            usn integer NOT NULL,
            config blob NOT NULL
        );
        CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
        CREATE TABLE fields (
            ntid integer NOT NULL,
            ord integer NOT NULL,
            name text NOT NULL COLLATE unicase,
            config blob NOT NULL,
            PRIMARY KEY (ntid, ord)
        ) WITHOUT ROWID;
        CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
        CREATE TABLE decks (
            id integer PRIMARY KEY NOT NULL,
            name text NOT NULL COLLATE unicase,
            mtime_secs integer NOT NULL,
            usn integer NOT NULL,
            common blob NOT NULL,
            kind blob NOT NULL
        );
        CREATE TABLE notes (
            id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL,
            tags text NOT NULL, flds text NOT NULL
        );
        """

    /// The fixture collection on disk, and the `.apkg` wrapping it (zstd-compressed, as a
    /// current Anki writes it).
    private struct Fixture {
        let collection: URL
        let package: URL

        func remove() {
            try? FileManager.default.removeItem(at: collection)
            try? FileManager.default.removeItem(at: package)
        }
    }

    /// Two note types with DISTINCT field lists, each inserted out of `ord` order so the
    /// read has to sort them, and one note of each.
    private func makeFixture() throws -> Fixture {
        let collection = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki21")
        let separator = AnkiFields.separator
        // Written by a test-local connection, NOT the package's wrapper, so the reader
        // tests below depend on the wrapper's own registration and nothing else: take it
        // out and the reader fails here exactly as it does on a real deck.
        try writeLikeAnki(at: collection.path, Self.schema + """
            INSERT INTO notetypes VALUES (1, 'Kaishi 1.5k', 0, 0, x''), (2, 'Basic', 0, 0, x'');
            INSERT INTO fields VALUES
                (1, 2, 'Word Meaning', x''), (1, 0, 'Word', x''), (1, 1, 'Word Reading', x''),
                (2, 1, 'Back', x''), (2, 0, 'Front', x'');
            INSERT INTO decks VALUES (10, 'Example', 0, 0, x'', x'');
            INSERT INTO notes VALUES
                (100, 'g1', 1, ' core ', '先生\(separator)せんせい\(separator)teacher'),
                (101, 'g2', 2, '', 'question\(separator)answer');
            """)
        let package = try AnkiTestPackage.make([
            "collection.anki21b": AnkiTestPackage.zstdCompress(try Data(contentsOf: collection)),
            "media": Data("{}".utf8)
        ])
        return Fixture(collection: collection, package: package)
    }

    /// Run `sql` on a new collection at `path` the way Anki would: through a connection
    /// that registers its OWN `unicase`, because creating a column `COLLATE unicase` needs
    /// the collation too. A case-insensitive compare is all a writer needs here; the
    /// semantics under test are the package's, below.
    private func writeLikeAnki(at path: String, _ sql: String) throws {
        var opened: OpaquePointer?
        defer { sqlite3_close(opened) }
        try #require(sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let handle = try #require(opened)
        let registered = sqlite3_create_collation_v2(
            handle, "unicase", SQLITE_UTF8, nil,
            { _, leftCount, left, rightCount, right in
                let decode = { (bytes: UnsafeRawPointer?, count: Int32) -> String in
                    guard let bytes, count > 0 else { return "" }
                    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
                }
                switch decode(left, leftCount).caseInsensitiveCompare(decode(right, rightCount)) {
                case .orderedAscending: return -1
                case .orderedSame: return 0
                case .orderedDescending: return 1
                }
            },
            nil)
        try #require(registered == SQLITE_OK)
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        try #require(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(handle)))")
    }

    /// What a connection WITHOUT `unicase` reports for `sql`: nil when it ran to the end,
    /// otherwise SQLite's own message.
    private func bareConnectionError(at path: String, running sql: String) throws -> String? {
        var opened: OpaquePointer?
        defer { sqlite3_close(opened) }
        try #require(sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let handle = try #require(opened)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return String(cString: sqlite3_errmsg(handle))
        }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        return code == SQLITE_DONE ? nil : String(cString: sqlite3_errmsg(handle))
    }

    /// A one-row, one-column integer query through the package's wrapper.
    private func integer(_ sql: String, in database: SQLiteDatabase) throws -> Int64? {
        try database.rows(sql).first?.int("value")
    }

    @Test("The fixture has a real collection's shape: WITHOUT ROWID, COLLATE unicase, the unique index")
    func fixtureHasTheRealShape() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let database = try SQLiteDatabase(path: fixture.collection.path, access: .openExisting)
        let objects = try database.rows("SELECT type, name, tbl_name, sql FROM sqlite_master")
        let fieldsTable = try #require(objects.first { $0.text("type") == "table" && $0.text("name") == "fields" })
        let tableSQL = try #require(fieldsTable.text("sql"))
        #expect(tableSQL.contains("WITHOUT ROWID"))
        #expect(tableSQL.contains("COLLATE unicase"))

        let uniqueIndexes = objects.filter { row in
            row.text("type") == "index" && row.text("tbl_name") == "fields"
                && (row.text("sql") ?? "").contains("CREATE UNIQUE INDEX")
        }
        #expect(uniqueIndexes.contains { ($0.text("sql") ?? "").contains("ON fields (name, ntid)") })
    }

    @Test("Control: a bare connection with no unicase fails on fields with 'no query solution'")
    func bareConnectionCannotReadFields() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.collection.path

        // The collation is the whole cause: the same connection reads a table that names
        // no collation, and fails on exactly the query the reader runs.
        #expect(try bareConnectionError(at: path, running: "SELECT id, guid FROM notes") == nil)
        #expect(try bareConnectionError(at: path, running: "SELECT ntid, ord, name FROM fields")
            == "no query solution")

        // The package's wrapper, which registers it before its first statement, reads the
        // very same file.
        let database = try SQLiteDatabase(path: path, access: .openExisting)
        let rows = try database.rows("SELECT ntid, ord, name FROM fields ORDER BY ntid, ord")
        let read = rows.map { "\($0.int("ntid") ?? -1)/\($0.int("ord") ?? -1)/\($0.text("name") ?? "")" }
        #expect(read == [
            "1/0/Word", "1/1/Word Reading", "1/2/Word Meaning",
            "2/0/Front", "2/1/Back"
        ])
    }

    @Test("AnkiPackageReader reads a collection whose fields table is WITHOUT ROWID and COLLATE unicase")
    func readerReadsTheRealShape() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let collection = try AnkiPackageReader().read(contentsOf: fixture.package)
        let kaishi = try #require(collection.noteTypes.first { $0.name == "Kaishi 1.5k" })
        let basic = try #require(collection.noteTypes.first { $0.name == "Basic" })
        #expect(collection.noteTypes.count == 2)
        #expect(kaishi.fieldNames == ["Word", "Word Reading", "Word Meaning"])
        #expect(basic.fieldNames == ["Front", "Back"])
        #expect(collection.decks.map(\.name) == ["Example"])

        let word = try #require(collection.notes.first { $0.noteTypeID == kaishi.id })
        #expect(word.value(of: "Word Meaning", in: kaishi) == "teacher")
        let card = try #require(collection.notes.first { $0.noteTypeID == basic.id })
        #expect(card.value(of: "Back", in: basic) == "answer")
    }

    @Test("unicase compares case-folded, as Rust's unicase does", arguments: [
        ("Front", "front"),
        ("\u{00C4}", "\u{00E4}"),
        // Full case folding, not a simple case map: "ß" folds to "ss", which no
        // per-character lowercase produces.
        ("Straße", "STRASSE")
    ])
    func caseFoldedNamesAreEqual(left: String, right: String) throws {
        let database = try SQLiteDatabase(path: ":memory:", access: .createOrOpen)
        let quotedLeft = left.replacingOccurrences(of: "'", with: "''")
        let quotedRight = right.replacingOccurrences(of: "'", with: "''")
        #expect(try integer(
            "SELECT '\(quotedLeft)' = '\(quotedRight)' COLLATE unicase AS value", in: database) == 1)
        // Plain binary comparison tells them apart, so the collation is what decided.
        #expect(try integer("SELECT '\(quotedLeft)' = '\(quotedRight)' AS value", in: database) == 0)
        #expect(SQLiteDatabase.unicaseOrder(left, right) == 0)
    }

    @Test("unicase still tells different names apart, in a stable order")
    func differentNamesAreUnequal() throws {
        let database = try SQLiteDatabase(path: ":memory:", access: .createOrOpen)
        #expect(try integer("SELECT 'Front' = 'Back' COLLATE unicase AS value", in: database) == 0)
        #expect(SQLiteDatabase.unicaseOrder("Front", "Back") > 0)
        #expect(SQLiteDatabase.unicaseOrder("back", "FRONT") < 0)
    }

    /// The fold Rust unicase 2.6.0 applies, as Tools/generate-unicase-fold.sh dumped it from
    /// the crate: scalar value to the scalar values the crate's iterator yields.
    private func crateFolds() throws -> [UInt32: [UInt32]] {
        let url = try #require(Bundle.module.url(forResource: "unicase-2.6.0-folds", withExtension: "tsv"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var folds: [UInt32: [UInt32]] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            try #require(columns.count == 2, "malformed row: \(line)")
            let key = try #require(UInt32(columns[0], radix: 16))
            let fold = try columns[1].split(separator: " ").map { try #require(UInt32($0, radix: 16)) }
            try #require(folds.updateValue(fold, forKey: key) == nil, "duplicate row: \(line)")
        }
        return folds
    }

    @Test("The fold is unicase 2.6.0's for every scalar, 0 through 10FFFF")
    func foldMatchesTheCrateExhaustively() throws {
        let oracle = try crateFolds()
        // The crate's own count, so a truncated or padded dump cannot pass as the oracle.
        #expect(oracle.count == 1487)
        #expect(oracle.values.filter { $0.count == 3 }.count == 16)
        // Every row names a real scalar, so the walk below checks each one.
        #expect(oracle.keys.allSatisfy { Unicode.Scalar($0) != nil })

        var mismatches: [String] = []
        var walked = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            walked += 1
            let expected = oracle[value] ?? [value]
            let actual = UnicaseFold.fold(scalar)
            if actual != expected {
                mismatches.append("U+\(String(value, radix: 16, uppercase: true)): \(actual) != \(expected)")
            }
        }
        // Every scalar: all of 0...10FFFF but the 2,048 surrogates.
        #expect(walked == 0x110000 - 0x800)
        #expect(mismatches.isEmpty, "\(mismatches.count) scalars differ, first: \(mismatches.prefix(5))")
    }

    @Test("unicase orders as the crate does, quirks included")
    func ordersAsTheCrateDoes() throws {
        // Cherokee U+13A0 folds to itself in the crate, so it sorts before Yi U+A000.
        // Foundation folds it to U+AB70 and gets the opposite.
        #expect(SQLiteDatabase.unicaseOrder("\u{13A0}", "\u{A000}") < 0)
        #expect(SQLiteDatabase.unicaseOrder("\u{A000}", "\u{13A0}") > 0)
        #expect(SQLiteDatabase.unicaseOrder("\u{00DF}", "ss") == 0)
        // The crate's iterator yields Fold::Three(a, b, c) as c, a, b, so U+FB03 is "iff",
        // not "ffi". Kept on purpose: the index order in a collection Anki wrote follows it.
        #expect(SQLiteDatabase.unicaseOrder("\u{FB03}", "iff") == 0)
        #expect(SQLiteDatabase.unicaseOrder("\u{FB03}", "ffi") != 0)

        // The same answers through SQLite, where the collection's indexes see them.
        let database = try SQLiteDatabase(path: ":memory:", access: .createOrOpen)
        #expect(try integer("SELECT '\u{13A0}' < '\u{A000}' COLLATE unicase AS value", in: database) == 1)
        #expect(try integer("SELECT '\u{FB03}' = 'iff' COLLATE unicase AS value", in: database) == 1)
        #expect(try integer("SELECT '\u{FB03}' = 'ffi' COLLATE unicase AS value", in: database) == 0)
    }

    @Test("The unique (name, ntid) index refuses Front then FRONT under one note type")
    func uniqueIndexFoldsCase() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let database = try SQLiteDatabase(path: fixture.collection.path, access: .openExisting)

        try database.execute("INSERT INTO fields VALUES (3, 0, 'Front', x'')")
        #expect {
            try database.execute("INSERT INTO fields VALUES (3, 1, 'FRONT', x'')")
        } throws: { error in
            guard case AnkiError.databaseFailure(let message) = error else { return false }
            return message.contains("UNIQUE constraint failed")
        }
        // The same name under a DIFFERENT note type is fine: the index is on the pair.
        try database.execute("INSERT INTO fields VALUES (4, 0, 'FRONT', x'')")
    }
}
