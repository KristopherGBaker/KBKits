import Foundation
import Testing
@testable import KBAnkiKit

/// What export refuses to write. Each case is one a caller could otherwise ship and
/// only discover inside someone else's Anki.
@Suite("Export validation")
struct AnkiWriteFailureTests {
    private let noteType = AnkiNoteTypeDraft(
        name: "Example Japanese",
        fieldNames: ["Word", "Meaning"],
        templates: [AnkiCardTemplate(name: "Recognition", question: "{{Word}}", answer: "{{Meaning}}")])

    private var destination: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).apkg")
    }

    @Test("A deck with no notes is refused rather than written empty")
    func emptyDeckIsRefused() {
        let draft = AnkiDeckDraft(deckName: "Empty", noteType: noteType, notes: [])
        // Writing it would produce a file that imports as nothing, which reads as a
        // silent failure rather than as the mistake it is.
        #expect(throws: AnkiError.emptyDeck) {
            try AnkiPackageWriter().write(draft, to: destination)
        }
    }

    @Test("A note whose field count disagrees with the note type is refused")
    func mismatchedNoteIsRefused() {
        let draft = AnkiDeckDraft(
            deckName: "Mismatched", noteType: noteType,
            notes: [
                AnkiNoteDraft(fields: ["先生", "teacher"]),
                AnkiNoteDraft(fields: ["遠慮"])
            ])
        #expect(throws: AnkiError.fieldCountMismatch(
            noteType: "Example Japanese", declared: 2, found: 1)) {
            try AnkiPackageWriter().write(draft, to: destination)
        }
    }

    @Test("Nothing is left behind when a write is refused")
    func refusedWriteLeavesNoFile() throws {
        let url = destination
        let draft = AnkiDeckDraft(deckName: "Empty", noteType: noteType, notes: [])
        #expect(throws: AnkiError.emptyDeck) { try AnkiPackageWriter().write(draft, to: url) }
        // Validation runs before anything is created, so a refused export cannot
        // leave a half-written file where the caller expects a deck.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Writing over an existing file replaces it")
    func writeReplacesExistingFile() throws {
        let url = destination
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("stale".utf8).write(to: url)

        let draft = AnkiDeckDraft(
            deckName: "Replaced", noteType: noteType,
            notes: [AnkiNoteDraft(fields: ["先生", "teacher"])])
        try AnkiPackageWriter().write(draft, to: url)
        #expect(try AnkiPackageReader().read(contentsOf: url).notes.count == 1)
    }

    @Test("Every error a person can hit carries a readable message")
    func errorsAreReadable() {
        let errors: [AnkiError] = [
            .notAnAnkiPackage(found: ["a.txt"]),
            .unreadableArchive("bad header"),
            .databaseFailure("no such table"),
            .fieldCountMismatch(noteType: "Japanese", declared: 2, found: 3),
            .emptyDeck,
            .writeFailure("disk full")
        ]
        // These surface in a dialog, so an empty description would leave the person
        // with a failure and no sentence explaining it.
        #expect(errors.allSatisfy { ($0.errorDescription?.isEmpty == false) })
    }
}
