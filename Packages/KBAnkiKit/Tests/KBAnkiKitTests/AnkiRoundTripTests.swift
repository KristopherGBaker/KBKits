import Foundation
import Testing
import ZIPFoundation
@testable import KBAnkiKit

/// Writing a deck and reading it back is the test that matters: it exercises the
/// archive layout, the collection schema and both parsers against each other, and it
/// fails if either side drifts.
@Suite("Anki package round trip")
struct AnkiRoundTripTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDraft(notes: [AnkiNoteDraft]? = nil) -> AnkiDeckDraft {
        AnkiDeckDraft(
            deckName: "Example::こころ",
            noteType: AnkiNoteTypeDraft(
                name: "Example Japanese",
                fieldNames: ["Word", "Reading", "Meaning", "Sentence"],
                templates: [
                    AnkiCardTemplate(
                        name: "Recognition", question: "{{Word}}",
                        answer: "{{FrontSide}}<hr id=answer>{{Reading}}<br>{{Meaning}}")
                ]),
            notes: notes ?? [
                AnkiNoteDraft(
                    fields: ["先生", "せんせい", "teacher; master", "私はその人を常に先生と呼んでいた。"],
                    tags: ["example", "kokoro"]),
                AnkiNoteDraft(fields: ["遠慮", "えんりょ", "restraint; reserve", ""], tags: [])
            ])
    }

    private func write(_ draft: AnkiDeckDraft) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        try AnkiPackageWriter().write(draft, to: url, timestamp: timestamp)
        return url
    }

    @Test("A written deck reads back with its notes, fields and tags intact")
    func roundTripPreservesNotes() throws {
        let draft = makeDraft()
        let url = try write(draft)
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteType = try #require(collection.noteTypes.first)
        #expect(noteType.name == "Example Japanese")
        #expect(noteType.fieldNames == ["Word", "Reading", "Meaning", "Sentence"])
        #expect(collection.notes.count == 2)

        let first = try #require(collection.notes.first)
        #expect(first.value(of: "Word", in: noteType) == "先生")
        #expect(first.value(of: "Reading", in: noteType) == "せんせい")
        #expect(first.value(of: "Sentence", in: noteType) == "私はその人を常に先生と呼んでいた。")
        #expect(first.tags == ["example", "kokoro"])
        #expect(collection.notes[1].tags.isEmpty)
        #expect(collection.noteType(for: first)?.id == noteType.id)
    }

    @Test("The deck's nested name survives the round trip")
    func roundTripPreservesDeckName() throws {
        let url = try write(makeDraft())
        defer { try? FileManager.default.removeItem(at: url) }
        let names = try AnkiPackageReader().read(contentsOf: url).decks.map(\.name)
        #expect(names.contains("Example::こころ"))
    }

    @Test("A caller-supplied guid is preserved, so a re-import can match the same note")
    func roundTripPreservesGUID() throws {
        let draft = makeDraft(notes: [
            AnkiNoteDraft(fields: ["先生", "せんせい", "teacher", ""], guid: "example-先生-1")
        ])
        let url = try write(draft)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AnkiPackageReader().read(contentsOf: url).notes.first?.guid == "example-先生-1")
    }

    @Test("The same draft and clock write byte-identical files")
    func writesAreReproducible() throws {
        let first = try write(makeDraft())
        let second = try write(makeDraft())
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        // Not cosmetic: reproducibility is what lets a caller tell "the deck changed"
        // from "the exporter ran again", and it catches unsorted JSON and stray clocks.
        #expect(try Data(contentsOf: first) == (try Data(contentsOf: second)))

        // Byte equality alone was passing on TIMING rather than on the property. Both ZIP
        // entries used to take their date from the wall clock, and ZIP stores dates at
        // two-second resolution, so two writes matched unless they straddled a boundary; this
        // test duly failed once under full-suite load. Asserting the entry dates equal the
        // INJECTED timestamp pins the thing the byte comparison was standing in for.
        let archive = try Archive(url: first, accessMode: .read)
        for name in ["collection.anki2", "media"] {
            let entry = try #require(archive[name], "missing \(name)")
            #expect(abs(entry.fileAttributes[.modificationDate].flatMap { $0 as? Date }?
                .timeIntervalSince(timestamp) ?? .infinity) < 2,
                    "\(name) carries a wall-clock date, not the injected one")
        }
    }

    @Test("The package holds the entries Anki looks for")
    func packageLayoutIsWhatAnkiExpects() throws {
        let url = try write(makeDraft())
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .read)
        let names = Set(archive.map(\.path))
        #expect(names.contains("collection.anki2"))
        #expect(names.contains("media"))
    }

    @Test("Exported cards carry no scheduling, so they arrive new")
    func exportedCardsAreNew() throws {
        let url = try write(makeDraft())
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try openCollection(in: url)
        let cards = try database.rows("SELECT type, queue, ivl, reps, lapses, factor FROM cards")
        #expect(cards.count == 2)
        // Type and queue 0 is Anki's "new". Everything else being zero is the point of
        // the fresh-scheduling decision: no invented interval or ease.
        #expect(cards.allSatisfy { $0.int("type") == 0 && $0.int("queue") == 0 })
        #expect(cards.allSatisfy { $0.int("ivl") == 0 && $0.int("reps") == 0 })
        #expect(cards.allSatisfy { $0.int("lapses") == 0 && $0.int("factor") == 0 })
    }

    @Test("One card is written per template, not per note")
    func cardsAreGeneratedPerTemplate() throws {
        let draft = AnkiDeckDraft(
            deckName: "Two Sided",
            noteType: AnkiNoteTypeDraft(
                name: "Both ways", fieldNames: ["Word", "Meaning"],
                templates: [
                    AnkiCardTemplate(name: "Recognition", question: "{{Word}}", answer: "{{Meaning}}"),
                    AnkiCardTemplate(name: "Recall", question: "{{Meaning}}", answer: "{{Word}}")
                ]),
            notes: [AnkiNoteDraft(fields: ["先生", "teacher"])])
        let url = try write(draft)
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try openCollection(in: url)
        #expect(try database.rows("SELECT id FROM notes").count == 1)
        #expect(try database.rows("SELECT id FROM cards").count == 2)
        #expect(try Set(database.rows("SELECT ord FROM cards").compactMap { $0.int("ord") }) == [0, 1])
    }

    @Test("Every id in the collection is unique")
    func idsDoNotCollide() throws {
        let notes = (1...25).map { AnkiNoteDraft(fields: ["word\($0)", "r", "m", "s"]) }
        let url = try write(makeDraft(notes: notes))
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try openCollection(in: url)
        let noteIDs = try database.rows("SELECT id FROM notes").compactMap { $0.int("id") }
        let cardIDs = try database.rows("SELECT id FROM cards").compactMap { $0.int("id") }
        #expect(noteIDs.count == 25)
        // Ids double as primary keys AND as timestamps, so a collision is a corrupt
        // collection that Anki only complains about long after the import.
        #expect(Set(noteIDs + cardIDs).count == noteIDs.count + cardIDs.count)
    }

    /// Open the collection inside a written package, for the assertions that are
    /// about the file Anki will read rather than about our own reader.
    private func openCollection(in url: URL) throws -> SQLiteDatabase {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive["collection.anki2"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki2")
        try data.write(to: path)
        return try SQLiteDatabase(path: path.path, access: .openExisting)
    }
}
