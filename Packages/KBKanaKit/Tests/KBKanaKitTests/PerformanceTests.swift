import Foundation
import Testing

@testable import KBKanaKit

/// Guards the conversion complexity fix with a wall-clock bound generous enough to survive a
/// loaded machine yet far below what the old shape cost.
///
/// The bound is a property assertion, not a micro-benchmark: linear conversion of 500k
/// transforming characters, input build included, takes under a second and a half here, while
/// the old quadratic splice takes many seconds at the same size (roughly 16s in this
/// environment), so a 6 second ceiling fails loudly on a regression yet keeps a comfortable
/// margin on a green build even under load.
///
/// There is deliberately no equivalent timing guard for `damerauLevenshteinDistance`'s buffer
/// rotation. That fix removes an allocation per source character, but the allocation is a
/// negligible fraction of the O(mn) inner loop it sits beside, so reverting it does not move
/// the wall clock enough to distinguish reliably. Its effect is memory pressure, not speed,
/// and it is not something a timing test can honestly prove. See the report and CHANGELOG.
@Suite("Performance")
struct PerformanceTests {
    @Test("converting a very long string stays roughly linear")
    func conversionIsNotQuadratic() {
        // 1M input characters, every pair a `ka` that transforms into one か, so the whole
        // input is doing work rather than passing through. The old in-place splice shifted the
        // unprocessed tail on every match, which is quadratic and takes many seconds at this
        // size while the forward build stays well under a second.
        let romaji = String(repeating: "ka", count: 500_000)
        let start = Date()
        let result = KanaConverter.convert(romaji)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.text.count == 500_000)
        #expect(result.text.first == "か")
        #expect(elapsed < 6, "conversion took \(elapsed)s, which suggests the quadratic shape is back")
    }
}
