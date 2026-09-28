import KBCore
import Foundation

/// The two-pass plumbing behind `KaraokeWord.tokenize`'s dictionary-decided compound join:
/// resolving each token's ruby with the join absent (pass 1), turning those segments into the
/// reading actually rendered, and offering the run to the join decision (pass 2). Kept out of
/// `KaraokeWord.swift` so neither the struct body nor `KaraokeWord+ReadingTier.swift` grows.
extension KaraokeWord {

    /// The per-surface providers threaded through the reading paths, bundled so
    /// `resolveTokenRuby` stays within the parameter-count limit.
    struct TokenRubyProviders {
        let reading: ((String) -> String?)?
        let baseForm: ((String) -> String?)?
        let payload: ((String) -> ReadingPayload?)?
        let annotatedPayload: ((String, TokenAnnotation) -> ReadingPayload?)?
    }

    /// One token's ruby with the compound join ABSENT — exactly the resolution `tokenize` did
    /// inline before the join existed. An okurigana override wins; then an author-ruby weave
    /// against the annotation; otherwise the per-surface path. Only this token's own surface is
    /// ever analyzed, never a merged one.
    static func resolveTokenRuby(
        token: WordTokenizer.Token,
        okuriganaOverride: [RubySegment]?,
        annotation rawAnnotation: TokenAnnotation?,
        sourceRuby: [RubyRun],
        providers: TokenRubyProviders
    ) -> [RubySegment] {
        // Rebase the segment-local source ruby onto this token's own 0-based offsets.
        let tokenRuby = RubyRun.rebased(sourceRuby, lower: token.offsets.lower, upper: token.offsets.upper)
        var tokenReading = providers.reading
        var tokenBaseForm = providers.baseForm
        var tokenPayload = providers.payload
        let annotation = rawAnnotation.flatMap { $0.reading.isEmpty ? nil : $0 }
        if let annotation, tokenRuby.isEmpty {
            // The token resolves whole from its sentence annotation, never from an isolated
            // per-surface re-analysis (静か alone becomes 静+か, doubling the か).
            tokenReading = { _ in annotation.reading }
            tokenBaseForm = { _ in annotation.baseForm }
            tokenPayload = { requested in providers.annotatedPayload?(requested, annotation) }
        }
        if let okuriganaOverride {
            return okuriganaOverride
        }
        if let annotation, !tokenRuby.isEmpty {
            return annotatedSourceRubySegments(surface: token.text, sourceRuby: tokenRuby,
                                               annotation: annotation,
                                               annotatedPayload: providers.annotatedPayload)
        }
        return rubySegments(surface: token.text, latinTranscription: token.latinTranscription,
                            reading: tokenReading, baseForm: tokenBaseForm,
                            sourceRuby: tokenRuby, payload: tokenPayload)
    }

    /// The reading a token's ruby segments actually render, by the SAME rule
    /// `Tools/FuriganaQA`'s `RenderedToken.renderedReading` uses: a segment's kana reading when
    /// it has one, else the segment's own text; an empty ruby renders its surface. Katakana is
    /// folded to hiragana so it never false-compares against a hiragana JMdict reading. Feeding
    /// the join decision THIS (not the annotation reading, which the tier may have discarded)
    /// is what makes the fix and the instrument agree on every run.
    static func renderedReading(segments: [RubySegment], surface: String) -> String {
        let parts = segments.isEmpty ? [RubySegment(text: surface)] : segments
        return parts.map { segment in
            if let reading = segment.reading, !reading.isEmpty { return normalizeKana(reading) }
            return normalizeKana(segment.text)
        }.joined()
    }

    /// Adapt the caller's single compound-join closure (a joined form -> its readings, each
    /// with optional spans) into the decision's two dictionary closures, key the decision by
    /// the reading each token actually rendered in pass 1, and run the join. A nil closure
    /// means the caller opted out: no overrides, no rendered-reading pass.
    static func compoundOverrides(
        tokens: [WordTokenizer.Token],
        baseRuby: [[RubySegment]],
        sourceRuby: [RubyRun],
        compoundReadings: ((String) -> [ReadingPayload])?
    ) -> JoinResult {
        guard let compoundReadings else { return JoinResult() }
        let rendered = tokens.indices.map {
            renderedReading(segments: baseRuby[$0], surface: tokens[$0].text)
        }
        return compoundJoinOverrides(
            tokens: tokens, renderedReadings: rendered, sourceRuby: sourceRuby,
            // Collapse script variants BEFORE the decision. JMdict lists いまいち and
            // イマイチ as separate readings of 今一, but they are one reading in two scripts,
            // and counting them as two had two bad effects: the single-reading arm never
            // fired, and the spans tiebreak saw BOTH candidates resolve to the same
            // hiragana row (the lookup below matches normalised), so `withSpans.count == 2`
            // and the run was declined as ambiguous. Measured over an 18-book corpus, that
            // wrongly declined 今一 21 times and the same shape elsewhere.
            readings: { form in
                var seen = Set<String>()
                return compoundReadings(form).map(\.reading).filter { seen.insert(normalizeKana($0)).inserted }
            },
            spans: { form, reading in
                compoundReadings(form)
                    .first { normalizeKana($0.reading) == normalizeKana(reading) }
                    .flatMap { $0.spans }
            })
    }
}
