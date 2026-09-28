import Testing
import Foundation
@testable import KBCore

@Suite("StyleRun (M4a inline traits + url)")
struct StyleRunTests {

    // MARK: - New traits

    @Test("the new inline traits occupy the expected bits and compose")
    func traitBits() {
        #expect(TextTraits.code.rawValue == 1 << 2)
        #expect(TextTraits.strikethrough.rawValue == 1 << 3)
        #expect(TextTraits.link.rawValue == 1 << 4)
        // Existing bits are untouched.
        #expect(TextTraits.bold.rawValue == 1 << 0)
        #expect(TextTraits.italic.rawValue == 1 << 1)
        let combined: TextTraits = [.bold, .link]
        #expect(combined.contains(.bold) && combined.contains(.link))
        #expect(!combined.contains(.italic))
    }

    // MARK: - url accessor

    @Test("url(in:lower:upper:) returns the url of an overlapping .link run")
    func urlOverlap() {
        let runs = [StyleRun(lower: 0, upper: 5, traits: .link, url: "https://a.com")]
        #expect(StyleRun.url(in: runs, lower: 2, upper: 4) == "https://a.com")
    }

    @Test("url(in:lower:upper:) returns nil for a non-overlapping span")
    func urlNoOverlap() {
        let runs = [StyleRun(lower: 0, upper: 5, traits: .link, url: "https://a.com")]
        #expect(StyleRun.url(in: runs, lower: 10, upper: 12) == nil)
    }

    @Test("url(in:lower:upper:) ignores a non-.link run even if it carries a url")
    func urlIgnoresNonLink() {
        let runs = [StyleRun(lower: 0, upper: 5, traits: .bold, url: "https://a.com")]
        #expect(StyleRun.url(in: runs, lower: 2, upper: 4) == nil)
    }

    @Test("url(in:lower:upper:) picks the FIRST overlapping .link run")
    func urlFirstWins() {
        let runs = [
            StyleRun(lower: 0, upper: 5, traits: .link, url: "first"),
            StyleRun(lower: 3, upper: 8, traits: .link, url: "second")
        ]
        #expect(StyleRun.url(in: runs, lower: 4, upper: 4 + 1) == "first")
    }

    // MARK: - Codec round-trip + back-compat

    @Test("a StyleRun with a url round-trips through Codable")
    func urlRoundTrip() throws {
        let run = StyleRun(lower: 1, upper: 4, traits: .link, url: "https://example.com")
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(StyleRun.self, from: data)
        #expect(decoded == run)
        #expect(decoded.url == "https://example.com")
    }

    @Test("a StyleRun JSON WITHOUT a url key decodes to url == nil")
    func backCompatNoURLKey() throws {
        // Old payload shape: no "url" key, traits as a raw bitmask of .bold|.italic.
        let json = #"{"lower":0,"upper":3,"traits":3}"#
        let decoded = try JSONDecoder().decode(StyleRun.self, from: Data(json.utf8))
        #expect(decoded.url == nil)
        #expect(decoded.lower == 0)
        #expect(decoded.upper == 3)
        #expect(decoded.traits == [.bold, .italic])
    }

    @Test("an old .bold/.italic-only TextTraits raw value still decodes")
    func backCompatTraitsRaw() throws {
        let bold = try JSONDecoder().decode(TextTraits.self, from: Data("1".utf8))
        #expect(bold == .bold)
        let italic = try JSONDecoder().decode(TextTraits.self, from: Data("2".utf8))
        #expect(italic == .italic)
    }

    // MARK: - TextSegment blockStyle decode (M5 back-compat)

    private func sampleSegment(displayText: String, blockStyle: BlockStyle) -> TextSegment {
        let documentID = DocumentID("hash")
        return TextSegment(
            id: SegmentID(documentID: documentID, sentenceIndex: 0),
            documentID: documentID,
            sentenceIndex: 0,
            text: "Code block.",
            sourceRange: DocRange(lower: 0, upper: 11),
            displayText: displayText,
            styleRuns: [],
            blockStyle: blockStyle)
    }

    @Test("a TextSegment JSON WITHOUT a blockStyle key decodes to .body")
    func backCompatNoBlockStyleKey() throws {
        // Mimic a pre-M5 persisted payload by stripping the blockStyle key.
        let encoded = try JSONEncoder().encode(sampleSegment(displayText: "Hi.", blockStyle: .body))
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("TextSegment did not encode to a JSON object")
            return
        }
        object.removeValue(forKey: "blockStyle")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: stripped)
        #expect(decoded.blockStyle == .body)
    }

    @Test("a TextSegment with blockStyle .codeBlock round-trips through Codable")
    func codeBlockRoundTrip() throws {
        let segment = sampleSegment(displayText: "let x = 1", blockStyle: .codeBlock)
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: data)
        #expect(decoded.blockStyle == .codeBlock)
        #expect(decoded.displayText == "let x = 1")
        #expect(decoded == segment)
    }

    // MARK: - TextSegment listInfo decode (M7a back-compat)

    @Test("a TextSegment JSON WITHOUT a listInfo key decodes to listInfo nil")
    func backCompatNoListInfoKey() throws {
        // Mimic a pre-M7a persisted payload by stripping the listInfo key.
        let encoded = try JSONEncoder().encode(sampleSegment(displayText: "Hi.", blockStyle: .body))
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("TextSegment did not encode to a JSON object")
            return
        }
        object.removeValue(forKey: "listInfo")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: stripped)
        #expect(decoded.listInfo == nil)
    }

    @Test("a .listItem TextSegment carrying a ListInfo round-trips through Codable")
    func listInfoRoundTrip() throws {
        let documentID = DocumentID("hash")
        let segment = TextSegment(
            id: SegmentID(documentID: documentID, sentenceIndex: 0),
            documentID: documentID,
            sentenceIndex: 0,
            text: "todo",
            sourceRange: DocRange(lower: 0, upper: 4),
            blockStyle: .listItem,
            listInfo: ListInfo(depth: 1, ordered: true, ordinal: 3, task: .checked))
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: data)
        #expect(decoded.listInfo == ListInfo(depth: 1, ordered: true, ordinal: 3, task: .checked))
        #expect(decoded == segment)
    }
}
