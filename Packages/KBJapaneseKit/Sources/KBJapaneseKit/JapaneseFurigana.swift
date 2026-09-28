public import KBCore
import Foundation
public import KBDictionaryKit
import Synchronization

/// The furigana wiring a Japanese document needs on its way into `ReaderContent`.
///
/// Assembling these closures used to live in the app's reader coordinator, which
/// meant every app that wanted Japanese furigana had to work out the order the pieces
/// go together in (the per-sentence in-context annotations, the JMdict-validated
/// payload over them, the per-surface fallbacks, the lemma, the katakana gloss, the
/// pitch). They are pure and `Sendable`, so a caller can build them once and hand
/// them to a detached tokenization pass.
public struct JapaneseFurigana: Sendable {
    /// The reading to show above a word, or nil to leave the tokenizer's own guess.
    /// PER-SURFACE: re-analyzes the surface alone, so it serves tokens the sentence
    /// aligner could not place and callers holding no sentence at all — display
    /// tokens the aligner DID place take their reading from `annotations` instead.
    public let reading: (@Sendable (String) -> String?)?
    /// The word's dictionary form, so SRS-driven visibility can key off the lemma.
    /// Per-surface, with the same fallback role as `reading`.
    public let baseForm: (@Sendable (String) -> String?)?
    /// The JMdict-validated reading + placement spans; nil keeps the build
    /// byte-identical to the untiered path. Per-surface fallback: the tier here
    /// re-derives the reading it validates, so the annotated path uses
    /// `annotatedPayload` instead.
    public let payload: (@Sendable (String) -> ReadingPayload?)?
    /// English gloss for a katakana loanword (コミュニケーション → "communication").
    public let gloss: (@Sendable (String) -> String?)?
    /// Per-word pitch patterns for one already-tokenized sentence, aligned onto the
    /// caller's word split. Nil when no Open JTalk dictionary is configured, since
    /// pitch accent comes from the same analysis the readings do.
    public let pitch: (@Sendable ([String]) -> [[MoraPitch]?])?
    /// Per-sentence, in-context annotations for one already-tokenized sentence:
    /// ONE frontend pass over the joined surfaces, aligned onto the caller's word
    /// split (concatenating across analysis words; nil on a boundary straddle).
    /// This is where display readings come from — a lone surface's re-analysis can
    /// re-tokenize it (静か → 静+か → しずかか), the sentence's cannot.
    public let annotations: (@Sendable ([String]) -> [TokenAnnotation?])?
    /// The JMdict tier over an aligned token's IN-CONTEXT reading: validates the
    /// annotation's reading (repairing an impossible one with spans) instead of
    /// re-deriving a reading from the surface alone.
    public let annotatedPayload: (@Sendable (String, TokenAnnotation) -> ReadingPayload?)?
    /// A joined candidate form's JMdict readings, each with its placement spans when the
    /// exact (form, reading) pair has a JmdictFurigana row. Feeds the compound join, which
    /// repairs a compound the display tiling split across analysis words (運転手 rendered
    /// うんてんて from 運転 + 手). Nil opts the join out entirely, which is what every
    /// caller got before this member existed.
    public let compoundReadings: (@Sendable (String) -> [ReadingPayload])?
    /// Whether the ordinary dictionary can account for a reading of a surface: any entry whose
    /// kanji form BEGINS WITH the surface having a reading that begins with ours. This is the
    /// gate on author-ruby propagation - the reader takes the author's own ruby for a surface
    /// only when our analysis produced something no dictionary form supports (つかさなみ over
    /// 司波), never when it produced a defensible alternative (のぞ over 覗, which 覗く accounts
    /// for). Nil turns the propagation off entirely.
    public let readingCorroborated: (@Sendable (String, String) -> Bool)?

    /// The wiring for a Japanese document, or `.none` when no Open JTalk dictionary is
    /// configured — in which case the tokenizer falls back to `CFStringTokenizer` and
    /// the reader still works, just without true readings.
    ///
    /// - Parameters:
    ///   - dictionary: the JMdict store, when one is ready. Passing nil keeps
    ///     the tier and the gloss off (and costs no dictionary queries at all).
    ///   - reader: the Open JTalk reader to wire the readings through. Defaults to
    ///     `JapaneseReader()`, which resolves the PROCESS-GLOBAL configured dictionary
    ///     (so every existing caller keeps the same reader it had). Passing nil
    ///     explicitly drives the degraded "no reader" wiring WITHOUT reading process
    ///     state, which lets a test exercise that path deterministically instead of
    ///     depending on whether a sibling suite has configured a dictionary.
    public static func providers(
        dictionary: JMDictStore?,
        reader: JapaneseReader? = JapaneseReader()
    ) -> JapaneseFurigana {
        var gloss: (@Sendable (String) -> String?)?
        if let dictionary {
            gloss = { dictionary.englishGloss(forKatakana: $0) }
        }
        guard let reader else {
            return JapaneseFurigana(reading: nil, baseForm: nil, payload: nil, gloss: gloss,
                                    pitch: nil)
        }
        // Display furigana comes from the SENTENCE: `annotations` runs one in-context
        // analysis over the joined surfaces and aligns it onto the caller's split. The
        // per-surface closures below remain as the fallback for unaligned tokens and
        // for callers with no sentence; both paths use the RECONCILED reading — `pron`
        // (correct sound changes, 八百 → はっぴゃく) with `read`'s orthographic long
        // vowels swapped in (方 → ほう, not the phonetic ほお). TTS keeps `pron` on its
        // own path, so audio is unchanged by any of this.
        let reading: @Sendable (String) -> String? = { reader.furiganaReading(for: $0) }
        let baseForm: @Sendable (String) -> String? = { reader.baseForm(for: $0) }
        return JapaneseFurigana(
            reading: reading,
            baseForm: baseForm,
            // The tier validates/repairs the DISPLAY reading only; the spoken text is
            // untouched. A nil dictionary keeps the build identical to the pre-tier path.
            payload: FuriganaTier.payloadProvider(dictionary: dictionary,
                                                  reading: reading, baseForm: baseForm),
            gloss: gloss,
            // Pitch is drawn over the furigana, so it rides along with it rather than
            // making every app re-derive the analyze/group/align order.
            pitch: { PitchPattern.alignedPatterns(forSurfaces: $0, using: reader) },
            annotations: { surfaces in
                FuriganaAlignment.align(surfaces: surfaces,
                                        words: reader.furiganaWords(in: surfaces.joined()))
            },
            annotatedPayload: FuriganaTier.annotatedPayloadProvider(dictionary: dictionary),
            // Same dictionary gate as `payload`: the join reads the store the tier already
            // reads. Built HERE rather than beside `gloss` so the no-reader path keeps nil
            // and stays observably what it was - without a reader there is no pass-1 ruby
            // for the join to correct, so a closure there would be inert as well as new.
            compoundReadings: compoundReadings(dictionary: dictionary),
            // Same dictionary gate as the join, for the same reason: the seed would answer
            // "uncorroborated" for almost everything, and uncorroborated is the branch that
            // ACTS - it would propagate an author's ruby over readings 46 entries simply do
            // not cover.
            readingCorroborated: readingCorroborated(dictionary: dictionary)
        )
    }

    /// A joined form's JMdict readings plus placement spans, memoized per form.
    ///
    /// Memoization is load-bearing, not a nicety. The join probes merged candidate forms
    /// on surfaces that are mostly NOT compounds, and `KaraokeWord.compoundOverrides`
    /// calls this twice per form (once for the reading list, once for the spans), each
    /// with a nested per-reading `furiganaSegments` query. Unmemoized that is a doubled
    /// SQLite round trip per candidate per token on the render path. Misses are cached
    /// too: an empty result for a non-compound is the common case and must not re-query.
    ///
    /// The BUNDLED SEED is refused. It is a non-nil store, so it would otherwise drive the
    /// join off 46 entries and 5 furigana rows. That is not merely weaker than the full
    /// dictionary, it can be worse than nothing: when the longest form is unknown the join
    /// falls back to shorter known subruns, so sparse coverage can produce an override that
    /// full coverage would have suppressed by consuming the longer form. Passing nil leaves
    /// the text as it renders today. `Tools/FuriganaQA`'s `SeedGuard` already refuses the
    /// seed for the same reason; this keeps the shipping path consistent with the harness
    /// that grades it.
    static func compoundReadings(
        dictionary: JMDictStore?
    ) -> (@Sendable (String) -> [ReadingPayload])? {
        guard let dictionary, !dictionary.isUsingBundledSeed else { return nil }
        let cache = Mutex<[String: [ReadingPayload]]>([:])
        return { form in
            if let hit = cache.withLock({ $0[form] }) { return hit }
            let payloads = dictionary.kanaReadings(forForm: form).map { reading in
                let spans = dictionary.furiganaSegments(form: form, reading: reading)
                    .map { ReadingSpan(range: $0.range, kana: $0.kana) }
                return ReadingPayload(reading: reading, spans: spans.isEmpty ? nil : spans)
            }
            cache.withLock { $0[form] = payloads }
            return payloads
        }
    }

    /// The corroboration gate, memoized per surface.
    ///
    /// Memoization matters here for the same reason it does on the join: the query runs on the
    /// render path, once per candidate surface per segment, and a prefix scan over a common
    /// kanji reads up to 1,890 rows. Misses cache too - most surfaces never reach the gate
    /// twice, but a main character's name reaches it on every page.
    ///
    /// The BUNDLED SEED is refused, as it is for the join. A 46-entry dictionary corroborates
    /// nothing, and "not corroborated" is the branch that acts.
    static func readingCorroborated(
        dictionary: JMDictStore?
    ) -> (@Sendable (String, String) -> Bool)? {
        guard let dictionary, !dictionary.isUsingBundledSeed else { return nil }
        let cache = Mutex<[String: Bool]>([:])
        return { surface, ours in
            // Keyed on the PAIR: the same surface is asked about with the reading we actually
            // rendered, and that can differ between occurrences (the sentence analysis has
            // context the surface alone does not).
            let key = surface + "\u{1}" + ours
            if let hit = cache.withLock({ $0[key] }) { return hit }
            let answer = dictionary.corroborates(form: surface, reading: ours)
            cache.withLock { $0[key] = answer }
            return answer
        }
    }

    public init(
        reading: (@Sendable (String) -> String?)?,
        baseForm: (@Sendable (String) -> String?)?,
        payload: (@Sendable (String) -> ReadingPayload?)?,
        gloss: (@Sendable (String) -> String?)?,
        pitch: (@Sendable ([String]) -> [[MoraPitch]?])? = nil,
        annotations: (@Sendable ([String]) -> [TokenAnnotation?])? = nil,
        annotatedPayload: (@Sendable (String, TokenAnnotation) -> ReadingPayload?)? = nil,
        // Trailing and defaulted so the narrow call site the degraded path uses
        // - JapaneseFurigana(reading:baseForm:payload:gloss:) - keeps compiling unchanged.
        compoundReadings: (@Sendable (String) -> [ReadingPayload])? = nil,
        readingCorroborated: (@Sendable (String, String) -> Bool)? = nil
    ) {
        self.reading = reading
        self.baseForm = baseForm
        self.payload = payload
        self.gloss = gloss
        self.pitch = pitch
        self.annotations = annotations
        self.annotatedPayload = annotatedPayload
        self.compoundReadings = compoundReadings
        self.readingCorroborated = readingCorroborated
    }
}
