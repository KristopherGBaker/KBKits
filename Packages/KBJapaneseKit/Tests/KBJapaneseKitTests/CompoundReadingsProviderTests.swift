import Foundation
import Synchronization
import Testing
import KBCore
import KBReadingKit
import KBDictionaryKit
@testable import KBJapaneseKit

/// Counts every storage hit so a test can assert query volume, not just query results.
/// Backed by a Mutex because the provider closure is `@Sendable` and the render path may
/// touch it from a detached task.
private final class CountingStorage: JMDictStorage {
    private let readings: [String: [String]]
    private let segmentations: [String: String]  // "form|reading" -> segmentation
    private let counts = Mutex<[String: Int]>([:])

    init(readings: [String: [String]], segmentations: [String: String] = [:]) {
        self.readings = readings
        self.segmentations = segmentations
    }

    func count(_ key: String) -> Int { counts.withLock { $0[key] ?? 0 } }

    var isReady: Bool { true }
    func entries(matchingForm form: String, limit: Int) -> [JMDictEntry] { [] }
    func englishGloss(forKatakana form: String) -> String? { nil }

    func kanaReadings(forForm form: String) -> [String] {
        counts.withLock { $0["kanaReadings", default: 0] += 1 }
        return readings[form] ?? []
    }

    func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String] {
        counts.withLock { $0["prefixReadings", default: 0] += 1 }
        return Array(readings.filter { $0.key.hasPrefix(prefix) }.flatMap(\.value).prefix(limit))
    }

    func furiganaSegmentation(form: String, reading: String) -> String? {
        counts.withLock { $0["furiganaSegmentation", default: 0] += 1 }
        return segmentations["\(form)|\(reading)"]
    }
}

private func store(_ storage: CountingStorage) -> JMDictStore {
    JMDictStore(storage: storage)
}

@Suite("Compound readings provider")
struct CompoundReadingsProviderTests {
    /// THE POINT OF THE UNIT. 運転手 is one word the display tiling splits into 運転 + 手;
    /// the analyser reads 手 as シュ in context but the isolated form cannot support it, so
    /// pass 1 renders うんてんて. The join repairs it from the dictionary. Driven through
    /// `KaraokeWord.tokenize`, which is the same call `ReaderContent.build` makes, so this
    /// asserts the rendered ruby rather than a provider's return value.
    @Test("a split compound renders its dictionary reading")
    func compoundRendersJoinedReading() throws {
        let storage = CountingStorage(
            readings: ["運転手": ["うんてんしゅ"]],
            segmentations: ["運転手|うんてんしゅ": "0:うん;1:てん;2:しゅ"])
        let provider = try #require(JapaneseFurigana.compoundReadings(dictionary: store(storage)))

        let words = KaraokeWord.tokenize("運転手", segmentIndex: 0,
                                         reading: { surface in
                                             switch surface {
                                             case "運転": return "うんてん"
                                             case "手": return "て"
                                             default: return nil
                                             }
                                         },
                                         compoundReadings: provider)
        let ruby = words.flatMap(\.ruby).compactMap(\.reading).joined()
        #expect(ruby == "うんてんしゅ", "joined compound should take the dictionary reading")
    }

    /// The negative control, as a test rather than a claim: the SAME render with the
    /// provider omitted must produce the defective reading. If this ever passes, the
    /// assertion above has stopped discriminating.
    @Test("without the provider the same compound renders the defect")
    func withoutProviderTheDefectRemains() {
        let words = KaraokeWord.tokenize("運転手", segmentIndex: 0,
                                         reading: { surface in
                                             switch surface {
                                             case "運転": return "うんてん"
                                             case "手": return "て"
                                             default: return nil
                                             }
                                         },
                                         compoundReadings: nil)
        let ruby = words.flatMap(\.ruby).compactMap(\.reading).joined()
        #expect(ruby == "うんてんて", "nil provider must leave the pre-fix rendering")
    }

    /// Interleaved A,A,B,B,A: a per-form cache answers 2 distinct forms in 2 queries no
    /// matter the order. A single-slot cache thrashes on the A,B,A alternation and a no-op
    /// re-queries every call, so both fail this. Counts `furiganaSegmentation` too, because
    /// `KaraokeWord.compoundOverrides` invokes the closure twice per form (readings, then
    /// spans) and the nested per-reading segmentation query is the round trip that doubles.
    @Test("readings and segmentations are memoized per form, in any order")
    func memoizedPerForm() throws {
        let storage = CountingStorage(
            readings: ["運転手": ["うんてんしゅ"], "図書館": ["としょかん"]],
            segmentations: ["運転手|うんてんしゅ": "0:うん;1:てん;2:しゅ",
                            "図書館|としょかん": "0:と;1:しょ;2:かん"])
        let provider = try #require(JapaneseFurigana.compoundReadings(dictionary: store(storage)))

        for form in ["運転手", "運転手", "図書館", "図書館", "運転手"] { _ = provider(form) }

        #expect(storage.count("kanaReadings") == 2, "one query per DISTINCT form")
        #expect(storage.count("furiganaSegmentation") == 2, "spans resolved once per form")
        // Results must still be correct and per-form distinct, so a cache that returns one
        // form's answer for another cannot pass by being cheap.
        #expect(provider("運転手").map(\.reading) == ["うんてんしゅ"])
        #expect(provider("図書館").map(\.reading) == ["としょかん"])
    }

    /// Most probes are not compounds, so the empty result is the common case and must be
    /// cached like any other. A cache that stores only non-empty answers re-queries forever.
    @Test("a miss is cached too")
    func missIsCached() throws {
        let storage = CountingStorage(readings: [:])
        let provider = try #require(JapaneseFurigana.compoundReadings(dictionary: store(storage)))

        for _ in 0..<3 { #expect(provider("走る").isEmpty) }

        #expect(storage.count("kanaReadings") == 1, "an empty result must cache")
    }

    /// Placement spans ride along when the exact (form, reading) pair has a row, and are nil
    /// when it does not. An always-nil-spans implementation renders one ruby over the whole
    /// compound instead of per character, which is the inert-join failure this unit exists
    /// to prevent, so it is asserted directly rather than left to the render test.
    @Test("spans propagate when the pair has a row, and are nil when it does not")
    func spansPropagate() throws {
        let storage = CountingStorage(
            readings: ["運転手": ["うんてんしゅ"], "大人": ["おとな"]],
            segmentations: ["運転手|うんてんしゅ": "0:うん;1:てん;2:しゅ"])
        let provider = try #require(JapaneseFurigana.compoundReadings(dictionary: store(storage)))

        let withRow = try #require(provider("運転手").first)
        let spans = try #require(withRow.spans, "a JmdictFurigana row must yield spans")
        #expect(spans.map(\.kana) == ["うん", "てん", "しゅ"])

        let withoutRow = try #require(provider("大人").first)
        #expect(withoutRow.reading == "おとな")
        #expect(withoutRow.spans == nil, "no row means no fabricated placement")
    }

    /// The four gating cases, pinned. Only the presence/absence of the closure is asserted
    /// here; what each one RENDERS is the render tests above.
    @Test("the closure is gated on the dictionary, and the no-reader path keeps nil")
    func gating() {
        // 1. No dictionary: nothing to join against.
        #expect(JapaneseFurigana.compoundReadings(dictionary: nil) == nil)
        // 2. A dictionary: the same gate `payload` uses.
        #expect(JapaneseFurigana.compoundReadings(
            dictionary: store(CountingStorage(readings: [:]))) != nil)
        // 3. No reader (degraded wiring): unchanged from before this member existed. Without
        //    a reader there is no pass-1 ruby to correct, so a closure here would be both new
        //    and inert; `providers` builds it after the reader guard for exactly that reason.
        let degraded = JapaneseFurigana.providers(
            dictionary: store(CountingStorage(readings: [:])), reader: nil)
        #expect(degraded.compoundReadings == nil)
        #expect(degraded.reading == nil, "the degraded path is otherwise what it always was")
        // 4. The narrow initializer the degraded path uses still compiles and still defaults
        //    the new member to nil.
        let narrow = JapaneseFurigana(reading: nil, baseForm: nil, payload: nil, gloss: nil)
        #expect(narrow.compoundReadings == nil)
    }

    /// The bundled seed is refused. It is a non-nil store with 46 entries and 5 furigana
    /// rows, and the join degrades non-monotonically on sparse coverage: an unknown longest
    /// form sends it to shorter known subruns, so the seed can produce an override the full
    /// dictionary would have suppressed. `Tools/FuriganaQA`'s SeedGuard already refuses the
    /// seed; this pins the shipping path to the same rule.
    @Test("the bundled seed does not drive the join")
    func seedRefused() {
        let seed = JMDictStore(storage: CountingStorage(readings: ["運転手": ["うんてんしゅ"]]),
                               isUsingBundledSeed: true)
        #expect(JapaneseFurigana.compoundReadings(dictionary: seed) == nil,
                "a seed-backed store must not drive the compound join")
    }

    /// THE ASSIGNMENT, not just the helper. Every other test here calls
    /// `JapaneseFurigana.compoundReadings(dictionary:)` directly, so nulling the
    /// `compoundReadings:` argument inside `providers()` would leave them all green while
    /// making the app wiring inert again - which is the exact bug this whole unit exists to
    /// fix. This is the only assertion that fails on that mutation.
    ///
    /// Needs a real reader, since `providers` returns the degraded wiring without one, so it
    /// is gated on OJT_DICT_DIR exactly like `FuriganaContextLiveTests`. Uses the
    /// `dictionaryDirectory:` initializer rather than `JapaneseReader()` so it never touches
    /// the process-global configuration, which a sibling suite asserts is unset.
    @Test("providers() actually assigns the closure when a reader is available",
          .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                   "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
    func providersAssignsTheClosure() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OJT_DICT_DIR"])
        let reader = try #require(JapaneseReader(dictionaryDirectory: URL(fileURLWithPath: path)),
                                  "OJT_DICT_DIR does not hold a loadable dictionary")
        let wired = JapaneseFurigana.providers(
            dictionary: store(CountingStorage(readings: ["運転手": ["うんてんしゅ"]])),
            reader: reader)
        let provider = try #require(wired.compoundReadings,
                                    "providers() must assign the closure, not just build it")
        #expect(provider("運転手").map(\.reading) == ["うんてんしゅ"])
    }
}
