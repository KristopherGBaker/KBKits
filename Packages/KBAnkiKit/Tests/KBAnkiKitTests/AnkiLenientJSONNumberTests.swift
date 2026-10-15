import Foundation
import Testing
@testable import KBAnkiKit

/// `col.models` / `col.decks` are hand-rolled JSON blobs, and the tools that write them
/// do not agree on whether a number is a number.
///
/// genanki - which builds most generated and shared decks - writes note-type ids as
/// STRINGS while writing deck ids as numbers. A strict `as? NSNumber` cast returned nil,
/// `compactMap` dropped every model, and the package read back as 665 notes and 0 note
/// types: nothing to map fields against, and no error anywhere saying so.
///
/// The fixtures below are hand-built and tiny on purpose. A 30 MB real deck would pin the
/// same behaviour and could not be committed, read in a sandbox, or narrowed when it
/// broke.
@Suite("Lenient JSON numbers in a legacy collection")
struct AnkiLenientJSONNumberTests {
    private static let notesDDL = """
    CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null,
                        tags text not null, flds text not null)
    """
    private static let cardsDDL = """
    CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null)
    """

    /// A schema 11 package whose `col` carries the given `models` and `decks` JSON
    /// verbatim, so a test controls exactly how the numbers are written. The `notes`
    /// table is always present because the reader queries it unconditionally; a fixture
    /// that omitted it would fail for a reason that has nothing to do with these tests.
    private func makePackage(models: String, decks: String, extra: [String] = []) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki2")
        let database = try SQLiteDatabase(path: path.path, access: .createOrOpen)
        try database.execute("CREATE TABLE col (models text not null, decks text not null)")
        try database.execute(
            "INSERT INTO col VALUES ('\(models.replacingOccurrences(of: "'", with: "''"))', "
            + "'\(decks.replacingOccurrences(of: "'", with: "''"))')")
        try database.execute(Self.notesDDL)
        try database.execute(Self.cardsDDL)
        for statement in extra { try database.execute(statement) }
        _ = database
        return try AnkiTestPackage.make([
            "collection.anki2": try Data(contentsOf: path), "media": Data("{}".utf8)
        ])
    }

    /// One model keyed by `id`, whose `id` value and whose every field `ord` are written
    /// exactly as `idJSON` / `ord` give them - quoted or not. The object KEY is always a
    /// string, as JSON requires; it is the VALUE whose type varies between writers.
    private func model(
        id: Int64, idJSON: String, name: String, fields: [(name: String, ord: String)]
    ) -> String {
        let flds = fields.map { #"{"name":"\#($0.name)","ord":\#($0.ord)}"# }.joined(separator: ",")
        return #"{"\#(id)":{"id":\#(idJSON),"name":"\#(name)","flds":[\#(flds)]}}"#
    }

    // MARK: - The reported bug

    @Test("a genanki deck's note types are read, ids and ords written as strings")
    func genankiStringIDsAreRead() throws {
        // The exact shape genanki writes: the id is a quoted string in BOTH the key and
        // the value. This returned zero note types.
        let url = try makePackage(
            models: model(
                id: 1_607_392_319, idJSON: #""1607392319""#, name: "BJT Vocabulary",
                fields: [("Word", #""0""#), ("Meaning", #""1""#)]),
            decks: #"{"1":{"id":1,"name":"BJT"}}"#,
            extra: [
                // `char(31)` is the unit separator the format packs fields with, written
                // in SQL so the fixture does not have to smuggle a control byte through
                // a Swift string literal.
                "INSERT INTO notes VALUES (1, 'n1', 1607392319, '', '単語' || char(31) || 'a word')",
                "INSERT INTO cards VALUES (10, 1, 1)"
            ])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.noteTypes.count == 1)
        let type = try #require(collection.noteTypes.first)
        #expect(type.id == 1_607_392_319)
        #expect(type.name == "BJT Vocabulary")
        #expect(type.fieldNames == ["Word", "Meaning"])
        // The note must resolve to that type, which is the whole point of reading it.
        let note = try #require(collection.notes.first)
        #expect(collection.noteType(for: note)?.id == type.id)
        #expect(note.value(of: "Word", in: type) == "単語")
        #expect(note.value(of: "Meaning", in: type) == "a word")
    }

    @Test("a deck id written as a string is read too")
    func stringDeckIDIsRead() throws {
        let url = try makePackage(
            models: model(id: 1, idJSON: "1", name: "Basic", fields: [("Front", "0")]),
            decks: #"{"1607392319":{"id":"1607392319","name":"BJT::Listening"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.decks.map(\.id) == [1_607_392_319])
        #expect(collection.decks.first?.name == "BJT::Listening")
    }

    // MARK: - Field ORDER, the site whose failure is silent

    @Test("a stringified ord orders fields, it does not collapse them")
    func stringOrdKeepsFieldOrder() throws {
        // The array is deliberately in the WRONG order, so only the `ord` values can
        // produce the right answer. Under the old cast both ords fell back to 0, the
        // sort became the array order, and every note's values were read out of the
        // wrong slot - fields are positional - with nothing reported anywhere.
        let url = try makePackage(
            models: model(
                id: 1, idJSON: "1", name: "Basic",
                fields: [("Meaning", #""1""#), ("Word", #""0""#)]),
            decks: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.noteTypes.first?.fieldNames == ["Word", "Meaning"])
    }

    @Test("a field with no readable ord keeps its position rather than jumping to the front")
    func unreadableOrdFallsBackToPosition() throws {
        // Defaulting an unreadable ord to 0 puts that field FIRST, which is a different
        // wrong answer from leaving it where the file put it. Position is the honest
        // fallback: the array order is what the writer actually recorded.
        let url = try makePackage(
            models: #"""
            {"1":{"id":1,"name":"Basic",
             "flds":[{"name":"Front","ord":0},{"name":"Back"},{"name":"Extra"}]}}
            """#,
            decks: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.noteTypes.first?.fieldNames == ["Front", "Back", "Extra"])
    }

    // MARK: - Diagnosability

    @Test("a collection that describes note types but yields none throws, naming how many")
    func totalParseFailureThrows() throws {
        // Two models, neither with a usable id. Returning [] here is indistinguishable
        // from "this file has no note types", and that is what made the original bug
        // read as a problem with the deck's contents.
        let url = try makePackage(
            models: #"{"a":{"id":"not-a-number","name":"One"},"b":{"name":"Two"}}"#,
            decks: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: AnkiError.unreadableNoteTypes(declared: 2)) {
            try AnkiPackageReader().read(contentsOf: url)
        }
    }

    @Test("a collection that genuinely describes no note types is an empty result, not an error")
    func noNoteTypesIsNotAnError() throws {
        let url = try makePackage(models: "{}", decks: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.noteTypes.isEmpty)
    }

    @Test("one unreadable model among good ones is tolerated, not fatal")
    func partialParseFailureIsTolerated() throws {
        // Refusing a whole deck over one junk entry would be stricter than Anki. The
        // dropped type is already visible downstream: its notes map to nothing and land
        // in the caller's unmappable tally.
        let url = try makePackage(
            models: #"{"1":{"id":1,"name":"Good","flds":[{"name":"Front","ord":0}]},"x":{"name":"Broken"}}"#,
            decks: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        #expect(collection.noteTypes.map(\.name) == ["Good"])
    }
}
