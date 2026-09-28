import KBCore
import Foundation
import Testing
@testable import KBReadingKit

/// The dictionary-decided compound join (`furigana-compound-join`): a maximal run of
/// adjacent, gapless, all-kanji, author-ruby-free display tokens whose JOINED form JMdict
/// knows has its rendered reading replaced when that reading is not one the dictionary
/// lists and a replacement can be settled. Every arm here injects a fake dictionary; no
/// real JMdict is involved.
@Suite("CompoundJoin decision arms (injected dictionary)")
struct CompoundJoinTests {

    // MARK: - A1: single reading, ours differs -> replace over the whole run

    @Test("single reading, ours differs: rendered reading replaced, distributed per kanji")
    func singleReadingReplaced() {
        var dict = FakeDict()
        // One reading, WITH a per-kanji spans row (the realistic shape for 運転手 in
        // JmdictFurigana), so the reading distributes across the run's tokens.
        dict.byForm["運転手"] = [("うんてんしゅ", [ReadingSpan(range: 0..<1, kana: "うん"),
                                            ReadingSpan(range: 1..<2, kana: "てん"),
                                            ReadingSpan(range: 2..<3, kana: "しゅ")])]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(!overrides.isEmpty)
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "うんてんしゅ")
    }

    // MARK: - Round 3: a settled reading whose span cannot tile the tokens is LEFT ALONE

    /// CHANGED deliberately: this run used to be declined, leaving the nonword 二[に]日[ひ] on
    /// the page. ふつか is jukujikun - it belongs to 二日 as a unit and has no per-character
    /// split - so the truthful rendering is one ruby spanning both tokens. What is still
    /// refused is the old whole-run FALLBACK, which put the reading on the first token and
    /// left the second bare (二[ふつか]日); that was measured correct zero times in 316.
    @Test("a reading that cannot tile the tokens spans them instead")
    func straddlingSpanSpansTheRun() throws {
        var dict = FakeDict()
        // 二日/ふつか is jukujikun: JmdictFurigana gives ONE span 0..<2 (ふつか maps to 二日
        // whole, no per-character split). Over display tokens 二|日 that span straddles the
        // boundary, so it cannot distribute. The old code fell back to whole-run placement and
        // rendered 二[ふつか]日 (a bare kanji inside the word's own furigana); the fix declines.
        dict.byForm["二日"] = [("ふつか", [ReadingSpan(range: 0..<2, kana: "ふつか")])]
        let tokens = [token("二", 0, 1), token("日", 1, 2)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["に", "ひ"], sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.overrides.isEmpty, "never a per-token override for an indivisible reading")
        let run = try #require(overrides.spanning.first)
        #expect(run.range == 0..<2, "the ruby covers BOTH tokens, not just the first")
        #expect(run.segment.text == "二日")
        #expect(run.segment.reading == "ふつか")
    }

    /// CHANGED with the same reasoning: a settled reading with no placement row at all used to
    /// be declined. It is still not split per character (nothing says where うん ends), but the
    /// word's own reading over the whole word is what the dictionary gives.
    @Test("a settled reading with no placement row spans the run")
    func singleReadingNoSpansSpansTheRun() throws {
        var dict = FakeDict()
        // A settled single reading but no placement row to distribute: nothing to tile, so the
        // run is left alone (the consequence of removing whole-run placement).
        dict.byForm["運転手"] = [("うんてんしゅ", nil)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        let run = try #require(overrides.spanning.first)
        #expect(run.segment.text == "運転手")
        #expect(run.segment.reading == "うんてんしゅ")
    }

    // MARK: - A2: ours equals a listed reading -> leave (heteronym protection)

    @Test("ours equals a listed reading: unchanged (heteronym protection)")
    func oursListedLeftAlone() {
        var dict = FakeDict()
        dict.byForm["運転手"] = [("うんてんしゅ", nil)]
        // Same form, but this time we already RENDER the listed reading.
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: ["うんてん", "しゅ"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty)
    }

    // MARK: - A3: several readings, none with a spans row -> leave

    @Test("several readings, none with a spans row: unchanged")
    func severalNoSpansLeftAlone() {
        var dict = FakeDict()
        dict.byForm["研究所"] = [("けんきゅうじょ", nil), ("けんきゅうしょ", nil)]
        let tokens = [token("研究", 0, 2), token("所", 2, 3)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["けんきゅう", "ところ"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty)
    }

    // MARK: - A4: several readings, exactly one spans row -> replace, per kanji

    @Test("several readings, exactly one spans row: replaced per kanji from that row")
    func severalOneSpansReplaced() {
        var dict = FakeDict()
        dict.byForm["博物館"] = [
            ("はくぶつかん", [ReadingSpan(range: 0..<1, kana: "はく"),
                          ReadingSpan(range: 1..<2, kana: "ぶつ"),
                          ReadingSpan(range: 2..<3, kana: "かん")]),
            ("はくぶつくわん", nil)   // a second reading with NO spans row
        ]
        let tokens = [token("博物", 0, 2), token("館", 2, 3)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["はくぶつ", "たて"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        let segments = flatSegments(overrides)
        #expect(segments.map { ($0.text, $0.reading) }.elementsEqual(
            [("博", "はく"), ("物", "ぶつ"), ("館", "かん")], by: ==))
        #expect(segments.map(\.text).joined() == "博物館")
    }

    // MARK: - A5: several readings, >= 2 spans rows -> the nearest one, or leave on a tie

    /// This case USED to be declined outright, and the nearest-reading rule deliberately
    /// changed that: it is the whole point of the rule. The old assertion's intent, that an
    /// arbitrary guess is never made, has not been dropped - it is now carried by
    /// `nearestTieLeftAlone` and `nearestNoPrefixLeftAlone`, which decline when nothing
    /// distinguishes the candidates. Here something does: we render じてん, and じてんしゃ
    /// agrees with four kana of it against じでんしゃ's one. じてんしゃ is also simply the
    /// right reading of 自転車, so declining was losing a reading it could have had.
    @Test("several readings, two spans rows: the nearest to what we render wins")
    func severalTwoSpansNearestWins() {
        var dict = FakeDict()
        dict.byForm["自転車"] = [
            ("じてんしゃ", [ReadingSpan(range: 0..<1, kana: "じ"), ReadingSpan(range: 1..<2, kana: "てん"),
                        ReadingSpan(range: 2..<3, kana: "しゃ")]),
            ("じでんしゃ", [ReadingSpan(range: 0..<1, kana: "じ"), ReadingSpan(range: 1..<2, kana: "でん"),
                        ReadingSpan(range: 2..<3, kana: "しゃ")])
        ]
        let tokens = [token("自転", 0, 2), token("車", 2, 3)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["じてん", "くるま"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "じてんしゃ")
    }

    // MARK: - A6: unknown joined form -> leave

    @Test("unknown joined form: unchanged")
    func unknownLeftAlone() {
        let dict = FakeDict()   // knows nothing
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty)
    }

    // MARK: - A7: run overlapping author ruby -> leave

    @Test("run overlapping a RubyRun: unchanged, regardless of readings/spans")
    func authorRubyLeftAlone() {
        var dict = FakeDict()
        dict.byForm["運転手"] = [("うんてんしゅ", nil)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered,
            sourceRuby: [RubyRun(lower: 0, upper: 2, reading: "かな")],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.isEmpty)
    }

    // MARK: - A8: run selection is closed

    @Test("a kana token, an offset gap, or a length-1 run is never joined")
    func selectionClosed() {
        var dict = FakeDict()
        dict.byForm["運転手"] = [("うんてんしゅ", nil)]
        dict.byForm["運手"] = [("うんて", nil)]   // a bogus two-token joined form, to prove gaps break

        // A kana token between the kanji tokens breaks the run.
        let kanaBreak = [token("運転", 0, 2), token("の", 2, 3), token("手", 3, 4)]
        #expect(KaraokeWord.compoundJoinOverrides(
            tokens: kanaBreak, renderedReadings: ["うんてん", "の", "て"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans).isEmpty)

        // An offset gap (non-contiguous) breaks the run even with both kanji.
        let gap = [token("運転", 0, 2), token("手", 3, 4)]
        #expect(KaraokeWord.compoundJoinOverrides(
            tokens: gap, renderedReadings: untenshuRendered,
            sourceRuby: [], readings: dict.readings, spans: dict.spans).isEmpty)

        // A single all-kanji token is not a join (no run of two).
        let single = [token("運転手", 0, 3)]
        #expect(KaraokeWord.compoundJoinOverrides(
            tokens: single, renderedReadings: ["うんてんて"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans).isEmpty)
    }

    // MARK: - A9: no re-analysis drives the result

    @Test("output uses the injected reading, never a re-analysis of the merged surface")
    func noReanalysis() {
        var dict = FakeDict()
        // The injected dictionary lists the ONE correct reading. A re-analysis closure (which
        // this function never calls) would return the wrong いちほん; it cannot influence us.
        dict.byForm["一本"] = [("いっぽん", [ReadingSpan(range: 0..<1, kana: "いっ"),
                                       ReadingSpan(range: 1..<2, kana: "ぽん")])]
        let reanalysis: (String) -> [String] = { _ in ["いちほん"] }   // deliberately wrong, unused
        _ = reanalysis
        let tokens = [token("一", 0, 1), token("本", 1, 2)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["いち", "ほん"],
            sourceRuby: [], readings: dict.readings, spans: dict.spans)
        let reading = flatSegments(overrides).compactMap(\.reading).joined()
        #expect(reading == "いっぽん")
    }

    // MARK: - Longest-first, non-overlapping over a stretch inside a longer run

    @Test("博物館 is joined even inside 歴史博物館 when the longer form is unknown")
    func longestFirstInsideStretch() {
        var dict = FakeDict()
        // 歴史博物館 is unknown to the JMdict headword lookup; 博物館 is known with spans.
        dict.byForm["博物館"] = [("はくぶつかん", [ReadingSpan(range: 0..<1, kana: "はく"),
                                           ReadingSpan(range: 1..<2, kana: "ぶつ"),
                                           ReadingSpan(range: 2..<3, kana: "かん")])]
        let tokens = [token("歴史", 0, 2), token("博物", 2, 4), token("館", 4, 5)]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: tokens, renderedReadings: ["れきし", "はくぶつ", "たて"], sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        // 歴史 (token 0) is untouched; 博物 and 館 (tokens 1, 2) carry the corrected reading.
        #expect(overrides.overrides[0] == nil)
        #expect(flatSegments(overrides).compactMap(\.reading).joined() == "はくぶつかん")
    }

    // MARK: - Named gate arms (contract assertions 7 & 8)
    //
    // These two carry NO `@Test("display name")` string on purpose: Swift Testing then prints
    // the function identifier itself, so the gate can prove from the log that the arm actually
    // RAN (a zero-selection `--filter` cannot fake an identifier that never printed).

    /// POSITIVE: an injected dictionary that SETTLES 運転手 to the single reading うんてんしゅ
    /// with per-kanji spans makes the join replace what we render (うんてんて) — per-token
    /// `.overrides` are produced and the joined rendered reading becomes the settled one.
    @Test func compoundJoinSettlesUntenshu() {
        var dict = FakeDict()
        dict.byForm["運転手"] = [("うんてんしゅ", [ReadingSpan(range: 0..<1, kana: "うん"),
                                            ReadingSpan(range: 1..<2, kana: "てん"),
                                            ReadingSpan(range: 2..<3, kana: "しゅ")])]
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(!overrides.overrides.isEmpty)
        #expect(flatSegments(overrides).compactMap(\.reading).joined() == "うんてんしゅ")
    }

    /// CONTRASTING NEGATIVE: a run whose joined form the injected dictionary does NOT settle
    /// (it knows nothing) is left UNCHANGED — both `.overrides` and `.spanning` empty. A
    /// degenerate always-join implementation passes the positive arm above but fails this one.
    @Test func compoundJoinLeavesUnsettledUnchanged() {
        let dict = FakeDict()   // knows nothing: the joined form is unsettled
        let overrides = KaraokeWord.compoundJoinOverrides(
            tokens: untenshuTokens, renderedReadings: untenshuRendered, sourceRuby: [],
            readings: dict.readings, spans: dict.spans)
        #expect(overrides.overrides.isEmpty)
        #expect(overrides.spanning.isEmpty)
    }

}
