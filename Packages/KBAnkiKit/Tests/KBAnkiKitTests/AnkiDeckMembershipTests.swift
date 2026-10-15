import Foundation
import Testing
import ZIPFoundation
@testable import KBAnkiKit

/// Deck membership is read from the `cards` table, which is where Anki keeps it in
/// both schemas. These fixtures are built by hand rather than through the writer: a
/// note's decks are EXACTLY the decks its own cards sit in, so the risk to rule out
/// is an implementation that hands every deck to every note, and a fixture with two
/// notes in two different decks plus a cardless third is what catches it.
@Suite("Per-note deck membership")
struct AnkiDeckMembershipTests {
    /// The `notes` columns the reader selects, spelled once. Nested deck names and
    /// field packing do not matter here, so a single plain field is enough.
    private static let notesDDL = """
    CREATE TABLE notes (
        id integer primary key, guid text not null, mid integer not null,
        tags text not null, flds text not null
    )
    """

    /// The `cards` table carries only what deck attribution needs: a card points at
    /// its note through `nid` and at its deck through `did`.
    private static let cardsDDL = """
    CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null)
    """

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

    /// Build a collection database from raw statements and package it as an `.apkg`,
    /// so the reader sees a real archive rather than a bare file.
    private func makePackage(collection statements: [String]) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki2")
        let database = try SQLiteDatabase(path: path.path, access: .createOrOpen)
        for statement in statements { try database.execute(statement) }
        _ = database
        let data = try Data(contentsOf: path)
        return try makePackage(["collection.anki2": data, "media": Data("{}".utf8)])
    }

    @Test("Schema 11 deck membership is attributed per note, not globally")
    func schema11DeckMembershipFromCards() throws {
        // Schema 11: note types and decks live in the `col` JSON, cards in `cards`.
        // No `notetypes` and no `decks` table, so the reader takes the legacy path.
        let url = try makePackage(collection: [
            "CREATE TABLE col (models text not null, decks text not null)",
            "INSERT INTO col VALUES ('{}', '{}')",
            Self.notesDDL,
            Self.cardsDDL,
            "INSERT INTO notes VALUES (1, 'noteA', 1, '', 'a'), (2, 'noteB', 1, '', 'b'), (3, 'noteC', 1, '', 'c')",
            // note A's only card is in deck 100, note B's only card in deck 200, note C has none.
            "INSERT INTO cards VALUES (10, 1, 100), (11, 2, 200)"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteA = try #require(collection.notes.first { $0.guid == "noteA" })
        let noteB = try #require(collection.notes.first { $0.guid == "noteB" })
        let cardless = try #require(collection.notes.first { $0.guid == "noteC" })
        #expect(noteA.deckIDs == [100])
        #expect(!noteA.deckIDs.contains(200))
        #expect(noteB.deckIDs == [200])
        #expect(!noteB.deckIDs.contains(100))
        #expect(cardless.deckIDs == [])
    }

    @Test("Schema 18 deck membership is attributed per note, not globally")
    func schema18DeckMembershipFromCards() throws {
        // Schema 18: its own `notetypes`/`fields`/`decks` tables, cards still in `cards`.
        let url = try makePackage(collection: [
            "CREATE TABLE notetypes (id integer primary key, name text not null)",
            "CREATE TABLE fields (ntid integer not null, ord integer not null, name text not null)",
            "CREATE TABLE decks (id integer primary key, name text not null)",
            Self.notesDDL,
            Self.cardsDDL,
            "INSERT INTO notetypes VALUES (7, 'Basic')",
            "INSERT INTO fields VALUES (7, 0, 'Front')",
            "INSERT INTO decks VALUES (100, 'DeckA'), (200, 'DeckB')",
            "INSERT INTO notes VALUES (1, 'noteA', 7, '', 'a'), (2, 'noteB', 7, '', 'b'), (3, 'noteC', 7, '', 'c')",
            "INSERT INTO cards VALUES (10, 1, 100), (11, 2, 200)"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteA = try #require(collection.notes.first { $0.guid == "noteA" })
        let noteB = try #require(collection.notes.first { $0.guid == "noteB" })
        let cardless = try #require(collection.notes.first { $0.guid == "noteC" })
        #expect(noteA.deckIDs == [100])
        #expect(!noteA.deckIDs.contains(200))
        #expect(noteB.deckIDs == [200])
        #expect(!noteB.deckIDs.contains(100))
        #expect(cardless.deckIDs == [])
    }

    @Test("A note whose cards span decks exposes all of them, sorted and deduped")
    func noteSpanningDecksExposesAllDecks() throws {
        // One note, three cards: two in deck 500 and one in deck 300. The result must
        // hold BOTH decks, deduped to two, sorted ascending, not just the first seen.
        let url = try makePackage(collection: [
            "CREATE TABLE notetypes (id integer primary key, name text not null)",
            "CREATE TABLE fields (ntid integer not null, ord integer not null, name text not null)",
            "CREATE TABLE decks (id integer primary key, name text not null)",
            Self.notesDDL,
            Self.cardsDDL,
            "INSERT INTO notetypes VALUES (7, 'Basic')",
            "INSERT INTO fields VALUES (7, 0, 'Front')",
            "INSERT INTO decks VALUES (300, 'Lower'), (500, 'Upper')",
            "INSERT INTO notes VALUES (1, 'span', 7, '', 'a')",
            "INSERT INTO cards VALUES (10, 1, 500), (11, 1, 500), (12, 1, 300)"
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let note = try #require(collection.notes.first { $0.guid == "span" })
        #expect(note.deckIDs == [300, 500])
    }

    @Test("The legacy initializers still compile and default deckIDs to empty")
    func compilesWithLegacyInitializers() {
        // Both call forms predate per-note deck membership and must keep compiling,
        // because consumers of this package already use them.
        let note = AnkiNote(guid: "g", noteTypeID: 1, fields: ["先生"], tags: ["core"])
        #expect(note.deckIDs == [])
        let collection = AnkiCollection(noteTypes: [], decks: [], notes: [note])
        #expect(collection.notes.count == 1)
        #expect(collection.notes.first?.deckIDs == [])
    }
}
