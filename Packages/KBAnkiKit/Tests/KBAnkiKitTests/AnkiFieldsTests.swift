import Foundation
import Testing
@testable import KBAnkiKit

/// The format details that decide whether another Anki agrees with ours: how fields
/// are packed, and the checksum it dedupes on.
@Suite("Anki field packing and checksums")
struct AnkiFieldsTests {
    @Test("Fields survive packing and unpacking")
    func fieldsRoundTrip() {
        let fields = ["先生", "せんせい", "teacher; master"]
        #expect(AnkiFields.split(AnkiFields.join(fields)) == fields)
    }

    @Test("A field containing the characters that separate other things is not split")
    func separatorIsUnambiguous() {
        // Newlines, colons and tabs all appear in real notes; only US separates fields.
        let fields = ["a::b", "line one\nline two", "tabbed\tvalue", ""]
        #expect(AnkiFields.split(AnkiFields.join(fields)) == fields)
    }

    @Test("The checksum matches the value Anki computes for the same field")
    func checksumMatchesAnki() {
        // Ground truth from SHA-1 of the UTF-8 bytes, first 8 hex digits as an integer,
        // which is what Anki's own fieldChecksum does. A wrong value here means an
        // imported note would not match a duplicate already in the collection.
        #expect(AnkiFields.checksum(ofFirstField: "先生") == 2_800_350_937)
        #expect(AnkiFields.checksum(ofFirstField: "teacher") == 1_250_085_741)
        #expect(AnkiFields.checksum(ofFirstField: "") == 3_661_210_606)
    }

    @Test("Markup does not change a field's checksum")
    func checksumIgnoresMarkup() {
        // Anki strips HTML before hashing, so the same word plain and marked up are
        // one note for duplicate purposes.
        #expect(AnkiFields.checksum(ofFirstField: "<b>先生</b>") == AnkiFields.checksum(ofFirstField: "先生"))
        #expect(AnkiFields.strippingHTML("<div class=\"x\">先生</div>") == "先生")
    }

    @Test("Generated guids use Anki's alphabet and stay unique per id")
    func guidsAreDistinctAndSafe() {
        let guids = (1...500).map { AnkiFields.makeGUID(UInt64($0)) }
        #expect(Set(guids).count == guids.count)
        // The alphabet deliberately excludes quotes, backslash and space, because a
        // guid travels through JSON and SQL without escaping.
        let forbidden = Set("\"'\\ ")
        #expect(!guids.contains { $0.contains { forbidden.contains($0) } })
    }
}
