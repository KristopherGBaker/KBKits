import Foundation
import Testing
@testable import KBDictionaryKit

/// Exercises the bundled seed dictionary (no full build needed for tests). The seed
/// ships with this package, so these run anywhere `swift test` does.
@Suite(.enabled(if: DictionaryTestSupport.seedIsAvailable))
struct JMDictStoreTests {
    @Test func opensBundledSeed() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        #expect(store.isReady)
    }

    @Test func looksUpByKanjiForm() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        let entries = store.lookup(form: "読む")
        let entry = try #require(entries.first)
        #expect(entry.kanaForms.contains("よむ"))
        #expect(entry.senses.flatMap(\.glosses).contains("to read"))
    }

    @Test func looksUpByKanaReading() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        let entries = store.lookup(form: "よむ")
        #expect(entries.contains { $0.kanjiForms.contains("読む") })
    }

    @Test func looksUpKatakanaLoanword() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        let entries = store.lookup(form: "コミュニケーション")
        let entry = try #require(entries.first)
        #expect(entry.senses.flatMap(\.glosses).contains("communication"))
    }

    @Test func missingFormReturnsEmpty() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        #expect(store.lookup(form: "存在しない語").isEmpty)
    }

    @Test func baseFormPreferredOverSurface() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        // 食べる is in the seed; a surface inflection (食べた) is not, so base wins.
        let entries = store.lookup(base: "食べる", surface: "食べた")
        #expect(entries.contains { $0.senses.flatMap(\.glosses).contains("to eat") })
    }

    @Test func headwordAndReadingHelpers() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        let entry = try #require(store.lookup(form: "日本語").first)
        #expect(entry.headword == "日本語")
        #expect(entry.primaryReading == "にほんご")

        let kana = try #require(store.lookup(form: "コーヒー").first)
        #expect(kana.headword == "コーヒー")
        #expect(kana.primaryReading == nil)  // kana-only: reading would duplicate
    }

    @Test func englishLoanwordHasGloss() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        #expect(store.englishGloss(forKatakana: "コミュニケーション") == "communication")
        #expect(store.englishGloss(forKatakana: "コンピューター") == "computer")
    }

    @Test func nonEnglishLoanAndKanjiHaveNoGloss() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        // コーヒー is from Dutch — deliberately not glossed by the English-only gate.
        #expect(store.englishGloss(forKatakana: "コーヒー") == nil)
        // A kanji word is never an English loan gloss target.
        #expect(store.englishGloss(forKatakana: "日本語") == nil)
    }

    @Test func deinflectsCommonVerbAndAdjectiveForms() throws {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        func base(_ surface: String) -> [String] {
            store.lookup(deinflecting: surface).flatMap(\.kanjiForms)
        }
        #expect(base("読んだ").contains("読む"))        // plain past (godan -む)
        #expect(base("読みます").contains("読む"))      // polite
        #expect(base("食べました").contains("食べる"))  // polite past (ichidan)
        #expect(base("食べない").contains("食べる"))    // negative (ichidan)
        #expect(base("話した").contains("話す"))        // godan -す past
        #expect(base("書いた").contains("書く"))        // godan -く past (音便)
        #expect(base("見た").contains("見る"))          // ichidan past
        #expect(base("高かった").contains("高い"))      // i-adjective past
        #expect(base("高く").contains("高い"))          // i-adjective adverbial
        #expect(base("美しくない").contains("美しい"))  // i-adjective negative
    }

    @Test func deinflectionHandlesIrregularIku() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        // 行った (not 行いた) — the famous irregular; the special rule must win over った→う.
        #expect(store.lookup(deinflecting: "行った").contains { $0.kanjiForms.contains("行く") })
    }

    @Test func directFormStillWinsAndMissesStayEmpty() {
        let store = JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
        #expect(store.lookup(deinflecting: "本").contains { $0.kanjiForms.contains("本") })
        #expect(store.lookup(deinflecting: "存在しない語").isEmpty)
    }

    @Test func candidatesAreOrderedMostSpecificFirst() {
        // 行った: the 4-char special suffix outranks the 2-char った rule.
        let candidates = Deinflector.candidates(for: "行った")
        #expect(candidates.first == "行く")
        #expect(candidates.contains("行う"))   // the over-generated った→う guess is still present
    }

    @Test func missingFullDictionaryFallsBackToSeed() {
        // A non-existent override path must fall back to the bundled seed, not no-op.
        let bogus = URL(fileURLWithPath: "/nonexistent/jmdict.sqlite")
        let store = JMDictStore(databaseURL: bogus)
        #expect(store.isReady)
        #expect(!store.lookup(form: "本").isEmpty)
    }
}
