import Foundation

/// Spoken-only text transforms — applied to a segment's `text` (the synthesized
/// side) without touching `displayText`. These are **length-preserving** so every
/// UTF-16 offset (timeline word spans, highlight ranges, persisted positions)
/// stays valid: the reader still shows the original word and highlights it as one
/// unit while the synthesizer speaks the adjusted form.
public enum SpokenTextTransform {

    /// Replace a hyphen *inside a compound word* (a letter on each side) with a
    /// space, e.g. "staff-level" → "staff level", "lip-curlingly" → "lip
    /// curlingly". Kokoro (and AVSpeech) otherwise treat the hyphen as a break and
    /// insert an awkward pause. Only letter–hyphen–letter is touched, so number
    /// ranges ("1-2"), dates, and spaced dashes are left alone.
    public static func hyphenatedCompoundsToSpaces(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isHyphen) else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        for index in scalars.indices {
            let scalar = scalars[index]
            if isHyphen(scalar),
               index > 0, index < scalars.count - 1,
               scalars[index - 1].properties.isAlphabetic,
               scalars[index + 1].properties.isAlphabetic {
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// ASCII hyphen-minus (U+002D) and the true Unicode hyphen (U+2010). En/em
    /// dashes are deliberately excluded — they're sentence punctuation, not
    /// compound-word joiners.
    private static func isHyphen(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{2D}" || scalar == "\u{2010}"
    }
}

public extension TextSegment {
    /// A copy with `text` (the spoken side) run through `transform`, leaving
    /// `displayText`/`styleRuns`/everything else untouched. Returns `self`
    /// unchanged when the transform is a no-op, avoiding needless copies.
    /// The transform receives this segment's `sentenceIndex` alongside its text.
    ///
    /// A global rule ("always say TERM as REPLACEMENT") needs only the text, but a correction
    /// bound to ONE OCCURRENCE cannot be expressed without knowing which segment it is: 十分 is
    /// legitimately じゅっぷん in one sentence of a book and じゅうぶん in another, so a
    /// text-only transform can apply a reader's fix to every occurrence or none. The scheduler
    /// already has the segment in hand; only this signature was throwing the identity away.
    func applyingSpokenTransform(_ transform: (String, Int) -> String) -> TextSegment {
        let transformed = transform(text, sentenceIndex)
        guard transformed != text else { return self }
        return TextSegment(
            id: id, documentID: documentID, sentenceIndex: sentenceIndex,
            text: transformed, sourceRange: sourceRange,
            displayText: displayText, styleRuns: styleRuns, blockStyle: blockStyle,
            listInfo: listInfo, rubyRuns: rubyRuns)
    }
}
