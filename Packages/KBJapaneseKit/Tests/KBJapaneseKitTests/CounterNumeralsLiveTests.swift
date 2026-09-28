import Foundation
import KBCore
import KBJapaneseKit
import Testing

/// The rewrite over the REAL Open JTalk dictionary. Skipped, never passed, without one.
@Suite("CounterNumeralsLive: digits before a counter, through the real analyser",
       .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct CounterNumeralsLiveTests {
    private func words(_ text: String) throws -> [(String, String)] {
        let path = try #require(ProcessInfo.processInfo.environment["OJT_DICT_DIR"])
        let reader = try #require(JapaneseReader(dictionaryDirectory: URL(fileURLWithPath: path)),
                                  "no Open JTalk dictionary at \(path)")
        return reader.furiganaWords(in: text).map { ($0.surface, $0.reading) }
    }

    @Test func theWordsStillTileTheOriginalText() throws {
        for text in ["入社５年の27歳。", "２人で行った。", "１日目、２日目。", "10月20日。",
                     "Ｒ２－Ｄ２は今探している。", "普通の文です。"] {
            let tiled = try words(text).map(\.0).joined()
            #expect(tiled == text, "surfaces must tile \(text)")
        }
    }

    @Test func theReportedCountersReadCorrectly() throws {
        let reported = try words("入社５年の27歳。入社３年目。")
        let dict = Dictionary(reported.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        #expect(dict["年"] == "ねん", "5年 read としevery time before this")
        #expect(dict["歳"] == "さい", "27歳 read とし")
    }

    /// Open JTalk rewrites what it reports: ２ comes back as 二, half-width Latin comes back
    /// widened. The surfaces then do not tile the input, the aligner's tiling guard fails, and
    /// the WHOLE sentence loses its in-context readings - so this is not cosmetic.
    @Test func theAnalyserOwnRewritesAreUndone() throws {
        for text in ["Ｒ２－Ｄ２は今探している。", "R2-D2は今探している。"] {
            #expect(try words(text).map(\.0).joined() == text)
        }
    }

    @Test func aWholeWordCounterReadingSpansTheDigits() throws {
        let two = try words("２人で行った。")
        #expect(two.contains { $0.0 == "２人" && $0.1 == "ふたり" },
                "got \(two)")
    }
}
