import Testing
import KBCore

/// One-document fixture where `displayText == text` (the default), so matches are
/// over the same text the reader tokenizes.
private func searchDoc(_ sentences: [String]) -> Document {
    let id = DocumentID("d")
    let segments = sentences.enumerated().map { index, sentence in
        TextSegment(id: SegmentID(documentID: id, sentenceIndex: index),
                    documentID: id, sentenceIndex: index, sentence: sentence)
    }
    return Document(id: id, title: "t", textHash: "h", segments: segments, chapters: [])
}

private extension TextSegment {
    /// Convenience for the fixtures: a body segment whose source span is its whole text.
    init(id: SegmentID, documentID: DocumentID, sentenceIndex: Int, sentence: String) {
        self.init(id: id, documentID: documentID, sentenceIndex: sentenceIndex, text: sentence,
                  sourceRange: DocRange(lower: 0, upper: sentence.utf16.count))
    }
}

@Test func findMatchesCaseInsensitivelyWithUTF16Span() {
    let matches = DocumentTextSearch.matches(in: searchDoc(["The Cat sat."]), query: "cat")
    #expect(matches.count == 1)
    #expect(matches[0].segmentIndex == 0)
    #expect(matches[0].range.lower == 4 && matches[0].range.upper == 7)   // "Cat"
}

@Test func findIgnoresDiacritics() {
    let matches = DocumentTextSearch.matches(in: searchDoc(["Café au lait"]), query: "cafe")
    #expect(matches.count == 1)
    #expect(matches[0].range.lower == 0 && matches[0].range.upper == 4)   // "Café"
}

@Test func findCollectsEveryNonOverlappingOccurrenceInOrder() {
    // "abab" / "ab" → 0..2 then 2..4 (non-overlapping), both in segment 0.
    let matches = DocumentTextSearch.matches(in: searchDoc(["abab"]), query: "ab")
    #expect(matches.map { $0.range.lower } == [0, 2])
    #expect(matches.allSatisfy { $0.range.length == 2 })
}

@Test func findSpansMultipleSegmentsInReadingOrder() {
    let matches = DocumentTextSearch.matches(in: searchDoc(["red apple", "green apple"]), query: "apple")
    #expect(matches.map(\.segmentIndex) == [0, 1])
}

@Test func findMatchesTwoCharJapaneseQuery() {
    // 日(0)本(1)の(2)言(3)葉(4) → "言葉" at UTF-16 3..5.
    let matches = DocumentTextSearch.matches(in: searchDoc(["日本の言葉"]), query: "言葉")
    #expect(matches.count == 1)
    #expect(matches[0].range.lower == 3 && matches[0].range.upper == 5)
}

@Test func findMatchesAcrossFullAndHalfWidth() {
    // Full-width "ＡＢＣ" should be found by the ASCII query "abc".
    let matches = DocumentTextSearch.matches(in: searchDoc(["ＡＢＣ"]), query: "abc")
    #expect(matches.count == 1)
    #expect(matches[0].range.lower == 0 && matches[0].range.upper == 3)
}

@Test func findReturnsUTF16OffsetsPastSurrogatePairs() {
    // "😀 cat": 😀 occupies UTF-16 units 0–1, space 2, so "cat" starts at 3.
    let matches = DocumentTextSearch.matches(in: searchDoc(["😀 cat"]), query: "cat")
    #expect(matches.count == 1)
    #expect(matches[0].range.lower == 3 && matches[0].range.upper == 6)
}

@Test func findEmptyOrBlankQueryYieldsNoMatches() {
    let document = searchDoc(["anything at all"])
    #expect(DocumentTextSearch.matches(in: document, query: "").isEmpty)
    #expect(DocumentTextSearch.matches(in: document, query: "   \n").isEmpty)
}
