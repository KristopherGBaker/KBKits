import Foundation

/// One display token's in-context annotation: the reading (and base form) the
/// SENTENCE analysis produced for it, as opposed to what re-analyzing the token
/// alone would guess. Produced by the per-sentence aligner in the Japanese
/// pipeline and consumed by `KaraokeWord`'s furigana path; it sits in KBCore
/// for the same reason `ReadingPayload` does — it is the shape of a reading's
/// provenance, not a detail of how one is derived or drawn.
///
/// A token with no annotation (the aligner returned nil for it) falls back to
/// the per-surface closures, which re-analyze the surface in isolation — the
/// path a token like 静か must NOT take, because its isolated re-analysis
/// re-tokenizes (静+か) and doubles the か.
public struct TokenAnnotation: Sendable, Hashable {
    /// One analysis word inside the token, tiling its surface in order. Parts
    /// let a consumer resolve a SLICE of the token — the gap beside author
    /// ruby — from the same sentence analysis, without re-analyzing anything.
    public struct Part: Sendable, Hashable {
        public let surface: String
        public let reading: String
        public let baseForm: String?

        public init(surface: String, reading: String, baseForm: String? = nil) {
            self.surface = surface
            self.reading = reading
            self.baseForm = baseForm
        }
    }

    /// The reconciled in-context reading (hiragana) for the whole token.
    public let reading: String
    /// The dictionary (base) form of the token's word, when the analysis has one.
    public let baseForm: String?
    /// The analysis words this annotation was built from, in order. Empty when
    /// the producer had no per-word breakdown; then only whole-token requests
    /// resolve.
    public let parts: [Part]

    public init(reading: String, baseForm: String? = nil, parts: [Part] = []) {
        self.reading = reading
        self.baseForm = baseForm
        self.parts = parts
    }
}
