import Testing
import KBCore

// The seam is only useful if it actually REACHES the code that turns spans into what a
// reader sees. Threading it through and never testing that it arrives is how
// `PacerDriver.run` kept calling a defaulted overload while its instance held an injected
// segmenter: the miss compiled, and produced silently wrong spans.
//
// Each of these injects the per-character `ScalarCJKSegmenter` and asserts the output
// CHANGES, which can only happen if the injected segmenter was the one consulted.
@Suite("Segmenter threading")
struct SegmenterThreadingTests {

    @Test(.enabled(if: hasReferenceCJKSegmenter))
    func alignHonorsAnInjectedSegmenter() {
        // 本気 is one word to CoreFoundation and two tokens to the scalar placeholder.
        let byDefault = SpokenTextAlignment.align(display: "本気", spoken: "本気")
        let injected = SpokenTextAlignment.align(
            display: "本気", spoken: "本気", segmenter: ScalarCJKSegmenter())
        #expect(byDefault.count == 1)
        #expect(injected.count == 2)
    }

    @Test(.enabled(if: hasReferenceCJKSegmenter))
    func remapHonorsAnInjectedSegmenter() {
        let provenance = TimingProvenance(providerID: .kokoro, providerVersion: "test",
                                          strategy: .durationPredictor, textHash: "x")
        let timeline = HighlightTimeline(
            segmentID: SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0),
            audioDuration: 1.0,
            words: [WordToken(offsets: WordOffsets(lower: 0, upper: 2), start: 0, duration: 1)],
            confidence: .aligned,
            provenance: provenance)

        // With the placeholder the spoken side splits per character, so the remap resolves
        // the token onto a one-character display span instead of the whole word.
        let byDefault = SpokenTextAlignment.remap(timeline: timeline, display: "本気", spoken: "本気")
        let injected = SpokenTextAlignment.remap(
            timeline: timeline, display: "本気", spoken: "本気", segmenter: ScalarCJKSegmenter())
        #expect(byDefault.words.first?.offsets == WordOffsets(lower: 0, upper: 2))
        #expect(injected.words.first?.offsets == WordOffsets(lower: 0, upper: 1))
    }
}
