import KBCore
import KBReadingKit
import Testing

/// The correction seam is reachable from a NON-Apple consumer.
///
/// `import KBReadingKit` only - no `@testable`, no SwiftUI - because the point of making
/// `applyingCorrections` public is that the Android bridge can call it. The bridge renders through
/// its own `renderWords` over `KaraokeWord.tokenize` rather than `ReaderContent.build`, so without
/// a public seam it would have to reimplement the span match, the surface guard and the okurigana
/// placement, and those three are exactly what this feature's mutations exist to protect.
///
/// A test that used `@testable` would pass while the real consumer could not link.
@Suite
struct CorrectionSeamReachabilityTests {

    private func word(_ text: String, lower: Int, upper: Int, reading: String) -> KaraokeWord {
        KaraokeWord(id: "0.\(lower)", text: text, segmentIndex: 0,
                    utf16Lower: lower, utf16Upper: upper,
                    ruby: [RubySegment(text: text, reading: reading)])
    }

    private func rendered(_ word: KaraokeWord) -> String {
        word.ruby.map { $0.reading ?? $0.text }.joined()
    }

    @Test
    func publicSeamAppliesPerOccurrence() {
        let words = [word("十分", lower: 0, upper: 2, reading: "じゅうぶん"),
                     word("十分", lower: 3, upper: 5, reading: "じゅうぶん")]
        let corrected = ReaderContent.applyingCorrections(
            [RubyCorrection(utf16Lower: 0, utf16Upper: 2, surface: "十分", reading: "じゅっぷん")],
            to: words)
        #expect(rendered(corrected[0]) == "じゅっぷん")
        #expect(rendered(corrected[1]) == "じゅうぶん", "the second occurrence must be untouched")
    }

    @Test
    func publicSeamHonoursTheSurfaceGuard() {
        let words = [word("十分", lower: 0, upper: 2, reading: "じゅうぶん")]
        let corrected = ReaderContent.applyingCorrections(
            [RubyCorrection(utf16Lower: 0, utf16Upper: 2, surface: "五分", reading: "ごふん")],
            to: words)
        #expect(rendered(corrected[0]) == "じゅうぶん",
                "a correction recorded against 五分 must never be written onto 十分")
    }

    @Test
    func publicSeamLeavesUncorrectedWordsAlone() {
        let words = [word("十分", lower: 0, upper: 2, reading: "じゅうぶん")]
        #expect(ReaderContent.applyingCorrections([], to: words).map(rendered) == ["じゅうぶん"])
    }
}
