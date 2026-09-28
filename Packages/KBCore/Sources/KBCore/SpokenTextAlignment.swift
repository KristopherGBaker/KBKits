import Foundation

/// Bridges a **non-length-preserving** spoken transform back to the reader's
/// display words so the karaoke cursor stays in sync.
///
/// The problem: the timing deriver produces `WordToken`s whose UTF-16 offsets
/// index the *spoken* text (e.g. "nineteen ninety-five"), but the reader draws —
/// and highlights — the *display* text ("1995"). With a length-preserving
/// transform (hyphen→space) the offsets coincide; with an expansion they don't,
/// so every token after the first expansion would point at the wrong display
/// character.
///
/// The fix: align display words to spoken words once (cheap word-level LCS), then
/// rewrite each timeline `WordToken`'s spoken offset to the *display* span of the
/// display word it falls in. Several spoken tokens of one expanded display word
/// all collapse onto that word's display span, so it highlights as a single unit
/// for the whole expansion's duration — no drift for the rest of the sentence.
public enum SpokenTextAlignment {

    /// A display word's span in display text paired with its span in spoken text.
    public struct WordSpan: Sendable, Equatable {
        public let display: WordOffsets
        public let spoken: WordOffsets
        public init(display: WordOffsets, spoken: WordOffsets) {
            self.display = display
            self.spoken = spoken
        }
    }

    /// Align `display` text to its `spoken` (normalized) form at word granularity.
    /// Returns one `WordSpan` per display word. Identical runs map 1:1 by position;
    /// a changed run maps every display word in it to the whole changed spoken
    /// region (so an expanded token claims all of its expansion).
    ///
    /// `segmenter` is threaded rather than defaulted-and-forgotten because alignment is one
    /// of the places CJK word boundaries become what a reader SEES: the placeholder
    /// segmenter used off Apple platforms splits per character, which maps a two-character
    /// compound onto two highlights instead of one. See `CJKWordSegmenter`.
    public static func align(
        display: String,
        spoken: String,
        segmenter: any CJKWordSegmenter = WordTokenizer.platformCJKSegmenter
    ) -> [WordSpan] {
        let displayWords = WordTokenizer.tokenize(display, segmenter: segmenter)
        let spokenWords = WordTokenizer.tokenize(spoken, segmenter: segmenter)
        guard !displayWords.isEmpty else { return [] }
        // Fast path: unchanged text (the common case — most sentences need no
        // expansion) maps 1:1.
        if display == spoken, displayWords.count == spokenWords.count {
            return zip(displayWords, spokenWords).map {
                WordSpan(display: $0.offsets, spoken: $1.offsets)
            }
        }
        return alignByLCS(displayWords: displayWords, spokenWords: spokenWords)
    }

    private static func alignByLCS(
        displayWords: [WordTokenizer.Token], spokenWords: [WordTokenizer.Token]
    ) -> [WordSpan] {
        let matches = longestCommonSubsequence(
            left: displayWords.map { $0.text.lowercased() },
            right: spokenWords.map { $0.text.lowercased() })

        var spans: [WordSpan] = []
        spans.reserveCapacity(displayWords.count)
        var prevDisplay = 0
        var prevSpoken = 0
        // Anchor on each matched pair, mapping the changed gap before it as a block,
        // then the matched word 1:1.
        for (displayIndex, spokenIndex) in matches {
            mapGap(displayWords: displayWords, spokenWords: spokenWords,
                   displayRange: prevDisplay..<displayIndex,
                   spokenRange: prevSpoken..<spokenIndex, into: &spans)
            spans.append(WordSpan(display: displayWords[displayIndex].offsets,
                                  spoken: spokenWords[spokenIndex].offsets))
            prevDisplay = displayIndex + 1
            prevSpoken = spokenIndex + 1
        }
        mapGap(displayWords: displayWords, spokenWords: spokenWords,
               displayRange: prevDisplay..<displayWords.count,
               spokenRange: prevSpoken..<spokenWords.count, into: &spans)
        return spans
    }

    /// Map a run of changed display words to the spoken region they expanded into.
    /// Every display word in the gap points at the *whole* spoken gap, so a single
    /// display token that became many spoken words highlights as one unit; if the
    /// gap has no spoken words (a deletion) it collapses to a zero-width point.
    private static func mapGap(
        displayWords: [WordTokenizer.Token],
        spokenWords: [WordTokenizer.Token],
        displayRange: Range<Int>,
        spokenRange: Range<Int>,
        into spans: inout [WordSpan]
    ) {
        guard !displayRange.isEmpty else { return }
        let spokenSpan: WordOffsets
        if spokenRange.isEmpty {
            // Deletion: anchor at the start of the next spoken word (or end).
            let anchor = spokenRange.lowerBound < spokenWords.count
                ? spokenWords[spokenRange.lowerBound].offsets.lower
                : (spokenWords.last?.offsets.upper ?? 0)
            spokenSpan = WordOffsets(lower: anchor, upper: anchor)
        } else {
            spokenSpan = WordOffsets(lower: spokenWords[spokenRange.lowerBound].offsets.lower,
                                     upper: spokenWords[spokenRange.upperBound - 1].offsets.upper)
        }
        for index in displayRange {
            spans.append(WordSpan(display: displayWords[index].offsets, spoken: spokenSpan))
        }
    }

    /// Classic LCS, returning matched (leftIndex, rightIndex) pairs in order. Inputs
    /// are sentence-length word arrays, so the O(n·m) table is tiny.
    static func longestCommonSubsequence(left: [String], right: [String]) -> [(Int, Int)] {
        let rows = left.count
        let cols = right.count
        guard rows > 0, cols > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for col in stride(from: cols - 1, through: 0, by: -1) {
                if left[row] == right[col] {
                    table[row][col] = table[row + 1][col + 1] + 1
                } else {
                    table[row][col] = max(table[row + 1][col], table[row][col + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0
        var col = 0
        while row < rows, col < cols {
            if left[row] == right[col] {
                pairs.append((row, col)); row += 1; col += 1
            } else if table[row + 1][col] >= table[row][col + 1] {
                row += 1
            } else {
                col += 1
            }
        }
        return pairs
    }

    /// Rewrite a timeline whose word offsets index `spoken` text so they index
    /// `display` text instead, using `spans` from `align`. Each timeline word is
    /// mapped to the display word whose spoken span contains it; words that fall in
    /// the same expanded span share that display span (highlighting as one unit),
    /// and their durations sum so the unit stays lit for the whole expansion.
    public static func remap(
        timeline: HighlightTimeline,
        display: String,
        spoken: String,
        segmenter: any CJKWordSegmenter = WordTokenizer.platformCJKSegmenter
    ) -> HighlightTimeline {
        let spans = align(display: display, spoken: spoken, segmenter: segmenter)
        guard !spans.isEmpty else { return timeline }

        var remapped: [WordToken] = []
        remapped.reserveCapacity(timeline.words.count)
        for token in timeline.words {
            let displaySpan = displaySpan(forSpokenOffset: token.offsets.lower, in: spans)
                ?? token.offsets
            if let last = remapped.last, last.offsets == displaySpan {
                // Same expanded display word — fold this token's time into it.
                remapped[remapped.count - 1] = WordToken(
                    offsets: last.offsets,
                    start: last.start,
                    duration: max(0, token.end - last.start))
            } else {
                remapped.append(WordToken(offsets: displaySpan,
                                          start: token.start, duration: token.duration))
            }
        }
        return HighlightTimeline(
            segmentID: timeline.segmentID,
            audioDuration: timeline.audioDuration,
            words: remapped,
            confidence: timeline.confidence,
            provenance: timeline.provenance)
    }

    private static func displaySpan(
        forSpokenOffset offset: Int, in spans: [WordSpan]
    ) -> WordOffsets? {
        // Containing span, else the nearest span that starts at/after the offset
        // (handles a token landing in inter-word spoken whitespace).
        var fallback: WordSpan?
        for span in spans {
            if span.spoken.lower <= offset && offset < span.spoken.upper { return span.display }
            if span.spoken.lower >= offset, fallback == nil { fallback = span }
        }
        return fallback?.display
    }
}
