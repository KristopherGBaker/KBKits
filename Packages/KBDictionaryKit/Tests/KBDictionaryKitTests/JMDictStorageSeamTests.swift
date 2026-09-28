import Foundation
import Testing
@testable import KBDictionaryKit

/// `JMDictStore` is policy over a `JMDictStorage`: deinflection, the base-then-surface
/// fallback, and turning a segmentation string into spans. None of that needs a database,
/// and these tests prove it by driving the store with a fake.
///
/// That is the point of the seam rather than a side effect of it. The rest of the suite
/// pins behaviour against the bundled SQLite seed, which cannot run where GRDB does not
/// build; this suite runs anywhere the package builds, so the policy stays covered on
/// Android even before there is an Android backend to store anything.
@Suite("JMDict storage seam")
struct JMDictStorageSeamTests {

    /// Records what it was asked for, so a test can assert the store consulted storage the
    /// way it claims to rather than inferring it from the answer.
    private final class FakeStorage: JMDictStorage, @unchecked Sendable {
        var entriesByForm: [String: [JMDictEntry]] = [:]
        var segmentationsByPair: [String: String] = [:]
        var readingsByForm: [String: [String]] = [:]
        var glossesByForm: [String: String] = [:]
        private(set) var requestedForms: [String] = []
        private(set) var requestedLimits: [Int] = []
        private(set) var requestedPrefixes: [String] = []

        var isReady: Bool { true }

        func entries(matchingForm form: String, limit: Int) -> [JMDictEntry] {
            requestedForms.append(form)
            requestedLimits.append(limit)
            return entriesByForm[form] ?? []
        }

        func englishGloss(forKatakana form: String) -> String? { glossesByForm[form] }

        func kanaReadings(forForm form: String) -> [String] { readingsByForm[form] ?? [] }

        func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String] {
            requestedPrefixes.append(prefix)
            return Array(readingsByForm.filter { $0.key.hasPrefix(prefix) }
                .flatMap(\.value).prefix(limit))
        }

        func furiganaSegmentation(form: String, reading: String) -> String? {
            segmentationsByPair["\(form)|\(reading)"]
        }
    }

    private static func entry(_ id: Int, kanji: [String], kana: [String]) -> JMDictEntry {
        JMDictEntry(
            id: id,
            kanjiForms: kanji,
            kanaForms: kana,
            senses: [JMDictSense(pos: ["v5m"], glosses: ["to read"])]
        )
    }

    // MARK: - The policy

    @Test("An exact hit never reaches the deinflector")
    func exactHitSkipsDeinflection() {
        let storage = FakeStorage()
        storage.entriesByForm["読む"] = [Self.entry(1, kanji: ["読む"], kana: ["よむ"])]
        let store = JMDictStore(storage: storage)

        #expect(store.lookup(deinflecting: "読む").count == 1)
        #expect(storage.requestedForms == ["読む"])
    }

    @Test("An inflected surface falls through to a deinflected candidate")
    func inflectedSurfaceDeinflects() {
        let storage = FakeStorage()
        storage.entriesByForm["読む"] = [Self.entry(1, kanji: ["読む"], kana: ["よむ"])]
        let store = JMDictStore(storage: storage)

        let hits = store.lookup(deinflecting: "読んだ")
        #expect(hits.map(\.id) == [1])
        // The surface is tried first, then candidates, and the walk stops at the first hit.
        #expect(storage.requestedForms.first == "読んだ")
        #expect(storage.requestedForms.last == "読む")
    }

    @Test("A surface that deinflects to nothing returns empty rather than guessing")
    func unknownSurfaceReturnsEmpty() {
        let store = JMDictStore(storage: FakeStorage())
        #expect(store.lookup(deinflecting: "存在しない").isEmpty)
    }

    @Test("Base wins, and surface is the fallback")
    func baseThenSurfaceFallback() {
        let storage = FakeStorage()
        storage.entriesByForm["猫"] = [Self.entry(2, kanji: ["猫"], kana: ["ねこ"])]
        let store = JMDictStore(storage: storage)

        #expect(store.lookup(base: "猫", surface: "猫達").map(\.id) == [2])
        #expect(store.lookup(base: "無い形", surface: "猫").map(\.id) == [2])
    }

    /// When base and surface are the same string there is nothing a second query could add,
    /// so the store must not issue one.
    @Test("Base equal to surface is queried once")
    func identicalBaseAndSurfaceQueriesOnce() {
        let storage = FakeStorage()
        let store = JMDictStore(storage: storage)

        _ = store.lookup(base: "犬", surface: "犬")
        #expect(storage.requestedForms == ["犬"])
    }

    @Test("The caller's limit reaches storage")
    func limitIsForwarded() {
        let storage = FakeStorage()
        let store = JMDictStore(storage: storage)

        _ = store.lookup(form: "本", limit: 3)
        #expect(storage.requestedLimits == [3])
    }

    // MARK: - Segmentation parsing sits above the seam

    @Test("A segmentation string from storage is parsed into spans")
    func segmentationIsParsedIntoSpans() {
        let storage = FakeStorage()
        storage.segmentationsByPair["食べる|たべる"] = "0:た"
        let store = JMDictStore(storage: storage)

        let spans = store.furiganaSegments(form: "食べる", reading: "たべる")
        #expect(spans.count == 3)
        #expect(spans.first?.kana == "た")
        // Okurigana positions carry no kana of their own.
        #expect(spans.dropFirst().allSatisfy { $0.kana == nil })
    }

    @Test("An unknown pair is empty, and an empty argument never reaches storage")
    func unknownPairIsEmpty() {
        let store = JMDictStore(storage: FakeStorage())
        #expect(store.furiganaSegments(form: "食べる", reading: "たべる").isEmpty)
        #expect(store.furiganaSegments(form: "", reading: "たべる").isEmpty)
        #expect(store.furiganaSegments(form: "食べる", reading: "").isEmpty)
    }

    // MARK: - The no-dictionary case

    @Test("EmptyJMDictStorage is not ready and answers nothing")
    func emptyStorageAnswersNothing() {
        let store = JMDictStore(storage: EmptyJMDictStorage())

        #expect(!store.isReady)
        #expect(store.lookup(form: "猫").isEmpty)
        #expect(store.lookup(deinflecting: "読んだ").isEmpty)
        #expect(store.lookup(base: "猫", surface: "猫達").isEmpty)
        #expect(store.kanaReadings(forForm: "猫").isEmpty)
        #expect(store.englishGloss(forKatakana: "コミュニケーション") == nil)
        #expect(store.furiganaSegments(form: "食べる", reading: "たべる").isEmpty)
    }

    /// `ReadingValidator` takes `any ReadingDictionary`, and `JMDictStore` conforms. With a
    /// storage that knows nothing, the validator must reach "unknown" rather than deciding
    /// a reading is impossible, which is what keeps a missing dictionary from rewriting text.
    @Test("A store with no data leaves the validator at unknown")
    func validatorStaysUnknownWithoutData() {
        let validator = ReadingValidator(dictionary: JMDictStore(storage: EmptyJMDictStorage()))
        #expect(validator.validate(surface: "無暗", baseForm: nil, ojtReading: "むあん") == .unknown)
    }
}
