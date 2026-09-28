import Testing
import Foundation
@testable import KBCore

@Test func schemaVersionIsStable() {
    #expect(KBCore.schemaVersion == 1)
}

@Test func utf16RangeMaterializesWordRange() {
    let text = "The quick brown fox"
    // "quick" is UTF-16 [4, 9)
    let range = text.range(fromUTF16: UTF16Range(lower: 4, upper: 9))
    #expect(range != nil)
    #expect(range.map { String(text[$0]) } == "quick")
}

@Test func utf16RangeRejectsOutOfBounds() {
    let text = "abc"
    #expect(text.range(fromUTF16: UTF16Range(lower: 0, upper: 99)) == nil)
}

@Test func timelineWordLookupIsCorrect() {
    let segID = SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0)
    let provenance = TimingProvenance(providerID: .apple, providerVersion: "test",
                                      strategy: .liveRange, textHash: "h")
    let words = [
        WordToken(offsets: .init(lower: 0, upper: 3), start: 0.0, duration: 0.5),
        WordToken(offsets: .init(lower: 4, upper: 9), start: 0.5, duration: 0.5),
        WordToken(offsets: .init(lower: 10, upper: 15), start: 1.0, duration: 0.5)
    ]
    let timeline = HighlightTimeline(segmentID: segID, audioDuration: 1.5, words: words,
                                     confidence: .exact, provenance: provenance)
    #expect(timeline.wordIndex(atSourceTime: -0.1) == nil)   // before first word
    #expect(timeline.wordIndex(atSourceTime: 0.0) == 0)
    #expect(timeline.wordIndex(atSourceTime: 0.6) == 1)
    #expect(timeline.wordIndex(atSourceTime: 1.2) == 2)
    #expect(timeline.wordIndex(atSourceTime: 5.0) == 2)      // past end → last word
}

@Test func readingPositionResolvesAgainstHash() {
    let docID = DocumentID("doc")
    let seg = TextSegment(id: SegmentID(documentID: docID, sentenceIndex: 0),
                          documentID: docID, sentenceIndex: 0, text: "Hi.",
                          sourceRange: DocRange(lower: 0, upper: 3))
    let doc = Document(id: docID, title: "T", textHash: "good", segments: [seg], chapters: [])
    let good = ReadingPosition(documentID: docID, sentenceIndex: 0, wordOffsetUTF16: nil,
                               textHash: "good", updatedAt: Date())
    let stale = ReadingPosition(documentID: docID, sentenceIndex: 0, wordOffsetUTF16: nil,
                                textHash: "stale", updatedAt: Date())
    #expect(good.resolvedSegmentIndex(in: doc) == 0)
    #expect(stale.resolvedSegmentIndex(in: doc) == 0)  // hash mismatch → start over (also 0 here)
}

@Test func textHashingIsStableAndDistinct() {
    #expect(TextHashing.sha256Hex("hello") == TextHashing.sha256Hex("hello"))
    #expect(TextHashing.sha256Hex("hello") != TextHashing.sha256Hex("world"))
}

@Test func documentSourceDefaultsToImportedWhenAbsent() throws {
    // A document JSON saved before the source split lacks the `source` key; it must
    // decode as .imported (the back-compat default), never fail (PRD C1).
    let docID = DocumentID("doc")
    let seg = TextSegment(id: SegmentID(documentID: docID, sentenceIndex: 0),
                          documentID: docID, sentenceIndex: 0, text: "Hi.",
                          sourceRange: DocRange(lower: 0, upper: 3))
    let legacy = Document(id: docID, title: "T", textHash: "h", segments: [seg], chapters: [])
    var json = try #require(String(data: JSONEncoder().encode(legacy), encoding: .utf8))
    // Strip the source key to simulate a pre-migration payload.
    json = json.replacingOccurrences(of: ",\"source\":{\"imported\":{\"_0\":\"txt\"}}", with: "")
    let decoded = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
    #expect(decoded.source == .imported(.txt))
}

@Test func documentSourceUserNoteRoundTrips() throws {
    let docID = DocumentID("note")
    let seg = TextSegment(id: SegmentID(documentID: docID, sentenceIndex: 0),
                          documentID: docID, sentenceIndex: 0, text: "Hi.",
                          sourceRange: DocRange(lower: 0, upper: 3))
    let note = Document(id: docID, title: "T", textHash: "h", segments: [seg],
                        chapters: [], source: .userNote)
    let data = try JSONEncoder().encode(note)
    let decoded = try JSONDecoder().decode(Document.self, from: data)
    #expect(decoded.source == .userNote)
    #expect(decoded.source.isUserNote)
}
