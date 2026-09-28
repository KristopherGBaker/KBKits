import Foundation
import Testing
@testable import KBJapaneseKit

/// The OpenJTalk dictionary lives outside the repo (downloaded on first use), so the
/// integration tests skip unless `OJT_DICT_DIR` points at an unpacked
/// `open_jtalk_dic_utf_8` directory. Setting it to something without `sys.dic` fails
/// loudly through `#require` rather than passing silently, matching MisakiSwift's own
/// suite.
func dictionaryDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["OJT_DICT_DIR"] else { return nil }
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("sys.dic").path) ? url : nil
}

/// Pure-value tests that need no dictionary: they pin the shape of the seam, not the
/// morphology. These always run.
@Suite("JapaneseReader.Word accent shape")
struct JapaneseReaderWordShapeTests {

    @Test("Word(surface:baseForm:) still constructs, defaulting to heiban and a new phrase")
    func defaultsPreserveCompatibility() {
        let word = JapaneseReader.Word(surface: "端", baseForm: "端")
        #expect(word.surface == "端")
        #expect(word.baseForm == "端")
        #expect(word.accent == JapaneseReader.PitchAccent(nucleus: 0, moraCount: 0))
        #expect(word.accent.isHeiban)
        #expect(word.phraseChain == .startsNewPhrase)
        #expect(!word.phraseChain.attachesToPreviousWord)
    }

    @Test("nucleus and mora count are inseparable and both readable as Int")
    func pitchAccentBundlesNucleusAndMora() {
        let accent = JapaneseReader.PitchAccent(nucleus: 2, moraCount: 2)
        let nucleus: Int = accent.nucleus
        let moraCount: Int = accent.moraCount
        #expect(nucleus == 2)
        #expect(moraCount == 2)
        #expect(!accent.isHeiban)
    }

    @Test("chain flags map to the three typed NJD states")
    func chainFlagMapsToTypedStates() {
        #expect(JapaneseReader.AccentPhraseChain(chainFlag: -1) == .beginsPhrase)
        #expect(JapaneseReader.AccentPhraseChain(chainFlag: 1) == .attachesToPrevious)
        #expect(JapaneseReader.AccentPhraseChain(chainFlag: 0) == .startsNewPhrase)
        // Only `attachesToPrevious` continues the previous phrase.
        #expect(JapaneseReader.AccentPhraseChain.attachesToPrevious.attachesToPreviousWord)
        #expect(!JapaneseReader.AccentPhraseChain.beginsPhrase.attachesToPreviousWord)
        #expect(!JapaneseReader.AccentPhraseChain.startsNewPhrase.attachesToPreviousWord)
    }
}

/// Dictionary-backed integration: proves accent actually survives `words(in:)` rather
/// than being zeroed or hardcoded at the seam.
/// Two different situations, deliberately handled differently.
///
/// `OJT_DICT_DIR` UNSET means nobody asked for the integration tests, so the suite is
/// SKIPPED. A fresh clone that has not downloaded the dictionary still goes green, and
/// a skip is reported as a skip rather than counted as coverage.
///
/// `OJT_DICT_DIR` SET but pointing somewhere without `sys.dic` means somebody tried to
/// run them and got it wrong. That must not pass quietly, so the suite still runs and
/// the `#require` inside each test fails loudly.
@Suite("JapaneseReader accent, dictionary integration",
       .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct JapaneseReaderAccentTests {

    private func word(
        _ surface: String,
        in sentence: String,
        using reader: JapaneseReader
    ) throws -> JapaneseReader.Word {
        try #require(
            reader.words(in: sentence).first { $0.surface == surface },
            "expected a word with surface \(surface) in \(sentence)"
        )
    }

    /// The textbook はし minimal triple: 箸, 橋, 端 share the reading はし but are atamadaka
    /// (1), odaka (2), and heiban (0). A seam that zeroed or hardcoded accent could not
    /// produce three distinct nuclei, and every reading is two moras so a nucleus above 2
    /// would be impossible.
    @Test("the はし minimal triple carries three distinct nuclei, each over two moras")
    func minimalTripleThroughWords() throws {
        let dir = try #require(dictionaryDirectory(), "set OJT_DICT_DIR to run")
        let reader = try #require(JapaneseReader(dictionaryDirectory: dir))

        let chopsticks = try word("箸", in: "箸を持つ", using: reader).accent
        let bridge = try word("橋", in: "橋を渡る", using: reader).accent
        let edge = try word("端", in: "端に置く", using: reader).accent

        for accent in [chopsticks, bridge, edge] {
            #expect(accent.moraCount == 2, "はし is two moras")
        }

        // Distinctness is load-bearing: it fails if accent is constant.
        #expect(Set([chopsticks.nucleus, bridge.nucleus, edge.nucleus]).count == 3,
                "expected three distinct nuclei, got 箸=\(chopsticks.nucleus) 橋=\(bridge.nucleus) 端=\(edge.nucleus)")
        #expect(chopsticks.nucleus == 1, "箸 is atamadaka")
        #expect(bridge.nucleus == 2, "橋 is odaka")
        #expect(edge.nucleus == 0, "端 is heiban")
        #expect(edge.isHeiban, "nucleus 0 reads as heiban")
    }

    /// Phrase chaining across a full sentence must survive `words(in:)`. "箸を持つ" exercises
    /// all three NJD states: 箸 heads the utterance and begins the phrase (chain_flag -1),
    /// を is a particle that attaches to it (1), and 持つ is a verb after a particle that
    /// starts a fresh phrase (0). These raw states follow from njd_set_accent_phrase.c
    /// (head keeps its -1 default; Rule 08 sets を to 1; Rule 09 sets 持つ to 0). Two of the
    /// three words are non-attaching, giving the required contrast against を.
    @Test("phrase chaining survives words(in:) across all three NJD states")
    func phraseChainingThroughWords() throws {
        let dir = try #require(dictionaryDirectory(), "set OJT_DICT_DIR to run")
        let reader = try #require(JapaneseReader(dictionaryDirectory: dir))

        let chopsticks = try word("箸", in: "箸を持つ", using: reader)
        let particle = try word("を", in: "箸を持つ", using: reader)
        let verb = try word("持つ", in: "箸を持つ", using: reader)

        #expect(chopsticks.phraseChain == .beginsPhrase, "箸 heads the utterance")
        #expect(!chopsticks.phraseChain.attachesToPreviousWord)

        #expect(particle.phraseChain == .attachesToPrevious, "を attaches to the preceding noun")
        #expect(particle.phraseChain.attachesToPreviousWord)

        #expect(verb.phraseChain == .startsNewPhrase, "持つ opens a new phrase after the particle")
        #expect(!verb.phraseChain.attachesToPreviousWord)

        // All three distinct states are present, and at least one is non-attaching.
        let states = Set([chopsticks.phraseChain, particle.phraseChain, verb.phraseChain])
        #expect(states.count == 3, "expected all three NJD chain states in one sentence")
    }
}
