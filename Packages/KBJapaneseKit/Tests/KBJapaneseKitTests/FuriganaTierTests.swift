import KBCore
import KBReadingKit
import KBDictionaryKit
import KBJapaneseKit
import Foundation
import Testing

/// A controlled, counting `ReadingDictionary` fake: every fixture property is defined
/// here — nothing is assumed about the real JMdict (P3 contract assertions 7/8/11).
private final class SpyDictionary: ReadingDictionary, @unchecked Sendable {
    private let lock = NSLock()
    private var queryCount = 0
    let readingsByForm: [String: [String]]
    let spansByPair: [String: [FuriganaSpan]]

    init(readings: [String: [String]] = [:], spans: [String: [FuriganaSpan]] = [:]) {
        self.readingsByForm = readings
        self.spansByPair = spans
    }

    var queries: Int { lock.withLock { queryCount } }

    func readings(forForm form: String) -> [String] {
        lock.withLock { queryCount += 1 }
        return readingsByForm[form] ?? []
    }

    func furiganaSegments(form: String, reading: String) -> [FuriganaSpan] {
        lock.withLock { queryCount += 1 }
        return spansByPair["\(form)|\(reading)"] ?? []
    }
}

private let haipairSpans = [FuriganaSpan(range: 0..<1, kana: "は"),
                            FuriganaSpan(range: 1..<2, kana: "い"),
                            FuriganaSpan(range: 2..<3, kana: nil)]

private func provider(
    _ fake: SpyDictionary?,
    reading: @escaping @Sendable (String) -> String?
) -> (@Sendable (String) -> ReadingPayload?)? {
    FuriganaTier.payloadProvider(dictionary: fake, reading: reading, baseForm: { _ in nil })
}

@Suite("JMdict furigana tier adapter")
struct FuriganaTierAdapterTests {

    @Test("impossible → repair reading + spans carried into the payload")
    func impossibleRepairs() throws {
        let fake = SpyDictionary(readings: ["這入る": ["はいる"]], spans: ["這入る|はいる": haipairSpans])
        let payload = try #require(provider(fake, reading: { _ in "こんにゅうる" })?("這入る"))
        #expect(payload.reading == "はいる")
        #expect(payload.spans == haipairSpans.map { ReadingSpan(range: $0.range, kana: $0.kana) })
    }

    @Test("consistent → OpenJTalk reading kept, no repair")
    func consistentKeepsOJT() throws {
        let fake = SpyDictionary(readings: ["本": ["ほん"]])
        let payload = try #require(provider(fake, reading: { _ in "ほん" })?("本"))
        #expect(payload.reading == "ほん")
        #expect(payload.spans == nil)
    }

    @Test("absent form → unknown, OpenJTalk output untouched")
    func unknownUntouched() throws {
        let fake = SpyDictionary()
        let payload = try #require(provider(fake, reading: { _ in "なぞよみ" })?("謎語"))
        #expect(payload.reading == "なぞよみ")
        #expect(payload.spans == nil)
    }

    @Test("reading with NO segmentation row → repair reading with nil spans (無暗 shape)")
    func repairWithoutSpans() throws {
        let fake = SpyDictionary(readings: ["無暗": ["むやみ"]])
        let payload = try #require(provider(fake, reading: { _ in "ぶあん" })?("無暗"))
        #expect(payload.reading == "むやみ")
        #expect(payload.spans == nil)
    }

    @Test("merged-surface join: positive resolves with spans, negative without")
    func mergedSurfaceJoin() throws {
        let spans = [FuriganaSpan(range: 0..<1, kana: "ひと"), FuriganaSpan(range: 1..<2, kana: nil)]
        let fake = SpyDictionary(readings: ["一つ": ["ひとつ"], "一": ["いち"]],
                                 spans: ["一つ|ひとつ": spans])
        guard let tier = provider(fake, reading: { $0 == "一つ" ? "ひとつ" : "いち" }) else {
            Issue.record("payloadProvider returned nil despite a dictionary")
            return
        }
        let positive = try #require(tier("一つ"))
        #expect(positive.spans == spans.map { ReadingSpan(range: $0.range, kana: $0.kana) })
        // Negative: a merged surface the fake doesn't confirm has no spans → no join.
        let negative = try #require(tier("一が"))
        #expect(negative.spans == nil)
    }

    @Test("kana-only and katakana-only tokens cost zero validator/tier queries")
    func kanaCostsNothing() throws {
        let fake = SpyDictionary(readings: ["本": ["ほん"]])
        guard let tier = provider(fake, reading: { $0 }) else {
            Issue.record("payloadProvider returned nil despite a dictionary")
            return
        }
        #expect(tier("する") == nil)
        #expect(tier("コーヒー") == nil)
        #expect(fake.queries == 0)
        // The gloss path is separate and out of tier scope; a kanji token does query.
        _ = tier("本")
        #expect(fake.queries > 0)
    }

    @Test("repeated surfaces are cached — one dictionary round per unique surface")
    func repeatedSurfacesAreCached() throws {
        let fake = SpyDictionary(readings: ["本": ["ほん"]])
        guard let tier = provider(fake, reading: { _ in "ほん" }) else {
            Issue.record("payloadProvider returned nil despite a dictionary")
            return
        }
        let first = tier("本")
        let afterFirst = fake.queries
        #expect(afterFirst > 0)
        #expect(tier("本") == first)
        #expect(tier("本") == first)
        #expect(fake.queries == afterFirst)
    }

    // These two build a real `ReaderContent` to prove the furigana tier survives the renderer's
    // tokenizer, which is a cross-seam assertion neither package can make alone. KBReadingKit
    // is SwiftUI-free, so they run everywhere this test target does, including where the
    // package cross-compiles.
    @Test("nil dictionary → no provider, no queries, equivalent ReaderContent; Document untouched")
    func nilDictionaryInvariants() throws {
        #expect(provider(nil, reading: { $0 }) == nil)
        let docID = DocumentID("doc")
        let text = "一つの本。"
        let segments = [TextSegment(id: SegmentID(documentID: docID, sentenceIndex: 0),
                                    documentID: docID, sentenceIndex: 0, text: text,
                                    sourceRange: DocRange(lower: 0, upper: text.utf16.count))]
        let doc = Document(id: docID, title: "T", textHash: "hash-1", segments: segments, chapters: [])
        let spy = SpyDictionary()
        // Tier off (nil provider) vs never-wired: field-level equivalence.
        let without = ReaderContent.build(from: doc, reading: { _ in nil })
        let withNil = ReaderContent.build(from: doc, reading: { _ in nil },
                                          readingPayload: provider(spy.readingsByForm.isEmpty ? nil : spy,
                                                                   reading: { _ in nil }))
        #expect(spy.queries == 0)
        let lhs = without.paragraphs.flatMap(\.words)
        let rhs = withNil.paragraphs.flatMap(\.words)
        #expect(lhs.map(\.text) == rhs.map(\.text))
        #expect(lhs.map(\.utf16Lower) == rhs.map(\.utf16Lower))
        #expect(lhs.map(\.utf16Upper) == rhs.map(\.utf16Upper))
        #expect(lhs.map(\.ruby) == rhs.map(\.ruby))
        // The Document itself is untouched by builds in every configuration.
        #expect(doc.id == docID && doc.textHash == "hash-1")
        #expect(doc.segments.map(\.text) == segments.map(\.text))
        #expect(doc.segments.map(\.displayText) == segments.map(\.displayText))
    }

    @Test("tier on: 一+つ join lands ひと over 一 in built ReaderContent, boundaries unmerged")
    func joinEndToEndThroughBuild() throws {
        let spans = [FuriganaSpan(range: 0..<1, kana: "ひと"), FuriganaSpan(range: 1..<2, kana: nil)]
        let fake = SpyDictionary(readings: ["一つ": ["ひとつ"], "一": ["いち"]],
                                 spans: ["一つ|ひとつ": spans, "一|いち": [FuriganaSpan(range: 0..<1, kana: "いち")]])
        let docID = DocumentID("doc")
        let text = "一つ"
        let segments = [TextSegment(id: SegmentID(documentID: docID, sentenceIndex: 0),
                                    documentID: docID, sentenceIndex: 0, text: text,
                                    sourceRange: DocRange(lower: 0, upper: text.utf16.count))]
        let doc = Document(id: docID, title: "T", textHash: "h", segments: segments, chapters: [])
        let tier = provider(fake, reading: { $0 == "一つ" ? "ひとつ" : "いち" })
        let content = ReaderContent.build(from: doc, reading: { _ in nil }, readingPayload: tier)
        let words = content.paragraphs.flatMap(\.words)
        let readings = words.flatMap(\.ruby).filter { $0.reading != nil }
        let bases: [String] = readings.map { $0.text }
        let kana: [String] = readings.compactMap { $0.reading }
        #expect(bases == ["一"])
        #expect(kana == ["ひと"])
        #expect(words.map { $0.text }.joined() == "一つ")
        #expect(words.last?.utf16Upper == text.utf16.count)
    }

    @Test("real OpenJTalk integration: 這入る end-to-end (skips when dictionary absent)")
    func realOpenJTalkWhenPresent() throws {
        let store = JMDictStore()
        guard store.isReady, !store.furiganaSegments(form: "這入る", reading: "はいる").isEmpty else {
            return // no furigana-capable dictionary bundled in this checkout
        }
        // liveProvider is the same wiring buildReaderContent uses; nil means the
        // configured OpenJTalk dictionary is absent — skip cleanly, not fail.
        guard let tier = FuriganaTier.liveProvider(dictionary: store) else { return }
        let payload = try #require(tier("這入る"))
        #expect(payload.reading == "はいる")
        #expect(payload.spans?.first?.kana == "は")
    }
}
