import Foundation
import Testing
@testable import KBDictionaryKit

/// The KANJIDIC shipped with this package (issue 033), read through `KanjiStore`.
///
/// These run against the REAL bundled database, not a fixture, because the thing most
/// likely to break is not the query - it is the build tool's parse. KANJIDIC2 puts every
/// language's readings in one element and every language's meanings in another, so a wrong
/// filter yields a store that works perfectly and teaches Pinyin.
@Suite("Kanji lookup over the bundled KANJIDIC")
struct KanjiStoreTests {

    private let store = KanjiStore()

    @Test("The bundled database is actually there")
    func bundledDatabaseOpens() {
        // If this fails, every other test in this file passes vacuously by returning nil.
        #expect(store.isReady)
    }

    @Test("A common character has its readings split into on and kun")
    func readingsAreSplitByType() throws {
        let entry = try #require(store.entry(for: "学"))
        #expect(entry.onReadings == ["ガク"])
        #expect(entry.kunReadings == ["まな.ぶ"])
        #expect(entry.meanings.first == "study")
        #expect(entry.strokeCount == 8)
        #expect(entry.grade == 1)
    }

    @Test("Only English meanings are kept")
    func meaningsAreEnglishOnly() throws {
        // 学 carries French, Spanish and Portuguese meanings in KANJIDIC2, all of them on
        // the same element as the English ones and distinguishable only by `m_lang`.
        let entry = try #require(store.entry(for: "学"))
        #expect(entry.meanings == ["study", "learning", "science"])
    }

    @Test("A character with no kun reading has an empty list, not a missing entry")
    func characterWithOnlyOnReadings() throws {
        let entry = try #require(store.entry(for: "校"))
        #expect(entry.onReadings.contains("コウ"))
        #expect(entry.kunReadings.isEmpty)
        #expect(entry.meanings.contains("school"))
    }

    @Test("Kun readings keep KANJIDIC's okurigana dot, because the split is the lesson")
    func kunReadingsKeepTheirDot() throws {
        let entry = try #require(store.entry(for: "古"))
        // Not ふるい: the dot says 古 covers ふる and い is okurigana. Stripping it teaches
        // that the character reads ふるい, which is the mistake the notation exists to prevent.
        #expect(entry.kunReadings.contains("ふる.い"))
    }

    @Test("Kana, punctuation and the iteration mark are not kanji")
    func nonKanjiAreRejected() {
        #expect(!KanjiStore.isKanji("あ"))
        #expect(!KanjiStore.isKanji("ア"))
        #expect(!KanjiStore.isKanji("、"))
        #expect(!KanjiStore.isKanji("A"))
        // 々 is ideographic by Unicode's reckoning and has no readings of its own.
        #expect(!KanjiStore.isKanji("々"))
        #expect(KanjiStore.isKanji("学"))
    }

    @Test("A word yields one entry per kanji, in order, skipping kana")
    func entriesInAWord() {
        let entries = store.entries(in: "学校")
        #expect(entries.map(\.character) == ["学", "校"])
        // Kana in the middle are skipped rather than ending the scan.
        #expect(store.entries(in: "食べ物").map(\.character) == ["食", "物"])
    }

    @Test("A repeated character is one card to make, not two")
    func duplicatesAreCollapsed() {
        #expect(store.entries(in: "人人").map(\.character) == ["人"])
    }

    @Test("A character outside the shipped set misses rather than crashing")
    func unshippedCharacterMisses() {
        // A rare variant with no grade, frequency or JLPT level: deliberately trimmed out.
        #expect(store.entry(for: "𠀋") == nil)
        #expect(store.entries(in: "ひらがなだけ").isEmpty)
    }
}
