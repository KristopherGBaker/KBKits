import KBCore
import Foundation
import Testing
@testable import KBJapaneseKit

/// Phrase-granularity pitch is a pure function over already-parsed words plus a reading
/// resolver, so this suite builds `Word` fixtures by hand and supplies readings directly:
/// no dictionary, always runs. It asserts the PROPERTY (the levels and drops a renderer
/// would draw) rather than any internal mechanism.
@Suite("Pitch pattern at phrase granularity")
struct PitchPatternTests {

    /// A fixture word: surface, chain flag, and the head accent that matters for pitch.
    private func word(
        _ surface: String,
        _ chain: JapaneseReader.AccentPhraseChain,
        nucleus: Int = 0,
        moraCount: Int = 0
    ) -> JapaneseReader.Word {
        JapaneseReader.Word(
            surface: surface,
            baseForm: surface,
            accent: JapaneseReader.PitchAccent(nucleus: nucleus, moraCount: moraCount),
            phraseChain: chain
        )
    }

    /// The はし reading for either bridge or edge, plus が for the particle. Everything else
    /// resolves to itself so a stray surface never silently yields nothing.
    private let hashiReadings: @Sendable (String) -> String? = { surface in
        switch surface {
        case "端", "橋": return "はし"
        case "が": return "が"
        default: return surface
        }
    }

    // MARK: - Assertion 1: pure entry produces output with no dictionary

    @Test("the pure entry point produces per-word patterns from hand-built phrases")
    func pureEntryProducesOutput() {
        let phrases = AccentPhrase.group([word("端", .beginsPhrase, nucleus: 0, moraCount: 2)])
        let patterns = PitchPattern.patterns(for: phrases, reading: hashiReadings)
        #expect(patterns.count == 1)
        #expect(!patterns[0].isEmpty)
    }

    // MARK: - Assertions 2, 3, 4: the load-bearing 端が / 橋が discrimination

    /// Build the single phrase `[head, が]` and return its per-word patterns.
    private func phrasePatterns(head: JapaneseReader.Word) -> [[MoraPitch]] {
        let words = [head, word("が", .attachesToPrevious, nucleus: 0, moraCount: 1)]
        return PitchPattern.patterns(for: AccentPhrase.group(words), reading: hashiReadings)
    }

    @Test("端が and 橋が produce DIFFERENT patterns from the same reading and particle")
    func edgeAndBridgeDiscriminate() {
        let edge = phrasePatterns(head: word("端", .beginsPhrase, nucleus: 0, moraCount: 2))
        let bridge = phrasePatterns(head: word("橋", .beginsPhrase, nucleus: 2, moraCount: 2))
        // Load-bearing: a per-word implementation, seeing only はし, cannot tell these apart.
        #expect(edge != bridge)
    }

    @Test("端が (heiban) is low-HIGH-HIGH with no drop")
    func edgePattern() {
        let patterns = phrasePatterns(head: word("端", .beginsPhrase, nucleus: 0, moraCount: 2))
        #expect(patterns[0] == [
            MoraPitch(mora: "は", level: .low, isDrop: false),
            MoraPitch(mora: "し", level: .high, isDrop: false)
        ])
        #expect(patterns[1] == [MoraPitch(mora: "が", level: .high, isDrop: false)])
    }

    @Test("橋が (odaka, nucleus 2) is low-HIGH↓-low, drop after し")
    func bridgePattern() {
        let patterns = phrasePatterns(head: word("橋", .beginsPhrase, nucleus: 2, moraCount: 2))
        #expect(patterns[0] == [
            MoraPitch(mora: "は", level: .low, isDrop: false),
            MoraPitch(mora: "し", level: .high, isDrop: true)
        ])
        #expect(patterns[1] == [MoraPitch(mora: "が", level: .low, isDrop: false)])
    }

    // MARK: - Assertion 5: mora count comes from the reading, not the surface

    @Test("端 (one surface character, reading はし) yields exactly two moras は,し")
    func moraCountFromReading() {
        let phrases = AccentPhrase.group([word("端", .beginsPhrase, nucleus: 0, moraCount: 2)])
        let patterns = PitchPattern.patterns(for: phrases, reading: hashiReadings)
        #expect(patterns[0].count == 2)
        #expect(patterns[0].map(\.mora) == ["は", "し"])
    }

    // MARK: - Assertion 6: atamadaka

    @Test("atamadaka (2-mora head, nucleus 1) is HIGH↓-low, drop after mora 1")
    func atamadakaPattern() {
        // か reading あか, nucleus 1: 赤 in isolation.
        let resolve: @Sendable (String) -> String? = { $0 == "赤" ? "あか" : $0 }
        let phrases = AccentPhrase.group([word("赤", .beginsPhrase, nucleus: 1, moraCount: 2)])
        let patterns = PitchPattern.patterns(for: phrases, reading: resolve)
        #expect(patterns[0] == [
            MoraPitch(mora: "あ", level: .high, isDrop: true),
            MoraPitch(mora: "か", level: .low, isDrop: false)
        ])
    }

    // MARK: - Assertion 7: isolated odaka vs heiban differ only in isDrop, not levels

    @Test("isolated 橋 vs 端 share levels low,HIGH but differ in final-mora isDrop")
    func isolatedOdakaVsHeiban() {
        let edge = PitchPattern.patterns(
            for: AccentPhrase.group([word("端", .beginsPhrase, nucleus: 0, moraCount: 2)]),
            reading: hashiReadings)[0]
        let bridge = PitchPattern.patterns(
            for: AccentPhrase.group([word("橋", .beginsPhrase, nucleus: 2, moraCount: 2)]),
            reading: hashiReadings)[0]
        // Same levels...
        #expect(edge.map(\.level) == [.low, .high])
        #expect(bridge.map(\.level) == [.low, .high])
        // ...but isDrop, and only isDrop, distinguishes them.
        #expect(edge.map(\.isDrop) == [false, false])
        #expect(bridge.map(\.isDrop) == [false, true])
    }

    // MARK: - Assertion 8: mora strings are lossless (splitter reused)

    @Test("a word's MoraPitch strings concatenate back to its reading exactly")
    func moraStringsAreLossless() {
        // コーヒー: four moras (long-vowel mark is its own mora) — proves MoraSplitter reuse.
        let resolve: @Sendable (String) -> String? = { $0 == "珈琲" ? "コーヒー" : $0 }
        let phrases = AccentPhrase.group([word("珈琲", .beginsPhrase, nucleus: 3, moraCount: 4)])
        let patterns = PitchPattern.patterns(for: phrases, reading: resolve)
        #expect(patterns[0].count == 4)
        #expect(patterns[0].map(\.mora).joined() == "コーヒー")
    }

    // MARK: - Assertion 9: multi-phrase reset & order

    @Test("two phrases keep word order and each keeps its OWN head accent")
    func multiPhraseResetAndOrder() {
        // Phrase A: 端(heiban) + が ; Phrase B: 橋(odaka, n=2) + が. One call, two phrases.
        let words = [
            word("端", .beginsPhrase, nucleus: 0, moraCount: 2),
            word("が", .attachesToPrevious, nucleus: 0, moraCount: 1),
            word("橋", .startsNewPhrase, nucleus: 2, moraCount: 2),
            word("が", .attachesToPrevious, nucleus: 0, moraCount: 1)
        ]
        let patterns = PitchPattern.patterns(for: AccentPhrase.group(words), reading: hashiReadings)
        // Exact order 端, が, 橋, が.
        #expect(patterns.count == 4)
        #expect(patterns.map { $0.map(\.mora) } == [["は", "し"], ["が"], ["は", "し"], ["が"]])
        // Phrase A: 端's し does NOT drop, its が is high (heiban carried across).
        #expect(patterns[0][1].isDrop == false)
        #expect(patterns[1][0].level == .high)
        // Phrase B: 橋's し drops, its が is low (odaka carried across) — no bleed from A.
        #expect(patterns[2][1].isDrop == true)
        #expect(patterns[3][0].level == .low)
    }

    // MARK: - Assertion 10: resolver failure semantics (nil and "")

    @Test("a word whose reading resolves to nil is preserved with an empty pattern")
    func resolverReturnsNil() {
        let resolve: @Sendable (String) -> String? = { surface in
            switch surface {
            case "端": return "はし"
            case "が": return "が"
            case "〓": return nil   // unresolvable middle word
            default: return surface
            }
        }
        let words = [
            word("端", .beginsPhrase, nucleus: 0, moraCount: 2),
            word("〓", .attachesToPrevious, nucleus: 0, moraCount: 0),
            word("が", .attachesToPrevious, nucleus: 0, moraCount: 1)
        ]
        let patterns = PitchPattern.patterns(for: AccentPhrase.group(words), reading: resolve)
        // Word order and length preserved; the unresolved word is [] but not dropped.
        #expect(patterns.count == 3)
        #expect(patterns[1].isEmpty)
        // Its neighbours still compute normally (は low, し high; が high off heiban head).
        #expect(patterns[0] == [
            MoraPitch(mora: "は", level: .low, isDrop: false),
            MoraPitch(mora: "し", level: .high, isDrop: false)
        ])
        #expect(patterns[2] == [MoraPitch(mora: "が", level: .high, isDrop: false)])
    }

    @Test("a word whose reading resolves to \"\" is preserved with an empty pattern")
    func resolverReturnsEmpty() {
        let resolve: @Sendable (String) -> String? = { surface in
            switch surface {
            case "端": return "はし"
            case "が": return "が"
            case "　": return ""    // empty reading
            default: return surface
            }
        }
        let words = [
            word("端", .beginsPhrase, nucleus: 0, moraCount: 2),
            word("　", .attachesToPrevious, nucleus: 0, moraCount: 0),
            word("が", .attachesToPrevious, nucleus: 0, moraCount: 1)
        ]
        let patterns = PitchPattern.patterns(for: AccentPhrase.group(words), reading: resolve)
        #expect(patterns.count == 3)
        #expect(patterns[1].isEmpty)
        #expect(patterns[0].map(\.mora) == ["は", "し"])
        #expect(patterns[2] == [MoraPitch(mora: "が", level: .high, isDrop: false)])
    }

    // MARK: - Assertion 20: uses the shared type, no parallel one

    @Test("the pattern element type is KBCore's MoraPitch")
    func usesSharedMoraPitchType() {
        let patterns = phrasePatterns(head: word("端", .beginsPhrase, nucleus: 0, moraCount: 2))
        // Unqualified on purpose: a module-qualified spelling would collide with a
        // same-named declaration inside the module. The binding still proves the type is
        // the shared one, because KBJapaneseKit declares no MoraPitch of its own.
        let first: MoraPitch = patterns[0][0]
        #expect(first.mora == "は")
    }
}

/// Dictionary-backed integration for the text-facing convenience over `JapaneseReader`.
/// Gated exactly like the C1b accent suite: `OJT_DICT_DIR` UNSET skips the suite (a fresh
/// clone stays green and the pure suite above still exercises the pitch logic), while
/// `OJT_DICT_DIR` SET but pointing somewhere without `sys.dic` fails LOUDLY through
/// `#require` rather than passing quietly. `dictionaryDirectory()` is shared with the
/// accent suite in this module.
@Suite("Pitch pattern, dictionary integration",
       .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct PitchPatternDictionaryTests {

    /// The text-facing convenience must yield non-empty, phrase-aware per-word pitch for a
    /// real utterance. "橋を渡る" is the sentence C1b/C1c proved parses (橋 odaka over two
    /// moras, を attaching into its phrase). Phrase-awareness is asserted structurally: the
    /// convenience must equal the pure phrase-grouped computation over the SAME reader, so
    /// the particle's pitch is leveled from its phrase head — not from the particle alone.
    @Test("text-facing pitch is non-empty and phrase-aware over a real dictionary")
    func textFacingPitchOverDictionary() throws {
        let dir = try #require(dictionaryDirectory(), "set OJT_DICT_DIR to run")
        let reader = try #require(JapaneseReader(dictionaryDirectory: dir))

        let text = "橋を渡る"
        let actual = PitchPattern.patterns(in: text, using: reader)

        // Non-empty per-word pitch for the utterance.
        #expect(!actual.isEmpty, "expected pitch for a parsed utterance")
        #expect(actual.contains { !$0.isEmpty }, "expected at least one word to carry moras")

        // Phrase-aware: the convenience routes words → AccentPhrase.group → phrase-scoped
        // leveling, so it must reproduce the pure entry over the same words and readings.
        let words = reader.words(in: text)
        let viaPhrases = PitchPattern.patterns(for: AccentPhrase.group(words)) {
            reader.furiganaReading(for: $0)
        }
        #expect(actual == viaPhrases)

        // Lossless: each word's mora strings concatenate back to its display reading, so the
        // pattern is per mora of the READING (the property the renderer aligns marks to).
        // Positional index (not firstIndex) so repeated particles stay aligned to `actual`.
        for (index, word) in words.enumerated() {
            guard let reading = reader.furiganaReading(for: word.surface), !reading.isEmpty
            else { continue }
            #expect(actual[index].map(\.mora).joined() == reading)
        }
    }
}

/// Aligning analyzed pitch back onto a caller's own word split. `ReaderContent` tokenizes
/// a document its own way, so this is the seam that decides whether a mark lands on the
/// right mora or is withheld.
@Suite("Pitch alignment onto a caller's word split")
struct PitchAlignmentTests {
    private let high = MoraPitch(mora: "x", level: .high, isDrop: false)
    private let low = MoraPitch(mora: "y", level: .low, isDrop: false)

    @Test("A split that already matches passes each pattern straight through")
    func identicalSplitPassesThrough() {
        let aligned = PitchPattern.align(
            surfaces: ["日本", "語"], analyzed: ["日本", "語"], patterns: [[low, high], [high]])
        #expect(aligned.count == 2)
        #expect(aligned[0]?.map(\.level) == [.low, .high])
        #expect(aligned[1]?.map(\.level) == [.high])
    }

    @Test("A caller word spanning several analyzed words merges their patterns in order")
    func coarserCallerSplitMerges() {
        let aligned = PitchPattern.align(
            surfaces: ["食べました"], analyzed: ["食べ", "まし", "た"],
            patterns: [[low, high], [high], [low]])
        #expect(aligned[0]?.map(\.level) == [.low, .high, .high, .low])
    }

    @Test("A word the analysis cannot spell exactly is withheld, not approximated")
    func unspellableWordIsWithheld() {
        // The analysis splits across the caller's boundary, so nothing spells "本語".
        let aligned = PitchPattern.align(
            surfaces: ["本語"], analyzed: ["日本", "語"], patterns: [[low, high], [high]])
        #expect(aligned[0] == nil)
    }

    @Test("A later word still aligns after the analysis splits through an earlier one")
    func alignmentResynchronizesAfterAMismatch() {
        // Same text either way ("日本語です"), but the caller cuts 日/本語 where the
        // analysis cuts 日本/語, so neither of those two can be spelled exactly.
        let aligned = PitchPattern.align(
            surfaces: ["日", "本語", "です"], analyzed: ["日本", "語", "です"],
            patterns: [[low, high], [high], [low, low]])
        #expect(aligned[0] == nil)
        #expect(aligned[1] == nil)
        // The third word starts on an analyzed boundary again, so it is unaffected.
        #expect(aligned[2]?.map(\.level) == [.low, .low])
    }

    @Test("A word whose analyzed pattern is empty is withheld rather than drawn blank")
    func emptyPatternIsWithheld() {
        let aligned = PitchPattern.align(surfaces: ["、"], analyzed: ["、"], patterns: [[]])
        #expect(aligned[0] == nil)
    }

    @Test("An analysis spelling different text than the caller draws nothing at all")
    func textMismatchWithholdsEverything() {
        // Offsets would be meaningless, so no mark is safe to place anywhere.
        let aligned = PitchPattern.align(
            surfaces: ["日本", "語"], analyzed: ["日本"], patterns: [[low, high]])
        #expect(aligned.count == 2)
        #expect(aligned.allSatisfy { $0 == nil })
    }

    @Test("An empty sentence yields no entries")
    func emptyInputYieldsNoEntries() {
        #expect(PitchPattern.align(surfaces: [], analyzed: [], patterns: []).isEmpty)
    }
}
