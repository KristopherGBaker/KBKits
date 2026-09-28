public import KBCore

/// Maps one sentence's in-context analysis onto a caller's display tokens.
///
/// The display tokenizer (CFStringTokenizer on Apple, or any consumer's own
/// split) and OpenJTalk do not share word boundaries, so the in-context
/// readings cannot simply be zipped onto display tokens. This aligner walks
/// both tilings of the same text by character offset:
///
/// - a display token whose edges both fall on analysis boundaries gets an
///   annotation — the ordered concatenation of the covered words' readings,
///   and the single covered word's base form (a token spanning several words
///   has no one lemma, so `baseForm` is nil there);
/// - a display token whose edge falls MID-word gets nil, and later tokens
///   resynchronize by offset — a reading is never attached to a wrong surface;
/// - when the two tilings do not even cover the same text (the joined
///   surfaces differ), the result is EMPTY - not an array of nils.
///
/// That distinction is load-bearing, and it used to be lost. Both a tiling
/// FAILURE and a sentence where every display token merely straddles a word
/// boundary returned all-nil, and a caller could not tell them apart:
///
///   四月     tiles fine (四|月 against the analysis word 四月); nothing placed
///   27日     Open JTalk answers 二十七日, so the tilings cover different text
///
/// The first is safe to re-probe with the tokens merged, and is exactly what
/// `KaraokeWord.regroupedForAnnotation` exists to repair. The second is not:
/// the analysis does not describe this text at all, so any merge would be a
/// guess. Returning a wrong-LENGTH array for the second is what lets every
/// caller reject it with the length check it already performs, while an
/// all-nil array of the right length now means only "tiled, placed nothing".
///
/// Pure and frontend-free, like `PitchPattern`'s aligner: unit-testable with
/// fake words, no dictionary required.
public enum FuriganaAlignment {
    public static func align(
        surfaces: [String],
        words: [JapaneseReader.Word]
    ) -> [TokenAnnotation?] {
        // The guard: both tilings must cover the same characters, or nothing
        // can be trusted to line up. EMPTY, not all-nil - see the note above.
        guard !surfaces.isEmpty,
              surfaces.joined() == words.map(\.surface).joined() else {
            return []
        }

        // Character offsets where analysis words begin/end.
        var wordStarts: [Int: Int] = [:]  // offset -> index of word starting there
        var offset = 0
        for (index, word) in words.enumerated() {
            wordStarts[offset] = index
            offset += word.surface.count
        }
        let textEnd = offset

        var annotations: [TokenAnnotation?] = []
        var tokenStart = 0
        for surface in surfaces {
            let tokenEnd = tokenStart + surface.count
            defer { tokenStart = tokenEnd }
            // Both edges must fall on word boundaries (the end of the text is
            // a boundary too).
            guard let firstWord = wordStarts[tokenStart],
                  tokenEnd == textEnd || wordStarts[tokenEnd] != nil else {
                annotations.append(nil)
                continue
            }
            var covered: [JapaneseReader.Word] = []
            var cursor = tokenStart
            var index = firstWord
            while cursor < tokenEnd, index < words.count {
                covered.append(words[index])
                cursor += words[index].surface.count
                index += 1
            }
            guard cursor == tokenEnd else {
                annotations.append(nil)
                continue
            }
            annotations.append(TokenAnnotation(
                reading: covered.map(\.reading).joined(),
                baseForm: covered.count == 1 ? covered[0].baseForm : nil,
                // The per-word breakdown rides along so a consumer can resolve
                // a slice of the token (the gap beside author ruby) from the
                // same analysis.
                parts: covered.map {
                    TokenAnnotation.Part(surface: $0.surface, reading: $0.reading,
                                         baseForm: $0.baseForm)
                }
            ))
        }
        return annotations
    }
}
