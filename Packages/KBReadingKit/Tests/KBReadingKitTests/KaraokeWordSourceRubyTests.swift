import Testing
import Foundation
import KBCore
@testable import KBReadingKit

@Suite("KaraokeWord source-ruby precedence (display seam)")
struct KaraokeWordSourceRubyTests {

    private func onlyWord(
        _ text: String,
        sourceRuby: [RubyRun],
        reading: @escaping (String) -> String?
    ) throws -> KaraokeWord {
        let words = KaraokeWord.tokenize(text, segmentIndex: 0, reading: reading, sourceRuby: sourceRuby)
        return try #require(words.first { KaraokeWord.containsCJK($0.text) })
    }

    // MARK: - Precedence over OpenJTalk (assertion 5)

    @Test("source ruby beats the OpenJTalk reading over the covered kanji")
    func sourceBeatsOpenJTalk() throws {
        let word = try onlyWord("私は",
                                sourceRuby: [RubyRun(lower: 0, upper: 1, reading: "わたくし")],
                                reading: { _ in "わたし" })
        #expect(word.ruby.contains(RubySegment(text: "私", reading: "わたくし")))
        #expect(word.ruby.map(\.text).joined() == word.text)
    }

    @Test("a full kana-inclusive base reads the source verbatim with no OpenJTalk override inside")
    func fullCoverageNoOverride() throws {
        // reading closure would disagree if consulted inside the covered range.
        let word = try onlyWord("走り出す",
                                sourceRuby: [RubyRun(lower: 0, upper: 4, reading: "はしりだす")],
                                reading: { _ in "ちがう" })
        #expect(word.ruby == [RubySegment(text: "走り出す", reading: "はしりだす")])
        #expect(word.ruby.map(\.text).joined() == word.text)
    }

    // MARK: - Regression guard: no source ruby (assertion 5)

    @Test("with NO source ruby, the OpenJTalk reading is used unchanged")
    func noSourceRegression() throws {
        let words = KaraokeWord.tokenize("私は", segmentIndex: 0, reading: { _ in "わたし" })
        let word = try #require(words.first { KaraokeWord.containsCJK($0.text) })
        // The OpenJTalk path stamps a baseForm, so match on text + reading only.
        #expect(word.ruby.contains { $0.text == "私" && $0.reading == "わたし" })
        #expect(word.ruby.map(\.text).joined() == word.text)
    }

    // MARK: - Partial coverage + deterministic fallback (assertion 5)

    @Test("partial source coverage keeps the covered 走 and segments the り出す remainder via fallback")
    func partialCoverageFallback() throws {
        // Drive the PUBLIC `tokenize` on a real surface `走り出す` where the source ruby covers
        // ONLY 走 (0,1). `WordTokenizer` splits the surface into words; the covered span reads
        // 走→はし from the source, and the uncovered り出す remainder falls through to the
        // deterministic OpenJTalk `reading` closure. We assert the CONCATENATION of every word's
        // ruby against a HARDCODED literal list (pinned by running the test), and that each word
        // tiles.
        let reading: (String) -> String? = { surface in
            switch surface {
            case "出す": return "だす"
            default: return nil
            }
        }
        let source = [RubyRun(lower: 0, upper: 1, reading: "はし")]
        let words = KaraokeWord.tokenize("走り出す", segmentIndex: 0, reading: reading, sourceRuby: source)
        // Hardcoded literal — pinned by running `tokenize` (NOT recomputed from `rubySegments`):
        // 走→はし comes from the source (no lemma stamp); the り出す remainder is segmented by the
        // OpenJTalk fallback under the `reading` closure (り plain, 出→だ, す plain), each fallback
        // run lemma-stamped with its token surface 出す.
        let expected: [RubySegment] = [
            RubySegment(text: "走", reading: "はし"),
            RubySegment(text: "り"),
            RubySegment(text: "出", reading: "だ", baseForm: "出す"),
            RubySegment(text: "す", baseForm: "出す")
        ]
        #expect(words.flatMap(\.ruby) == expected)
        // Each word tiles: word.ruby.map(text).joined() == word.text.
        for word in words where KaraokeWord.containsCJK(word.text) {
            #expect(word.ruby.map(\.text).joined() == word.text)
        }
    }

    // MARK: - Tiling invariant across every CJK token (assertion 5)

    @Test("every CJK token tiles: word.ruby.map(text).joined() == word.text")
    func tilingInvariant() {
        let words = KaraokeWord.tokenize("地球《ほし》".replacingOccurrences(of: "《ほし》", with: ""),
                                         segmentIndex: 0,
                                         reading: { _ in "ちきゅう" },
                                         sourceRuby: [RubyRun(lower: 0, upper: 2, reading: "ほし")])
        for word in words where KaraokeWord.containsCJK(word.text) {
            #expect(word.ruby.map(\.text).joined() == word.text)
        }
    }
}
