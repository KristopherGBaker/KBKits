import KBCore
import Foundation
import Testing
import KBReadingKit

/// A reader's chosen reading must change the RUBY on the page too, matching the spoken side.
///
/// Every assertion here is exercised THROUGH `ReaderContent.build` — the one path the app uses
/// to reach `KaraokeWord.tokenize` — and reads the resulting words back through the PUBLIC
/// surface (`content.paragraphs.flatMap(\.words)`), so the module is imported normally, NOT
/// `@testable`. A helper-level test would pass while the reader saw nothing; that exact gap was
/// found in the provenance work.
///
/// Offsets are DISCOVERED from an uncorrected build rather than hardcoded, so a correction is
/// keyed to the real UTF-16 span the tokenizer produced (as it is in the app, where the span
/// comes from where the reader tapped).
@Suite("Reading correction changes the displayed ruby")
struct ReadingCorrectionDisplayTests {

    // MARK: - Fixtures

    /// A document of one segment per supplied sentence text, each its own paragraph so
    /// `content.paragraphs` carries every segment's words on the public path.
    private func document(_ texts: [String]) -> Document {
        let docID = DocumentID("d")
        var segments: [TextSegment] = []
        var paragraphs: [Paragraph] = []
        for (index, text) in texts.enumerated() {
            segments.append(TextSegment(id: SegmentID(documentID: docID, sentenceIndex: index),
                                        documentID: docID, sentenceIndex: index, text: text,
                                        sourceRange: DocRange(lower: 0, upper: text.utf16.count)))
            paragraphs.append(Paragraph(id: ParagraphID(documentID: docID, index: index),
                                        segmentRange: index..<(index + 1)))
        }
        return Document(id: docID, title: "T", textHash: "h", segments: segments,
                        chapters: [Chapter(id: ChapterID(documentID: docID, index: 0), title: "T",
                                           paragraphs: paragraphs)])
    }

    /// The per-surface reading provider (as an app would inject). The tokenizer keeps 十分 and
    /// 広く whole when a particle follows, so these surfaces are the ones consulted.
    private let reading: @Sendable (String) -> String? = { surface in
        switch surface {
        case "十分": return "じゅうぶん"
        case "広く": return "ひろく"
        case "広": return "ひろ"
        default: return nil
        }
    }

    /// Reconstruct a word's rendered reading from its ruby: each run contributes its reading, or
    /// its own text when it is a plain (okurigana/punctuation) run.
    private func rendered(_ word: KaraokeWord) -> String {
        word.ruby.map { $0.reading ?? $0.text }.joined()
    }

    private func words(_ content: ReaderContent) -> [KaraokeWord] {
        content.paragraphs.flatMap(\.words)
    }

    private func word(_ content: ReaderContent, surface: String, segment: Int? = nil) throws -> KaraokeWord {
        try #require(words(content).first {
            $0.text == surface && (segment == nil || $0.segmentIndex == segment)
        }, "expected a \(surface) word (segment \(segment ?? -1))")
    }

    /// Every occurrence of `surface`, left-to-right, within `segment`.
    private func occurrences(_ content: ReaderContent, surface: String, segment: Int) -> [KaraokeWord] {
        words(content)
            .filter { $0.text == surface && $0.segmentIndex == segment }
            .sorted { $0.utf16Lower < $1.utf16Lower }
    }

    // MARK: - 2. Value type is app-free, Equatable, and accepted by build

    @Test("RubyCorrection is a Sendable, Equatable value threaded into build")
    func valueTypeIsAppFreeEquatable() throws {
        let first = RubyCorrection(utf16Lower: 0, utf16Upper: 2, surface: "十分", reading: "じゅっぷん")
        let sameAsFirst = RubyCorrection(utf16Lower: 0, utf16Upper: 2, surface: "十分", reading: "じゅっぷん")
        let differing = RubyCorrection(utf16Lower: 0, utf16Upper: 2, surface: "十分", reading: "じゅうぶん")
        #expect(first == sameAsFirst)
        #expect(first != differing)
        #expect(first.utf16Lower == 0 && first.utf16Upper == 2
                && first.surface == "十分" && first.reading == "じゅっぷん")
        // An instance flows into build without a compile/type error (the seam works end to end).
        let content = ReaderContent.build(from: document(["十分で十分だ"]), reading: reading,
                                          corrections: [0: [first]])
        #expect(!words(content).isEmpty)
    }

    // MARK: - 3. Renders the chosen reading through build

    @Test("renders chosen reading through build")
    func rendersChosenReadingThroughBuild() throws {
        let doc = document(["十分だ"])
        let base = ReaderContent.build(from: doc, reading: reading)
        let computed = try word(base, surface: "十分")
        #expect(rendered(computed) == "じゅうぶん", "the uncorrected page shows the computed reading")

        let correction = RubyCorrection(utf16Lower: computed.utf16Lower, utf16Upper: computed.utf16Upper,
                                        surface: "十分", reading: "じゅっぷん")
        let content = ReaderContent.build(from: doc, reading: reading, corrections: [0: [correction]])
        let corrected = try word(content, surface: "十分")
        #expect(rendered(corrected) == "じゅっぷん",
                "the reader's choice must reach the ruby via ReaderContent.build")
    }

    // MARK: - 4. Per-occurrence discrimination (surface-keyed cannot pass)

    @Test("per-occurrence discrimination")
    func perOccurrenceDiscrimination() throws {
        let doc = document(["十分で十分だ"])
        let base = ReaderContent.build(from: doc, reading: reading)
        let occ = occurrences(base, surface: "十分", segment: 0)
        try #require(occ.count == 2, "fixture must produce two 十分 occurrences in one sentence")
        #expect(occ[0].utf16Lower != occ[1].utf16Lower, "the two occupy DISTINCT utf16 spans")

        let corrections: [Int: [RubyCorrection]] = [0: [
            RubyCorrection(utf16Lower: occ[0].utf16Lower, utf16Upper: occ[0].utf16Upper,
                           surface: "十分", reading: "じゅっぷん"),
            RubyCorrection(utf16Lower: occ[1].utf16Lower, utf16Upper: occ[1].utf16Upper,
                           surface: "十分", reading: "じゅうぶん")
        ]]
        let content = ReaderContent.build(from: doc, reading: reading, corrections: corrections)
        let got = occurrences(content, surface: "十分", segment: 0)
        try #require(got.count == 2, "still two distinct 十分 tokens after correction")
        #expect(rendered(got[0]) == "じゅっぷん")
        #expect(rendered(got[1]) == "じゅうぶん")
        // The point of per-occurrence: a surface-within-sentence match would give both the SAME
        // reading. This inequality is what the surface-only mutation cannot satisfy.
        #expect(rendered(got[0]) != rendered(got[1]))
    }

    // MARK: - 5. No cross-sentence leak

    @Test("a correction does not leak into another sentence")
    func noCrossSentenceLeak() throws {
        let doc = document(["十分だ", "十分だ"])
        let base = ReaderContent.build(from: doc, reading: reading)
        let w0 = try word(base, surface: "十分", segment: 0)

        let corrections: [Int: [RubyCorrection]] = [0: [
            RubyCorrection(utf16Lower: w0.utf16Lower, utf16Upper: w0.utf16Upper,
                           surface: "十分", reading: "じゅっぷん")
        ]]
        let content = ReaderContent.build(from: doc, reading: reading, corrections: corrections)
        #expect(rendered(try word(content, surface: "十分", segment: 0)) == "じゅっぷん")
        #expect(rendered(try word(content, surface: "十分", segment: 1)) == "じゅうぶん",
                "sentence 1 keeps its computed reading; the correction is scoped to sentence 0")
    }

    // MARK: - 6. Surface guard skips a mismatched recorded surface

    @Test("a mismatched recorded surface is skipped")
    func surfaceGuardSkipsMismatch() throws {
        let doc = document(["十分だ"])
        let base = ReaderContent.build(from: doc, reading: reading)
        let target = try word(base, surface: "十分")
        // Same offsets, but the surface recorded when the choice was made ("五分") no longer
        // matches the token there — the correction must be dropped, not written onto 十分.
        let corrections: [Int: [RubyCorrection]] = [0: [
            RubyCorrection(utf16Lower: target.utf16Lower, utf16Upper: target.utf16Upper,
                           surface: "五分", reading: "ごふん")
        ]]
        let content = ReaderContent.build(from: doc, reading: reading, corrections: corrections)
        let got = try word(content, surface: "十分")
        #expect(rendered(got) == "じゅうぶん", "the chosen reading must NOT be written onto a different word")
    }

    // MARK: - 7. Provenance survives correction (concrete)

    @Test("provenance survives correction with its full candidate list")
    func provenanceSurvivesCorrection() throws {
        let doc = document(["十分だ"])
        // A payload with several candidates makes the tokenizer stamp analysis provenance, which
        // is exactly what the popover offers a reader.
        let payload: @Sendable (String) -> ReadingPayload? = { surface in
            surface == "十分"
                ? ReadingPayload(reading: "じゅうぶん", spans: nil,
                                 candidates: ["じゅうぶん", "じゅっぷん"])
                : nil
        }
        let base = ReaderContent.build(from: doc, reading: { _ in "じゅうぶん" }, readingPayload: payload)
        let uncorrected = try word(base, surface: "十分")
        let baseProv = try #require(uncorrected.ruby.compactMap(\.provenance).first,
                                    "the fixture must carry provenance BEFORE correction")
        #expect(baseProv.candidates == ["じゅうぶん", "じゅっぷん"])

        let correction = RubyCorrection(utf16Lower: uncorrected.utf16Lower,
                                        utf16Upper: uncorrected.utf16Upper,
                                        surface: "十分", reading: "じゅっぷん")
        let content = ReaderContent.build(from: doc, reading: { _ in "じゅうぶん" },
                                          readingPayload: payload, corrections: [0: [correction]])
        let corrected = try word(content, surface: "十分")
        #expect(rendered(corrected) == "じゅっぷん")
        let prov = try #require(corrected.ruby.compactMap(\.provenance).first,
                                "correcting a word must NOT strip its ability to be corrected again")
        #expect(prov.candidates == ["じゅうぶん", "じゅっぷん"], "the exact ordered candidate list survives")
        #expect(prov.hasAlternatives)
        #expect(prov.candidates.contains { $0 != "じゅっぷん" },
                "at least one candidate differs from the newly chosen reading")
    }

    // MARK: - 8. Okurigana correctness (exact)

    @Test("a correction is placed okurigana-correct over the kanji only")
    func okuriganaCorrect() throws {
        let doc = document(["広く"])
        let base = ReaderContent.build(from: doc, reading: reading)
        let target = try word(base, surface: "広く")
        let correction = RubyCorrection(utf16Lower: target.utf16Lower, utf16Upper: target.utf16Upper,
                                        surface: "広く", reading: "ひろく")
        let content = ReaderContent.build(from: doc, reading: reading, corrections: [0: [correction]])
        let corrected = try word(content, surface: "広く")

        let pairs = corrected.ruby.map { RubyPair(text: $0.text, reading: $0.reading) }
        #expect(pairs == [RubyPair(text: "広", reading: "ひろ"), RubyPair(text: "く", reading: nil)],
                "reading sits over 広 only; the trailing く is a plain run, NOT ひろく over the whole surface")
        #expect(rendered(corrected) == "ひろく", "tail neither doubled nor dropped")
    }

    // MARK: - 9. No-op when empty (exact + byte-identical)

    @Test("an empty corrections map renders byte-identically")
    func emptyCorrectionsAreByteIdentical() throws {
        let doc = document(["広く"])
        let withEmpty = ReaderContent.build(from: doc, reading: reading, corrections: [:])
        let withoutArg = ReaderContent.build(from: doc, reading: reading)

        // The corrected-shape word computes ひろく over 広 only even with no correction applied.
        let corrected = try word(withEmpty, surface: "広く")
        let pairs = corrected.ruby.map { RubyPair(text: $0.text, reading: $0.reading) }
        #expect(pairs == [RubyPair(text: "広", reading: "ひろ"), RubyPair(text: "く", reading: nil)])
        #expect(rendered(corrected) == "ひろく")

        // Full KaraokeWord equality (ruby included) against the no-argument build: additive.
        #expect(words(withEmpty) == words(withoutArg),
                "an empty corrections map must leave every word byte-identical to the no-arg build")
    }

    private struct RubyPair: Equatable {
        let text: String
        let reading: String?
    }
}
