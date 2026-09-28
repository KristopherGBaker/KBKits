import Testing
import Foundation
@testable import KBCore

@Suite("RubyRun (source furigana spans)")
struct RubyRunTests {

    private func documentID() -> DocumentID { DocumentID("hash") }

    private func sampleSegment(rubyRuns: [RubyRun]) -> TextSegment {
        let id = documentID()
        return TextSegment(
            id: SegmentID(documentID: id, sentenceIndex: 0),
            documentID: id,
            sentenceIndex: 0,
            text: "私は",
            sourceRange: DocRange(lower: 0, upper: 2),
            displayText: "私は",
            rubyRuns: rubyRuns)
    }

    @Test("RubyRun exposes public lower/upper/reading and round-trips through Codable")
    func codecRoundTrip() throws {
        let run = RubyRun(lower: 0, upper: 2, reading: "ほし")
        #expect(run.lower == 0)
        #expect(run.upper == 2)
        #expect(run.reading == "ほし")
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(RubyRun.self, from: data)
        #expect(decoded == run)
    }

    @Test("rebased clips overlapping runs to the span and rebases to span-local offsets")
    func rebasedClipsAndRebases() {
        let runs = [RubyRun(lower: 0, upper: 1, reading: "わたくし"),
                    RubyRun(lower: 3, upper: 5, reading: "ほし")]
        // Window [3, 5): only the second run overlaps, rebased to 0-based.
        #expect(RubyRun.rebased(runs, lower: 3, upper: 5) == [RubyRun(lower: 0, upper: 2, reading: "ほし")])
        // A window covering the first char rebases it too.
        #expect(RubyRun.rebased(runs, lower: 0, upper: 1) == [RubyRun(lower: 0, upper: 1, reading: "わたくし")])
        // A non-overlapping window yields nothing.
        #expect(RubyRun.rebased(runs, lower: 6, upper: 8).isEmpty)
    }

    // MARK: - TextSegment.rubyRuns persistence (assertion 2)

    @Test("a TextSegment carrying rubyRuns round-trips through Codable")
    func segmentRubyRoundTrip() throws {
        let segment = sampleSegment(rubyRuns: [RubyRun(lower: 0, upper: 1, reading: "わたくし")])
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: data)
        #expect(decoded.rubyRuns == [RubyRun(lower: 0, upper: 1, reading: "わたくし")])
        #expect(decoded == segment)
    }

    @Test("a TextSegment JSON WITHOUT a rubyRuns key decodes to rubyRuns == [] (back-compat)")
    func backCompatNoRubyRunsKey() throws {
        // Mimic a pre-ruby persisted payload by stripping the rubyRuns key.
        let encoded = try JSONEncoder().encode(sampleSegment(rubyRuns: []))
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("TextSegment did not encode to a JSON object")
            return
        }
        object.removeValue(forKey: "rubyRuns")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TextSegment.self, from: stripped)
        #expect(decoded.rubyRuns.isEmpty)
    }

    // MARK: - Spoken-text substitution (Phase 3, assertions 1 & 2)

    @Test("substituting replaces each base span with its kana reading, correct across length changes")
    func substituteAcrossLengthChanges() {
        // 私(0..1) → わたくし LENGTHENS the string before the 硝子(2..4) span; the later
        // span must still be replaced correctly because splicing walks original offsets.
        let runs = [RubyRun(lower: 0, upper: 1, reading: "わたくし"),
                    RubyRun(lower: 2, upper: 4, reading: "がらす")]
        #expect(RubyRun.substituting(runs, in: "私と硝子") == "わたくしとがらす")
    }

    @Test("substituting keeps the base for a latin reading (kana-only guard)")
    func substituteLatinReadingKeepsBase() {
        let runs = [RubyRun(lower: 0, upper: 2, reading: "glass")]
        #expect(RubyRun.substituting(runs, in: "硝子だ") == "硝子だ")
    }

    @Test("substituting keeps the base for an empty reading")
    func substituteEmptyReadingKeepsBase() {
        let runs = [RubyRun(lower: 0, upper: 2, reading: "")]
        #expect(RubyRun.substituting(runs, in: "硝子だ") == "硝子だ")
    }

    @Test("substituting applies a kana reading and leaves surrounding text untouched")
    func substituteKanaReading() {
        let runs = [RubyRun(lower: 0, upper: 2, reading: "マジ")]
        #expect(RubyRun.substituting(runs, in: "本気だ") == "マジだ")
    }

    @Test("readingIsKana accepts hiragana/katakana (incl. ー) and rejects latin/digits/empty")
    func readingIsKanaGuard() {
        #expect(RubyRun(lower: 0, upper: 1, reading: "わたくし").readingIsKana)
        #expect(RubyRun(lower: 0, upper: 1, reading: "マジ").readingIsKana)
        #expect(RubyRun(lower: 0, upper: 1, reading: "ラーメン").readingIsKana)   // chōonpu ー
        #expect(!RubyRun(lower: 0, upper: 1, reading: "glass").readingIsKana)
        #expect(!RubyRun(lower: 0, upper: 1, reading: "12").readingIsKana)
        #expect(!RubyRun(lower: 0, upper: 1, reading: "").readingIsKana)
    }

    // MARK: - applyingSpokenTransform preserves rubyRuns (assertion 7)

    @Test("applyingSpokenTransform preserves rubyRuns unchanged")
    func spokenTransformPreservesRubyRuns() {
        let id = documentID()
        let segment = TextSegment(
            id: SegmentID(documentID: id, sentenceIndex: 0),
            documentID: id,
            sentenceIndex: 0,
            text: "staff-level 私",
            sourceRange: DocRange(lower: 0, upper: 13),
            displayText: "staff-level 私",
            rubyRuns: [RubyRun(lower: 12, upper: 13, reading: "わたくし")])
        let transformed = segment.applyingSpokenTransform { text, _ in
            SpokenTextTransform.hyphenatedCompoundsToSpaces(text)
        }
        // The transform actually changed the spoken text (so it's not the identity return)…
        #expect(transformed.text == "staff level 私")
        // …and it carried rubyRuns through unchanged.
        #expect(transformed.rubyRuns == segment.rubyRuns)
    }
}
