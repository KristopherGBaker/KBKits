import Foundation
import Testing
@testable import KBDictionaryKit

/// Exercises the JmdictFurigana line parser directly (the same validation the build
/// tool mirrors) and the `furigana` table through `JMDictStore` on the bundled seed.
/// The parser half is pure Swift and runs on every platform the package builds for.
struct JmdictFuriganaParserTests {
    @Test func bomPrefixedFirstLineParses() throws {
        let line = try #require(JmdictFuriganaParser.parseLine("\u{FEFF}〃|おなじ|0:おなじ"))
        #expect(line.form == "〃")
        #expect(line.reading == "おなじ")
        #expect(line.spans == [FuriganaSpan(range: 0..<1, kana: "おなじ")])
    }

    @Test func plainSpansCoverEveryCharacter() throws {
        let line = try #require(JmdictFuriganaParser.parseLine("這入る|はいる|0:は;1:い"))
        #expect(line.spans == [
            FuriganaSpan(range: 0..<1, kana: "は"),
            FuriganaSpan(range: 1..<2, kana: "い"),
            FuriganaSpan(range: 2..<3, kana: nil)
        ])
    }

    @Test func multiCharRangeBecomesOneSpan() throws {
        let line = try #require(JmdictFuriganaParser.parseLine("大人|おとな|0-1:おとな"))
        #expect(line.spans == [FuriganaSpan(range: 0..<2, kana: "おとな")])
    }

    @Test func okuriganaGapsBecomeNilKanaSpans() throws {
        let line = try #require(JmdictFuriganaParser.parseLine("俄かに|にわかに|0:にわ"))
        #expect(line.spans == [
            FuriganaSpan(range: 0..<1, kana: "にわ"),
            FuriganaSpan(range: 1..<2, kana: nil),
            FuriganaSpan(range: 2..<3, kana: nil)
        ])
    }

    @Test(arguments: [
        "這入る|はいる",              // wrong field count (2)
        "這入る|はいる|0:は|extra",   // wrong field count (4)
        "|はいる|0:は",               // empty form
        "這入る||0:は",               // empty reading
        "這入る|はいる|",             // empty segmentation
        "這入る|はいる|x:y",          // non-numeric index
        "這入る|はいる|5:は",         // out-of-range index
        "這入る|はいる|0-9:はいる",   // out-of-range range end
        "這入る|はいる|1-0:はい",     // reversed range
        "這入る|はいる|0:",           // empty kana
        "這入る|はいる|0-1:はい;1:い" // overlapping spans
    ])
    func malformedLineIsRejectedWithoutThrowing(line: String) {
        #expect(JmdictFuriganaParser.parseLine(line) == nil)
    }
}

// This suite builds its own SQLite fixture with GRDB, so unlike the seed-backed suites it
// cannot merely skip where GRDB is absent: it would not compile. The suites that assert
// against dictionary DATA use `.enabled(if:)` instead and stay visible in the run.
#if canImport(GRDB)
import GRDB

@Suite(.enabled(if: DictionaryTestSupport.seedIsAvailable))
struct FuriganaStoreTests {
    private let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)

    @Test func exactPairReturnsSpans() {
        #expect(store.furiganaSegments(form: "這入る", reading: "はいる") == [
            FuriganaSpan(range: 0..<1, kana: "は"),
            FuriganaSpan(range: 1..<2, kana: "い"),
            FuriganaSpan(range: 2..<3, kana: nil)
        ])
        #expect(store.furiganaSegments(form: "大人", reading: "おとな") == [
            FuriganaSpan(range: 0..<2, kana: "おとな")
        ])
    }

    @Test func absentPairReturnsEmpty() {
        #expect(store.furiganaSegments(form: "這入る", reading: "ちがう").isEmpty)  // wrong reading
        #expect(store.furiganaSegments(form: "存在しない語", reading: "よみ").isEmpty)
        // 無暗 has no furigana row; the sibling variant 無闇's must not leak in.
        #expect(store.furiganaSegments(form: "無暗", reading: "むやみ").isEmpty)
    }

    @Test func databasePredatingFuriganaTableDegradesToEmpty() throws {
        // An old dictionary without the `furigana` table must return [] — never error.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jmdict-old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE entry (id INTEGER PRIMARY KEY, senses_json TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE entry_form (entry_id INTEGER NOT NULL, form TEXT NOT NULL, is_kanji INTEGER NOT NULL)
                """)
            try db.execute(sql: "INSERT INTO entry (id, senses_json) VALUES (1, '[]')")
            try db.execute(sql: "INSERT INTO entry_form (entry_id, form, is_kanji) VALUES (1, '這入る', 1)")
        }
        try queue.close()

        let old = JMDictStore(databaseURL: url)
        #expect(old.isReady)
        #expect(old.furiganaSegments(form: "這入る", reading: "はいる").isEmpty)
    }
}
#endif
