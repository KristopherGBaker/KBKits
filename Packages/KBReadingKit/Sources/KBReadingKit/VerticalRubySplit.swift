import Foundation

/// Splitting one word's reading across a column break.
///
/// A vertical column is short — twenty-odd characters — so a two-character compound landing on
/// a column boundary is ordinary, not an edge case. The horizontal reader answers this by
/// drawing the kana over the FIRST line's rect only and dropping the rest
/// (`ReaderTextLayoutView.drawAnnotation`), which is tolerable when a line holds sixty
/// characters and a straddle is rare. Transposed to vertical it is not: the first render of
/// this surface put きおく beside 記 at the foot of one column and きおく again beside 憶 at the
/// head of the next, because each column asked for the whole reading.
///
/// So vertical splits instead: each column carries the slice of the reading that belongs to the
/// base characters it actually holds, apportioned by position. 記憶[きおく] broken between the
/// two kanji reads き beside 記 and おく beside 憶 — which is also what a typesetter does.
public enum VerticalRubySplit {

    /// The slice of `reading` that belongs to base characters `baseRange` of a run `baseLength`
    /// characters long.
    ///
    /// Apportioned by position rather than by any reading-to-character mapping, because there
    /// isn't one to be had: 記憶 is two characters and four kana only by coincidence, and a
    /// jukujikun like 昨日[きのう] has no per-character reading at all. Position is the honest
    /// approximation, and it is exact in the common 1:1 and 2:2 cases.
    ///
    /// A range covering the whole run returns the whole reading unchanged, so the overwhelmingly
    /// common case (no straddle) is byte-identical to not splitting at all.
    public static func slice(
        of reading: String,
        baseRange: Range<Int>,
        baseLength: Int
    ) -> String {
        guard baseLength > 0, !reading.isEmpty else { return "" }
        let lower = max(0, min(baseRange.lowerBound, baseLength))
        let upper = max(lower, min(baseRange.upperBound, baseLength))
        guard lower > 0 || upper < baseLength else { return reading }

        let kana = Array(reading)
        let count = kana.count
        // Round to nearest so a 2-base / 3-kana run splits 1 + 2 rather than dropping a kana,
        // and so the slices of a fully covered run always reassemble into the whole reading.
        let start = Int((Double(lower) * Double(count) / Double(baseLength)).rounded())
        let end = Int((Double(upper) * Double(count) / Double(baseLength)).rounded())
        guard start < end, start >= 0, end <= count else { return "" }
        return String(kana[start..<end])
    }
}
