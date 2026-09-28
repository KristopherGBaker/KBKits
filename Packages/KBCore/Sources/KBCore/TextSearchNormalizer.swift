public import Foundation

/// One shared text-folding for search, used by both the in-book matcher
/// (`DocumentTextSearch`) and the cross-book index (`SearchStore`). `fold` produces
/// the case/diacritic/width-insensitive form stored as the index pre-filter column
/// (`LIKE` matches against it); `matchOptions` finds the *precise* span in the
/// original text for highlighting. The two agree on what counts as "the same"
/// characters, so a folded database hit always re-locates in the original text.
public enum TextSearchNormalizer {
    /// Compare options shared by every search path: case-, diacritic-, and
    /// width-insensitive — so "Cafe" ≈ "café" and full/half-width kana match. It is
    /// deliberately NOT kana-insensitive: それ and ソレ stay distinct.
    public static let matchOptions: String.CompareOptions =
        [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Case/diacritic/width-folded form for the index's pre-filter column. `folding`
    /// is *not* length-preserving, so never map text offsets through the folded
    /// string — fold only to `LIKE`/compare, then re-find the real range in the
    /// original via `matchOptions` (see `DocumentTextSearch.appendMatches`).
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: nil)
    }
}
