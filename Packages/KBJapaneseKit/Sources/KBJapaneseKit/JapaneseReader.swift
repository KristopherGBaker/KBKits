public import Foundation
import MisakiJapanese
import Synchronization

/// Process-global Open JTalk configuration. The frontend resolves its dictionary from
/// one directory for the whole process, so pointing it somewhere is a one-time setup
/// step rather than per-reader state.
///
/// `OpenJTalkDictionary` calls this after it downloads/extracts; a consumer that
/// already has a dictionary on disk can call it directly.
///
/// **This type is the ONLY place in Kits that touches MisakiSwift's
/// `JapaneseG2PConfiguration.dictionaryDirectory`, and it does so under one lock.** That
/// global is declared `nonisolated(unsafe)`, so it carries no synchronization of its own: a
/// reader constructed on one thread while a download finishes on another is an unsynchronized
/// read of a `URL?`, which is a data race with a torn pointer at the end of it. Kits cannot
/// fix the declaration (MisakiSwift is a separate repository, and the upstream change is
/// listed for the owner), but it can make every Kits-side access serial, which is what the
/// mutex below does. Kits deliberately exposes no mutable static of its own over it: a
/// `public static var` here would hand callers a second, unsynchronized door to the same
/// state.
public enum JapaneseTextAnalysis {
    /// The one lock. It guards the MisakiSwift global itself rather than a local mirror,
    /// because a mirror would be a second source of truth that drifts the moment anything
    /// else writes the real one.
    private static let dictionaryLock = Mutex<Void>(())

    /// Point the Open JTalk frontend at an extracted dictionary directory.
    ///
    /// Idempotent per directory: pointing it at the directory it already uses writes nothing,
    /// so the common case (every `ensureAvailable` on an installed dictionary) does not churn
    /// a global that other threads are reading.
    public static func useDictionary(at directory: URL) {
        dictionaryLock.withLock { _ in
            guard JapaneseG2PConfiguration.dictionaryDirectory != directory else { return }
            JapaneseG2PConfiguration.dictionaryDirectory = directory
        }
    }

    /// Whether a dictionary has been configured for this process.
    public static var isDictionaryConfigured: Bool {
        configuredDictionaryDirectory != nil
    }

    /// The configured dictionary directory, read under the lock. Package-internal on purpose:
    /// it is the read path `JapaneseReader()` uses, and widening it would only invite a caller
    /// to read the raw global instead.
    static var configuredDictionaryDirectory: URL? {
        dictionaryLock.withLock { _ in JapaneseG2PConfiguration.dictionaryDirectory }
    }
}

/// Japanese morphological analysis over the Open JTalk frontend: the reading a word
/// is pronounced with, and its dictionary (base) form.
///
/// This is the seam that keeps MisakiSwift off consumers' import lists — the kits and
/// apps above depend on `JapaneseReader`, and only this package links the frontend.
/// Values are cheap wrappers over a shared frontend; construct one per build pass.
public struct JapaneseReader: Sendable {
    private let reader: OpenJTalkReader

    /// A reader over the configured dictionary, or nil when none has been configured
    /// (`JapaneseTextAnalysis.useDictionary(at:)` hasn't run, or the download hasn't
    /// happened yet). Callers treat nil as "no Japanese analysis available" and fall
    /// back — never as an error.
    ///
    /// The directory comes from `JapaneseTextAnalysis`, under its lock, rather than from
    /// MisakiSwift's `OpenJTalkReader.makeFromConfiguredDictionary()`, which reads the
    /// unsynchronized global directly. Same result, one serialized read.
    public init?() {
        guard let directory = JapaneseTextAnalysis.configuredDictionaryDirectory,
              let reader = OpenJTalkReader(dictionaryDirectory: directory) else { return nil }
        self.reader = reader
    }

    /// A reader over a specific extracted dictionary directory, bypassing the
    /// process-global configuration. For tools that are handed a path (the furigana
    /// QA harness) rather than running inside an app that downloaded one.
    public init?(dictionaryDirectory: URL) {
        guard let reader = OpenJTalkReader(dictionaryDirectory: dictionaryDirectory) else { return nil }
        self.reader = reader
    }

    /// The reading to DISPLAY as furigana: `pron` (correct sound changes, 八百 → はっぴゃく)
    /// reconciled with `read`'s orthographic long vowels (方 → ほう, not the phonetic ほお).
    /// Either alone regresses one case or the other. Synthesis uses `pron` on its own
    /// path, so audio is unaffected by this choice.
    /// Non-kana answers are dropped here as well as on the sentence path. This is the one that
    /// mattered: the 486 tokens rendering a COMMA as their furigana all came through the
    /// per-surface fallback, not through `furiganaWords`, so guarding only the sentence pass
    /// changed nothing and the corpus said so.
    public func furiganaReading(for text: String) -> String? {
        guard let reading = reader.furiganaReading(for: text) else { return nil }
        let kana = Self.kanaOnly(reading)
        return kana.isEmpty ? nil : kana
    }

    /// The dictionary (base) form of the first word in `text` (読んだ → 読む), or nil when
    /// the analysis yields nothing. Threading the lemma rather than the surface is what
    /// lets SRS-driven furigana visibility key off the word the learner actually studies.
    public func baseForm(for text: String) -> String? {
        reader.words(for: text).first?.baseForm
    }

    /// Every word in `text`, in reading order, with its surface, base form, and the
    /// pitch-accent analysis OpenJTalk computed for it (nucleus + mora count, and how the
    /// word chains into an accent phrase).
    public func words(in text: String) -> [Word] {
        reader.words(for: text).map {
            Word(
                surface: $0.surface,
                baseForm: $0.baseForm,
                accent: PitchAccent(nucleus: $0.accent, moraCount: $0.moraCount),
                phraseChain: AccentPhraseChain(chainFlag: $0.accentPhraseChain)
            )
        }
    }

    /// Every word in `text` WITH its reconciled in-context reading, from ONE frontend
    /// pass over the whole sentence. This is the pass display furigana must come from:
    /// re-analyzing a lone surface can re-tokenize it (静か alone becomes 静+か, whose
    /// joined reading doubles the か), while the sentence analysis reads it correctly.
    /// Words with no reading (punctuation) carry `reading == ""` so the surfaces still
    /// tile the line.
    public func furiganaWords(in text: String) -> [Word] {
        // Digits before a counter are rewritten as kanji numerals for this one call and the
        // words mapped back onto the original text, because Open JTalk reads 5年 as とし and
        // 五年 as ねん (see `CounterNumerals`). `normalize` returns nil - and this costs one
        // scan - for text with no such run, which is nearly all text.
        guard let normalized = CounterNumerals.normalize(text) else {
            return analysedWords(in: text)
        }
        let analysed = analysedWords(in: normalized.text)
        let projected = CounterNumerals.project(
            analysed.map { (surface: $0.surface, reading: $0.reading) },
            replacements: normalized.replacements,
            original: text)
        // A projected word may merge several analysed words. Accent belongs to the first of
        // them: a merged group is one display word, and a nucleus measured over a different
        // mora count would be worse than none.
        return projected.map { group in
            let first = analysed[group.sources.lowerBound]
            return Word(
                surface: group.surface,
                baseForm: group.sources.count == 1 ? first.baseForm : group.surface,
                reading: group.reading,
                accent: group.sources.count == 1 ? first.accent : PitchAccent(),
                phraseChain: first.phraseChain
            )
        }
    }

    /// A reading that is not kana is not a reading, and is dropped.
    ///
    /// Open JTalk answers with its pause symbol 、 for a token it cannot pronounce, and that was
    /// reaching the page: 重就 rendered 重[、] and 慚死 rendered [、]し - a COMMA drawn as
    /// furigana over a kanji. Corpus-wide it was 486 tokens. An empty reading renders no ruby,
    /// which is the honest answer to "I do not know how this is read".
    ///
    /// Long vowels (ー) and katakana readings are kana and survive; only characters outside the
    /// two kana blocks are rejected, and one bad character discards the whole reading rather
    /// than leaving a hole in it.
    static func kanaOnly(_ reading: String) -> String {
        guard !reading.isEmpty else { return reading }
        let allKana = reading.unicodeScalars.allSatisfy { scalar in
            (0x3041...0x309F).contains(scalar.value) || (0x30A1...0x30FF).contains(scalar.value)
        }
        return allKana ? reading : ""
    }

    /// The raw one-pass sentence analysis, over whatever text it is given, with the surfaces
    /// restored to the caller's own characters.
    ///
    /// Open JTalk REWRITES the text it reports back. It widens half-width Latin (R -> Ｒ), swaps
    /// hyphen forms, and converts numerals (２ -> 二). The surfaces then no longer tile the input,
    /// `FuriganaAlignment.align` fails its tiling guard, and EVERY token in the sentence falls
    /// back to isolated per-surface analysis - the path 静か must not take. So a sentence
    /// containing any digit quietly lost its in-context readings, which is a far bigger effect
    /// than the substitution itself.
    ///
    /// Where the rewrite preserved the character count the original characters are sliced back
    /// in at the same offsets, which is exact. Where it did not (27 -> 二十七) nothing can be
    /// recovered here and the words are returned as they came, exactly as before.
    private func analysedWords(in text: String) -> [Word] {
        let words = reader.furiganaWords(for: text).map {
            Word(
                surface: $0.surface,
                baseForm: $0.baseForm,
                reading: Self.kanaOnly($0.reading),
                accent: PitchAccent(nucleus: $0.accent, moraCount: $0.moraCount),
                phraseChain: AccentPhraseChain(chainFlag: $0.accentPhraseChain)
            )
        }
        let reported = words.map(\.surface).joined()
        guard reported != text, reported.count == text.count else { return words }
        let characters = Array(text)
        var offset = 0
        return words.map { word in
            let end = offset + word.surface.count
            defer { offset = end }
            return Word(surface: String(characters[offset..<end]), baseForm: word.baseForm,
                        reading: word.reading, accent: word.accent, phraseChain: word.phraseChain)
        }
    }

    /// A pitch-accent pattern: the nucleus (the mora after which pitch falls) paired with
    /// the mora count it indexes into. The two are inseparable by construction because a
    /// nucleus of 3 is final-accented on a three-mora word and impossible on a two-mora
    /// one; a caller cannot hold one without the other.
    public struct PitchAccent: Equatable, Sendable {
        /// The accent nucleus as a 1-based mora index, or `0` for heiban (no downstep).
        public let nucleus: Int

        /// The number of moras in the reading the nucleus is measured against.
        public let moraCount: Int

        public init(nucleus: Int = 0, moraCount: Int = 0) {
            self.nucleus = nucleus
            self.moraCount = moraCount
        }

        /// Whether the word is heiban (flat, no downstep): nucleus `0`.
        public var isHeiban: Bool { nucleus == 0 }
    }

    /// How a word joins the previous one into an accent phrase, from NJD's `chain_flag`.
    /// A typed value rather than a raw integer so the three states read at the call site
    /// and an out-of-range flag cannot leak in.
    public enum AccentPhraseChain: Hashable, Sendable {
        /// The word opens the utterance's first accent phrase (`chain_flag == -1`).
        case beginsPhrase
        /// The word attaches to the preceding word, extending its phrase (`chain_flag == 1`).
        case attachesToPrevious
        /// The word starts a new accent phrase mid-utterance (`chain_flag == 0`).
        case startsNewPhrase

        /// Whether this word continues the previous word's accent phrase rather than
        /// opening one of its own.
        public var attachesToPreviousWord: Bool { self == .attachesToPrevious }

        /// Map NJD's raw `chain_flag`. Anything outside the documented -1/0/1 set is
        /// treated as starting a new phrase, the safe default for grouping.
        init(chainFlag: Int) {
            switch chainFlag {
            case -1: self = .beginsPhrase
            case 1: self = .attachesToPrevious
            default: self = .startsNewPhrase
            }
        }
    }

    /// One analyzed word: what appeared in the text, what to look up in a dictionary, and
    /// the pitch accent OpenJTalk assigned it. Carrying accent across this seam is the whole
    /// point of the package existing between MisakiSwift and consumers, so it lives here
    /// rather than forcing callers to import the frontend.
    public struct Word: Equatable, Sendable {
        public let surface: String
        public let baseForm: String

        /// The reconciled in-context reading (hiragana) this word had within its
        /// sentence, or "" for words with no reading (punctuation) and for words
        /// from `words(in:)`, which predates the reading-carrying pass. Populated
        /// by `furiganaWords(in:)` — the one-pass sentence analysis — so a caller
        /// never has to re-analyze a surface in isolation to learn its reading.
        public let reading: String

        /// The pitch-accent nucleus and the mora count it is measured against, kept together
        /// because a nucleus is meaningless without knowing how many moras it indexes into.
        public let accent: PitchAccent

        /// How this word joins the one before it into an accent phrase. A consumer rendering
        /// pitch groups words by walking this: a word that attaches continues the previous
        /// phrase, one that begins or starts opens a new group.
        public let phraseChain: AccentPhraseChain

        public init(
            surface: String,
            baseForm: String,
            reading: String = "",
            accent: PitchAccent = PitchAccent(),
            phraseChain: AccentPhraseChain = .startsNewPhrase
        ) {
            self.surface = surface
            self.baseForm = baseForm
            self.reading = reading
            self.accent = accent
            self.phraseChain = phraseChain
        }

    }
}
