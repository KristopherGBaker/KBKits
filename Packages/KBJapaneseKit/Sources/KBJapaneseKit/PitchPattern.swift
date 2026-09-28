public import KBCore
import Foundation

/// Computes the per-mora pitch pattern a UI package draws, for each word of an
/// utterance, at ACCENT-PHRASE granularity.
///
/// ## Why this is not a fifth `JapaneseFurigana` closure
///
/// The four `JapaneseFurigana` closures (`reading`, `baseForm`, `payload`, `gloss`) are
/// per-WORD: each maps one surface string to one answer, in isolation. Pitch cannot be
/// shaped that way. 端 (edge, heiban) and 橋 (bridge, odaka) both read はし and both are
/// low-HIGH in isolation; they diverge only once a particle joins the phrase — 端が is
/// low-HIGH-HIGH while 橋が is low-HIGH-low. A closure handed only 端 cannot see the が
/// that follows, so a per-word design silently collapses the exact distinction pitch
/// exists to show, and looks correct in the common (isolated) case while doing it.
///
/// So this is a SEPARATE surface that takes a RUN of words together: the accent phrase.
/// The accent lives on the phrase, not the word — its nucleus comes from the phrase HEAD
/// (`AccentPhrase.accent`) and is applied across the phrase's whole concatenated mora
/// sequence, particles included, before being sliced back to each word. It complements
/// the per-word closures rather than pretending to be one: readings still come from a
/// per-word resolver (the same shape as `JapaneseFurigana.reading`), but the leveling
/// that turns those readings into pitch is phrase-scoped.
///
/// Pure: it reuses `MoraSplitter` (C1c) for moras and `AccentPhrase` (C1c) for grouping,
/// and computes no accent, no mora rules, and no grouping of its own. It draws nothing —
/// the UI package's `PitchOverlay` (C1d) owns rendering.
public enum PitchPattern {
    /// The per-word pitch pattern for already-grouped accent phrases, in phrase/word
    /// order (flattened): element *i* is the `[MoraPitch]` of the *i*-th word across all
    /// phrases, aligned one-to-one with `phrases.flatMap(\.words)`.
    ///
    /// Each word's moras come from `MoraSplitter.moras(in:)` over the READING the
    /// resolver returns, never the surface, so 箸 (one character, reading はし) yields two
    /// entries. The whole phrase's moras are concatenated, leveled from the phrase head's
    /// accent nucleus, then sliced back to each word by that word's own mora count.
    ///
    /// - Parameters:
    ///   - phrases: accent phrases already grouped by `AccentPhrase.group(_:)`.
    ///   - resolve: a per-word reading resolver, the same shape as
    ///     `JapaneseFurigana.reading`. Returning `nil` or `""` for a word preserves that
    ///     word in the output with an EMPTY pattern (it contributes zero moras to its
    ///     phrase's sequence); the phrase's other words are unaffected.
    /// - Returns: one `[MoraPitch]` per input word, in phrase then word order.
    public static func patterns(
        for phrases: [AccentPhrase],
        reading resolve: @Sendable (String) -> String?
    ) -> [[MoraPitch]] {
        var result: [[MoraPitch]] = []
        for phrase in phrases {
            // Each word's moras from its READING; a missing/empty reading contributes none.
            let wordMoras: [[String]] = phrase.words.map { word in
                guard let reading = resolve(word.surface), !reading.isEmpty else { return [] }
                return MoraSplitter.moras(in: reading)
            }
            // Level the phrase's full mora run from the head's nucleus, then slice it back
            // to each word so the drop can land on a mora a LATER word contributes.
            let leveled = level(wordMoras.flatMap { $0 }, nucleus: phrase.accent.nucleus)
            var cursor = 0
            for moras in wordMoras {
                result.append(Array(leveled[cursor..<cursor + moras.count]))
                cursor += moras.count
            }
        }
        return result
    }

    /// The per-word pitch pattern for Japanese `text`, resolving readings through a
    /// configured `JapaneseReader`: `words(in:)` → `AccentPhrase.group` → per-word
    /// `furiganaReading`. The text-facing convenience over the pure `patterns(for:reading:)`
    /// seam; needs a dictionary because `JapaneseReader` does.
    public static func patterns(in text: String, using reader: JapaneseReader) -> [[MoraPitch]] {
        let phrases = AccentPhrase.group(reader.words(in: text))
        return patterns(for: phrases) { reader.furiganaReading(for: $0) }
    }

    /// Level a phrase's whole mora run from its head accent nucleus (1-based; `0` heiban).
    /// The standard two-level Tokyo pattern:
    /// - heiban (n=0): mora 1 low, the rest high, no drop.
    /// - atamadaka (n=1): mora 1 high, the rest low, drop after mora 1.
    /// - n≥2: mora 1 low, moras 2..n high, moras n+1..end low, drop after mora n.
    private static func level(_ moras: [String], nucleus: Int) -> [MoraPitch] {
        moras.enumerated().map { index, mora in
            let level: PitchLevel
            let isDrop: Bool
            switch nucleus {
            case 0: // heiban: flat, low only on the first mora, never drops.
                level = index == 0 ? .low : .high
                isDrop = false
            case 1: // atamadaka: high first mora, drop right after it.
                level = index == 0 ? .high : .low
                isDrop = index == 0
            default: // n≥2: rises off mora 1, high through the nucleus, drops after it.
                level = (index >= 1 && index <= nucleus - 1) ? .high : .low
                isDrop = index == nucleus - 1
            }
            return MoraPitch(mora: mora, level: level, isDrop: isDrop)
        }
    }
}

extension PitchPattern {
    /// Per-word pitch patterns for an ALREADY-TOKENIZED sentence, aligned back onto the
    /// caller's own word split.
    ///
    /// `ReaderContent` tokenizes a document its own way, so the words it renders do not
    /// always match Open JTalk's split of the same text. This re-analyzes the joined
    /// sentence, then walks the analyzed words consuming them until their surfaces spell
    /// each caller word, merging their patterns. A word the analysis cannot spell exactly
    /// gets `nil` rather than a pattern borrowed from a neighbor: a pitch mark on the
    /// wrong mora teaches the wrong word, so declining to draw is the safer failure.
    ///
    /// - Returns: one entry per element of `surfaces`, in the same order.
    public static func alignedPatterns(
        forSurfaces surfaces: [String],
        using reader: JapaneseReader
    ) -> [[MoraPitch]?] {
        guard !surfaces.isEmpty else { return [] }
        let phrases = AccentPhrase.group(reader.words(in: surfaces.joined()))
        let analyzed = phrases.flatMap(\.words)
        let patterns = patterns(for: phrases) { reader.furiganaReading(for: $0) }
        // patterns(for:) is documented one-to-one with the flattened words; if that ever
        // stops holding, draw nothing rather than misalign every mark in the sentence.
        guard patterns.count == analyzed.count else {
            return Array(repeating: nil, count: surfaces.count)
        }

        return align(surfaces: surfaces, analyzed: analyzed.map(\.surface), patterns: patterns)
    }

    /// Merge `patterns` (one per analyzed word) onto `surfaces` (the caller's split).
    ///
    /// Both splits cover the same text, so this works in character offsets rather than
    /// walking a shared cursor: a caller word takes the patterns of the analyzed words
    /// that exactly cover its range, and gets `nil` when the analysis puts no boundary at
    /// its edges. Offsets are what make it resynchronize; an earlier word the analysis
    /// splits through costs only that word, not the rest of the sentence. Pure, so it is
    /// testable without a configured dictionary.
    static func align(
        surfaces: [String],
        analyzed: [String],
        patterns: [[MoraPitch]]
    ) -> [[MoraPitch]?] {
        // The analysis ran on the joined surfaces; if it came back spelling something
        // else, every offset below would be meaningless.
        guard analyzed.count == patterns.count,
              analyzed.joined() == surfaces.joined()
        else { return Array(repeating: nil, count: surfaces.count) }

        // Start offset of each analyzed word, plus the end of the last, so a caller word
        // can be matched to a run of them by its own start and end.
        var boundaries: [Int: Int] = [:]  // character offset -> analyzed word index
        var offset = 0
        for (index, word) in analyzed.enumerated() {
            boundaries[offset] = index
            offset += word.count
        }

        var result: [[MoraPitch]?] = []
        var start = 0
        for surface in surfaces {
            let end = start + surface.count
            defer { start = end }
            guard var index = boundaries[start] else {
                result.append(nil)  // no analyzed word begins here
                continue
            }
            var merged: [MoraPitch] = []
            var covered = start
            while index < analyzed.count, covered < end {
                covered += analyzed[index].count
                merged += patterns[index]
                index += 1
            }
            result.append(covered == end && !merged.isEmpty ? merged : nil)
        }
        return result
    }
}
