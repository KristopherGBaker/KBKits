import Foundation
import KBCore
import Testing
@testable import KBReadingKit

/// Merging display tokens the sentence analysis treats as one word.
///
/// The concrete defect: `２人` tokenizes as `２ | 人` by script and analyses as one word reading
/// ふたり, so the aligner rejects both halves and 人 renders ひと - "hito" over a word that says
/// "futari".
struct AnnotationRegroupTests {

    /// An aligner that places only the surfaces in `table`, and counts how often it is asked.
    private final class Spy: @unchecked Sendable {
        let table: [String: String]
        private(set) var passes = 0
        private(set) var asked: [[String]] = []

        /// Whether to answer the way a FAILED tiling does: an empty array, whatever it was
        /// asked. `FuriganaAlignment` reserves that for "the analysis describes different text".
        let answersNothing: Bool

        init(_ table: [String: String], answersNothing: Bool = false) {
            self.table = table
            self.answersNothing = answersNothing
        }

        func annotations(_ surfaces: [String]) -> [TokenAnnotation?] {
            passes += 1
            asked.append(surfaces)
            if answersNothing { return [] }
            return surfaces.map { table[$0].map { TokenAnnotation(reading: $0, baseForm: nil) } }
        }
    }

    private func tokens(_ surfaces: [String]) -> [WordTokenizer.Token] {
        var offset = 0
        return surfaces.map { surface in
            defer { offset += surface.utf16.count }
            return WordTokenizer.Token(
                offsets: WordOffsets(lower: offset, upper: offset + surface.utf16.count),
                text: surface, latinTranscription: nil, tightLeading: false)
        }
    }

    /// ISSUE 051. Punctuation aligns with an EMPTY reading. A sentence built only of numerals
    /// and punctuation - 二月、三月、四月。 - places 、 and 。 and nothing else, so a guard that
    /// asked for a NON-EMPTY reading skipped the regroup, every token fell back to isolated
    /// per-surface analysis, and 四月 rendered よつき on a real screen.
    ///
    /// The same sentence with anything ordinary after it regroups and reads しがつ, which is how
    /// a wrong reading can depend on what FOLLOWS the word that shows it. Both are asserted here,
    /// because the second is what made the first look like it could not be the regroup.
    @Test func punctuationAloneStillCountsAsAnAlignment() {
        let table = ["、": "", "。": "", "二月": "にがつ", "三月": "さんがつ", "四月": "しがつ"]
        let spy = Spy(table)
        let result = KaraokeWord.regroupedForAnnotation(
            tokens(["二", "月", "、", "三", "月", "、", "四", "月", "。"]),
            annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["二月", "、", "三月", "、", "四月", "。"])
        #expect(result.annotations?.compactMap { $0?.reading }
            == ["にがつ", "", "さんがつ", "", "しがつ", ""])

        // The control: with an ordinary word after it the sentence regrouped even before the
        // fix, so it cannot distinguish one guard from the other on its own.
        let withTail = Spy(table.merging(["です": "です"]) { existing, _ in existing })
        let tailed = KaraokeWord.regroupedForAnnotation(
            tokens(["四", "月", "です", "。"]), annotations: withTail.annotations)
        #expect(tailed.tokens.map(\.text) == ["四月", "です", "。"])
    }

    /// A sentence the aligner TILED but placed nothing in is exactly what this function is for.
    /// A bare 四月 splits 四|月 against the single analysis word 四月, so both tokens straddle and
    /// nothing is placed - and merging them is the right answer.
    @Test func aTiledSentenceWithNothingPlacedIsStillProbed() {
        let spy = Spy(["四月": "しがつ"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["四", "月"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["四月"])
        #expect(result.annotations?.compactMap { $0?.reading } == ["しがつ"])
    }

    /// The guard that must NOT be removed, and the reason it can now be told apart: an aligner
    /// that could not tile the sentence at all returns an EMPTY array (Open JTalk answers 二十七日
    /// for 27日, so the analysis describes different text). Merging on that would be a guess, and
    /// the length check refuses it without a second condition.
    @Test func aSentenceTheAlignerCouldNotTileIsNotRegrouped() {
        let spy = Spy([:], answersNothing: true)
        let result = KaraokeWord.regroupedForAnnotation(tokens(["27", "日"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["27", "日"], "left exactly as tokenized")
        #expect(spy.passes == 1, "and not probed, so it costs one frontend pass")
    }

    @Test func aRunTheAnalysisPlacesAsOneWordIsMerged() {
        let spy = Spy(["で": "で", "２人": "ふたり"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["２", "人", "で"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["２人", "で"])
        #expect(result.annotations?.map { $0?.reading } == ["ふたり", "で"])
        #expect(result.tokens[0].offsets.lower == 0)
        #expect(result.tokens[0].offsets.upper == 2, "the merged token spans both originals")
    }

    @Test func aRunTheAnalysisStillRejectsIsLeftExactlyAsItWas() {
        let spy = Spy(["で": "で"])   // neither ２, 人 nor ２人 is placed
        let result = KaraokeWord.regroupedForAnnotation(tokens(["２", "人", "で"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["２", "人", "で"])
        #expect(result.annotations?.map { $0?.reading } == [nil, nil, "で"])
    }

    /// A sentence is never FUSED into one word, and what guarantees that is the probe checking
    /// its own answer - not the guard refusing to probe.
    ///
    /// This assertion used to require the aligner to have placed something, on the reasoning
    /// that all-nil meant a tiling failure. It can mean that OR a sentence every display token
    /// straddles, and refusing both cost a bare 四月 its reading. The tiling failure is now
    /// signalled by an EMPTY array instead, so this case is probed - and the analysis placing
    /// nothing is what leaves it alone.
    ///
    /// The cost of probing it is one extra frontend pass, bounded here: a sentence the analysis
    /// answers nothing for must not turn into a series of probes.
    @Test func anEntirelyUnalignedSentenceIsNeverFused() {
        let spy = Spy([:])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["静", "か", "だ"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["静", "か", "だ"])
        #expect(result.annotations?.allSatisfy { $0 == nil } == true)
        #expect(spy.passes <= 2, "one alignment and at most one probe, never a probe per run")
    }

    @Test func theRunLengthIsCapped() {
        let spy = Spy(["あ": "あ"])
        let long = tokens(["人", "年", "日", "月", "花", "山", "あ"])
        _ = KaraokeWord.regroupedForAnnotation(long, annotations: spy.annotations, maxRun: 4)
        let probe = spy.asked.last
        #expect(probe?.contains("人年日月") == true, "the run is cut at maxRun, not swallowed whole")
        #expect(probe?.contains("人年日月花山") == false)
    }

    /// An all-kanji run merges too. It was restricted to mixed-script runs for a while, on the
    /// worry that taking 日本|人 from the compound join would delete the reader's choice between
    /// にほんじん and にっぽんじん. Probing the real pipeline disproved it: the merged word carries
    /// the SAME candidates, from the tier rather than the join, stamped `.analysis` instead of
    /// `.heuristic` - the better source, because the sentence chose the reading with context
    /// where the join guesses by prefix. The restriction cost 585 gold mismatches and tripled
    /// the join's own defect count.
    @Test func anAllKanjiRunMergesToo() {
        let spy = Spy(["は": "は", "日本人": "にほんじん"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["日本", "人", "は"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["日本人", "は"])
        #expect(result.annotations?.map { $0?.reading } == ["にほんじん", "は"])
    }

    @Test func latinBesideKanjiMergesAsWell() {
        let spy = Spy(["の": "の", "Ｂ級": "びいきゅう"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["Ｂ", "級", "の"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["Ｂ級", "の"])
    }

    /// Each pass is an Open JTalk frontend pass over the sentence. A sentence with nothing to
    /// merge - almost every sentence - must still cost exactly one.
    @Test func nothingToMergeCostsOnePass() {
        let spy = Spy(["私": "わたし", "は": "は"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["私", "は"]),
                                                        annotations: spy.annotations)
        #expect(spy.passes == 1)
        #expect(result.tokens.map(\.text) == ["私", "は"])
    }

    @Test func noAnnotationClosureChangesNothing() {
        let result = KaraokeWord.regroupedForAnnotation(tokens(["２", "人"]), annotations: nil)
        #expect(result.tokens.map(\.text) == ["２", "人"])
        #expect(result.annotations == nil)
    }

    /// Two separate merges in one sentence, with unmergeable tokens between them: the rebuild
    /// walks the probe rather than re-deriving positions, which is where an earlier draft put
    /// an annotation on the wrong token.
    @Test func severalRunsInOneSentenceEachMapBack() {
        let spy = Spy(["と": "と", "２人": "ふたり", "１日": "いちにち"])
        let result = KaraokeWord.regroupedForAnnotation(tokens(["２", "人", "と", "１", "日"]),
                                                        annotations: spy.annotations)
        #expect(result.tokens.map(\.text) == ["２人", "と", "１日"])
        #expect(result.annotations?.map { $0?.reading } == ["ふたり", "と", "いちにち"])
    }
}
