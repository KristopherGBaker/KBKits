import Testing
import Foundation
@testable import KBCore

private func makeDocument(_ sentences: [String]) -> Document {
    let id = DocumentID("doc")
    var offset = 0
    let segments = sentences.enumerated().map { index, text -> TextSegment in
        let lower = offset
        offset += text.utf16.count + 1   // +1 for a joining space
        return TextSegment(id: SegmentID(documentID: id, sentenceIndex: index),
                           documentID: id, sentenceIndex: index, text: text,
                           sourceRange: DocRange(lower: lower, upper: lower + text.utf16.count))
    }
    return Document(id: id, title: "T", textHash: "h", segments: segments, chapters: [])
}

@Suite("Passage construction")
struct PassageTests {
    let doc = makeDocument(["The cat sat.", "It was happy.", "The end."])

    @Test("a single-sentence passage carries that sentence's text + source range")
    func sentencePassage() throws {
        let passage = try #require(Passage.sentence(in: doc, at: 1, language: "English"))
        #expect(passage.text == "It was happy.")
        #expect(passage.segmentRange == 1...1)
        #expect(passage.sourceRange == doc.segment(at: 1)?.sourceRange)
        #expect(passage.language == "English")
        #expect(passage.documentID == doc.id)
    }

    @Test("a multi-sentence range joins text and spans the source range")
    func multiSentencePassage() throws {
        let passage = try #require(Passage.from(document: doc, segmentRange: 0...1))
        #expect(passage.text == "The cat sat. It was happy.")
        #expect(passage.segmentRange == 0...1)
        #expect(passage.sourceRange?.lower == doc.segment(at: 0)?.sourceRange.lower)
        #expect(passage.sourceRange?.upper == doc.segment(at: 1)?.sourceRange.upper)
    }

    @Test("out-of-range indices clamp to the document bounds")
    func clamping() throws {
        let passage = try #require(Passage.from(document: doc, segmentRange: 1...99))
        #expect(passage.segmentRange == 1...2)   // clamped to the last segment
        #expect(passage.text == "It was happy. The end.")
    }

    @Test("an empty document yields no passage")
    func emptyDocument() {
        let empty = Document(id: DocumentID("e"), title: "", textHash: "h", segments: [], chapters: [])
        #expect(Passage.sentence(in: empty, at: 0) == nil)
    }
}
