import Foundation
import Testing
@testable import KBDictionaryKit

/// A dictionary fake for the validator's injectable seam: verdicts must derive from
/// injected knowledge, not from anything hardcoded against the bundled seed.
private struct FakeDictionary: ReadingDictionary {
    var readingsByForm: [String: [String]] = [:]
    var segmentationByPair: [String: String] = [:]  // "form|reading" → raw segmentation

    func readings(forForm form: String) -> [String] { readingsByForm[form] ?? [] }

    func furiganaSegments(form: String, reading: String) -> [FuriganaSpan] {
        guard let raw = segmentationByPair["\(form)|\(reading)"] else { return [] }
        return JmdictFuriganaParser.spans(segmentation: raw, formLength: form.count) ?? []
    }
}

/// Anti-hardcoding: a made-up form absent from the bundled seed drives all three
/// verdicts purely from the injected fake's knowledge.
struct ReadingValidatorSeamTests {
    // 犬猫語 is not a real word and not in any seed/full dictionary.
    private let fake = FakeDictionary(
        readingsByForm: ["犬猫語": ["けんびょうご"]],
        segmentationByPair: ["犬猫語|けんびょうご": "0:けん;1:びょう;2:ご"]
    )

    @Test func injectedKnowledgeYieldsConsistent() {
        let validator = ReadingValidator(dictionary: fake)
        let verdict = validator.validate(surface: "犬猫語", baseForm: nil, ojtReading: "けんびょうご")
        #expect(verdict == .consistent(segmentation: [
            FuriganaSpan(range: 0..<1, kana: "けん"),
            FuriganaSpan(range: 1..<2, kana: "びょう"),
            FuriganaSpan(range: 2..<3, kana: "ご")
        ]))
    }

    @Test func injectedKnowledgeYieldsImpossibleWithRepair() {
        let validator = ReadingValidator(dictionary: fake)
        let verdict = validator.validate(surface: "犬猫語", baseForm: nil, ojtReading: "いぬねこご")
        let repair = ReadingRepair(reading: "けんびょうご", segmentation: [
            FuriganaSpan(range: 0..<1, kana: "けん"),
            FuriganaSpan(range: 1..<2, kana: "びょう"),
            FuriganaSpan(range: 2..<3, kana: "ご")
        ])
        #expect(verdict == .impossible(repair: repair))
    }

    @Test func emptyFakeYieldsUnknown() {
        let validator = ReadingValidator(dictionary: FakeDictionary())
        let verdict = validator.validate(surface: "犬猫語", baseForm: nil, ojtReading: "けんびょうご")
        #expect(verdict == .unknown)
    }

    /// Hot-path laziness: deriving baseForm costs a second OpenJTalk frontend pass, so
    /// the closure variant must not evaluate it when the exact-form check already hits.
    @Test func directHitNeverEvaluatesBaseForm() {
        let validator = ReadingValidator(dictionary: fake)
        var evaluated = false
        let verdict = validator.validate(surface: "犬猫語", ojtReading: "けんびょうご",
                                         baseForm: { evaluated = true; return nil })
        #expect(verdict != .unknown)
        #expect(!evaluated)
    }

    /// …and a miss still consults it (行った-style inflected corroboration).
    @Test func missEvaluatesBaseFormLazily() {
        let inflectable = FakeDictionary(readingsByForm: ["行く": ["いく"]])
        let validator = ReadingValidator(dictionary: inflectable)
        var evaluated = false
        let verdict = validator.validate(surface: "行った", ojtReading: "いった",
                                         baseForm: { evaluated = true; return "行く" })
        #expect(verdict == .consistent(segmentation: nil))
        #expect(evaluated)
    }
}

/// Policy safety against the bundled seed: trust OpenJTalk's contextual choices,
/// never override an inflected surface, keep hands off unknown forms.
@Suite(.enabled(if: DictionaryTestSupport.seedIsAvailable))
struct ReadingValidatorSafetyTests {
    private let validator = ReadingValidator(
        dictionary: JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
    )

    @Test func contextualReadingsOfInflectedIkuAreConsistent() {
        // 行った is legitimately いった (行く) or おこなった (行う) — both corroborated.
        #expect(validator.validate(surface: "行った", baseForm: "行く", ojtReading: "いった")
            == .consistent(segmentation: nil))
        #expect(validator.validate(surface: "行った", baseForm: "行う", ojtReading: "おこなった")
            == .consistent(segmentation: nil))
    }

    @Test func kaHenSurfaceIsNeverOverridden() {
        // 来た=きた, but base 来る=くる: the base kana must not poison the surface check.
        let verdict = validator.validate(surface: "来た", baseForm: "来る", ojtReading: "きた")
        if case .impossible = verdict {
            Issue.record("来た+きた must never be impossible (got \(verdict))")
        }
        #expect(verdict == .unknown)  // no exact-form hit → hands off, no repair
    }

    @Test func kanaOnlySurfacesAreNeverImpossible() {
        for (surface, reading) in [("する", "する"), ("コーヒー", "コーヒー")] {
            let verdict = validator.validate(surface: surface, baseForm: nil, ojtReading: reading)
            if case .impossible = verdict {
                Issue.record("\(surface) is kana-only and must never be impossible")
            }
        }
    }

    @Test func unknownKanjiSurfaceIsLeftAlone() {
        let verdict = validator.validate(surface: "鄭寧", baseForm: "鄭寧", ojtReading: "ていねい")
        #expect(verdict == .unknown)
    }

    @Test func katakanaOjtReadingNormalizesForComparison() {
        // OpenJTalk pron is katakana; corroboration must still hit はいる.
        let verdict = validator.validate(surface: "這入る", baseForm: "這入る", ojtReading: "ハイル")
        #expect(verdict == .consistent(segmentation: [
            FuriganaSpan(range: 0..<1, kana: "は"),
            FuriganaSpan(range: 1..<2, kana: "い"),
            FuriganaSpan(range: 2..<3, kana: nil)
        ]))
    }
}

/// Repair cases against the bundled seed: exact-form dictionary hits whose reading
/// matches nothing JMdict lists get overridden with the dictionary reading.
@Suite(.enabled(if: DictionaryTestSupport.seedIsAvailable))
struct ReadingValidatorRepairTests {
    private let validator = ReadingValidator(
        dictionary: JMDictStore(databaseURL: JMDictStore.bundledSeedURL)
    )

    @Test func garbledHairuIsRepairedWithSegmentation() {
        // OpenJTalk's dictionary lacks 這入る and mangles the reading.
        let verdict = validator.validate(surface: "這入る", baseForm: "這入る", ojtReading: "しゃにゅうる")
        let repair = ReadingRepair(reading: "はいる", segmentation: [
            FuriganaSpan(range: 0..<1, kana: "は"),
            FuriganaSpan(range: 1..<2, kana: "い"),
            FuriganaSpan(range: 2..<3, kana: nil)
        ])
        #expect(verdict == .impossible(repair: repair))
    }

    @Test func yukueIsRepairedWithSegmentation() {
        let verdict = validator.validate(surface: "行衛", baseForm: "行衛", ojtReading: "ゆきえ")
        let repair = ReadingRepair(reading: "ゆくえ", segmentation: [
            FuriganaSpan(range: 0..<1, kana: "ゆく"),
            FuriganaSpan(range: 1..<2, kana: "え")
        ])
        #expect(verdict == .impossible(repair: repair))
    }

    @Test func muyamiVariantRepairsReadingWithoutBorrowedSegmentation() {
        // 無暗 resolves to むやみ through the 無闇/無暗 entry_form variant, but has no
        // JmdictFurigana row of its own — the sibling 無闇's segmentation must NOT be
        // borrowed, so the repair carries reading only.
        let verdict = validator.validate(surface: "無暗", baseForm: "無暗", ojtReading: "むくら")
        #expect(verdict == .impossible(repair: ReadingRepair(reading: "むやみ", segmentation: nil)))
    }
}
