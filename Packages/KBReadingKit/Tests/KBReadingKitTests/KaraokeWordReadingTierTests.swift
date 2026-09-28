import KBCore
import Foundation
import Testing
@testable import KBReadingKit

/// The dictionary reading-tier seam (`ReadingPayload`) at the KBReadingKit side —
/// fake payloads only, no dictionary/store involved (P3 contract assertions 3–6).
@Suite("KaraokeWord reading-tier payload (display seam)")
struct KaraokeWordReadingTierTests {

    private func tierRuby(_ surface: String, payload: ReadingPayload?) -> [RubySegment] {
        KaraokeWord.rubySegments(surface: surface, latinTranscription: nil, reading: nil,
                                 payload: { $0 == surface ? payload : nil })
    }

    // MARK: - Dictionary placement spans drive the ruby

    @Test("這入る → はいる placed per kanji [(這,は),(入,い)], る bare")
    func hairuPlacement() {
        let ruby = tierRuby("這入る", payload: ReadingPayload(
            reading: "はいる",
            spans: [ReadingSpan(range: 0..<1, kana: "は"),
                    ReadingSpan(range: 1..<2, kana: "い"),
                    ReadingSpan(range: 2..<3, kana: nil)]))
        #expect(ruby.map { ($0.text, $0.reading) } .elementsEqual(
            [("這", "は"), ("入", "い"), ("る", nil)], by: ==))
        #expect(ruby.map(\.text).joined() == "這入る")
    }

    @Test("行衛 → ゆくえ placed [(行,ゆく),(衛,え)]")
    func yukuePlacement() {
        let ruby = tierRuby("行衛", payload: ReadingPayload(
            reading: "ゆくえ",
            spans: [ReadingSpan(range: 0..<1, kana: "ゆく"),
                    ReadingSpan(range: 1..<2, kana: "え")]))
        #expect(ruby == [RubySegment(text: "行", reading: "ゆく", baseForm: "行衛"),
                         RubySegment(text: "衛", reading: "え", baseForm: "行衛")])
        #expect(ruby.map(\.text).joined() == "行衛")
    }

    // MARK: - No spans → the EXISTING annotator alignment, with the payload reading

    @Test("無暗 → むやみ with NO spans falls back to whole-run annotator placement")
    func muyamiAnnotatorFallback() {
        let ruby = tierRuby("無暗", payload: ReadingPayload(reading: "むやみ", spans: nil))
        // Identical to today's annotator output for (無暗, むやみ): one whole-run span.
        let annotator = FuriganaAnnotator.segments(token: "無暗", reading: "むやみ")
            .map { $0.withBaseForm("無暗") }
        #expect(ruby == annotator)
        #expect(ruby == [RubySegment(text: "無暗", reading: "むやみ", baseForm: "無暗")])
        #expect(ruby.map(\.text).joined() == "無暗")
    }

    @Test("keep-OpenJTalk payload (行った/いった) renders exactly today's ruby")
    func keepOpenJTalkUnchanged() {
        let viaPayload = tierRuby("行った", payload: ReadingPayload(reading: "いった", spans: nil))
        let today = KaraokeWord.rubySegments(surface: "行った", latinTranscription: nil,
                                             reading: { $0 == "行った" ? "いった" : nil })
        #expect(viaPayload == today)
        #expect(viaPayload.map(\.text).joined() == "行った")
    }

    @Test("malformed spans (not tiling the surface) fall back to annotator, tiling holds")
    func malformedSpansFallBack() {
        let ruby = tierRuby("這入る", payload: ReadingPayload(
            reading: "はいる", spans: [ReadingSpan(range: 0..<1, kana: "は")]))
        #expect(ruby == FuriganaAnnotator.segments(token: "這入る", reading: "はいる")
            .map { $0.withBaseForm("這入る") })
        #expect(ruby.map(\.text).joined() == "這入る")
    }

    // MARK: - Guarded okurigana join (assertion 3)

    /// 一+つ as `WordTokenizer` splits them: the merged form 一つ/ひとつ is dictionary-
    /// confirmed with span `0:ひと` → ひと over 一, つ bare; offsets untouched.
    @Test("join positive: 一+つ → ひと over 一, つ bare, tokens unmerged")
    func joinPositive() {
        let hitotsu = ReadingPayload(reading: "ひとつ",
                                     spans: [ReadingSpan(range: 0..<1, kana: "ひと"),
                                             ReadingSpan(range: 1..<2, kana: nil)])
        // 一 alone is a valid word (いち) — the fake mirrors that trap; the join must win.
        let ichi = ReadingPayload(reading: "いち", spans: [ReadingSpan(range: 0..<1, kana: "いち")])
        let payload: (String) -> ReadingPayload? = {
            switch $0 {
            case "一つ": return hitotsu
            case "一": return ichi
            default: return nil
            }
        }
        let words = KaraokeWord.tokenize("一つ", segmentIndex: 0, payload: payload)
        let readings = words.flatMap(\.ruby).filter { $0.reading != nil }
        #expect(readings.map { ($0.text, $0.reading!) } .elementsEqual([("一", "ひと")], by: ==))
        for word in words { #expect(word.ruby.isEmpty || word.ruby.map(\.text).joined() == word.text) }
        // Token objects / UTF-16 spans stay unmerged and contiguous.
        #expect(words.map(\.text).joined() == "一つ")
        #expect(words.map(\.utf16Upper).last == "一つ".utf16.count)
    }

    @Test("俄+か join at the unit seam: にわ over 俄 only, か consumed bare")
    func joinNiwaka() {
        let tokens = [WordTokenizer.Token(offsets: WordOffsets(lower: 0, upper: 1), text: "俄",
                                          latinTranscription: nil, tightLeading: false),
                      WordTokenizer.Token(offsets: WordOffsets(lower: 1, upper: 2), text: "か",
                                          latinTranscription: nil, tightLeading: false)]
        let niwaka = ReadingPayload(
            reading: "にわか",
            spans: [ReadingSpan(range: 0..<1, kana: "にわ"), ReadingSpan(range: 1..<2, kana: nil)])
        let overrides = KaraokeWord.joinedRubyOverrides(
            tokens: tokens,
            payload: { $0 == "俄か" ? niwaka : nil },
            baseForm: nil, sourceRuby: [])
        #expect(overrides == [0: [RubySegment(text: "俄", reading: "にわ", baseForm: "俄か")]])
    }

    @Test("join negative: merged pair without spans leaves every token as without the join")
    func joinNegative() {
        // The merged surface resolves to a reading but has NO dictionary spans → not
        // confirmed for a join; the kanji token renders from its own payload.
        let payload: (String) -> ReadingPayload? = {
            switch $0 {
            case "一つ": return ReadingPayload(reading: "ひとつ", spans: nil)
            case "一": return ReadingPayload(reading: "いち", spans: [ReadingSpan(range: 0..<1, kana: "いち")])
            default: return nil
            }
        }
        let joined = KaraokeWord.tokenize("一つ", segmentIndex: 0, payload: payload)
        // Whatever the tokenizer did, the join contributed nothing: identical output to a
        // payload that never resolves the merged surface.
        let unjoined = KaraokeWord.tokenize("一つ", segmentIndex: 0,
                                            payload: { $0 == "一つ" ? nil : payload($0) })
        // Both tokenizations agree only when the tokenizer split 一+つ; when it kept 一つ
        // whole the single-token payload path legitimately differs. Guard on the split.
        if joined.count > 1 {
            #expect(joined == unjoined)
        }
        for word in joined { #expect(word.ruby.isEmpty || word.ruby.map(\.text).joined() == word.text) }
    }

    @Test("join lookahead spans two kana tokens (俄+か+に)")
    func joinLookaheadTwo() {
        let tokens = ["俄", "か", "に"].enumerated().map { index, text in
            WordTokenizer.Token(offsets: WordOffsets(lower: index, upper: index + 1), text: text,
                                latinTranscription: nil, tightLeading: false)
        }
        let niwakani = ReadingPayload(
            reading: "にわかに",
            spans: [ReadingSpan(range: 0..<1, kana: "にわ"), ReadingSpan(range: 1..<2, kana: nil),
                    ReadingSpan(range: 2..<3, kana: nil)])
        let overrides = KaraokeWord.joinedRubyOverrides(
            tokens: tokens,
            payload: { $0 == "俄かに" ? niwakani : nil },
            baseForm: nil, sourceRuby: [])
        #expect(overrides == [0: [RubySegment(text: "俄", reading: "にわ", baseForm: "俄かに")]])
    }

    @Test("join rejects kana placed over the okurigana tokens or straddling spans")
    func joinRejectsBadSpans() {
        let tokens = [WordTokenizer.Token(offsets: WordOffsets(lower: 0, upper: 1), text: "大",
                                          latinTranscription: nil, tightLeading: false),
                      WordTokenizer.Token(offsets: WordOffsets(lower: 1, upper: 2), text: "な",
                                          latinTranscription: nil, tightLeading: false)]
        // A jukujikun-style span covering both tokens straddles the boundary → reject.
        let straddling = ReadingPayload(
            reading: "おとな",
            spans: [ReadingSpan(range: 0..<2, kana: "おとな")])
        let overrides = KaraokeWord.joinedRubyOverrides(
            tokens: tokens,
            payload: { $0 == "大な" ? straddling : nil },
            baseForm: nil, sourceRuby: [])
        #expect(overrides.isEmpty)
    }

    @Test("a source-ruby-covered group never joins (author ruby stays on top)")
    func joinSkipsSourceRuby() {
        let tokens = [WordTokenizer.Token(offsets: WordOffsets(lower: 0, upper: 1), text: "一",
                                          latinTranscription: nil, tightLeading: false),
                      WordTokenizer.Token(offsets: WordOffsets(lower: 1, upper: 2), text: "つ",
                                          latinTranscription: nil, tightLeading: false)]
        let overrides = KaraokeWord.joinedRubyOverrides(
            tokens: tokens,
            payload: { _ in ReadingPayload(reading: "ひとつ",
                                           spans: [ReadingSpan(range: 0..<1, kana: "ひと"),
                                                   ReadingSpan(range: 1..<2, kana: nil)]) },
            baseForm: nil,
            sourceRuby: [RubyRun(lower: 0, upper: 1, reading: "かず")])
        #expect(overrides.isEmpty)
    }

    // MARK: - Tiling invariant across all tier paths (assertion 5)

    @Test("tiling: dictionary-span, join, and fallback paths all re-concatenate exactly")
    func tilingInvariantAcrossPaths() {
        let hairu = ReadingPayload(
            reading: "はいる",
            spans: [ReadingSpan(range: 0..<1, kana: "は"), ReadingSpan(range: 1..<2, kana: "い"),
                    ReadingSpan(range: 2..<3, kana: nil)])
        let cases: [(String, ReadingPayload)] = [
            ("這入る", hairu),
            ("無暗", ReadingPayload(reading: "むやみ", spans: nil)),
            ("行った", ReadingPayload(reading: "いった", spans: nil))
        ]
        for (surface, payload) in cases {
            let ruby = tierRuby(surface, payload: payload)
            #expect(ruby.map(\.text).joined() == surface, "tier path for \(surface)")
        }
    }
}
