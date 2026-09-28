import KBCore
import Foundation
import Testing
@testable import KBReadingKit

/// The nearest-reading arm of the compound join: when the unambiguous arms decline, take
/// the candidate agreeing with the longest leading run of what the page already renders.
/// Its own suite so the decision-arm suite stays under the house type_body_length limit.
/// GATES MUST NOT use `--filter CompoundJoinTests`: it does not match this suite, and a
/// focused gate that runs zero tests looks identical to one that passes. Use the whole
/// package suite, or `--filter CompoundJoin`, which matches every arm.
@Suite("CompoundJoin nearest-reading arm (injected dictionary)")
struct CompoundJoinNearestTests {
    // MARK: - The nearest-reading arm: settle what the unambiguous arms decline

    // 日本人 as the tokenizer splits it: 日本|人, rendering にっぽん + ひと. Both JMdict
    // readings carry spans rows, so the "exactly one with spans" arm declines and only the
    // nearest rule can settle it. にっぽんじん shares にっぽん with what we render; にほんじん
    // shares only に.
    private var nihonjinTokens: [WordTokenizer.Token] {
        [token("日本", 0, 2), token("人", 2, 3)]
    }
    private var nihonjinRendered: [String] { ["にっぽん", "ひと"] }

    private func spansFor(_ parts: [(Range<Int>, String)]) -> [ReadingSpan] {
        parts.map { ReadingSpan(range: $0.0, kana: $0.1) }
    }

    @Test("several spanned readings: the one agreeing with the rendered prefix wins")
    func nearestUniqueReplaced() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            ("にっぽんじん", spansFor([(0..<1, "にっ"), (1..<2, "ぽん"), (2..<3, "じん")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let segments = flatSegments(overrides)
        #expect(segments.compactMap(\.reading).joined() == "にっぽんじん",
                "the candidate sharing the longest leading run with にっぽん must win")
        // Per-token placement, not just the concatenation: putting the whole reading on one
        // token concatenates to the same string and would pass a reading-only assertion.
        #expect(segments.map(\.text) == ["日", "本", "人"], "one segment per kanji")
        #expect(segments.map { $0.reading ?? "" } == ["にっ", "ぽん", "じん"])
        #expect(segments.map(\.text).joined() == "日本人", "segments must tile the surface")
        #expect(overrides.overrides.count == 2, "both display tokens must be overridden")
    }

    @Test("a tie on the shared prefix is declined, not guessed")
    func nearestTieLeftAlone() {
        var dict = FakeDict()
        // Both candidates share exactly に with the rendered にっぽん, so nothing distinguishes
        // them. Declining is the same answer the unambiguous arms give.
        dict.byForm["日本人"] = [
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            ("にたろうじん", spansFor([(0..<1, "に"), (1..<2, "たろう"), (2..<3, "じん")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty, "a tie must decline rather than pick the first candidate")
    }

    /// CHANGED: sharing NOTHING with any candidate no longer declines, it takes the
    /// dictionary's first (commonest) reading. What we render in that case is not a reading the
    /// word has in any context, just a kun concatenation, so there is no ambiguity to respect.
    ///
    /// The boundary is `nearestTieLeftAlone`, which still declines: a tie at a POSITIVE prefix
    /// is a genuine heteronym and belongs to the reader. That test passing while this one
    /// changed is what shows the line is drawn where it was meant to be.
    @Test("sharing nothing with any reading takes the commonest, not a nonword")
    func noSharedPrefixTakesCommonest() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("やまとびと", spansFor([(0..<1, "や"), (1..<2, "まと"), (2..<3, "びと")])),
            ("からびと", spansFor([(0..<1, "か"), (1..<2, "ら"), (2..<3, "びと")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "やまとびと", "the dictionary's first reading, not the nonword")
        let provenance = flatSegments(overrides).compactMap(\.provenance).first
        #expect(provenance?.source == .heuristic, "a guess, so the reader can correct it")
        #expect(provenance?.invitesChoice == true)
    }

    /// The fallback needs alternatives to be a choice at all: a lone candidate that shares
    /// nothing is handled by the single-reading arm, not by this one.
    @Test("a single candidate sharing nothing is not the commonest-reading case")
    func singleCandidateNotCommonestCase() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [("やまとびと", spansFor([(0..<1, "や"), (1..<2, "まと"),
                                                    (2..<3, "びと")]))]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let provenance = flatSegments(overrides).compactMap(\.provenance).first
        #expect(provenance?.source == .dictionary, "one reading is settled, not guessed")
    }

    /// Heteronym protection must NOT be weakened by the new arm: when the rendered reading is
    /// already one JMdict lists, the run is left alone before `chooseReplacement` is reached.
    @Test("a rendering already among the readings is still left alone")
    func nearestDoesNotOverrideAListedRendering() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にっぽんひと", spansFor([(0..<1, "にっ"), (1..<2, "ぽん"), (2..<3, "ひと")])),
            ("にっぽんじん", spansFor([(0..<1, "にっ"), (1..<2, "ぽん"), (2..<3, "じん")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty, "what we render IS a listed reading; never second-guess it")
    }

    /// The nearest candidate still has to place. A unique nearest whose span straddles the
    /// token boundary is left alone, exactly as the unambiguous arms are.
    /// CHANGED: an unplaceable nearest now spans the run rather than being declined. The
    /// placement is still never GUESSED - nothing is put on an arbitrary token - it is simply
    /// applied at the granularity the dictionary supports, which is the whole compound.
    @Test("unique nearest whose spans cannot tile the tokens spans the run")
    func nearestStraddleSpansTheRun() throws {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            // Nearest to にっぽん, but one indivisible span over 日本 straddles 日本|人.
            ("にっぽんじん", spansFor([(0..<3, "にっぽんじん")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let run = try #require(overrides.spanning.first)
        #expect(run.segment.reading == "にっぽんじん")
        #expect(run.range == 0..<2, "one ruby over the whole run, not a guessed per-token split")
    }

    /// The nearest is chosen over ALL candidates, not just the placeable ones.
    ///
    /// Found by a cross-model review of the shipped rule. Scoring only span-backed candidates
    /// silently drops the nearest when it lacks a placement row and renders a FARTHER reading
    /// instead - here にほんじん, when what the page renders (にっぽん...) points at
    /// にっぽんじん. Asserting a reading the evidence points away from is worse than declining,
    /// so the nearest wins the scoring and then fails to place, and the run is left alone.
    @Test("a nearer candidate without spans blocks a farther one, it does not lose to it")
    func nearestWithoutSpansDeclinesRatherThanFallingBack() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にっぽんじん", nil),                                             // nearest, unplaceable
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            ("やまとびと", spansFor([(0..<1, "や"), (1..<2, "まと"), (2..<3, "びと")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        // The point of this test is UNCHANGED: the farther placeable candidate must not win.
        // Previously that meant declining; now the nearer one spans the run, which renders the
        // reading the evidence actually points at rather than にほんじん.
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "にっぽんじん",
                "scoring only placeable candidates would render にほんじん here; got \(reading)")
        #expect(overrides.overrides.isEmpty, "and never as a per-token split")
    }

    /// Arm precedence: when exactly one candidate carries a spans row, that arm settles it and
    /// the nearest rule never runs, even though another candidate is nearer to the rendering.
    @Test("the single-spans-row arm wins over a nearer candidate without a row")
    func spansRowBeatsNonNearest() {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            ("にっぽんじん", nil)  // nearer to にっぽん, but no placement row
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "にほんじん",
                "the dictionary-settled arm must take precedence over the heuristic")
    }

    // MARK: - Candidate preservation, so the reader-choice affordance stays buildable

    /// A heuristic pick must be DISTINGUISHABLE from a dictionary-settled one, and must carry
    /// every candidate. Discarding these was the gap that would have made the reader-choice
    /// feature a regression: a word showing a confident reading yesterday would grow an
    /// ambiguity marker today. See docs/furigana/backlog-reading-choice.md.
    @Test("a heuristic pick carries its alternatives and says it was a guess")
    func nearestPickIsDistinguishable() throws {
        var dict = FakeDict()
        dict.byForm["日本人"] = [
            ("にほんじん", spansFor([(0..<1, "に"), (1..<2, "ほん"), (2..<3, "じん")])),
            ("にっぽんじん", spansFor([(0..<1, "にっ"), (1..<2, "ぽん"), (2..<3, "じん")]))
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: nihonjinTokens, renderedReadings: nihonjinRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let segments = flatSegments(overrides)
        #expect(!segments.isEmpty)
        // EVERY segment of the run carries it, so a per-occurrence correction path can hang
        // off any character the reader taps.
        for segment in segments {
            let provenance = try #require(segment.provenance,
                                          "every segment of a joined run must carry provenance")
            #expect(provenance.source == .heuristic)
            #expect(provenance.chosen == "にっぽんじん")
            #expect(provenance.candidates == ["にほんじん", "にっぽんじん"],
                    "the WHOLE candidate list, in dictionary order, including the chosen one")
            #expect(provenance.invitesChoice, "a guess with alternatives is exactly the case")
        }
    }

    /// The counterpart: an unambiguous dictionary hit must NOT invite a choice, or the
    /// affordance would mark words that were never in doubt.
    @Test("a dictionary-settled reading is marked as settled, not as a guess")
    func dictionaryPickIsNotAGuess() throws {
        var dict = FakeDict()
        dict.byForm["運転手"] = [("うんてんしゅ", spansFor([(0..<1, "うん"), (1..<2, "てん"),
                                                     (2..<3, "しゅ")]))]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let provenance = try #require(flatSegments(overrides).first?.provenance)
        #expect(provenance.source == .dictionary)
        #expect(provenance.candidates == ["うんてんしゅ"])
        #expect(!provenance.invitesChoice, "one candidate is not a choice")
    }

    /// The spans-row arm is dictionary-settled too, even though several readings existed.
    @Test("the single-spans-row arm reports dictionary, not heuristic")
    func spansRowArmReportsDictionary() throws {
        var dict = FakeDict()
        dict.byForm["博物館"] = [
            ("はくぶつかん", spansFor([(0..<1, "はく"), (1..<2, "ぶつ"), (2..<3, "かん")])),
            ("はくぶつくわん", nil)
        ]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: [token("博物", 0, 2), token("館", 2, 3)],
            renderedReadings: ["はくぶつ", "たて"], sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let provenance = try #require(flatSegments(overrides).first?.provenance)
        #expect(provenance.source == .dictionary)
        #expect(provenance.candidates.count == 2, "both readings are still offered")
        #expect(!provenance.invitesChoice)
    }

    /// Provenance must SURVIVE the production copy paths. `ReaderContent.build` re-stamps every
    /// segment through `applyingPitch`, and `withBaseForm` rebuilds them too; either dropping
    /// the field would leave this correct at the decision and empty by the time it is rendered.
    @Test("provenance survives withPitch and withBaseForm")
    func provenanceSurvivesCopies() throws {
        let original = RubySegment(text: "人", reading: "じん", baseForm: "日本人",
                                   provenance: ReadingProvenance(
                                    candidates: ["にほんじん", "にっぽんじん"],
                                    chosen: "にっぽんじん", source: .heuristic))
        let pitched = original.withPitch([MoraPitch(mora: "じん", level: .high, isDrop: false)])
        #expect(pitched.provenance == original.provenance, "withPitch must not drop provenance")
        let rebased = original.withBaseForm("別")
        #expect(rebased.provenance == original.provenance,
                "withBaseForm must not drop provenance")
    }
}

/// The compound join through the REAL `KaraokeWord.tokenize` in-context path.
@Suite("CompoundJoin end-to-end (KaraokeWord.tokenize)")
struct CompoundJoinEndToEndTests {

    /// A segmenter that yields fixed tokens, so a fixture can force the 博物館 -> 博物|館
    /// split (and 静か -> one token) the defect needs.
    private struct FixedSplit: CJKWordSegmenter {
        let tokens: [WordTokenizer.Token]
        func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token] { tokens }
    }

    private func token(_ text: String, _ lower: Int, _ upper: Int) -> WordTokenizer.Token {
        WordTokenizer.Token(offsets: WordOffsets(lower: lower, upper: upper), text: text,
                            latinTranscription: nil, tightLeading: false)
    }

    // MARK: - Script variants of one reading are not ambiguity

    @Test("いまいち and イマイチ are one reading, so the join still fires")
    func scriptVariantsAreNotAmbiguity() throws {
        // JMdict lists 今一 under both いまいち and イマイチ. They are the same reading in
        // two scripts. Counting them as two candidates broke the join twice over: the
        // single-reading arm never fired, and the spans tiebreak saw BOTH candidates
        // resolve to the same hiragana row, because the span lookup matches on normalised
        // kana, so "exactly one carries spans" counted two and the run was declined.
        // Measured over an 18-book corpus, that wrongly declined 今一 21 times.
        let text = "今一"
        let segmenter = FixedSplit(tokens: [token("今", 0, 1), token("一", 1, 2)])
        let annotations: ([String]) -> [TokenAnnotation?] = { surfaces in
            surfaces.map { ["今": TokenAnnotation(reading: "こん", baseForm: "今"),
                            "一": TokenAnnotation(reading: "ひと", baseForm: "一")][$0] }
        }
        let spans = [ReadingSpan(range: 0..<1, kana: "いま"),
                     ReadingSpan(range: 1..<2, kana: "いち")]
        // The katakana variant carries no spans row of its own; the lookup normalises, so
        // before the fix it aliased onto the hiragana row and made the count two.
        let compound: (String) -> [ReadingPayload] = { form in
            form == "今一"
                ? [ReadingPayload(reading: "いまいち", spans: spans),
                   ReadingPayload(reading: "イマイチ", spans: nil)]
                : []
        }
        let joined = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                          compoundReadings: compound, segmenter: segmenter)
        #expect(joined.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined() == "いまいち")

        // And with the join absent the defect is still present, so this fixture is not
        // passing for some unrelated reason.
        let without = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                           compoundReadings: nil, segmenter: segmenter)
        #expect(without.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined() == "こんひと")
    }

    // MARK: - A10: nil closure exhibits the defect, present closure fixes it

    @Test("博物館 renders はくぶつたて with the join nil, はくぶつかん with it present")
    func museumFixedOnlyWithJoin() throws {
        let text = "博物館"
        let segmenter = FixedSplit(tokens: [token("博物", 0, 2), token("館", 2, 3)])
        // In-context annotation: 博物 -> はくぶつ (right), 館 -> たて (the split-out half's
        // wrong reading, the exact defect).
        let annotations: ([String]) -> [TokenAnnotation?] = { surfaces in
            surfaces.map { ["博物": TokenAnnotation(reading: "はくぶつ", baseForm: "博物"),
                            "館": TokenAnnotation(reading: "たて", baseForm: "館")][$0] }
        }
        let compound: (String) -> [ReadingPayload] = { form in
            form == "博物館"
                ? [ReadingPayload(reading: "はくぶつかん",
                                  spans: [ReadingSpan(range: 0..<1, kana: "はく"),
                                          ReadingSpan(range: 1..<2, kana: "ぶつ"),
                                          ReadingSpan(range: 2..<3, kana: "かん")])]
                : []
        }
        let without = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                           segmenter: segmenter)
        #expect(without.flatMap(\.ruby).compactMap(\.reading).joined() == "はくぶつたて")

        let with = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                        compoundReadings: compound, segmenter: segmenter)
        #expect(with.flatMap(\.ruby).compactMap(\.reading).joined() == "はくぶつかん")
        // Token identity/offsets are untouched by the join.
        #expect(with.map(\.text) == without.map(\.text))
        #expect(with.map(\.utf16Upper) == without.map(\.utf16Upper))
    }

    // MARK: - A11: the isolation defect stays fixed (静か -> しずか, never しずかか)

    @Test("静か still renders しずか with the join present (isolation defect stays fixed)")
    func shizukaUnaffectedByJoin() throws {
        let text = "静か"
        let segmenter = FixedSplit(tokens: [token("静か", 0, 2)])
        let annotations: ([String]) -> [TokenAnnotation?] = { surfaces in
            surfaces.map { $0 == "静か" ? TokenAnnotation(reading: "しずか", baseForm: "静か") : nil }
        }
        // A join closure that WOULD fire on 静 if the run were eligible; 静か is not all-kanji,
        // so the join must never touch it.
        let compound: (String) -> [ReadingPayload] = { _ in [] }
        let words = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                         compoundReadings: compound, segmenter: segmenter)
        // The reading over the surface (しず over 静, か bare) reconstructs to しずか, never the
        // isolation defect しずかか (which double-counts か by re-analysing 静か as 静+か).
        let overSurface = words.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined()
        #expect(overSurface == "しずか")
        #expect(overSurface != "しずかか")
        #expect(words.flatMap(\.ruby).map(\.text).joined() == "静か")
    }

    // MARK: - The regression this round fixes: annotation != rendered

    /// A run whose per-token ANNOTATION readings concatenate to a LISTED reading (うんてん+しゅ
    /// = うんてんしゅ) while what is actually RENDERED is a different, UNLISTED one (うんてん+て
    /// = うんてんて) must be JOINED. The rendered divergence happens because the tier discards
    /// the annotation reading しゅ for 手 and the token falls back to て. Round 1 keyed the
    /// decision on the annotation reading, so heteronym protection wrongly fired and left the
    /// nonword on screen; keying on the rendered reading fixes it. Fails against round-1 code.
    @Test("annotation reads listed but the run RENDERS an unlisted reading -> joined")
    func annotationListedButRenderedUnlistedJoins() throws {
        let text = "運転手"
        let segmenter = FixedSplit(tokens: [token("運転", 0, 2), token("手", 2, 3)])
        let annotations: ([String]) -> [TokenAnnotation?] = { surfaces in
            surfaces.map { ["運転": TokenAnnotation(reading: "うんてん", baseForm: "運転"),
                            "手": TokenAnnotation(reading: "しゅ", baseForm: "手")][$0] }
        }
        // The tier cannot validate (手, しゅ) and repairs it to て, so 手 RENDERS て even though
        // its annotation says しゅ. 運転's payload is nil, so it renders its annotation うんてん.
        let annotatedPayload: (String, TokenAnnotation) -> ReadingPayload? = { surface, _ in
            surface == "手" ? ReadingPayload(reading: "て") : nil
        }
        let compound: (String) -> [ReadingPayload] = { form in
            form == "運転手"
                ? [ReadingPayload(reading: "うんてんしゅ",
                                  spans: [ReadingSpan(range: 0..<1, kana: "うん"),
                                          ReadingSpan(range: 1..<2, kana: "てん"),
                                          ReadingSpan(range: 2..<3, kana: "しゅ")])]
                : []
        }
        // Without the join the fixture genuinely renders the nonword (annotation != rendered).
        let without = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                           annotatedPayload: annotatedPayload, segmenter: segmenter)
        #expect(without.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined() == "うんてんて")

        let with = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                        annotatedPayload: annotatedPayload,
                                        compoundReadings: compound, segmenter: segmenter)
        #expect(with.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined() == "うんてんしゅ")
    }

    /// The converse: when what is RENDERED is already a listed reading, the run is left alone
    /// even though a join closure is present. Here the tier keeps (手, しゅ), so the run renders
    /// うんてんしゅ; the join must not re-distribute it (運転 stays a single ruby segment).
    @Test("run that RENDERS a listed reading is left alone with the join present")
    func renderedListedLeavesAlone() throws {
        let text = "運転手"
        let segmenter = FixedSplit(tokens: [token("運転", 0, 2), token("手", 2, 3)])
        let annotations: ([String]) -> [TokenAnnotation?] = { surfaces in
            surfaces.map { ["運転": TokenAnnotation(reading: "うんてん", baseForm: "運転"),
                            "手": TokenAnnotation(reading: "しゅ", baseForm: "手")][$0] }
        }
        let compound: (String) -> [ReadingPayload] = { form in
            form == "運転手"
                ? [ReadingPayload(reading: "うんてんしゅ",
                                  spans: [ReadingSpan(range: 0..<1, kana: "うん"),
                                          ReadingSpan(range: 1..<2, kana: "てん"),
                                          ReadingSpan(range: 2..<3, kana: "しゅ")])]
                : []
        }
        let with = KaraokeWord.tokenize(text, segmentIndex: 0, annotations: annotations,
                                        compoundReadings: compound, segmenter: segmenter)
        #expect(with.flatMap(\.ruby).map { $0.reading ?? $0.text }.joined() == "うんてんしゅ")
        // Left alone: 運転 keeps its single whole-token ruby segment rather than being split
        // per kanji (運[うん]転[てん]) as a spans-distributed replacement would.
        #expect(with.first?.ruby.count == 1)
    }

}
