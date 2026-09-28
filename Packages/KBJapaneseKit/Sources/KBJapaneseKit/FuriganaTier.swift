public import KBCore
public import KBDictionaryKit
import Synchronization

/// The JMdict furigana tier's adapter: maps P1's `ReadingValidator` verdicts over a
/// `ReadingDictionary` onto the DesignSystem `ReadingPayload` seam consumed by
/// `KaraokeWord`. Display-only — TTS/audio and document identity never touch this.
///
/// Policy (docs/jmdict-furigana-tier-plan.md): `consistent`/`unknown` keep OpenJTalk's
/// reconciled reading (a wrong override is worse than a missed fix); `impossible`
/// applies the repair reading. Placement spans ride along only when the exact FINAL
/// (form, reading) pair has a JmdictFurigana row — they also gate the okurigana join
/// on the KBReadingKit side (一+つ), so spans are never fabricated here.
public enum FuriganaTier {
    /// The tier over the LIVE OpenJTalk reader, or nil when no Open JTalk dictionary is
    /// configured. The same wiring `JapaneseFurigana.providers` uses, exposed on its own
    /// so a test can drive the real end-to-end path.
    public static func liveProvider(
        dictionary: (any ReadingDictionary)?
    ) -> (@Sendable (String) -> ReadingPayload?)? {
        guard let reader = JapaneseReader() else { return nil }
        return payloadProvider(dictionary: dictionary,
                               reading: { reader.furiganaReading(for: $0) },
                               baseForm: { reader.baseForm(for: $0) })
    }

    /// The payload closure for `ReaderContent.build`, or nil when there is no ready
    /// dictionary — nil keeps the whole build byte-identical to the pre-tier path
    /// (no validator invocation, no store query). `reading`/`baseForm` are the same
    /// OpenJTalk closures the build already injects.
    public static func payloadProvider(
        dictionary: (any ReadingDictionary)?,
        reading: @escaping @Sendable (String) -> String?,
        baseForm: @escaping @Sendable (String) -> String?
    ) -> (@Sendable (String) -> ReadingPayload?)? {
        guard let dictionary else { return nil }
        let validator = ReadingValidator(dictionary: dictionary)
        // Real text repeats surfaces heavily (particles-adjacent joins re-probe the same
        // merges), and each miss costs an OpenJTalk frontend pass + dictionary queries —
        // cache per surface. Lifetime is one provider (one reader build), so the cache
        // is naturally bounded by the document's unique-token count.
        let cache = Mutex<[String: ReadingPayload?]>([:])
        return { surface in
            if let hit = cache.withLock({ $0[surface] }) { return hit }
            let value = payload(surface: surface, validator: validator,
                                reading: reading, baseForm: baseForm)
            cache.withLock { $0[surface] = value }
            return value
        }
    }

    /// The tier over a KNOWN in-context reading: validates the reading the SENTENCE
    /// analysis produced for this surface rather than re-deriving one from the surface
    /// alone (whose isolated re-analysis can differ — the 静か → しずかか class).
    /// `consistent`/`unknown` keep the given reading; `impossible` repairs with spans,
    /// exactly as the per-surface path does. Nil dictionary keeps the tier off.
    public static func annotatedPayloadProvider(
        dictionary: (any ReadingDictionary)?
    ) -> (@Sendable (String, TokenAnnotation) -> ReadingPayload?)? {
        guard let dictionary else { return nil }
        let validator = ReadingValidator(dictionary: dictionary)
        let cache = Mutex<[String: ReadingPayload?]>([:])
        return { surface, annotation in
            let key = "\(surface)|\(annotation.reading)"
            if let hit = cache.withLock({ $0[key] }) { return hit }
            let value = payload(surface: surface, validator: validator,
                                reading: { _ in annotation.reading },
                                baseForm: { _ in annotation.baseForm })
            cache.withLock { $0[key] = value }
            return value
        }
    }

    /// One surface (a token, or a merged okurigana-join candidate) through the
    /// validate/repair flow. Kana-only/katakana-only/non-CJK surfaces return nil
    /// BEFORE any validator or store work — they have nothing to fix. The reading
    /// closure supplies the reading under validation: the in-context sentence value
    /// on the annotated path, or the per-surface fallback's own resolution.
    static func payload(
        surface: String,
        validator: ReadingValidator,
        reading: (String) -> String?,
        baseForm: (String) -> String?
    ) -> ReadingPayload? {
        guard surface.contains(where: isKanji) else { return nil }
        // The analyser knows nothing about a rare or old-form kanji (啣, 縊, 瞠, 魘, 搔) and
        // answers with nothing, so the reader drew NO ruby over a kanji - the one thing furigana
        // exists to prevent. Ask the dictionary before giving up; it can read 268 of the 551
        // such tokens in the corpus, mostly through the inflected form (啣え from 啣える).
        guard let ojtReading = reading(surface), !ojtReading.isEmpty,
              !isOkuriganaOnly(reading: ojtReading, surface: surface) else {
            guard let rescued = validator.readingWhenUnreadable(surface: surface) else { return nil }
            // Candidates ride along so a rescued reading the reader disagrees with is one tap
            // from being corrected, which a blank kanji never was.
            return ReadingPayload(reading: rescued.repair.reading,
                                  spans: rescued.repair.segmentation.map(spans),
                                  candidates: rescued.candidates)
        }
        // Lazy baseForm: it costs a second frontend pass, and the validator only needs
        // it when the exact-form check misses.
        // `detailed` rather than `validate`: it returns the candidate readings the validator
        // already fetched, which a reader-facing affordance needs and which cost nothing extra
        // here. Same verdict, same policy.
        let (verdict, candidates) = validator.detailed(surface: surface, ojtReading: ojtReading,
                                                       baseForm: { baseForm(surface) })
        switch verdict {
        case .consistent(let segmentation):
            return ReadingPayload(reading: ojtReading, spans: segmentation.map(spans),
                                  candidates: candidates)
        case .unknown:
            return ReadingPayload(reading: ojtReading, spans: nil, candidates: candidates)
        case .impossible(let repair):
            guard let repair else {
                return ReadingPayload(reading: ojtReading, spans: nil, candidates: candidates)
            }
            return ReadingPayload(reading: repair.reading,
                                  spans: repair.segmentation.map(spans), candidates: candidates)
        }
    }

    /// A "reading" that is only the token's own okurigana carries nothing about the KANJI.
    ///
    /// Open JTalk answers 搔い with い - it does not know 搔, so it echoes the kana it does know.
    /// That is not empty, so it passed the emptiness guard, and then no ruby could be placed:
    /// the annotator matched い to the trailing い and had nothing left for 搔. On screen the
    /// kanji stayed bare while 瞠 and 縊 beside it - bare tokens with no okurigana - were both
    /// rescued. Treated as unreadable, so the dictionary is asked instead.
    static func isOkuriganaOnly(reading: String, surface: String) -> Bool {
        let trailing = surface.reversed().prefix { !isKanji($0) }.reversed()
        guard !trailing.isEmpty, trailing.count < surface.count else { return false }
        return reading == String(trailing)
    }

    /// DictionaryKit spans → the UI-side mirror type (DesignSystem must not import GRDB).
    private static func spans(_ spans: [FuriganaSpan]) -> [ReadingSpan] {
        spans.map { ReadingSpan(range: $0.range, kana: $0.kana) }
    }

    /// CJK ideographs (URO + Extension A) and the iteration mark 々 — mirrors the
    /// validator's own gate so non-kanji surfaces never reach it.
    private static func isKanji(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || scalar.value == 0x3005
        }
    }
}
