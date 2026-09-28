public import KBCore
import Foundation

/// One piece of a furigana-annotated word: a run of text, optionally with a
/// reading shown above it (kana over a kanji run). `reading == nil` is a plain
/// run (kana, okurigana, punctuation) that renders with no ruby.
/// Where a compound's reading came from, and what else the dictionary offered.
///
/// Carried so a reader-facing affordance can let a learner confirm or change a reading, per
/// `docs/furigana/backlog-reading-choice.md`. The compound join already computes the full
/// candidate list before choosing; discarding it made a heuristic pick indistinguishable on
/// screen from a dictionary-settled one, which is the state that would have made the choice
/// feature arrive as a regression.
///
/// `nil` on a segment means no compound decision was involved, which is the common case.
public struct ReadingProvenance: Sendable, Hashable {
    /// How confidently the reading was settled.
    public enum Source: Sendable, Hashable {
        /// The dictionary listed exactly one reading, or exactly one with a placement row.
        case dictionary
        /// Several readings remained and the nearest to what the page already rendered was
        /// taken. A considered guess: it can be contextually wrong (十分 as じゅうぶん where
        /// the passage means じゅっぷん), and it is the class a reader is best placed to settle.
        case heuristic
        /// The sentence analysis chose this reading and the dictionary lists others for the
        /// same surface (辺 read あたり, with へん and ほとり also listed). NOT a guess: the
        /// analyser had the sentence, which the compound heuristic does not. Carried so a
        /// reader who taps the word can see the alternatives, and deliberately NOT treated as
        /// inviting a choice, because most kanji words list several readings and marking them
        /// all would violate the "quiet by default" rule this feature is built on.
        case analysis
        /// THE AUTHOR of this document rubied this surface, once, somewhere else in it, and no
        /// ordinary dictionary form accounts for what our analysis produced. The author is the
        /// authority for their own text, so their reading is taken and ours is kept as the
        /// alternative - a reader who disagrees can still change it.
        ///
        /// Not `.dictionary`: no dictionary was consulted for the answer, only for the
        /// permission. Not `.heuristic` either, and so NOT `invitesChoice`: marking every
        /// propagated name would put a badge on every occurrence of a main character's name,
        /// which is the noise the quiet-by-default rule exists to prevent.
        case authorRuby
    }

    /// Every kana reading the dictionary lists for the joined form, in dictionary order and
    /// INCLUDING the chosen one. Kept whole: a shortened list cannot support the affordance.
    public let candidates: [String]
    /// The reading actually rendered across the run.
    public let chosen: String
    public let source: Source

    public init(candidates: [String], chosen: String, source: Source) {
        self.candidates = candidates
        self.chosen = chosen
        self.source = source
    }

    /// Whether a reader could reasonably be offered a choice here: a GUESS with alternatives.
    /// `.analysis` is excluded on purpose - see that case's note. Most kanji words have several
    /// dictionary readings, so a predicate that fired on every one of them would mark half a
    /// book and make the affordance noise rather than help.
    public var invitesChoice: Bool { source == .heuristic && candidates.count > 1 }

    /// Whether there is anything to show a reader who taps this word, regardless of whether it
    /// is worth marking unprompted.
    public var hasAlternatives: Bool { candidates.count > 1 }
}

public struct RubySegment: Sendable, Hashable {
    public let text: String
    public let reading: String?
    /// The word's dictionary (base) form / lemma, when known (OpenJTalk). The SRS unit is
    /// the lemma, not the surface form (PRD F1), so a learner's "known words" / furigana
    /// visibility key off this rather than `text`. `nil` for plain runs or when OpenJTalk's
    /// dictionary isn't installed; rendering ignores it (existing furigana is unchanged).
    public let baseForm: String?
    /// Per-mora pitch for this run's `reading`, already split and leveled by the caller
    /// (the app's next unit owns the linguistics). `nil` for plain runs, katakana gloss, or
    /// when pitch isn't computed; the renderer draws nothing then. Optional and defaulted so every
    /// existing construction site compiles unchanged, exactly as `baseForm` was added.
    /// The UI package never splits moras itself: it draws precisely this array.
    public let pitch: [MoraPitch]?
    /// How this run's reading was settled by the compound join, and what the alternatives
    /// were. `nil` when no compound decision produced this segment. Optional and defaulted so
    /// every existing construction site compiles unchanged, as `baseForm` and `pitch` were.
    public let provenance: ReadingProvenance?

    public init(
        text: String,
        reading: String? = nil,
        baseForm: String? = nil,
        pitch: [MoraPitch]? = nil,
        provenance: ReadingProvenance? = nil
    ) {
        self.text = text
        self.reading = reading
        self.baseForm = baseForm
        self.pitch = pitch
        self.provenance = provenance
    }

    /// A copy carrying `pitch` for this run's reading, one entry per mora of that reading.
    public func withPitch(_ pitch: [MoraPitch]) -> RubySegment {
        RubySegment(text: text, reading: reading, baseForm: baseForm, pitch: pitch,
                    provenance: provenance)
    }

    /// A copy stamped with `baseForm` (the word lemma applies to every ruby run of a word).
    public func withBaseForm(_ baseForm: String?) -> RubySegment {
        RubySegment(text: text, reading: reading, baseForm: baseForm, pitch: pitch,
                    provenance: provenance)
    }
}

/// On-device furigana generation, adapted from a sibling app's
/// `JapaneseRubyAnnotator`. Given a Japanese token and its kana reading, it
/// returns ruby segments with the reading placed over each kanji run only —
/// matching leading/trailing kana (okurigana) is trimmed off, and a mixed
/// kanji+kana core is split per kanji run so each ruby span is short (better
/// line wrapping and no kana-over-kana noise).
///
/// The reading comes from the same `CFStringTokenizer` (ja_JP) + ICU
/// `Latin-Hiragana` path the reader already uses to tokenize CJK text, so
/// furigana needs no morphological-analyzer dependency. Readings are the system
/// dictionary's first reading (so a few are imperfect, e.g. 私→わたくし) — good
/// enough as a reading aid, consistent with the Phase-1 spoken G2P.
enum FuriganaAnnotator {

    /// Ruby segments for a token given its hiragana `reading`. Returns `[]` when
    /// the token has no kanji to annotate (caller renders it as plain text).
    static func segments(token: String, reading: String) -> [RubySegment] {
        guard containsKanji(token), !reading.isEmpty else { return [] }

        var tokenChars = Array(token)
        var readingChars = Array(reading)

        var leading = ""
        while let tokenChar = tokenChars.first, let readingChar = readingChars.first,
              kanaAligns(tokenChar, readingChar), isKana(tokenChar) {
            leading.append(tokenChar)
            tokenChars.removeFirst()
            readingChars.removeFirst()
        }
        var trailing = ""
        while let tokenChar = tokenChars.last, let readingChar = readingChars.last,
              kanaAligns(tokenChar, readingChar), isKana(tokenChar) {
            trailing = String(tokenChar) + trailing
            tokenChars.removeLast()
            readingChars.removeLast()
        }

        let core = String(tokenChars)
        let coreReading = String(readingChars)
        guard !core.isEmpty, !coreReading.isEmpty, containsKanji(core) else { return [] }

        var segments: [RubySegment] = []
        if !leading.isEmpty { segments.append(RubySegment(text: leading)) }

        if !containsKana(core) {
            segments.append(RubySegment(text: core, reading: coreReading))   // pure-kanji core
        } else if let split = splitMixedCore(core: core, reading: coreReading) {
            segments.append(contentsOf: split)
        } else {
            segments.append(RubySegment(text: core, reading: coreReading))   // alignment failed → one span
        }

        if !trailing.isEmpty { segments.append(RubySegment(text: trailing)) }
        return segments
    }

    /// Hiragana reading for a romaji transcription (ICU `Latin-Hiragana`).
    ///
    /// Apple-only, and deliberately so. `CFStringTransform` is CoreFoundation, which
    /// swift-corelibs-foundation does not provide, so this cannot cross-compile for Android
    /// unguarded. The audit that moved this file cleared it by its imports (KBCore, Foundation)
    /// and missed the symbol; `make check-portability` is what caught it.
    ///
    /// Guarding is right here rather than writing a portable romaji table, because of WHO calls
    /// it: this is the LAST fallback in `KaraokeWord+RubySegments`, reached only when there is
    /// no dictionary-tier reading, no injected reading, and a `latinTranscription` was supplied.
    /// That transcription is the Apple-reading G2P path. Android takes its readings from
    /// OpenJTalk and the JMdict tier and never populates it. A romaji table would also change
    /// behaviour, and this move must render byte-identically.
    ///
    /// If Android ever DOES reach this, the symptom is silent: `resolved` becomes nil, the
    /// caller returns no segments, and the word renders with NO ruby. That is a reading
    /// regression, not a cosmetic one, so the fix at that point is a portable romaji-to-kana
    /// mapping - not accepting the silence.
    static func hiragana(fromRomaji romaji: String) -> String? {
        let trimmed = romaji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(Darwin)
        let mutable = NSMutableString(string: trimmed)
        guard CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false) else { return nil }
        let hira = mutable as String
        return hira.isEmpty ? nil : hira
        #else
        return nil
        #endif
    }

    // MARK: - Mixed core

    /// Split a kanji+kana core into per-kanji-run ruby. For each kana run, consume
    /// matching reading chars; for each kanji run, slice the reading up to the next
    /// kana run's first char. Returns nil if alignment fails.
    private static func splitMixedCore(core: String, reading: String) -> [RubySegment]? {
        let runs = characterRuns(in: core)
        let readingChars = Array(reading)
        var index = 0
        var output: [RubySegment] = []

        for (runIndex, run) in runs.enumerated() {
            if run.isKanji {
                let end: Int
                if let nextKana = runs[(runIndex + 1)...].first(where: { !$0.isKanji }),
                   let firstKana = nextKana.chars.first {
                    guard let found = (index..<readingChars.count)
                        .first(where: { kanaAligns(firstKana, readingChars[$0]) }) else { return nil }
                    end = found
                } else {
                    end = readingChars.count
                }
                guard end > index else { return nil }
                output.append(RubySegment(text: run.chars, reading: String(readingChars[index..<end])))
                index = end
            } else {
                for char in run.chars {
                    guard index < readingChars.count, kanaAligns(char, readingChars[index]) else { return nil }
                    index += 1
                }
                output.append(RubySegment(text: run.chars))
            }
        }
        return index == readingChars.count ? output : nil
    }

    private struct CharacterRun { let chars: String; let isKanji: Bool }

    private static func characterRuns(in text: String) -> [CharacterRun] {
        var runs: [CharacterRun] = []
        var current = ""
        var currentKanji = false
        for char in text {
            let kanji = isKanji(char)
            if current.isEmpty {
                current = String(char)
                currentKanji = kanji
            } else if kanji == currentKanji {
                current.append(char)
            } else {
                runs.append(CharacterRun(chars: current, isKanji: currentKanji))
                current = String(char)
                currentKanji = kanji
            }
        }
        if !current.isEmpty { runs.append(CharacterRun(chars: current, isKanji: currentKanji)) }
        return runs
    }

    // MARK: - Character classes

    static func containsKanji(_ text: String) -> Bool { text.unicodeScalars.contains(where: isKanjiScalar) }
    private static func containsKana(_ text: String) -> Bool { text.unicodeScalars.contains(where: isKanaScalar) }

    /// A pure-katakana token (a loanword candidate for the English gloss): at least one
    /// katakana letter and every scalar in the katakana block (incl. ・ middle dot and ー
    /// long-vowel mark). Excludes anything with kanji or hiragana.
    static func isKatakanaWord(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var sawKatakana = false
        for scalar in text.unicodeScalars {
            if isKatakanaScalar(scalar) {
                sawKatakana = true
            } else {
                return false
            }
        }
        return sawKatakana
    }

    private static func isKatakanaScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value)
    }
    private static func isKanji(_ char: Character) -> Bool { char.unicodeScalars.contains(where: isKanjiScalar) }
    private static func isKana(_ char: Character) -> Bool { char.unicodeScalars.contains(where: isKanaScalar) }

    /// Whether a token kana and a reading kana align for okurigana trimming / per-kanji split.
    /// Tolerates the phonetic long vowel the reading path emits — the reading writes a long o/e as
    /// おお/ええ where the surface writes おう/えい (e.g. 切りあげ**よう** ↔ reading きりあげ**よお**,
    /// ほう ↔ ほお) — so the okurigana still trims and alignment doesn't fall back to one big span.
    private static func kanaAligns(_ tokenChar: Character, _ readingChar: Character) -> Bool {
        if tokenChar == readingChar { return true }
        return (tokenChar == "う" && readingChar == "お") || (tokenChar == "お" && readingChar == "う")
            || (tokenChar == "い" && readingChar == "え") || (tokenChar == "え" && readingChar == "い")
    }

    private static func isKanjiScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }
    // Internal (not private): `KaraokeWord+ReadingTier` reuses it for its kana-only check.
    static func isKanaScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
            || (0xFF66...0xFF9F).contains(scalar.value) || scalar.value == 0x30FC
    }
}
