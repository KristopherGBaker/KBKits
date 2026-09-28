import Testing
@testable import KBReadingKit

/// The rule that stops a compound's reading being drawn twice when it straddles a column break.
@Suite("Vertical ruby split")
struct VerticalRubySplitTests {

    /// The no-straddle case is the overwhelming majority, and it must be untouched.
    @Test("a run wholly inside one column keeps its whole reading")
    func wholeRunIsUnchanged() {
        #expect(VerticalRubySplit.slice(of: "きおく", baseRange: 0..<2, baseLength: 2) == "きおく")
        #expect(VerticalRubySplit.slice(of: "わがはい", baseRange: 0..<2, baseLength: 2) == "わがはい")
        #expect(VerticalRubySplit.slice(of: "な", baseRange: 0..<1, baseLength: 1) == "な")
    }

    /// THE defect this exists for: 記憶[きおく] broken across the column boundary rendered
    /// きおく twice. Split, the two halves reassemble into the reading and neither repeats.
    ///
    /// Note what is NOT asserted: that the break falls at 記=き / 憶=おく. Position cannot know
    /// that - the run carries one reading for two characters and no per-character mapping (see
    /// `VerticalRubySplit`) - so demanding the linguistically true split would be demanding
    /// information the reading pipeline never produced. What must hold is that the kana are
    /// dealt out once each, in order, across the columns the base occupies.
    @Test("a compound broken across columns splits its reading between them")
    func straddleSplits() {
        let head = VerticalRubySplit.slice(of: "きおく", baseRange: 0..<1, baseLength: 2)
        let tail = VerticalRubySplit.slice(of: "きおく", baseRange: 1..<2, baseLength: 2)
        #expect(head + tail == "きおく", "the halves must reassemble, losing no kana")
        #expect(!head.isEmpty && !tail.isEmpty)
        #expect(head != "きおく" && tail != "きおく",
                "neither column may draw the WHOLE reading - that is the doubling defect")
    }

    @Test("an even split divides evenly")
    func evenSplit() {
        let head = VerticalRubySplit.slice(of: "けんとう", baseRange: 0..<1, baseLength: 2)
        let tail = VerticalRubySplit.slice(of: "けんとう", baseRange: 1..<2, baseLength: 2)
        #expect(head == "けん")
        #expect(tail == "とう")
        #expect(head + tail == "けんとう")
    }

    /// A four-character compound broken anywhere still reassembles - the property that proves
    /// no kana is dropped or repeated, whatever the break point.
    @Test("every break point of a run reassembles into the whole reading")
    func everyBreakReassembles() {
        let reading = "としょかん"     // 5 kana over 3 characters (図書館)
        for cut in 1..<3 {
            let head = VerticalRubySplit.slice(of: reading, baseRange: 0..<cut, baseLength: 3)
            let tail = VerticalRubySplit.slice(of: reading, baseRange: cut..<3, baseLength: 3)
            #expect(head + tail == reading, "break after \(cut) lost or repeated kana")
        }
    }

    @Test("degenerate inputs return nothing rather than crashing")
    func degenerate() {
        #expect(VerticalRubySplit.slice(of: "", baseRange: 0..<1, baseLength: 1).isEmpty)
        #expect(VerticalRubySplit.slice(of: "あ", baseRange: 0..<1, baseLength: 0).isEmpty)
        #expect(VerticalRubySplit.slice(of: "あ", baseRange: 5..<9, baseLength: 2).isEmpty)
        // An empty range asks for no characters and gets none. (An INVERTED range cannot be
        // tested: `Range<Int>` traps in its own initializer, so the clamp in `slice` guards a
        // case no caller can construct - kept only so the arithmetic below it is total.)
        #expect(VerticalRubySplit.slice(of: "あい", baseRange: 1..<1, baseLength: 2).isEmpty)
    }

    /// A single kanji whose reading is longer than the run still splits sensibly rather than
    /// giving one column the lot.
    @Test("a jukujikun reading longer than its base splits by position")
    func longReading() {
        // 昨日[きのう] is 2 characters and 3 kana with no per-character mapping.
        let head = VerticalRubySplit.slice(of: "きのう", baseRange: 0..<1, baseLength: 2)
        let tail = VerticalRubySplit.slice(of: "きのう", baseRange: 1..<2, baseLength: 2)
        #expect(head + tail == "きのう")
        #expect(!head.isEmpty && !tail.isEmpty, "neither column may be left with nothing")
    }
}
