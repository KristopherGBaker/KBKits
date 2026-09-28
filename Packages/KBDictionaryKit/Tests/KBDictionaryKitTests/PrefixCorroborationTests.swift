import Foundation
import Testing
@testable import KBDictionaryKit

/// The prefix scan behind "can the ordinary dictionary account for our reading of this
/// surface?" - the gate that separates a name the tokenizer spelled out of its kanji from
/// ordinary vocabulary, without any proper-noun tag (no analyser we have exposes one).
///
/// Two suites, because the two halves fail differently. The policy suite drives a fake and
/// runs anywhere the package builds, including Android. The data suite needs a FULL JMdict
/// (`KB_FULL_JMDICT=...`, the path `make dict` prints) because the discriminating cases are
/// exactly the ones the 46-entry seed cannot contain, and it is the half that proves the
/// gate is worth having rather than merely implemented.
@Suite("Prefix corroboration policy")
struct PrefixCorroborationPolicyTests {

    private final class PrefixStorage: JMDictStorage, @unchecked Sendable {
        var readingsByForm: [String: [String]] = [:]
        private(set) var prefixQueries: [(String, Int)] = []

        var isReady: Bool { true }
        func entries(matchingForm form: String, limit: Int) -> [JMDictEntry] { [] }
        func englishGloss(forKatakana form: String) -> String? { nil }
        func kanaReadings(forForm form: String) -> [String] { readingsByForm[form] ?? [] }
        func furiganaSegmentation(form: String, reading: String) -> String? { nil }

        func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String] {
            prefixQueries.append((prefix, limit))
            return Array(readingsByForm.sorted { $0.key < $1.key }
                .filter { $0.key.hasPrefix(prefix) }.flatMap(\.value).prefix(limit))
        }
    }

    /// THE POINT: an INFLECTED form corroborates its stem. Asking the exact form 撫 gives
    /// nothing, and the closed ending list this replaces misses でる, so 撫 read な was
    /// uncorroborated and would have been handed to a name dictionary.
    @Test("an inflected form corroborates the bare kanji's reading")
    func inflectedFormCorroboratesStem() {
        let storage = PrefixStorage()
        storage.readingsByForm["撫でる"] = ["なでる"]
        let store = JMDictStore(storage: storage)

        #expect(store.kanaReadings(forForm: "撫").isEmpty, "the exact form knows nothing")
        #expect(store.corroborates(form: "撫", reading: "な"))
    }

    /// The other half of the gate: a kun concatenation the tokenizer assembled is accounted
    /// for by no form at all, which is what makes it distinguishable from vocabulary.
    ///
    /// The second case is the one that earns its place. 司波 finds NO forms, so a broken
    /// comparison still answers "uncorroborated" there and the test passes for the wrong
    /// reason - which is how an `ours = ""` mutant first survived this suite. 八釜 finds
    /// 八釜しい(やかましい), so the answer can only be right if our reading is actually
    /// compared against it.
    @Test("a reading no form accounts for is uncorroborated")
    func unaccountedReadingIsUncorroborated() {
        let storage = PrefixStorage()
        storage.readingsByForm["司会"] = ["しかい"]
        storage.readingsByForm["司"] = ["つかさ"]
        storage.readingsByForm["八釜しい"] = ["やかましい"]
        let store = JMDictStore(storage: storage)

        #expect(store.corroborates(form: "司", reading: "つかさ"))
        #expect(!store.corroborates(form: "司波", reading: "つかさなみ"), "no form at all")
        #expect(!store.kanaReadings(forFormsStartingWith: "八釜").isEmpty,
                "the fixture must reach the comparison, not stop at an empty answer")
        #expect(!store.corroborates(form: "八釜", reading: "はちかま"), "a form, a different reading")
    }

    /// A katakana dictionary reading must not false-negative against our hiragana rendering.
    @Test("katakana readings fold to hiragana before comparing")
    func katakanaFolds() {
        let storage = PrefixStorage()
        storage.readingsByForm["珈琲店"] = ["コーヒーてん"]
        let store = JMDictStore(storage: storage)

        #expect(store.corroborates(form: "珈琲", reading: "こーひー"))
    }

    /// Truncation errs toward the ACTING branch, so the default limit has to clear the real
    /// fan-out; this pins that the limit is passed down rather than silently ignored.
    @Test("the limit reaches storage and bounds the answer")
    func limitReachesStorage() {
        let storage = PrefixStorage()
        storage.readingsByForm["大安"] = ["たいあん"]
        storage.readingsByForm["大分"] = ["だいぶ"]
        let store = JMDictStore(storage: storage)

        #expect(store.kanaReadings(forFormsStartingWith: "大", limit: 1).count == 1)
        #expect(storage.prefixQueries.last?.1 == 1)
        #expect(store.kanaReadings(forFormsStartingWith: "大").count == 2)
        #expect(storage.prefixQueries.last?.1 == 4000, "the shipped default must clear 大's 1,890")
    }

    @Test("an empty side never corroborates and never queries")
    func emptyInputs() {
        let storage = PrefixStorage()
        let store = JMDictStore(storage: storage)

        #expect(!store.corroborates(form: "", reading: "のぞ"))
        #expect(!store.corroborates(form: "覗", reading: ""))
        #expect(storage.prefixQueries.isEmpty)
    }

    @Test("no dictionary corroborates nothing")
    func emptyStorage() {
        let store = JMDictStore(storage: EmptyJMDictStorage())
        #expect(store.kanaReadings(forFormsStartingWith: "覗").isEmpty)
        #expect(!store.corroborates(form: "覗", reading: "のぞ"))
    }
}

/// The cases that decide whether the gate is a net gain, measured against the real dictionary.
/// Set `KB_FULL_JMDICT` to a full jmdict.sqlite (`Tools/build-jmdict.swift` prints the path).
///
/// `.enabled(if:)` rather than a `#require` inside each test, matching `BundledFuriganaTests`:
/// a machine with no full dictionary - CI, a fresh clone, a test run before the build script -
/// must SKIP these and stay visible in the run, not fail. A first draft used `#require` and
/// turned an absent 66 MB download into three red tests.
@Suite("Prefix corroboration against a full JMdict",
       .enabled(if: DictionaryTestSupport.fullDictionary != nil))
struct PrefixCorroborationDataTests {

    private static var fullStore: JMDictStore? { DictionaryTestSupport.fullDictionary }

    /// The RISK side of issue 048: positions we read correctly today. Every one of these is
    /// corroborated only through an inflected form, so an exact-form gate would hand them all
    /// to a name dictionary that lists 覗 as のぞき and 睨 as にらむ.
    @Test("readings we get right today are corroborated through inflection")
    func correctReadingsAreCorroborated() throws {
        let store = try #require(Self.fullStore)
        for (form, reading) in [("覗", "のぞ"), ("撫", "な"), ("睨", "にら"), ("儲", "もう")] {
            #expect(store.corroborates(form: form, reading: reading),
                    "\(form) read \(reading) must be accounted for by JMdict")
        }
    }

    /// The BENEFIT side: kun concatenations over names. No JMdict form accounts for them,
    /// which is precisely why they are safe to hand to another source of readings.
    @Test("kun concatenations over names are uncorroborated")
    func nameConcatenationsAreUncorroborated() throws {
        let store = try #require(Self.fullStore)
        for (form, reading) in [("司波", "つかさなみ"), ("養源寺", "やしなえげんてら"),
                                ("径子", "みちこ"), ("薬師町", "くずしまち"),
                                ("自来也", "じらいなり"), ("海屋", "うみや")] {
            #expect(!store.corroborates(form: form, reading: reading),
                    "\(form) read \(reading) must be unaccounted for")
        }
        // These two DO find forms - 八釜しい(やかましい), 波江蛙(なみえがえる) - so they
        // exercise the reading comparison rather than stopping at an empty answer. Without
        // them the suite passes even when the comparison is removed.
        for (form, reading) in [("八釜", "はちかま"), ("波江", "なみこう")] {
            #expect(!store.kanaReadings(forFormsStartingWith: form).isEmpty,
                    "\(form) must reach the comparison")
            #expect(!store.corroborates(form: form, reading: reading),
                    "\(form) read \(reading) must be unaccounted for")
        }
    }

    /// The default limit has to clear the real fan-out, and the fan-out is a property of the
    /// DATA, not of the code - so assert it against the data rather than trusting the comment.
    @Test("no single kanji out-runs the default limit")
    func defaultLimitClearsTheWorstPrefix() throws {
        let store = try #require(Self.fullStore)
        for kanji in ["大", "一", "日", "御", "自", "無", "小"] {
            let count = store.kanaReadings(forFormsStartingWith: kanji).count
            #expect(count < 4000, "\(kanji) returned \(count) readings, at or past the default cap")
        }
    }
}
