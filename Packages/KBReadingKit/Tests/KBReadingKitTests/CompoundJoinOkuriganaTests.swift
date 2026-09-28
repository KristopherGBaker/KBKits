import KBCore
import Foundation
import Testing
@testable import KBReadingKit

/// The okurigana-headed compound join (`furigana-okurigana-join`): a run may now be OPENED by a
/// token that carries its own okurigana (生き, 考え, 読み), so 生き+方 is a candidate and 方 stops
/// being read alone as ほう. Every arm injects a fake dictionary; no real JMdict is involved.
///
/// The class is held to a STRICTER standard than an all-kanji run, and each guard has its own
/// arm here: a placement row that distributes per token is required (no whole-run `.spanning`,
/// no unplaced heuristic), and a reading that ABSORBS okurigana the text spells on is refused.
@Suite("CompoundJoin okurigana head (injected dictionary)")
struct CompoundJoinOkuriganaTests {

    /// 生き方 as the tokenizer splits it: 生き|方. Pass 1 renders いき + ほう, because 方 alone is
    /// commoner as ほう - the defect this unit exists to fix.
    private var ikikataTokens: [WordTokenizer.Token] { [token("生き", 0, 2), token("方", 2, 3)] }
    private var ikikataRendered: [String] { ["いき", "ほう"] }

    /// The JmdictFurigana row for 生き方/いきかた, `0:い;2:かた`, expanded the way
    /// `JmdictFuriganaParser.spans` expands it: the kana position 1 becomes a bare filler span.
    private var ikikataSpans: [ReadingSpan] {
        [ReadingSpan(range: 0..<1, kana: "い"),
         ReadingSpan(range: 1..<2, kana: nil),
         ReadingSpan(range: 2..<3, kana: "かた")]
    }

    // MARK: - The predicate that opens the class

    @Test("isKanjiWithOkurigana: kanji first, some kana, nothing else")
    func headPredicate() {
        #expect(FuriganaAnnotator.isKanjiWithOkurigana("生き"))
        #expect(FuriganaAnnotator.isKanjiWithOkurigana("考え"))
        #expect(FuriganaAnnotator.isKanjiWithOkurigana("打ち合わ"))
        // A leading kana would start the joined surface mid-word.
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("お知らせ"))
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("きな"))
        // No kana at all is the all-kanji case, which `isKanjiOnly` already covers.
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("運転"))
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana(""))
        // Anything that is neither kanji nor kana is never part of a form JMdict lists.
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生kき"))
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生き、"))
        // PUNCTUATION THAT LIVES IN A KANA BLOCK. `isKanaScalar` answers "is this in a kana
        // block" and says yes to both of these, so a predicate written on top of it admits
        // 生・ as an okurigana head. A cross-model review found exactly that.
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生・"))
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生゠"))
        // The SPACING sound marks stand alone rather than attaching to a kana, so they are
        // punctuation here too - the same class, found as a residual note by the same review.
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生゛"))
        #expect(!FuriganaAnnotator.isKanjiWithOkurigana("生゜"))
        // ー is a kana LETTER and spells part of a word, so it stays admitted. So do the
        // COMBINING marks: a decomposed が is か + U+3099, and rejecting it would turn an
        // ordinary token away over nothing but the text's normalisation form.
        #expect(FuriganaAnnotator.isKanjiWithOkurigana("生ー"))
        #expect(FuriganaAnnotator.isKanjiWithOkurigana("生か\u{3099}"))
        // The two predicates stay disjoint: a token is one or the other, never both.
        #expect(!FuriganaAnnotator.isKanjiOnly("生き"))
    }

    // MARK: - The fix itself

    @Test("生き+方: the row distributes, 生[い]き stays bare on き, 方 becomes かた")
    func okuriganaHeadReplaces() {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", ikikataSpans)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let head = try? #require(result.overrides[0])
        let tail = try? #require(result.overrides[1])
        #expect(head?.map { ($0.text, $0.reading) } .elementsEqual(
            [("生", "い"), ("き", nil)], by: ==) == true)
        #expect(tail?.map { ($0.text, $0.reading) } .elementsEqual([("方", "かた")], by: ==) == true)
        // The run reconstructs to its own surface and to the dictionary's reading.
        #expect(flatSegments(result).map(\.text).joined() == "生き方")
        #expect(KaraokeWord.renderedReading(segments: head ?? [], surface: "生き")
            + KaraokeWord.renderedReading(segments: tail ?? [], surface: "方") == "いきかた")
        #expect(result.spanning.isEmpty)
    }

    // MARK: - The run-selection grammar, closed by deny fixtures

    /// Every arm here is arranged so that ELIGIBILITY is the only thing stopping the join: the
    /// joined form is known, its row distributes, and what the tokens render is NOT among the
    /// listed readings. A deny list that passes because the fixture was toothless proves nothing,
    /// so `admitsAnAllKanjiRun` is the positive control run against the same helper.
    private func grammarResult(
        _ tokens: [WordTokenizer.Token],
        _ rendered: [String],
        joined: String,
        reading: String,
        sourceRuby: [RubyRun] = []
    ) -> KaraokeWord.JoinResult {
        var dict = FakeDict()
        var spans: [ReadingSpan] = []
        var cursor = 0
        // One kana per character keeps the row tiling and distributing whatever the surface is.
        for _ in Array(joined) {
            spans.append(ReadingSpan(range: cursor..<(cursor + 1), kana: "ん"))
            cursor += 1
        }
        dict.byForm[joined] = [(reading, spans)]
        return KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: rendered, sourceRuby: sourceRuby,
            readings: dict.readings, spans: dict.spans)
    }

    @Test("POSITIVE control: the all-kanji run this fixture shape describes still joins")
    func admitsAnAllKanjiRun() {
        let result = grammarResult([token("運転", 0, 2), token("手", 2, 3)], ["うんてん", "て"],
                                   joined: "運転手", reading: "んんん")
        #expect(!result.overrides.isEmpty, "the deny arms below must be denying something real")
    }

    @Test("DENY: a kana-first head (お知らせ shape) never opens a run")
    func deniesKanaFirstHead() {
        #expect(grammarResult([token("お知ら", 0, 3), token("方", 3, 4)], ["おしら", "ほう"],
                              joined: "お知ら方", reading: "んんんん").isEmpty)
    }

    @Test("DENY: a head carrying a scalar that is neither kanji nor kana never opens a run")
    func deniesForeignScalarInHead() {
        #expect(grammarResult([token("生k", 0, 2), token("方", 2, 3)], ["いけ", "ほう"],
                              joined: "生k方", reading: "んんん").isEmpty)
        #expect(grammarResult([token("生き、", 0, 3), token("方", 3, 4)], ["いき、", "ほう"],
                              joined: "生き、方", reading: "んんんん").isEmpty)
        // Observable at the CORE ENTRY, not only at the predicate: ・ and ゠ sit INSIDE the
        // katakana block, so a scalar test that asks "is this in a kana block" admits them and
        // the join stamps ruby over a separator. The predicate arm above would pass a fix that
        // never reached `compoundJoinOverrides`; this one would not.
        #expect(grammarResult([token("生・", 0, 2), token("方", 2, 3)], ["いき", "ほう"],
                              joined: "生・方", reading: "んんん").isEmpty)
        #expect(grammarResult([token("生゠", 0, 2), token("方", 2, 3)], ["いき", "ほう"],
                              joined: "生゠方", reading: "んんん").isEmpty)
        #expect(grammarResult([token("生゛", 0, 2), token("方", 2, 3)], ["いき", "ほう"],
                              joined: "生゛方", reading: "んんん").isEmpty)
    }

    @Test("DENY: an okurigana-bearing token as the SECOND token of a run")
    func deniesOkuriganaAtTokenTwo() {
        #expect(grammarResult([token("方", 0, 1), token("生き", 1, 3)], ["かた", "いき"],
                              joined: "方生き", reading: "んんん").isEmpty)
    }

    @Test("DENY: an okurigana-bearing token at a LATER position, so the rule is only-the-head")
    func deniesOkuriganaAtTokenThree() {
        // 運転|手|生き: the first two tokens are all-kanji, so a rule reading "only token two"
        // would still admit 生き here and join the three. Only the HEAD may carry okurigana, so
        // the run stops at 手 and the three-token form is never offered.
        let result = grammarResult(
            [token("運転", 0, 2), token("手", 2, 3), token("生き", 3, 5)],
            ["うんてん", "て", "いき"], joined: "運転手生き", reading: "んんんんん")
        #expect(result.isEmpty)
    }

    @Test("DENY: an okurigana head overlapping author ruby (author ruby stays above this tier)")
    func deniesOkuriganaHeadUnderSourceRuby() {
        #expect(grammarResult(ikikataTokens, ikikataRendered, joined: "生き方", reading: "んんん",
                              sourceRuby: [RubyRun(lower: 0, upper: 2, reading: "いき")]).isEmpty)
    }

    // MARK: - Placement is required: no spanning, no unplaced heuristic

    @Test("okurigana head with NO placement row: declined, not spanned")
    func noRowDeclines() {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", nil)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        // An all-kanji run in this position would have SPANNED (二日/ふつか). An okurigana head
        // must not: a single ruby over 生き方 would put いきかた over the き that reads as itself.
        #expect(result.isEmpty)
    }

    @Test("okurigana head whose row straddles the token boundary: declined, not spanned")
    func straddlingRowDeclines() {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", [ReadingSpan(range: 0..<3, kana: "いきかた")])]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(result.isEmpty)
    }

    // MARK: - The okurigana-absorption guard

    @Test("受け+取: the reading absorbs okurigana the text spells on, so the run is declined")
    func absorbingReadingDeclines() {
        var dict = FakeDict()
        // 受け取 is an okurigana-LESS variant spelling; 受け取り is the canonical form and reads
        // THE SAME. Joining the short one would render うけとり and then a bare り/らし after it.
        dict.byForm["受け取"] = [("うけとり", [ReadingSpan(range: 0..<1, kana: "う"),
                                          ReadingSpan(range: 1..<2, kana: nil),
                                          ReadingSpan(range: 2..<3, kana: "とり")])]
        dict.byForm["受け取り"] = [("うけとり", nil)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: [token("受け", 0, 2), token("取", 2, 3)], renderedReadings: ["うけ", "と"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        #expect(result.isEmpty)
    }

    @Test("the guard folds script: a KATAKANA sibling reading still declines")
    func absorptionGuardIsScriptNormalized() {
        var dict = FakeDict()
        dict.byForm["受け取"] = [("うけとり", [ReadingSpan(range: 0..<1, kana: "う"),
                                          ReadingSpan(range: 1..<2, kana: nil),
                                          ReadingSpan(range: 2..<3, kana: "とり")])]
        // JMdict writes some readings in katakana. うけとり and ウケトリ are one reading in two
        // scripts, exactly as いまいち/イマイチ are for the join decision itself, so a guard keyed
        // on raw string equality would let this through while passing the hiragana arm above.
        dict.byForm["受け取り"] = [("ウケトリ", nil)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: [token("受け", 0, 2), token("取", 2, 3)], renderedReadings: ["うけ", "と"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        #expect(result.isEmpty)
    }

    @Test("the guard is keyed on the DICTIONARY, not on the text: 生き方 has no such sibling")
    func absorptionGuardDoesNotOverreach() {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", ikikataSpans)]
        // The completed surface the guard probes for. Absent, so the run is joined.
        #expect(dict.readings("生き方た").isEmpty)
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(!result.overrides.isEmpty)
    }

    @Test("a SIBLING with a different reading does not trip the guard")
    func absorptionGuardNeedsTheSameReading() {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", ikikataSpans)]
        // 生き方た exists but reads something else entirely: not an okurigana-less variant.
        dict.byForm["生き方た"] = [("まったくべつ", nil)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(!result.overrides.isEmpty)
    }

    // MARK: - Nothing an all-kanji run does today may change

    /// 生き|物|語 - the interaction the brief names. The okurigana-headed run must decide nothing
    /// AND must not consume the run, or 物語 inside it is never tried and an all-kanji join that
    /// works today is silently lost. Four ways the run can fail to settle, each asserted to leave
    /// 物語 joinable: no placement row, a straddling row, an unplaced heuristic pick, and a
    /// rendering that is already correct.
    private var ikimonogatariTokens: [WordTokenizer.Token] {
        [token("生き", 0, 2), token("物", 2, 3), token("語", 3, 4)]
    }
    private var ikimonogatariRendered: [String] { ["いき", "もの", "ご"] }
    private var monogatariSpans: [ReadingSpan] {
        [ReadingSpan(range: 0..<1, kana: "もの"), ReadingSpan(range: 1..<2, kana: "がたり")]
    }

    /// Assert the shape both halves of the claim share: the okurigana-headed run decided nothing,
    /// and 物語 was still replaced. `.leave` satisfies the first half while breaking the second.
    private func expectInnerCompoundStillJoins(
        _ result: KaraokeWord.JoinResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.overrides[0] == nil, "the okurigana head decided nothing",
                sourceLocation: sourceLocation)
        #expect(result.spanning.isEmpty, "an okurigana head must never span",
                sourceLocation: sourceLocation)
        #expect(flatSegments(result).compactMap(\.reading).joined() == "ものがたり",
                "物語 inside the run must still join", sourceLocation: sourceLocation)
    }

    private func ikimonogatari(_ readings: [(reading: String, spans: [ReadingSpan]?)])
        -> KaraokeWord.JoinResult {
        var dict = FakeDict()
        dict.byForm["生き物語"] = readings
        dict.byForm["物語"] = [("ものがたり", monogatariSpans)]
        return KaraokeWord.compoundJoinOverrides(
            tokens: ikimonogatariTokens, renderedReadings: ikimonogatariRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
    }

    @Test("no placement row: UNKNOWN, and 物語 inside the run still joins")
    func noRowLeavesInnerRunScannable() {
        expectInnerCompoundStillJoins(ikimonogatari([("いきものがたり", nil)]))
    }

    @Test("a straddling row: UNKNOWN, and 物語 inside the run still joins")
    func straddlingRowLeavesInnerRunScannable() {
        // One indivisible span over the whole surface: `distribute` cannot split it at 生き|物.
        expectInnerCompoundStillJoins(ikimonogatari(
            [("いきものがたり", [ReadingSpan(range: 0..<4, kana: "いきものがたり")])]))
    }

    @Test("nothing settles at all: UNKNOWN, and 物語 inside the run still joins")
    func unsettledLeavesInnerRunScannable() {
        // Two readings, neither with a row. They TIE on the prefix they share with what we render
        // (いき), so the nearest arm declines and the commonest arm - which fires only when
        // nothing shares a prefix - declines too. Nothing settles, and nothing is consumed.
        expectInnerCompoundStillJoins(ikimonogatari(
            [("いきあああああ", nil), ("いきいいいいい", nil)]))
    }

    @Test("an UNPLACED heuristic pick: UNKNOWN, and 物語 inside the run still joins")
    func unplacedHeuristicLeavesInnerRunScannable() {
        // Distinct from the arm above, and the distinction is the point. Here a reading IS
        // settled - いきものがたら shares the longest prefix with what the tokens render
        // (いきものご), so the nearest arm picks it uniquely - but NEITHER candidate carries a
        // placement row, so nothing can be distributed across 生き|物|語. An okurigana head must
        // decline an unplaceable pick rather than span it, and must still leave 物語 joinable.
        //
        // The first version of this test used a TIE, which returns from `chooseReplacement`
        // before the placement decision is ever reached: it asserted the right outcome for the
        // wrong reason, and a cross-model review caught that it never exercised this path.
        expectInnerCompoundStillJoins(ikimonogatari(
            [("いきものがたら", nil), ("ぜんぜんちがう", nil)]))
    }

    @Test("the unplaced-heuristic fixture really does settle on a reading")
    func unplacedHeuristicFixtureActuallyPicks() {
        // Guards the arm above against silently degenerating back into the tie case: give the
        // SAME candidates a distributing row and the same fixture must REPLACE, which it can
        // only do if `chooseReplacement` settled on いきものがたら.
        var dict = FakeDict()
        let spans = (0..<4).map { ReadingSpan(range: $0..<($0 + 1), kana: "ん") }
        dict.byForm["生き物語"] = [("いきものがたら", spans), ("ぜんぜんちがう", nil)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikimonogatariTokens, renderedReadings: ikimonogatariRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(!result.overrides.isEmpty,
                "the fixture must settle on a reading, or the unplaced arm proves nothing")
    }

    @Test("a rendering already among the readings: UNKNOWN, and 物語 inside the run still joins")
    func correctReadingLeavesInnerRunScannable() {
        // Heteronym protection fires: the run renders exactly what the dictionary lists. That
        // must not CONSUME the run - `.leave` would, and 物語 would never be tried.
        expectInnerCompoundStillJoins(ikimonogatari([("いきものご", nil)]))
    }

    // MARK: - Provenance placement

    @Test("provenance rides EVERY reading-bearing run and NO bare run")
    func provenanceSkipsBareRuns() throws {
        var dict = FakeDict()
        dict.byForm["生き方"] = [("いきかた", ikikataSpans)]
        let result = KaraokeWord.compoundJoinOverrides(
            tokens: ikikataTokens, renderedReadings: ikikataRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let segments = flatSegments(result)
        #expect(segments.map(\.text) == ["生", "き", "方"])
        // Exhaustive on purpose: checking only 方 would pass a partially stamped implementation
        // that dropped the head's provenance, and the reader-choice affordance keys off it.
        for segment in segments where segment.reading != nil {
            let provenance = try #require(segment.provenance,
                                          "\(segment.text) carries a reading but no provenance")
            #expect(provenance.source == .dictionary)
            #expect(provenance.chosen == "いきかた")
            #expect(provenance.candidates == ["いきかた"])
        }
        for segment in segments where segment.reading == nil {
            // The same rule `KaraokeWord.applyingCorrectedReading` applies, so correcting a word
            // and re-rendering it cannot disagree about which run offers the alternatives.
            #expect(segment.provenance == nil,
                    "the bare run \(segment.text) must not offer alternatives of its own")
        }
    }
}
