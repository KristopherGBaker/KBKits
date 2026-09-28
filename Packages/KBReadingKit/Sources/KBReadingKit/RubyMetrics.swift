import Foundation

/// How big furigana is, and — in vertical setting — where the column it rides beside sits.
///
/// Platform-free by construction (`Double`, not `CGFloat`): this target is the one the
/// Android bridge imports, and the column arithmetic is the part Android would need if it
/// ever grows a vertical surface of its own. Nothing here knows about CoreText.
public enum RubyMetrics {

    /// The ruby point size for a base run: about half the base, floored so it stays legible.
    ///
    /// THE one definition. It was previously written out three times — the TextKit reader's
    /// private `rubySize`, the dissolve focus view's `rubyFont`, and (implicitly) the builder's
    /// `rubyLaneHeight` — and three copies of a rule is how two surfaces come to disagree about
    /// how big furigana is. Callers differ only in what they do with the number.
    public static func size(forBase base: Double) -> Double { max(9, base * 0.5) }
}

/// The column geometry of a vertical (縦書き) page.
///
/// Vertical setting puts ruby to the RIGHT of the base column, not above it, so the lane is
/// carved out of the gap *between* columns rather than out of the line spacing. Reading runs
/// right to left, which means a column's own ruby sits between it and the column BEFORE it —
/// exactly the transposition of horizontal ruby, which sits between a line and the line above.
///
/// One consequence has to be stated because it is easy to lose: the FIRST column has no
/// column before it to borrow the gap from, so the page's content rect must be inset on its
/// right edge by a whole lane or the first column's kana falls off the page. That is the
/// vertical twin of `ReaderTextLayoutView.rubyFirstLineInset`, which reserves the same lane
/// above a horizontal paragraph's first line.
public struct VerticalMetrics: Sendable, Equatable {
    /// The full-width advance — one CJK character. Equal to the base point size for every
    /// Japanese face (verified: a run under a Latin body font falls back to Hiragino and still
    /// advances by exactly the point size).
    public let em: Double
    /// The ruby point size, from `RubyMetrics.size(forBase:)`.
    public let rubyEm: Double
    /// The base font's own leading. CoreText already puts this between columns, so the lane
    /// only has to pay for what the leading does not already cover.
    public let fontLeading: Double
    /// Breathing room between the ruby lane and the next column, so kana never kisses the
    /// neighbouring base characters.
    public let columnGap: Double
    /// Whether furigana is being shown at all. With it off no lane is reserved and the columns
    /// close up to ordinary tategaki spacing — the page genuinely reflows rather than leaving
    /// an empty channel.
    public let reservesRubyLane: Bool

    public init(
        em: Double,
        fontLeading: Double,
        columnGap: Double = 4,
        reservesRubyLane: Bool
    ) {
        self.em = max(1, em)
        self.rubyEm = RubyMetrics.size(forBase: em)
        self.fontLeading = max(0, fontLeading)
        self.columnGap = max(0, columnGap)
        self.reservesRubyLane = reservesRubyLane
    }

    /// The width the ruby lane needs beyond what the font's own leading already provides.
    ///
    /// Zero when the leading is already wider than a lane: a Japanese face typically leads by
    /// half an em, which is exactly a ruby em, so in the common case vertical ruby costs the
    /// page NOTHING and the columns sit at their natural rhythm.
    public var extraLaneWidth: Double {
        guard reservesRubyLane else { return 0 }
        return max(0, rubyEm + columnGap - fontLeading)
    }

    /// Distance from one column's baseline to the next one's. Columns advance leftward, so
    /// column *n* sits this much to the LEFT of column *n - 1*.
    public var columnAdvance: Double { em + fontLeading + extraLaneWidth }

    /// The inset the page's right edge needs so the first column's ruby stays on the page.
    /// See the type's note: the first column has no predecessor to borrow a gap from.
    public var firstColumnRubyInset: Double { reservesRubyLane ? rubyEm + columnGap : 0 }

    /// How many columns fit across a content width. At least one, so a viewport narrower than
    /// a single column still renders (clipped) rather than paginating into nothing — a zero
    /// count would make an empty page and a divide-by-zero downstream.
    public func columnCount(fittingWidth width: Double) -> Int {
        let usable = width - firstColumnRubyInset
        guard usable > 0 else { return 1 }
        // The last column needs only its own em, not a further advance, so a page fits one
        // more column than `usable / advance` alone suggests whenever the remainder covers it.
        return max(1, Int(((usable - em) / columnAdvance).rounded(.down)) + 1)
    }

    /// The centre-line x of column `index` (0 = the rightmost, first-read column) within a
    /// content rect whose right edge is `contentMaxX`.
    ///
    /// Derived from the right edge because that is where reading starts and because CoreText
    /// anchors a right-to-left frame there: measured across two point sizes and five rects,
    /// the first column's baseline lands at exactly `rect.maxX - em / 2`.
    public func columnBaselineX(index: Int, contentMaxX: Double) -> Double {
        contentMaxX - firstColumnRubyInset - em / 2 - Double(index) * columnAdvance
    }

    /// The column index under a point, inverting `columnBaselineX`. Clamped into range, so a
    /// tap in a page's margin lands on the nearest column instead of nowhere.
    public func columnIndex(atX x: Double, contentMaxX: Double, columnCount: Int) -> Int {
        let first = columnBaselineX(index: 0, contentMaxX: contentMaxX)
        let raw = ((first - x) / columnAdvance).rounded()
        return min(max(0, Int(raw)), max(0, columnCount - 1))
    }

    /// The along-column extent of the ruby lane for a column: it starts at the base column's
    /// right edge and runs one ruby em further right, into the gap toward the previous column.
    public func rubyLaneMinX(columnBaselineX: Double) -> Double { columnBaselineX + em / 2 }
}
