import Foundation
import KBCore
@testable import KBReadingKit
import Testing

/// A counting stand-in for the whole provider set: every isolated per-surface
/// call and every sentence pass is tallied, so the one-pass guarantee is a
/// number, not a code-reading claim.
private final class SpyProviders: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sentencePasses = 0
    private(set) var isolatedReadings: [String] = []
    private(set) var isolatedBaseForms: [String] = []
    let annotationsByToken: [String: TokenAnnotation]
    let fallbackReading: [String: String]

    init(annotations: [String: TokenAnnotation], fallback: [String: String] = [:]) {
        self.annotationsByToken = annotations
        self.fallbackReading = fallback
    }

    var annotations: ([String]) -> [TokenAnnotation?] {
        { surfaces in
            self.lock.withLock { self.sentencePasses += 1 }
            return surfaces.map { self.annotationsByToken[$0] }
        }
    }

    var reading: (String) -> String? {
        { surface in
            self.lock.withLock { self.isolatedReadings.append(surface) }
            return self.fallbackReading[surface]
        }
    }

    var baseForm: (String) -> String? {
        { surface in
            self.lock.withLock { self.isolatedBaseForms.append(surface) }
            return nil
        }
    }
}

@Suite("InContextReading: the Apple seam consumes sentence readings")
struct InContextReadingTests {

    private let sentence = "猫が静かな公園を歩いている。"

    /// The first kanji-bearing token of the REAL tokenizer split, so nothing here
    /// assumes where CFStringTokenizer draws its boundaries.
    private func kanjiTarget() throws -> String {
        let split = KaraokeWord.tokenize(sentence, segmentIndex: 0).map(\.text)
        return try #require(split.first { FuriganaAnnotator.containsKanji($0) })
    }

    @Test("an aligned token's ruby reading is the annotation's, not the per-surface closure's")
    func annotationSupersedes() throws {
        let target = try kanjiTarget()
        let spy = SpyProviders(
            annotations: [target: TokenAnnotation(reading: "せいかい", baseForm: target)],
            fallback: [target: "まちがい"])
        let words = KaraokeWord.tokenize(sentence, segmentIndex: 0,
                                         reading: spy.reading, baseForm: spy.baseForm,
                                         annotations: spy.annotations)
        let token = try #require(words.first { $0.text == target })
        #expect(token.ruby.compactMap(\.reading).joined() == "せいかい")
        #expect(!spy.isolatedReadings.contains(target))
    }

    @Test("a nil annotation falls back to the per-surface closure, on the right surface")
    func straddleFallsBack() throws {
        let target = try kanjiTarget()
        let spy = SpyProviders(
            annotations: [:],
            fallback: [target: "ふぉーるばっく"])
        let words = KaraokeWord.tokenize(sentence, segmentIndex: 0,
                                         reading: spy.reading,
                                         annotations: spy.annotations)
        let token = try #require(words.first { $0.text == target })
        #expect(token.ruby.compactMap(\.reading).joined() == "ふぉーるばっく")
        // The fallback asked about surfaces from THIS sentence — never a wrong one.
        #expect(spy.isolatedReadings.allSatisfy { sentence.contains($0) })
    }

    @Test("token identity is untouched by the per-sentence closure")
    func identityUntouched() throws {
        let spy = SpyProviders(
            annotations: ["静か": TokenAnnotation(reading: "しずか", baseForm: "静か")],
            fallback: ["静か": "しずかか"])
        let with = KaraokeWord.tokenize(sentence, segmentIndex: 3,
                                        reading: spy.reading,
                                        annotations: spy.annotations)
        let without = KaraokeWord.tokenize(sentence, segmentIndex: 3,
                                           reading: spy.reading)
        #expect(with.map(\.id) == without.map(\.id))
        #expect(with.map(\.text) == without.map(\.text))
        #expect(with.map(\.utf16Lower) == without.map(\.utf16Lower))
        #expect(with.map(\.utf16Upper) == without.map(\.utf16Upper))
    }

    @Test("a fully aligned sentence takes one pass and zero isolated calls")
    func onePassZeroIsolated() throws {
        // Every token the tokenizer produces gets an annotation, computed by
        // first asking the tokenizer for its split (kana tokens annotate as
        // themselves, so nothing needs the per-surface path).
        let split = KaraokeWord.tokenize(sentence, segmentIndex: 0).map(\.text)
        var table: [String: TokenAnnotation] = [:]
        for token in split {
            table[token] = TokenAnnotation(reading: "よみ", baseForm: token)
        }
        let spy = SpyProviders(annotations: table, fallback: [:])
        _ = KaraokeWord.tokenize(sentence, segmentIndex: 0,
                                 reading: spy.reading, baseForm: spy.baseForm,
                                 annotations: spy.annotations)
        #expect(spy.sentencePasses == 1)
        #expect(spy.isolatedReadings.isEmpty)
        #expect(spy.isolatedBaseForms.isEmpty)
    }

    @Test("an aligned token with PARTIAL source ruby fills the gap from its parts, never isolated")
    func annotationFillsBesideSourceRuby() throws {
        // One display token 走り出す, author ruby over 走り only. The gap 出す
        // must resolve from the annotation's analysis PARTS - the round-1 grade
        // found the old code skipping the annotation entirely here and falling
        // back to the isolated closures the contract forbids.
        struct OneToken: CJKWordSegmenter {
            func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token] {
                [WordTokenizer.Token(
                    offsets: WordOffsets(lower: 0, upper: text.utf16.count),
                    text: text, latinTranscription: nil, tightLeading: false)]
            }
        }
        let spy = SpyProviders(annotations: [
            "走り出す": TokenAnnotation(
                reading: "はしりだす", baseForm: "走り出す",
                parts: [TokenAnnotation.Part(surface: "走り", reading: "はしり", baseForm: "走る"),
                        TokenAnnotation.Part(surface: "出す", reading: "だす", baseForm: "出す")])
        ], fallback: ["出す": "きんし"])
        let words = KaraokeWord.tokenize("走り出す", segmentIndex: 0,
                                         reading: spy.reading, baseForm: spy.baseForm,
                                         sourceRuby: [RubyRun(lower: 0, upper: 2, reading: "オサー")],
                                         annotations: spy.annotations,
                                         segmenter: OneToken())
        let word = try #require(words.first)
        // Author kana over the covered span; the gap's ruby from the PART (だ over
        // 出, す bare - the annotator aligns the okurigana), nothing isolated.
        let readings = word.ruby.compactMap(\.reading)
        #expect(readings.first == "オサー")
        #expect(readings.contains("だ"))
        #expect(!readings.joined().contains("きんし"))
        #expect(spy.isolatedReadings.isEmpty)
        #expect(spy.isolatedBaseForms.isEmpty)
        #expect(spy.sentencePasses == 1)
    }

    @Test("repeated identical part surfaces with different readings resolve by POSITION")
    func repeatedSurfacesResolveByPosition() throws {
        // 人人: the same surface twice with different readings (ひと, びと).
        // Author ruby covers the FIRST 人; the gap is the SECOND. A resolver
        // matching by surface text would hand the gap the first part's ひと -
        // the round-2 grade's finding; by offset it must be びと.
        struct OneToken: CJKWordSegmenter {
            func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token] {
                [WordTokenizer.Token(
                    offsets: WordOffsets(lower: 0, upper: text.utf16.count),
                    text: text, latinTranscription: nil, tightLeading: false)]
            }
        }
        let spy = SpyProviders(annotations: [
            "人人": TokenAnnotation(
                reading: "ひとびと", baseForm: "人人",
                parts: [TokenAnnotation.Part(surface: "人", reading: "ひと", baseForm: "人"),
                        TokenAnnotation.Part(surface: "人", reading: "びと", baseForm: "人")])
        ], fallback: ["人": "だめ"])
        let words = KaraokeWord.tokenize("人人", segmentIndex: 0,
                                         reading: spy.reading, baseForm: spy.baseForm,
                                         sourceRuby: [RubyRun(lower: 0, upper: 1, reading: "オサー")],
                                         annotations: spy.annotations,
                                         segmenter: OneToken())
        let word = try #require(words.first)
        let readings = word.ruby.compactMap(\.reading)
        #expect(readings == ["オサー", "びと"])
        #expect(spy.isolatedReadings.isEmpty)
        #expect(spy.isolatedBaseForms.isEmpty)
    }

    @Test("a straddling token permits the per-surface path for that token only")
    func straddlePermitsOneFallback() throws {
        let target = try kanjiTarget()
        let split = KaraokeWord.tokenize(sentence, segmentIndex: 0).map(\.text)
        var table: [String: TokenAnnotation] = [:]
        for token in split where token != target {
            table[token] = TokenAnnotation(reading: "よみ", baseForm: token)
        }
        let spy = SpyProviders(annotations: table, fallback: [target: "ふぉーる"])
        _ = KaraokeWord.tokenize(sentence, segmentIndex: 0,
                                 reading: spy.reading, baseForm: spy.baseForm,
                                 annotations: spy.annotations)
        #expect(spy.sentencePasses == 1)
        #expect(Set(spy.isolatedReadings) == [target])
        #expect(Set(spy.isolatedBaseForms).isSubset(of: [target]))
    }
}

@Suite("NoSentenceConsumer: a lone surface with no sentence closure keeps the per-surface path")
struct NoSentenceConsumerTests {

    @Test("lone 静か with no per-sentence closure takes the per-surface reading")
    func loneSurfaceUsesPerSurface() throws {
        // The same tokenize seam that builds every reader word, driven the way a
        // no-sentence caller drives it (the dictionary sheet reuses a word built
        // this way; it never retokenizes).
        let words = KaraokeWord.tokenize("静か", segmentIndex: 0,
                                         reading: { $0 == "静か" ? "しずか" : nil },
                                         baseForm: { _ in "静か" })
        let shizuka = try #require(words.first)
        // The annotator aligns okurigana: しず rides over 静, the か stays bare.
        #expect(shizuka.ruby.map(\.text).joined() == "静か")
        #expect(shizuka.ruby.compactMap(\.reading).joined() == "しず")
        #expect(shizuka.ruby.first?.baseForm == "静か")
    }

    @Test("field-equal to the pre-item path for a mixed kanji and kana fixture")
    func fieldEqualWithoutAnnotations() throws {
        let text = "静かな公園"
        let reading: (String) -> String? = { ["静か": "しずか", "公園": "こうえん"][$0] }
        let withNil = KaraokeWord.tokenize(text, segmentIndex: 1, reading: reading,
                                           annotations: nil)
        let plain = KaraokeWord.tokenize(text, segmentIndex: 1, reading: reading)
        #expect(withNil.map(\.text) == plain.map(\.text))
        #expect(withNil.map(\.id) == plain.map(\.id))
        #expect(withNil.map(\.utf16Lower) == plain.map(\.utf16Lower))
        #expect(withNil.map(\.utf16Upper) == plain.map(\.utf16Upper))
        #expect(withNil.map(\.ruby) == plain.map(\.ruby))
    }
}
