import KBCore
import Foundation

/// The ruby-segment builders for `KaraokeWord`: how a token's furigana is woven from
/// author-supplied source ruby, the in-context sentence annotation, and the OpenJTalk
/// fallback. Split out of `KaraokeWord.swift` to keep that type under the house
/// `type_body_length` limit; no behavior changes with the move.
///
/// The tiling invariant every builder here preserves: the returned segments' `text`
/// concatenates back to the token's surface.
extension KaraokeWord {
    /// Source-ruby weave for a token carrying an in-context annotation: author kana
    /// verbatim over each covered span, and every uncovered gap resolved BY POSITION
    /// against the annotation's part offsets — a gap whose UTF-16 edges both fall on
    /// part boundaries takes those parts' readings (through the annotated tier when
    /// one is injected); any other gap renders plain. Nothing here ever re-analyzes
    /// a surface in isolation.
    static func annotatedSourceRubySegments(
        surface: String,
        sourceRuby: [RubyRun],
        annotation: TokenAnnotation,
        annotatedPayload: ((String, TokenAnnotation) -> ReadingPayload?)?
    ) -> [RubySegment] {
        let runs = sourceRuby.sorted { $0.lower < $1.lower }
        let length = surface.utf16.count
        var segments: [RubySegment] = []
        var cursor = 0
        for run in runs {
            let lower = max(cursor, run.lower), upper = min(length, run.upper)
            guard lower < upper else { continue }
            if lower > cursor {
                appendAnnotatedGap(surface, range: cursor..<lower, annotation: annotation,
                                   annotatedPayload: annotatedPayload, into: &segments)
            }
            segments.append(RubySegment(text: utf16Slice(surface, lower, upper), reading: run.reading))
            cursor = upper
        }
        if cursor < length {
            appendAnnotatedGap(surface, range: cursor..<length, annotation: annotation,
                               annotatedPayload: annotatedPayload, into: &segments)
        }
        return segments
    }

    /// One uncovered gap: positional part resolution, then the same kanji-only
    /// annotator path the per-surface gaps take — with the SUB-annotation's reading,
    /// never an isolated re-analysis. An unresolvable gap renders plain.
    private static func appendAnnotatedGap(
        _ surface: String,
        range: Range<Int>,
        annotation: TokenAnnotation,
        annotatedPayload: ((String, TokenAnnotation) -> ReadingPayload?)?,
        into segments: inout [RubySegment]
    ) {
        let gap = utf16Slice(surface, range.lowerBound, range.upperBound)
        guard !gap.isEmpty else { return }
        if FuriganaAnnotator.containsKanji(gap),
           let sub = subAnnotation(annotation, utf16Range: range) {
            let fallback = openJTalkSegments(
                surface: gap, latinTranscription: nil,
                reading: { _ in sub.reading },
                baseForm: { _ in sub.baseForm },
                payload: { requested in annotatedPayload?(requested, sub) })
            if !fallback.isEmpty { segments.append(contentsOf: fallback); return }
        }
        segments.append(RubySegment(text: gap))
    }

    /// The contiguous run of annotation parts exactly tiling the token-local UTF-16
    /// `range`, as a sub-annotation — resolution by OFFSET, so repeated identical
    /// part surfaces with different readings can never swap. Nil when either edge
    /// falls mid-part.
    private static func subAnnotation(
        _ annotation: TokenAnnotation,
        utf16Range range: Range<Int>
    ) -> TokenAnnotation? {
        guard !annotation.parts.isEmpty else { return nil }
        var offset = 0
        var covered: [TokenAnnotation.Part] = []
        for part in annotation.parts {
            let partEnd = offset + part.surface.utf16.count
            if offset >= range.lowerBound, partEnd <= range.upperBound {
                covered.append(part)
            } else if partEnd > range.lowerBound, offset < range.upperBound {
                // The part straddles an edge of the requested range.
                return nil
            }
            offset = partEnd
        }
        let width = covered.reduce(0) { $0 + $1.surface.utf16.count }
        guard !covered.isEmpty, width == range.upperBound - range.lowerBound else { return nil }
        return TokenAnnotation(
            reading: covered.map(\.reading).joined(),
            baseForm: covered.count == 1 ? covered[0].baseForm : nil,
            parts: covered)
    }

    /// Merge adjacent tokens whenever a source-ruby run straddles their shared boundary,
    /// so an author reading over e.g. 走り出す (which `WordTokenizer` splits into 走り + 出す)
    /// stays ONE display word carrying the reading once — rather than the reading being
    /// duplicated over each split fragment. A run wholly inside a single token leaves the
    /// tokenization untouched (the common case, and every no-source caller). Offsets stay
    /// contiguous so highlight matching is unaffected.
    static func mergingAcrossRuby(
        _ tokens: [WordTokenizer.Token], sourceRuby: [RubyRun]
    ) -> [WordTokenizer.Token] {
        guard !sourceRuby.isEmpty else { return tokens }
        var merged: [WordTokenizer.Token] = []
        for token in tokens {
            if let last = merged.last,
               sourceRuby.contains(where: { $0.lower < token.offsets.lower && token.offsets.lower < $0.upper }) {
                merged[merged.count - 1] = WordTokenizer.Token(
                    offsets: WordOffsets(lower: last.offsets.lower, upper: token.offsets.upper),
                    text: last.text + token.text,
                    latinTranscription: nil,
                    tightLeading: last.tightLeading)
            } else {
                merged.append(token)
            }
        }
        return merged
    }

    /// Furigana segments for a token, applying the source-ruby precedence rule: an
    /// author-supplied `sourceRuby` span (token-local UTF-16 offsets) wins over the
    /// OpenJTalk/romaji reading for the base glyphs it covers, and the OpenJTalk/romaji
    /// path (`openJTalkSegments`) fills in only the kanji ranges NO source ruby covers.
    /// With no `sourceRuby` this is exactly the pre-existing behavior. The tiling
    /// invariant holds: the returned segments' `text` concatenates to `surface`.
    ///
    /// Internal (not private) so the precedence/fallback rule can be exercised directly
    /// over a whole multi-token surface (`走り出す`) — a shape `tokenize` never yields
    /// because `WordTokenizer` pre-splits it — in the partial-coverage fallback test.
    static func rubySegments(
        surface: String,
        latinTranscription: String?,
        reading: ((String) -> String?)?,
        baseForm: ((String) -> String?)? = nil,
        sourceRuby: [RubyRun] = [],
        payload: ((String) -> ReadingPayload?)? = nil
    ) -> [RubySegment] {
        guard !sourceRuby.isEmpty else {
            return openJTalkSegments(surface: surface, latinTranscription: latinTranscription,
                                     reading: reading, baseForm: baseForm, payload: payload)
        }
        return sourceRubySegments(surface: surface, sourceRuby: sourceRuby,
                                  reading: reading, baseForm: baseForm, payload: payload)
    }

    /// Weave the author's `sourceRuby` (each covered span reads its author kana verbatim,
    /// no OpenJTalk override inside it) with OpenJTalk fallback for uncovered kanji ranges
    /// and plain runs for uncovered kana. Walks the surface left to right by UTF-16 offset.
    private static func sourceRubySegments(
        surface: String,
        sourceRuby: [RubyRun],
        reading: ((String) -> String?)?,
        baseForm: ((String) -> String?)?,
        payload: ((String) -> ReadingPayload?)? = nil
    ) -> [RubySegment] {
        let runs = sourceRuby.sorted { $0.lower < $1.lower }
        let length = surface.utf16.count
        var segments: [RubySegment] = []
        var cursor = 0
        for run in runs {
            let lower = max(cursor, run.lower), upper = min(length, run.upper)
            guard lower < upper else { continue }
            if lower > cursor { appendGap(surface, range: cursor..<lower, reading: reading,
                                          baseForm: baseForm, payload: payload, into: &segments) }
            segments.append(RubySegment(text: utf16Slice(surface, lower, upper), reading: run.reading))
            cursor = upper
        }
        if cursor < length { appendGap(surface, range: cursor..<length, reading: reading,
                                       baseForm: baseForm, payload: payload, into: &segments) }
        return segments
    }

    /// Append the uncovered slice `range`: OpenJTalk segmentation when it holds kanji,
    /// otherwise (or if that yields nothing) one plain run — so tiling never breaks.
    private static func appendGap(
        _ surface: String,
        range: Range<Int>,
        reading: ((String) -> String?)?,
        baseForm: ((String) -> String?)?,
        payload: ((String) -> ReadingPayload?)? = nil,
        into segments: inout [RubySegment]
    ) {
        let gap = utf16Slice(surface, range.lowerBound, range.upperBound)
        guard !gap.isEmpty else { return }
        if FuriganaAnnotator.containsKanji(gap) {
            let fallback = openJTalkSegments(surface: gap, latinTranscription: nil,
                                             reading: reading, baseForm: baseForm, payload: payload)
            if !fallback.isEmpty { segments.append(contentsOf: fallback); return }
        }
        segments.append(RubySegment(text: gap))
    }

    /// Slice `surface` by a half-open UTF-16 offset range (source ruby offsets are UTF-16).
    private static func utf16Slice(_ surface: String, _ lower: Int, _ upper: Int) -> String {
        let utf16 = surface.utf16
        guard let from = utf16.index(utf16.startIndex, offsetBy: lower, limitedBy: utf16.endIndex),
              let to = utf16.index(utf16.startIndex, offsetBy: upper, limitedBy: utf16.endIndex),
              let start = from.samePosition(in: surface), let end = to.samePosition(in: surface)
        else { return "" }
        return String(surface[start..<end])
    }

    /// Furigana segments for a CJK token (kanji-bearing only). Prefers the injected
    /// `reading` (OpenJTalk); else derives kana from the token's Latin transcription
    /// (`WordTokenizer.Token.latinTranscription`).
    private static func openJTalkSegments(
        surface: String,
        latinTranscription: String?,
        reading: ((String) -> String?)?,
        baseForm: ((String) -> String?)? = nil,
        payload: ((String) -> ReadingPayload?)? = nil
    ) -> [RubySegment] {
        guard FuriganaAnnotator.containsKanji(surface) else { return [] }
        // The dictionary tier, when injected and it resolves this surface, supplies the
        // FINAL reading (validate/repair applied) and — when the exact pair has a
        // JmdictFurigana row — the placement spans that drive the ruby directly.
        var tierReading: String?
        // The dictionary's alternatives for this exact surface, so a reader can be offered
        // them on tap. `.analysis` rather than `.heuristic`: the sentence analysis chose this
        // reading WITH context, unlike the compound join's prefix guess, so it does not invite
        // a marker. Whether to surface it at all is the affordance's policy.
        var tierProvenance: ReadingProvenance?
        if let resolved = payload?(surface) {
            if resolved.candidates.count > 1 {
                tierProvenance = ReadingProvenance(
                    candidates: resolved.candidates, chosen: resolved.reading, source: .analysis)
            }
            if let spans = resolved.spans,
               let placed = segments(surface: surface, spans: spans) {
                let lemma = baseForm?(surface) ?? surface
                return placed.map {
                    RubySegment(text: $0.text, reading: $0.reading, baseForm: lemma,
                                pitch: $0.pitch, provenance: tierProvenance)
                }
            }
            tierReading = resolved.reading
        }
        let resolved: String?
        if let tierReading {
            resolved = tierReading
        } else if let injected = reading?(surface) {
            resolved = injected
        } else if let romaji = latinTranscription {
            resolved = FuriganaAnnotator.hiragana(fromRomaji: romaji)
        } else {
            resolved = nil
        }
        guard let hiragana = resolved else { return [] }
        let segments = FuriganaAnnotator.segments(token: surface, reading: hiragana)
        // Stamp every run of the word with its lemma (PRD F1 — the SRS unit is the lemma).
        // The lemma defaults to the surface when OpenJTalk can't deinflect it, so the
        // visibility predicate always has a key. Rendering ignores `baseForm`.
        guard !segments.isEmpty else { return segments }
        let lemma = baseForm?(surface) ?? surface
        // Provenance rides BOTH tier paths. The spans path returns early above; this is the
        // one taken when the (surface, reading) pair has no JmdictFurigana row, which is the
        // common case for a single-kanji heteronym and so is exactly where the alternatives
        // matter most. Stamping only the spans path would have left 辺 without them.
        return segments.map {
            RubySegment(text: $0.text, reading: $0.reading, baseForm: lemma,
                        pitch: $0.pitch, provenance: tierProvenance)
        }
    }
}
