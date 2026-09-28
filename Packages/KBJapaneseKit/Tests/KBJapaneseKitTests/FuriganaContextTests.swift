import Foundation
import KBCore
import KBDictionaryKit
import KBJapaneseKit
import Testing

/// A word fixture for the pure aligner: no frontend, just tiles of surface+reading.
private func word(_ surface: String, _ reading: String, base: String? = nil) -> JapaneseReader.Word {
    JapaneseReader.Word(surface: surface, baseForm: base ?? surface, reading: reading)
}

@Suite("FuriganaContext: the pure aligner")
struct FuriganaContextAlignerTests {

    @Test("a display token equal to one analysis word carries that word's reading")
    func oneToOne() throws {
        let words = [word("猫", "ねこ"), word("が", "が"), word("静か", "しずか", base: "静か")]
        let annotations = FuriganaAlignment.align(surfaces: ["猫", "が", "静か"], words: words)
        #expect(annotations.count == 3)
        #expect(annotations[0]?.reading == "ねこ")
        #expect(annotations[2]?.reading == "しずか")
        #expect(annotations[2]?.baseForm == "静か")
    }

    @Test("a display token spanning two analysis words concatenates their readings in order")
    func concatenation() throws {
        // Distinct readings, so a degenerate single-reading path cannot fake the result.
        let words = [word("走り", "はしり", base: "走る"), word("出す", "だす", base: "出す")]
        let annotations = FuriganaAlignment.align(surfaces: ["走り出す"], words: words)
        // Two unwraps rather than `first ?? nil`: `annotations.first` is a DOUBLE optional
        // (no element at all, versus an element that aligned to nothing), and flattening it
        // with `?? nil` reads to SwiftLint as a redundant coalesce. Unwrapping each level
        // asserts the same two things and still fails rather than trapping on an empty array.
        let aligned = try #require(annotations.first)
        let merged = try #require(aligned)
        #expect(merged.reading == "はしりだす")
        #expect(merged.baseForm == nil)
        // The per-word breakdown rides along, so a slice of the token (the gap
        // beside author ruby) can resolve from the same analysis.
        #expect(merged.parts.map(\.surface) == ["走り", "出す"])
        #expect(merged.parts.map(\.reading) == ["はしり", "だす"])
    }

    @Test("a token edge falling mid-word yields nil there, and later tokens resynchronize")
    func straddleFallback() throws {
        // Display splits 静か into 静+か: both straddle the single analysis word.
        // 公園, on a clean boundary after them, must still resolve.
        let words = [word("静か", "しずか"), word("な", "な"), word("公園", "こうえん")]
        let annotations = FuriganaAlignment.align(surfaces: ["静", "か", "な", "公園"], words: words)
        #expect(annotations[0] == nil)
        #expect(annotations[1] == nil)
        #expect(annotations[2]?.reading == "な")
        #expect(annotations[3]?.reading == "こうえん")
    }

    /// A tiling FAILURE and a tiling that simply placed nothing must be distinguishable, because
    /// only one of them is safe to re-probe with the tokens merged. The failure is EMPTY; the
    /// other is the right length and all nil.
    ///
    /// This is what lets `KaraokeWord.regroupedForAnnotation` repair 四月 (split 四|月 against
    /// one analysis word) without also merging blind on 27日, where Open JTalk answers 二十七日
    /// and the analysis describes different text. Before the split, both returned all-nil and
    /// the caller had to refuse both.
    @Test("a tiling failure is EMPTY; a tiled sentence that placed nothing is all nil")
    func joinedMismatchGuard() throws {
        // The tilings cover different text: nothing here can be trusted to line up.
        #expect(FuriganaAlignment.align(surfaces: ["犬"], words: [word("猫", "ねこ")]).isEmpty)
        #expect(FuriganaAlignment.align(surfaces: [], words: [word("猫", "ねこ")]).isEmpty)

        // Same text, but every display token straddles the one analysis word. Right length,
        // all nil - a caller may re-probe this.
        let straddled = FuriganaAlignment.align(surfaces: ["四", "月"],
                                                words: [word("四月", "しがつ")])
        #expect(straddled.count == 2)
        #expect(straddled.allSatisfy { $0 == nil })
    }
}

/// A controlled `ReadingDictionary`: every fixture property defined here, nothing
/// assumed about the real JMdict (same shape as the tier adapter tests).
private final class SpyDictionary: ReadingDictionary, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var validated: [String] = []
    let readingsByForm: [String: [String]]
    let spansByPair: [String: [FuriganaSpan]]

    init(readings: [String: [String]] = [:], spans: [String: [FuriganaSpan]] = [:]) {
        self.readingsByForm = readings
        self.spansByPair = spans
    }

    func readings(forForm form: String) -> [String] {
        lock.withLock { validated.append(form) }
        return readingsByForm[form] ?? []
    }

    func furiganaSegments(form: String, reading: String) -> [FuriganaSpan] {
        spansByPair["\(form)|\(reading)"] ?? []
    }
}

@Suite("FuriganaContext: the tier over a known in-context reading")
struct FuriganaContextTierTests {

    private let shizukaSpans = [FuriganaSpan(range: 0..<1, kana: "しず"),
                                FuriganaSpan(range: 1..<2, kana: nil)]

    @Test("the tier validates the given reading, never a re-derived one")
    func validatesGivenReading() throws {
        let fake = SpyDictionary(readings: ["静か": ["しずか"]],
                                 spans: ["静か|しずか": shizukaSpans])
        let tier = try #require(FuriganaTier.annotatedPayloadProvider(dictionary: fake))
        let payload = try #require(tier("静か", TokenAnnotation(reading: "しずか", baseForm: "静か")))
        #expect(payload.reading == "しずか")
    }

    @Test("a consistent pair carries the placement spans: しず over 静, か bare")
    func placesSpans() throws {
        let fake = SpyDictionary(readings: ["静か": ["しずか"]],
                                 spans: ["静か|しずか": shizukaSpans])
        let tier = try #require(FuriganaTier.annotatedPayloadProvider(dictionary: fake))
        let payload = try #require(tier("静か", TokenAnnotation(reading: "しずか")))
        let spans = try #require(payload.spans)
        #expect(spans == [ReadingSpan(range: 0..<1, kana: "しず"),
                          ReadingSpan(range: 1..<2, kana: nil)])
    }

    @Test("an impossible in-context reading still gets the repair, with spans")
    func repairsImpossible() throws {
        let fake = SpyDictionary(readings: ["静か": ["しずか"]],
                                 spans: ["静か|しずか": shizukaSpans])
        let tier = try #require(FuriganaTier.annotatedPayloadProvider(dictionary: fake))
        let payload = try #require(tier("静か", TokenAnnotation(reading: "しずかか")))
        #expect(payload.reading == "しずか")
        #expect(payload.spans != nil)
    }

    @Test("an unknown surface keeps the in-context reading verbatim, no override")
    func unknownKeepsReading() throws {
        let fake = SpyDictionary()
        let tier = try #require(FuriganaTier.annotatedPayloadProvider(dictionary: fake))
        let payload = try #require(tier("駆逐", TokenAnnotation(reading: "くちく")))
        #expect(payload.reading == "くちく")
        #expect(payload.spans == nil)
    }

    @Test("a nil dictionary keeps the annotated tier off entirely")
    func nilDictionary() {
        #expect(FuriganaTier.annotatedPayloadProvider(dictionary: nil) == nil)
    }
}
