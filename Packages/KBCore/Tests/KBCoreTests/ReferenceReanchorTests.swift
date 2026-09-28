import Testing
@testable import KBCore

/// Build segments from plain sentences (display == spoken text), for re-anchor fixtures.
private func segments(_ sentences: [String]) -> [TextSegment] {
    let id = DocumentID("d")
    return sentences.enumerated().map { index, sentence in
        TextSegment(id: SegmentID(documentID: id, sentenceIndex: index),
                    documentID: id, sentenceIndex: index, text: sentence,
                    sourceRange: DocRange(lower: 0, upper: sentence.utf16.count))
    }
}

// MARK: - Card re-anchor (exact-ish search; content never lost)

@Test func cardReanchorKeepsHintWhenStillMatching() {
    let segs = segments(["First sentence.", "The cat sat on the mat.", "Third sentence."])
    let outcome = ReferenceReanchor.reanchorCard(
        sourceText: "The cat sat on the mat.", oldIndex: 1, in: segs)
    #expect(outcome == .kept(index: 1))
}

@Test func cardReanchorMovesWhenSentenceShifted() {
    // An inserted opening sentence pushes the source from index 1 to index 2.
    let segs = segments([
        "Brand new opening line.", "First sentence.", "The cat sat on the mat.", "Third."])
    let outcome = ReferenceReanchor.reanchorCard(
        sourceText: "The cat sat on the mat.", oldIndex: 1, in: segs)
    #expect(outcome == .moved(from: 1, to: 2))
    #expect(outcome.resolvedIndex == 2)
    #expect(outcome.didMove)
}

@Test func cardReanchorOrphansWhenSourceTextGone() {
    let segs = segments(["First sentence.", "Totally different text.", "Third."])
    let outcome = ReferenceReanchor.reanchorCard(
        sourceText: "The cat sat on the mat.", oldIndex: 1, in: segs)
    #expect(outcome == .orphaned(from: 1))
    #expect(outcome.resolvedIndex == nil)
    #expect(outcome.isOrphaned)
}

@Test func cardReanchorMatchesAfterWhitespaceAndCaseEdits() {
    // Re-wrapping + casing shouldn't break the match (normalization).
    let segs = segments(["the CAT   sat\non the mat."])
    let outcome = ReferenceReanchor.reanchorCard(
        sourceText: "The cat sat on the mat.", oldIndex: 0, in: segs)
    #expect(outcome == .kept(index: 0))
}

// MARK: - Reading-position re-anchor (edit→read: match + no-match→top)

@Test func readingPositionResolvesToMatchedSentence() {
    let segs = segments(["Intro.", "First sentence.", "The cat sat on the mat."])
    let outcome = ReferenceReanchor.fuzzyReanchor(
        sourceText: "The cat sat on the mat.", oldIndex: 1, in: segs)
    #expect(outcome.resolvedIndex == 2)
}

@Test func readingPositionFallsBackToTopWhenNoMatch() {
    let segs = segments(["Completely.", "Different.", "Content here."])
    let outcome = ReferenceReanchor.fuzzyReanchor(
        sourceText: "The cat sat on the mat.", oldIndex: 1, in: segs)
    #expect(outcome.isOrphaned)
    // The AppModel maps orphaned → 0 (top); resolvedIndex is nil to signal that.
    #expect(outcome.resolvedIndex == nil)
}

// MARK: - Bookmark fuzzy-match: keep / move / orphan

@Test func bookmarkFuzzyKeepsWhenSentenceUnchanged() {
    let segs = segments(["A.", "The quick brown fox jumps.", "C."])
    let outcome = ReferenceReanchor.fuzzyReanchor(
        sourceText: "The quick brown fox jumps.", oldIndex: 1, in: segs)
    #expect(outcome == .kept(index: 1))
}

@Test func bookmarkFuzzyMovesOnRewordedShiftedSentence() {
    // Sentence reworded (one word swapped, no exact containment) and shifted down — fuzzy
    // still finds it by token overlap (7/8 shared tokens clears the 0.6 threshold).
    let segs = segments([
        "New intro", "Padding", "the quick brown fox leaps over the dog"])
    let outcome = ReferenceReanchor.fuzzyReanchor(
        sourceText: "the quick brown fox jumps over the dog", oldIndex: 1, in: segs)
    #expect(outcome.didMove)
    #expect(outcome.resolvedIndex == 2)
}

@Test func bookmarkFuzzyOrphansBelowThreshold() {
    let segs = segments(["Apples and oranges.", "Bananas in bunches."])
    let outcome = ReferenceReanchor.fuzzyReanchor(
        sourceText: "The quick brown fox jumps over the lazy dog.", oldIndex: 0, in: segs)
    #expect(outcome == .orphaned(from: 0))
}

@Test func bookmarkPassthroughWhenNoSnapshotButIndexInRange() {
    let segs = segments(["A.", "B.", "C."])
    let outcome = ReferenceReanchor.fuzzyReanchor(sourceText: nil, oldIndex: 1, in: segs)
    #expect(outcome == .kept(index: 1))
}

@Test func bookmarkOrphansWhenNoSnapshotAndIndexOutOfRange() {
    let segs = segments(["A.", "B."])
    let outcome = ReferenceReanchor.fuzzyReanchor(sourceText: nil, oldIndex: 5, in: segs)
    #expect(outcome == .orphaned(from: 5))
}

// MARK: - Similarity primitive

@Test func similarityIsOneForIdenticalAndZeroForDisjoint() {
    #expect(ReferenceReanchor.similarity("the cat sat", "the cat sat") == 1.0)
    #expect(ReferenceReanchor.similarity("alpha beta", "gamma delta") == 0.0)
}
