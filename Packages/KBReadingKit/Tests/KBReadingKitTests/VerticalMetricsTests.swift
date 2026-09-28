import Testing
@testable import KBReadingKit

/// The column arithmetic of vertical setting, with no screen in it.
///
/// Every number here was measured out of CoreText first (see `VerticalMetrics`' notes); these
/// tests pin the arithmetic that consumes those measurements, so a later refactor cannot quietly
/// move ruby to the wrong side of the column or lose the first column's lane off the page edge.
@Suite("Vertical column metrics")
struct VerticalMetricsTests {

    /// Hiragino at 20pt: em 20, leading 10 (half an em), ruby 10.
    private func metrics(ruby: Bool, em: Double = 20, leading: Double = 10) -> VerticalMetrics {
        VerticalMetrics(em: em, fontLeading: leading, reservesRubyLane: ruby)
    }

    @Test("ruby is half the base, floored at 9pt")
    func rubySize() {
        #expect(RubyMetrics.size(forBase: 20) == 10)
        #expect(RubyMetrics.size(forBase: 38) == 19)
        // The floor: at small base sizes half an em would be unreadable.
        #expect(RubyMetrics.size(forBase: 12) == 9)
        #expect(RubyMetrics.size(forBase: 10) == 9)
    }

    /// The point of `extraLaneWidth`: a Japanese face already leads by about half an em, which
    /// is a whole ruby em, so ruby usually costs the page nothing.
    @Test("a font that already leads by a ruby em pays no extra for the lane")
    func laneIsFreeWhenTheLeadingCoversIt() {
        // leading 14 >= ruby 10 + gap 4, so nothing extra.
        let generous = VerticalMetrics(em: 20, fontLeading: 14, reservesRubyLane: true)
        #expect(generous.extraLaneWidth == 0)
        #expect(generous.columnAdvance == 34)

        // leading 10 < ruby 10 + gap 4, so the columns open by the shortfall and only by it.
        let tight = metrics(ruby: true)
        #expect(tight.extraLaneWidth == 4)
        #expect(tight.columnAdvance == 34)
    }

    @Test("turning furigana off closes the columns back up")
    func noLaneWithoutFurigana() {
        let off = metrics(ruby: false)
        #expect(off.extraLaneWidth == 0)
        #expect(off.firstColumnRubyInset == 0)
        #expect(off.columnAdvance == 30)
        #expect(off.columnAdvance < metrics(ruby: true).columnAdvance,
                "with ruby on, the columns must be further apart, or the kana has nowhere to go")
    }

    /// THE assertion this file exists for. Ruby sits to the RIGHT of its base column, in the
    /// gap toward the column read BEFORE it. Get the sign wrong and the kana lands on top of
    /// the neighbouring text, which is what "above the line, transposed" would give you.
    @Test("the ruby lane is to the right of the base column, inside the gap")
    func laneIsRightOfTheColumn() {
        let column = metrics(ruby: true)
        let contentMaxX = 500.0
        let first = column.columnBaselineX(index: 0, contentMaxX: contentMaxX)
        let second = column.columnBaselineX(index: 1, contentMaxX: contentMaxX)

        #expect(second < first, "columns advance right to left")
        #expect(first - second == column.columnAdvance)

        let lane = column.rubyLaneMinX(columnBaselineX: second)
        #expect(lane > second, "the lane is to the RIGHT of its own column")
        #expect(lane >= second + column.em / 2, "it starts at the column's right edge, not inside it")
        #expect(lane + column.rubyEm <= first - column.em / 2 + 0.001,
                "and it ends before the previous column's glyphs begin")
    }

    /// The first column has no predecessor to borrow a gap from, so the page pays for one lane
    /// out of its own right margin. Without this the first column's kana is simply off the page.
    @Test("the page reserves a lane for the first column's ruby")
    func firstColumnLaneIsReserved() {
        let column = metrics(ruby: true)
        #expect(column.firstColumnRubyInset == column.rubyEm + column.columnGap)
        let contentMaxX = 500.0
        let lane = column.rubyLaneMinX(columnBaselineX: column.columnBaselineX(index: 0, contentMaxX: contentMaxX))
        #expect(lane + column.rubyEm <= contentMaxX,
                "the first column's kana must land inside the page, not past its right edge")
    }

    @Test("column count fills the width and never returns zero")
    func columnCount() {
        let column = metrics(ruby: true)          // advance 34, em 20, first-column inset 14
        // 14 inset + 20 (one column) = 34 exactly.
        #expect(column.columnCount(fittingWidth: 34) == 1)
        #expect(column.columnCount(fittingWidth: 67) == 1)
        #expect(column.columnCount(fittingWidth: 68) == 2)   // 14 + 20 + 34
        #expect(column.columnCount(fittingWidth: 500) == 14)
        // Narrower than a single column still renders one, rather than an empty page.
        #expect(column.columnCount(fittingWidth: 5) == 1)
        #expect(column.columnCount(fittingWidth: 0) == 1)
        #expect(column.columnCount(fittingWidth: -10) == 1)
    }

    @Test("a point maps back to the column it is in")
    func columnHitTest() {
        let column = metrics(ruby: true)
        let maxX = 500.0
        for index in 0..<8 {
            let x = column.columnBaselineX(index: index, contentMaxX: maxX)
            #expect(column.columnIndex(atX: x, contentMaxX: maxX, columnCount: 8) == index)
            // Anywhere inside the column's own em resolves to the same column.
            #expect(column.columnIndex(atX: x + column.em / 2 - 0.5, contentMaxX: maxX, columnCount: 8) == index)
            #expect(column.columnIndex(atX: x - column.em / 2 + 0.5, contentMaxX: maxX, columnCount: 8) == index)
        }
        // Off either edge clamps rather than going out of range.
        #expect(column.columnIndex(atX: 9_999, contentMaxX: maxX, columnCount: 8) == 0)
        #expect(column.columnIndex(atX: -9_999, contentMaxX: maxX, columnCount: 8) == 7)
    }

    @Test("a degenerate em cannot divide by zero")
    func degenerateEm() {
        let column = VerticalMetrics(em: 0, fontLeading: 0, columnGap: 0, reservesRubyLane: true)
        #expect(column.em >= 1)
        #expect(column.columnAdvance > 0)
        #expect(column.columnCount(fittingWidth: 100) >= 1)
    }
}
