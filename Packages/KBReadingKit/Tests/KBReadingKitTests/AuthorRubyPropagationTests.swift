import KBCore
import Foundation
import Testing
import KBReadingKit

/// THE DEFECT: a publisher rubies a name on its FIRST appearance and never again, and we render
/// every later occurrence from our own analysis. 沙名子 reads さなこ on one line and すななご
/// four lines down, on ONE screen. The page contradicts itself.
///
/// Driven THROUGH `ReaderContent.build`, which is the only path the Apple reader takes to
/// `KaraokeWord.tokenize`, and read back through the PUBLIC word list - not `@testable`. A
/// helper-level test would pass while the reader saw nothing; that is exactly how the compound
/// join sat inert in the app for weeks.
@Suite("Author ruby propagates within a document")
struct AuthorRubyPropagationTests {

    // MARK: - Fixtures

    /// A document of one segment per sentence, each its own paragraph, with the author's ruby
    /// attached to whichever segments carry it.
    private func document(_ lines: [(text: String, ruby: [RubyRun])]) -> Document {
        let docID = DocumentID("d")
        var segments: [TextSegment] = []
        var paragraphs: [Paragraph] = []
        for (index, line) in lines.enumerated() {
            segments.append(TextSegment(id: SegmentID(documentID: docID, sentenceIndex: index),
                                        documentID: docID, sentenceIndex: index, text: line.text,
                                        sourceRange: DocRange(lower: 0, upper: line.text.utf16.count),
                                        rubyRuns: line.ruby))
            paragraphs.append(Paragraph(id: ParagraphID(documentID: docID, index: index),
                                        segmentRange: index..<(index + 1)))
        }
        return Document(id: docID, title: "T", textHash: "h", segments: segments,
                        chapters: [Chapter(id: ChapterID(documentID: docID, index: 0), title: "T",
                                           paragraphs: paragraphs)])
    }

    /// Our analysis: the kun concatenation the tokenizer assembles out of the individual kanji,
    /// which is the whole shape of the defect. 沙名子 is not in any dictionary.
    private let ours: @Sendable (String) -> String? = { surface in
        switch surface {
        case "沙名子": return "すななご"
        case "私": return "わたし"
        case "覗": return "のぞ"
        case "沙名": return "すなな"
        case "子": return "ご"
        default: return nil
        }
    }

    /// The dictionary gate. Only 私 and 覗 are readings JMdict can account for; nothing accounts
    /// for すななご over 沙名子.
    private let corroborated: @Sendable (String, String) -> Bool = { surface, reading in
        switch (surface, reading) {
        case ("私", "わたし"), ("覗", "のぞ"): return true
        default: return false
        }
    }

    private func words(_ content: ReaderContent) -> [KaraokeWord] {
        content.paragraphs.flatMap(\.words)
    }

    private func rendered(_ word: KaraokeWord) -> String {
        word.ruby.isEmpty ? word.text : word.ruby.map { $0.reading ?? $0.text }.joined()
    }

    /// Every word of ONE segment. Keyed by segment rather than by position in the flattened
    /// list, because the propagation CHANGES the word count: it collapses a split run into one
    /// word, so "the last word whose text is X" can silently name a different line's word in
    /// the on and off arms. That is how the negative control first passed for the wrong reason.
    private func words(_ content: ReaderContent, segment: Int) -> [KaraokeWord] {
        words(content).filter { $0.segmentIndex == segment }
    }

    /// What one segment renders, word by word, as `surface[reading]` - the same shape the QA
    /// harness dumps. Asserting on the WHOLE line means a split the propagation did or did not
    /// perform is visible in the failure message instead of being averaged away.
    private func line(_ content: ReaderContent, segment: Int) -> String {
        words(content, segment: segment).map { word in
            word.ruby.isEmpty ? word.text : "\(word.text)[\(rendered(word))]"
        }.joined(separator: " ")
    }

    // MARK: - The defect

    /// The two lines from the reported screenshot, in one document. The author rubies 沙名子
    /// once; the second occurrence must not contradict it.
    @Test("a name rubied once reads the same on every later line")
    func aNameRubiedOncePropagates() {
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かって言った。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: corroborated)

        // The author's own line is untouched, and the SECOND line - which the tokenizer splits
        // into 沙|名子 and reads すな+なご - now reads the name the author gave.
        #expect(line(content, segment: 0) == "沙名子[さなこ] は 自席[じせき] に いる 。")
        #expect(line(content, segment: 1) == "沙名子[さなこ] に 向かっ[むかっ] て 言っ[いっ] た 。")
    }

    /// Without the corroboration closure the build is what it was: the contradiction stands.
    /// This is the negative control for the whole feature - if it ever renders さなこ, the test
    /// above is measuring something other than the propagation.
    @Test("with no dictionary gate supplied, nothing propagates")
    func propagationIsOffWithoutTheGate() {
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かって言った。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours)

        #expect(line(content, segment: 1) == "沙[すな] 名子[なご] に 向かっ[むかっ] て 言っ[いっ] た 。",
                "the contradicting page, exactly as it renders today")
    }

    // MARK: - The two gates

    /// THE GATE THAT MATTERS MOST. The unfiltered class is 41,823 corpus positions and is
    /// dominated by ordinary polysemous words whose ruby is context-specific: the author writes
    /// 私《わたくし》 once and わたし is still right everywhere else. 1,129 positions of 私 alone.
    @Test("a surface the author read two ways propagates neither")
    func twoAuthorReadingsPropagateNothing() {
        let document = document([
            ("私は行く。", [RubyRun(lower: 0, upper: 1, reading: "わたくし")]),
            ("私は帰る。", [RubyRun(lower: 0, upper: 1, reading: "わたし")]),
            ("私は待つ。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: corroborated)

        #expect(line(content, segment: 2) == "私[わたし] は 待つ[まつ] 。",
                "our own analysis, untouched - the author's わたくし was context-specific")
        // And the arms agree, so the gate is what held rather than the fixture never matching.
        let ungated = ReaderContent.build(from: document, reading: ours)
        #expect(line(ungated, segment: 2) == line(content, segment: 2))
    }

    /// THE SECOND GATE. Even with one author reading, a reading the ordinary dictionary can
    /// account for is a defensible alternative and not ours to overwrite: 覗 reads のぞ because
    /// JMdict knows 覗く, whatever the author rubied elsewhere.
    @Test("a reading the dictionary accounts for is left alone")
    func corroboratedReadingIsLeftAlone() {
        let document = document([
            ("覗いた。", [RubyRun(lower: 0, upper: 1, reading: "のぞき")]),
            ("覗を見る。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: corroborated)

        // The index HAS 覗 -> のぞき (one author reading) and ours is のぞ, so gate one passes
        // and only the dictionary holds this back.
        #expect(AuthorRubyIndex(document: document).reading(for: "覗") == "のぞき")
        #expect(line(content, segment: 1) == "覗[のぞ] を 見る[みる] 。",
                "corroborated by 覗く, so ours stands")
    }

    // MARK: - Shape

    /// A run the tokenizer SPLIT still takes the author's reading, collapsing into one word that
    /// keeps the run's full offset span - the same shape a spanning compound join produces, and
    /// the reason highlighting, find and scroll anchors still resolve.
    @Test("a split surface collapses into one word over the whole span")
    func splitSurfaceCollapses() {
        // No 沙名子 reading is offered, so the per-surface path renders 沙名 + 子 separately.
        let split: @Sendable (String) -> String? = { surface in
            surface == "沙名" ? "すなな" : (surface == "子" ? "ご" : nil)
        }
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かう。", [])
        ])
        let content = ReaderContent.build(from: document, reading: split,
                                          readingCorroborated: corroborated)

        guard let merged = words(content, segment: 1).first(where: { $0.text == "沙名子" }) else {
            Issue.record("the split run did not collapse: \(line(content, segment: 1))")
            return
        }
        #expect(rendered(merged) == "さなこ")
        #expect(merged.utf16Lower == 0 && merged.utf16Upper == 3,
                "the merged word spans the whole run, so highlight and find still resolve")
    }

    /// The analysis reading is kept as a CANDIDATE, so a reader who thinks the author's ruby was
    /// context-specific can still change it back. Losing it would make the propagation a silent,
    /// unarguable override.
    @Test("our own reading survives as an alternative")
    func ourReadingSurvivesAsACandidate() {
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かう。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: corroborated)

        let second = words(content, segment: 1).first { $0.text == "沙名子" }
        let provenance = second?.ruby.compactMap(\.provenance).first
        #expect(provenance?.source == .authorRuby)
        #expect(provenance?.chosen == "さなこ")
        #expect(provenance?.candidates == ["さなこ", "すななご"])
        #expect(provenance?.hasAlternatives == true)
        #expect(provenance?.invitesChoice == false,
                "a badge on every occurrence of a main character's name is noise")
    }

    /// A reader who disagrees must not have the author's ruby written back over their choice on
    /// the next build. The correction is applied AFTER the propagation for exactly this reason.
    @Test("a reader's own correction outranks the author's ruby")
    func readerCorrectionOutranksAuthor() {
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かう。", [])
        ])
        let correction = RubyCorrection(utf16Lower: 0, utf16Upper: 3, surface: "沙名子",
                                        reading: "しゃめいこ")
        let content = ReaderContent.build(from: document, reading: ours,
                                          corrections: [1: [correction]],
                                          readingCorroborated: corroborated)

        #expect(line(content, segment: 1) == "沙名子[しゃめいこ] に 向かう[むかう] 。")
    }

    /// Okurigana stays on the baseline: the author's reading is placed by the SAME annotator the
    /// tier and the correction path use, so a kana tail is its own plain run rather than being
    /// swallowed into the ruby.
    @Test("okurigana keeps its own run")
    func okuriganaKeepsItsRun() {
        let reading: @Sendable (String) -> String? = { $0 == "叮寧" ? "ちょうやす" : nil }
        let document = document([
            ("叮寧に言う。", [RubyRun(lower: 0, upper: 2, reading: "ていねい")]),
            ("叮寧な人。", [])
        ])
        let content = ReaderContent.build(from: document, reading: reading,
                                          readingCorroborated: corroborated)

        let second = words(content, segment: 1).first { $0.text.hasPrefix("叮寧") }
        #expect(second?.ruby.first?.text == "叮寧")
        #expect(second?.ruby.first?.reading == "ていねい")
    }

    /// THE THIRD GATE, found by measuring rather than by reasoning: the run must be a WHOLE
    /// adjacent kanji stretch, never a proper part of one.
    ///
    /// An author who rubies 歩《あ》 (from 歩く) has said what 歩 reads ALONE. Writing that onto
    /// the 歩 inside 一歩 renders いっあ, because the correct いっぽ is a sandhi form the isolated
    /// reading cannot carry. Without this gate the 30-book corpus gained 102 gold-free join
    /// defects of exactly this shape - 一遍 いっへん for いっぺん, 内緒話 ないしょはな for
    /// ないしょばなし, 六分 ろっぶ for ろっぷん - while the headline gold-mismatch total was
    /// falling by 4,789. The aggregate said the change was good; the join check said which part
    /// of it was not.
    ///
    /// Removing `isWholeKanjiRun` makes this test render 一[いっ] 歩[あ] 進む[すすむ] 。
    @Test("a reading is not written onto a token inside a longer kanji run")
    func aTokenInsideACompoundIsLeftAlone() {
        let reading: @Sendable (String) -> String? = { surface in
            ["一": "いっ", "歩": "ぽ", "進む": "すすむ"][surface]
        }
        let document = document([
            ("歩いた。", [RubyRun(lower: 0, upper: 1, reading: "あ")]),
            ("一歩進む。", [])
        ])
        // The index HAS 歩 -> あ and our ぽ is uncorroborated here, so gates one and two both
        // pass; only the run gate holds this back.
        #expect(AuthorRubyIndex(document: document).reading(for: "歩") == "あ")
        let content = ReaderContent.build(from: document, reading: reading,
                                          readingCorroborated: { _, _ in false })

        #expect(line(content, segment: 1) == "一[いっ] 歩[ぽ] 進む[すすむ] 。",
                "the sandhi the in-context analysis got right must survive")
        // And the author's own line is still read the author's way.
        #expect(line(content, segment: 0) == "歩い[あい] た 。")
    }

    /// The other side of the same gate: a kana neighbour is not a compound, so the name still
    /// propagates. Without this the gate could be satisfied by never firing at all.
    @Test("a kana neighbour does not block propagation")
    func kanaNeighbourDoesNotBlock() {
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かう。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: corroborated)
        #expect(line(content, segment: 1) == "沙名子[さなこ] に 向かう[むかう] 。")
    }

    /// THE FOURTH GATE. A publisher setting ruby in FULL-SIZE kana has not given a different
    /// reading, only a different typesetting convention - 服部 as はつとり, 大給 as おぎゆう,
    /// 魔法力 as まほうりよく. Taking those would put 346 corpus positions we already had right
    /// onto the page in the publisher's spelling instead of the correct one.
    ///
    /// Directional, not symmetric: when the AUTHOR's spelling is the more precise one, it wins.
    @Test("a publisher's full-size kana does not overwrite the correct spelling")
    func fullSizeKanaDoesNotOverwrite() {
        let reading: @Sendable (String) -> String? = { ["服部": "はっとり", "君": "くん"][$0] }
        let document = document([
            ("服部君。", [RubyRun(lower: 0, upper: 2, reading: "はつとり")]),
            ("服部です。", [])
        ])
        #expect(AuthorRubyIndex(document: document).reading(for: "服部") == "はつとり")
        let content = ReaderContent.build(from: document, reading: reading,
                                          readingCorroborated: { _, _ in false })
        #expect(line(content, segment: 1) == "服部[はっとり] です 。",
                "our small kana is the reading; the publisher's is a convention")
    }

    @Test("the author's MORE precise spelling still wins")
    func moreSmallKanaStillPropagates() {
        let reading: @Sendable (String) -> String? = { ["服部": "はつとり", "君": "くん"][$0] }
        let document = document([
            ("服部君。", [RubyRun(lower: 0, upper: 2, reading: "はっとり")]),
            ("服部です。", [])
        ])
        let content = ReaderContent.build(from: document, reading: reading,
                                          readingCorroborated: { _, _ in false })
        #expect(line(content, segment: 1) == "服部[はっとり] です 。")
    }

    // MARK: - Per document

    /// A reading learned from one book must NEVER reach another. The index is derived from the
    /// document each build and never cached, which is the property `RubyCorrection` needs a text
    /// hash to get - so the test that proves it is a SECOND document that never saw the ruby.
    @Test("a reading learned in one document does not leak into another")
    func readingsDoNotLeakAcrossDocuments() {
        let first = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")])
        ])
        _ = ReaderContent.build(from: first, reading: ours, readingCorroborated: corroborated)

        let second = document([("沙名子に向かう。", [])])
        let content = ReaderContent.build(from: second, reading: ours,
                                          readingCorroborated: corroborated)

        #expect(line(content, segment: 0) == "沙[すな] 名子[なご] に 向かう[むかう] 。",
                "the second document never saw the ruby, so it renders its own analysis")
    }

    // MARK: - The index itself

    @Test("gapless per-character ruby merges into the word the author annotated")
    func perCharacterRubyMerges() {
        let index = AuthorRubyIndex(document: document([
            ("沙名子は。", [RubyRun(lower: 0, upper: 1, reading: "さ"),
                          RubyRun(lower: 1, upper: 2, reading: "な"),
                          RubyRun(lower: 2, upper: 3, reading: "こ")])
        ]))
        #expect(index.reading(for: "沙名子") == "さなこ")
    }

    @Test("a base with no kanji and a non-kana reading are both refused")
    func nonReadingsAreRefused() {
        let index = AuthorRubyIndex(rubied: [
            (base: "Ｂ", reading: "びい"),          // the author spelling out a letter
            (base: "甲板", reading: "deck"),        // a gloss, not a reading
            (base: "沙名子", reading: "サナコ")      // katakana folds and IS indexed
        ])
        #expect(index.reading(for: "Ｂ") == nil)
        #expect(index.reading(for: "甲板") == nil)
        #expect(index.reading(for: "沙名子") == "さなこ")
        #expect(index.count == 1)
    }

}

/// `ReaderContent.words(inSegment:)` - the accessor the focus surfaces read through.
///
/// Issue 044: both focus surfaces re-tokenized the current sentence themselves, calling
/// `KaraokeWord.tokenize` with `sourceRuby` and nothing else. No reading provider, no JMdict
/// tier, no compound join, no author-ruby propagation - so a sentence the reader drew with
/// furigana came out bare beside it. The fix is to read the reader's OWN words back, and this
/// pins that the accessor hands over annotated words rather than a re-derivation.
@Suite("Words of one segment")
struct ReaderContentSegmentWordsTests {

    private func document(_ lines: [(text: String, ruby: [RubyRun])]) -> Document {
        let docID = DocumentID("d")
        var segments: [TextSegment] = []
        var paragraphs: [Paragraph] = []
        for (index, line) in lines.enumerated() {
            segments.append(TextSegment(id: SegmentID(documentID: docID, sentenceIndex: index),
                                        documentID: docID, sentenceIndex: index, text: line.text,
                                        sourceRange: DocRange(lower: 0, upper: line.text.utf16.count),
                                        rubyRuns: line.ruby))
            paragraphs.append(Paragraph(id: ParagraphID(documentID: docID, index: index),
                                        segmentRange: index..<(index + 1)))
        }
        return Document(id: docID, title: "T", textHash: "h", segments: segments,
                        chapters: [Chapter(id: ChapterID(documentID: docID, index: 0), title: "T",
                                           paragraphs: paragraphs)])
    }

    /// THE POINT: the words handed over carry the reading the READER settled, including one that
    /// only author-ruby propagation could have produced. A re-tokenization of the bare sentence
    /// cannot reach さなこ on the second line, which is exactly what the focus surfaces did.
    @Test("a segment's words carry the reader's own readings, propagation included")
    func segmentWordsCarryTheReadersReadings() {
        let ours: @Sendable (String) -> String? = {
            ["沙名子": "すななご", "自席": "じせき", "向かう": "むかう"][$0]
        }
        let document = document([
            ("沙名子は自席にいる。", [RubyRun(lower: 0, upper: 3, reading: "さなこ")]),
            ("沙名子に向かう。", [])
        ])
        let content = ReaderContent.build(from: document, reading: ours,
                                          readingCorroborated: { _, _ in false })

        let second = content.words(inSegment: 1)
        let name = second.first { $0.text == "沙名子" }
        #expect(name?.ruby.compactMap(\.reading).joined() == "さなこ")
        // And it is the same object the paragraph shows, not a parallel derivation.
        #expect(second.map(\.id) == content.paragraphs[1].words.map(\.id))
    }

    @Test("a segment with no words, and an index the document does not have, answer empty")
    func absentSegmentsAnswerEmpty() {
        let content = ReaderContent.build(from: document([("あ。", [])]))
        #expect(content.words(inSegment: 99).isEmpty)
        #expect(!content.words(inSegment: 0).isEmpty)
    }
}
