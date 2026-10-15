import Foundation
import Testing
import ZIPFoundation
@testable import KBAnkiKit

/// Files we did not write: the modern schema, malformed packages, and notes that
/// disagree with their note type. Building the fixtures by hand is the point: a
/// reader tested only against its own writer proves the two agree, not that either
/// is right.
@Suite("Reading foreign and malformed packages")
struct AnkiReadFailureTests {
    /// Zip `entries` into an `.apkg`-shaped file.
    private func makePackage(_ entries: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(data.count),
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    /// Build a collection database with the given schema statements and rows, and
    /// return its bytes so a test can drop it into a package under any name.
    private func makeCollection(_ statements: [String]) throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki2")
        let database = try SQLiteDatabase(path: path.path, access: .createOrOpen)
        for statement in statements { try database.execute(statement) }
        // Close before reading the file back.
        _ = database
        return try Data(contentsOf: path)
    }

    private static let modernSchema = [
        "CREATE TABLE notetypes (id integer primary key, name text not null)",
        "CREATE TABLE fields (ntid integer not null, ord integer not null, name text not null)",
        "CREATE TABLE decks (id integer primary key, name text not null)",
        """
        CREATE TABLE notes (
            id integer primary key, guid text not null, mid integer not null,
            tags text not null, flds text not null
        )
        """
    ]

    @Test("A schema 18 collection reads through its own tables")
    func readsModernSchema() throws {
        let separator = AnkiFields.separator
        let data = try makeCollection(Self.modernSchema + [
            "INSERT INTO notetypes VALUES (17, 'Japanese (recognition)')",
            "INSERT INTO fields VALUES (17, 1, 'Reading'), (17, 0, 'Expression'), (17, 2, 'Meaning')",
            // Schema 18 spells deck nesting with US, not '::'.
            "INSERT INTO decks VALUES (5, 'Japanese\(separator)Core 2k')",
            """
            INSERT INTO notes VALUES
                (1, 'abc', 17, ' core ', '先生\(separator)せんせい\(separator)teacher')
            """
        ])
        let url = try makePackage(["collection.anki21": data, "media": Data("{}".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteType = try #require(collection.noteTypes.first)
        // Ordered by `ord`, not by insertion order, or every field lands one across.
        #expect(noteType.fieldNames == ["Expression", "Reading", "Meaning"])
        #expect(collection.decks.map(\.name) == ["Japanese::Core 2k"])
        let note = try #require(collection.notes.first)
        #expect(note.value(of: "Expression", in: noteType) == "先生")
        #expect(note.value(of: "Meaning", in: noteType) == "teacher")
        #expect(note.tags == ["core"])
    }

    @Test("A note with fewer fields than its type declares is read, not rejected")
    func shortNoteIsAccepted() throws {
        let data = try makeCollection(Self.modernSchema + [
            "INSERT INTO notetypes VALUES (17, 'Japanese')",
            "INSERT INTO fields VALUES (17, 0, 'Expression'), (17, 1, 'Reading'), (17, 2, 'Meaning')",
            "INSERT INTO notes VALUES (1, 'abc', 17, '', '先生\(AnkiFields.separator)せんせい')"
        ])
        let url = try makePackage(["collection.anki21": data, "media": Data("{}".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteType = try #require(collection.noteTypes.first)
        let note = try #require(collection.notes.first)
        // Normal: a field added to the type later leaves older notes short.
        #expect(note.value(of: "Reading", in: noteType) == "せんせい")
        #expect(note.value(of: "Meaning", in: noteType) == nil)
    }

    @Test("A note with more fields than its type declares is rejected")
    func overlongNoteIsRejected() throws {
        let separator = AnkiFields.separator
        let data = try makeCollection(Self.modernSchema + [
            "INSERT INTO notetypes VALUES (17, 'Japanese')",
            "INSERT INTO fields VALUES (17, 0, 'Expression'), (17, 1, 'Reading')",
            "INSERT INTO notes VALUES (1, 'abc', 17, '', 'a\(separator)b\(separator)c')"
        ])
        let url = try makePackage(["collection.anki21": data, "media": Data("{}".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }

        // Silently dropping the extra would misalign every field a consumer maps.
        #expect(throws: AnkiError.fieldCountMismatch(noteType: "Japanese", declared: 2, found: 3)) {
            try AnkiPackageReader().read(contentsOf: url)
        }
    }

    @Test("A zip that is not an Anki deck names what it actually held")
    func nonAnkiZipIsRejected() throws {
        let url = try makePackage(["notes.txt": Data("hello".utf8), "cover.jpg": Data()])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: AnkiError.notAnAnkiPackage(found: ["cover.jpg", "notes.txt"])) {
            try AnkiPackageReader().read(contentsOf: url)
        }
    }

    @Test("An empty compressed collection is reported rather than read as nothing")
    func emptyCompressedCollectionIsReported() throws {
        let url = try makePackage(["collection.anki21b": Data(), "media": Data("{}".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }
        // Decoding it to an empty database would present a deck with no notes as a
        // successful import of nothing.
        #expect(throws: AnkiError.unreadableArchive("the compressed collection is empty")) {
            try AnkiPackageReader().read(contentsOf: url)
        }
    }

    @Test("A file that is not a zip at all fails as an unreadable archive")
    func nonZipIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: AnkiError.self) { try AnkiPackageReader().read(contentsOf: url) }
    }

    @Test("A package holding both collections prefers the newer one")
    func newerCollectionWins() throws {
        let modern = try makeCollection(Self.modernSchema + [
            "INSERT INTO notetypes VALUES (17, 'Modern')",
            "INSERT INTO fields VALUES (17, 0, 'Expression')",
            "INSERT INTO notes VALUES (1, 'abc', 17, '', 'from anki21')"
        ])
        let legacy = try makeCollection([
            "CREATE TABLE col (models text not null, decks text not null)",
            "INSERT INTO col VALUES ('{}', '{}')",
            """
            CREATE TABLE notes (
                id integer primary key, guid text not null, mid integer not null,
                tags text not null, flds text not null
            )
            """,
            "INSERT INTO notes VALUES (1, 'abc', 17, '', 'from anki2')"
        ])
        let url = try makePackage([
            "collection.anki2": legacy, "collection.anki21": modern, "media": Data("{}".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        // Anki writes both for cross-version compatibility; the newer one is complete.
        #expect(try AnkiPackageReader().read(contentsOf: url).notes.first?.fields == ["from anki21"])
    }
}
