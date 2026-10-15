import Foundation
import Testing
@testable import KBAnkiKit

/// The details a round trip cannot catch, because our reader and writer would agree
/// on a wrong answer. Each of these is about what ANKI does, not about what we do.
@Suite("Format fidelity against Anki's own behaviour")
struct AnkiFormatFidelityTests {
    // MARK: req

    @Test("A template's requirement names the field its front actually references")
    func requirementFollowsTheTemplate() {
        let fields = ["Word", "Reading", "Meaning"]
        // A reversed card fronts the MEANING. Claiming it needs field 0 would have
        // Anki generate a card from a field the front never shows.
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{Meaning}}", in: fields) == [2])
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{Word}}", in: fields) == [0])
    }

    @Test("Several referenced fields are all reported, in order")
    func requirementCoversEveryReference() {
        let fields = ["Word", "Reading", "Meaning"]
        let ordinals = AnkiCollectionSchema.fieldOrdinals(
            referencedBy: "{{Meaning}} / {{Word}}", in: fields)
        #expect(ordinals == [0, 2])
    }

    @Test("Filters, conditionals and special names are not mistaken for fields")
    func templateSyntaxIsUnderstood() {
        let fields = ["Word", "Reading", "Meaning"]
        // `{{furigana:Word}}` is the Word field through a filter; `{{#Reading}}` opens
        // a conditional; `{{FrontSide}}` is not a field at all.
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{furigana:Word}}", in: fields) == [0])
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{text:furigana:Word}}", in: fields) == [0])
        #expect(AnkiCollectionSchema.fieldOrdinals(
            referencedBy: "{{#Reading}}{{Reading}}{{/Reading}}", in: fields) == [1])
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{FrontSide}}", in: fields).isEmpty)
        #expect(AnkiCollectionSchema.fieldOrdinals(referencedBy: "{{Nonexistent}}", in: fields).isEmpty)
    }

    // MARK: Field packing

    @Test("A separator inside a field value cannot split it in two")
    func embeddedSeparatorIsRemoved() {
        // Left in, this shifts every field after it by one on the way back out.
        let packed = AnkiFields.join(["a\(AnkiFields.separator)b", "c"])
        #expect(AnkiFields.split(packed) == ["ab", "c"])
    }

    // MARK: Checksums

    @Test("Entities are decoded before hashing, as Anki does")
    func checksumDecodesEntities() {
        // Anki hashes the decoded text, so a field written by Anki and the same text
        // typed here must land on one checksum or duplicates never match.
        #expect(AnkiFields.strippingHTML("A &amp; B") == "A & B")
        #expect(AnkiFields.strippingHTML("&lt;tag&gt;") == "<tag>")
        #expect(AnkiFields.checksum(ofFirstField: "A &amp; B") == AnkiFields.checksum(ofFirstField: "A & B"))
    }

    @Test("A double-escaped entity decodes once, not twice")
    func entityDecodingIsNotRecursive() {
        // `&amp;lt;` is a literal "&lt;", not "<". Decoding `&amp;` first would eat it.
        #expect(AnkiFields.strippingHTML("&amp;lt;") == "&lt;")
    }

    // MARK: Guids

    @Test("Guids come from content, so the same card exports the same guid every time")
    func guidsAreContentDerived() {
        let fields = ["先生", "せんせい", "teacher"]
        // Stability is what lets a receiving collection recognise a card it already
        // has instead of duplicating it on every re-export.
        #expect(AnkiFields.contentGUID(fields: fields, salt: 0)
                == AnkiFields.contentGUID(fields: fields, salt: 0))
    }

    @Test("Different notes get different guids, and identical notes are salted apart")
    func guidsDoNotCollide() {
        let one = AnkiFields.contentGUID(fields: ["先生", "teacher"], salt: 0)
        let two = AnkiFields.contentGUID(fields: ["遠慮", "restraint"], salt: 0)
        let repeated = AnkiFields.contentGUID(fields: ["先生", "teacher"], salt: 1)
        #expect(one != two)
        // Two byte-identical notes would otherwise merge into one in Anki.
        #expect(one != repeated)
    }

    @Test("Two different decks exported at the same instant do not share guids")
    func guidsAreIndependentOfTheExportClock() throws {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ word: String) throws -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).apkg")
            defer { try? FileManager.default.removeItem(at: url) }
            let draft = AnkiDeckDraft(
                deckName: "Deck",
                noteType: AnkiNoteTypeDraft(
                    name: "Basic", fieldNames: ["Front", "Back"],
                    templates: [AnkiCardTemplate(name: "Card 1", question: "{{Front}}", answer: "{{Back}}")]),
                notes: [AnkiNoteDraft(fields: [word, "gloss"])])
            try AnkiPackageWriter().write(draft, to: url, timestamp: clock)
            return try #require(AnkiPackageReader().read(contentsOf: url).notes.first?.guid)
        }
        // Deriving a guid from the clock and the row position made these identical,
        // which tells Anki two unrelated notes are one note.
        #expect(try write("先生") != (try write("遠慮")))
    }
}
