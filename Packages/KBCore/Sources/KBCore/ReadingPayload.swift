import Foundation

/// One span of a token's characters with its furigana kana, as supplied by the
/// dictionary tier. `range` is over the surface's `Character` positions; `kana` is
/// nil at okurigana positions (the character reads as itself, so it takes no ruby).
///
/// This deliberately mirrors, rather than imports, the dictionary package's span type,
/// so neither the UI nor the Japanese pipeline has to pull GRDB/KBDictionaryKit to name a
/// furigana span. It sits in KBCore because both of them need it: it is the shape of a
/// reading, not a detail of how one is drawn.
public struct ReadingSpan: Sendable, Hashable {
    public let range: Range<Int>
    public let kana: String?

    public init(range: Range<Int>, kana: String?) {
        self.range = range
        self.kana = kana
    }
}

/// The final display reading for a token, plus optional per-character placement
/// spans. Produced by the injected reading-tier closure (`KBFeatureKit`'s
/// validate/repair adapter over JMdict) and consumed by `KaraokeWord`'s furigana
/// path:
///
/// - `spans` non-nil ⇒ the exact (surface, reading) pair is dictionary-confirmed
///   with JmdictFurigana segmentation — the spans drive per-kanji ruby placement,
///   and ONLY such payloads may be applied across an okurigana token join.
/// - `spans` nil ⇒ placement falls back to the existing `FuriganaAnnotator.segments`
///   alignment over `reading` (unchanged behavior, possibly with a repaired reading).
public struct ReadingPayload: Sendable, Hashable {
    public let reading: String
    public let spans: [ReadingSpan]?
    /// Every kana reading the dictionary lists for this exact surface, INCLUDING `reading`
    /// when the dictionary corroborated it. Empty when the dictionary does not know the form.
    ///
    /// Carried so a reader can be offered the alternatives for a word they tap. The validator
    /// fetches these on the way to its verdict and used to discard them; re-querying would
    /// double the dictionary reads on the render path for information already in hand.
    ///
    /// This is DATA, not a decision to mark anything: most kanji words list several readings,
    /// so treating a non-empty list as "ambiguous" would mark half a book. Whether a word is
    /// worth flagging is the affordance's policy, not this type's.
    public let candidates: [String]

    public init(reading: String, spans: [ReadingSpan]? = nil, candidates: [String] = []) {
        self.reading = reading
        self.spans = spans
        self.candidates = candidates
    }
}
