import Testing
import KBCore
@testable import KBReadingKit

// TEST: the OpenJTalk lemma is threaded onto a word's furigana ruby (PRD F1 / issue 018).
// An inflected kanji word exposes its dictionary base form on every annotated run, so
// SRS-driven furigana visibility (Stage 4) can key off the lemma, not the surface.

@Suite("Ruby base form threading")
struct RubyBaseFormTests {
    @Test("the base-form closure's lemma is threaded onto a word's ruby")
    func lemmaThreadedOntoRuby() throws {
        // The lemma can differ from the surface (deinflection); a sentinel proves the
        // closure's result — not the surface — reaches the ruby. (Single-kanji surface keeps
        // tokenization deterministic.)
        let words = KaraokeWord.tokenize(
            "本", segmentIndex: 0,
            reading: { $0 == "本" ? "ほん" : nil },
            baseForm: { _ in "LEMMA" })
        let word = try #require(words.first)
        let kanjiRun = try #require(word.ruby.first { $0.reading != nil })
        #expect(kanjiRun.reading == "ほん")
        #expect(kanjiRun.baseForm == "LEMMA")
        #expect(word.ruby.allSatisfy { $0.baseForm == "LEMMA" })
    }

    @Test("without a base-form source the lemma defaults to the surface")
    func defaultsToSurface() throws {
        let words = KaraokeWord.tokenize(
            "本", segmentIndex: 0,
            reading: { $0 == "本" ? "ほん" : nil })
        let word = try #require(words.first)
        let run = try #require(word.ruby.first { $0.reading != nil })
        #expect(run.baseForm == "本")   // falls back to the surface, never nil for annotated runs
    }

    @Test("existing call sites without furigana are unaffected (no ruby, no base form)")
    func nonKanjiUnaffected() {
        let words = KaraokeWord.tokenize("hello world", segmentIndex: 0)
        #expect(words.allSatisfy { $0.ruby.isEmpty })
    }
}
