import Testing
@testable import KBCore

// MARK: - M6 table announce+skip remap crash-safety

/// A table segment's spoken text is the short marker "Table." while its display is the
/// multi-line aligned table — a large length/word-count mismatch. `remap` must NOT trap
/// (no precondition/range crash); the exact remapped shape is not pinned.
@Test func remapIsCrashSafeForTableAnnounceVsMultilineTable() {
    let spoken = "Table."
    let display = "Name | X          | Description\n---- | ---------- | -----------\nAl   | wide-value | ok"
    let spokenWords = WordTokenizer.tokenize(spoken)
    let tokens = spokenWords.enumerated().map { index, word in
        WordToken(offsets: word.offsets, start: Double(index) * 0.25, duration: 0.25)
    }
    let timeline = HighlightTimeline(
        segmentID: SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0),
        audioDuration: 1.0, words: tokens, confidence: .aligned,
        provenance: TimingProvenance(providerID: .kokoro, providerVersion: "test",
                                     strategy: .durationPredictor, textHash: "x"))
    let remapped = SpokenTextAlignment.remap(timeline: timeline, display: display, spoken: spoken)
    // Returned without trapping; it collapses to at most the spoken token count.
    #expect(remapped.words.count <= tokens.count)
}
