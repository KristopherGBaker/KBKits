import Foundation
import Testing
@testable import KBDictionaryKit

/// The alternation recognizer itself. Every case is a real word's real in-context reading,
/// because the whole point of the type is that a citation dictionary never lists these.
struct SandhiVariantTests {
    /// A case, named rather than a 3-tuple: the third member is the reason the case exists and
    /// an unlabelled `.2` hides it.
    struct Case: Sendable {
        let variant: String
        let listed: String
        let why: String

        init(_ variant: String, _ listed: String, _ why: String) {
            (self.variant, self.listed, self.why) = (variant, listed, why)
        }
    }

    @Test(arguments: [
        Case("ぷん", "ふん", "三十分"),      // handakuon on the head
        Case("ぽん", "ほん", "三本"),
        Case("ぴき", "ひき", "一匹"),
        Case("ぱい", "はい", "一杯"),
        Case("はっ", "はち", "八分"),        // gemination on the tail
        Case("いっ", "いち", "一分"),
        Case("ろっ", "ろく", "六分"),
        Case("じゅっ", "じゅう", "十分"),
        Case("だっ", "だつ", "脱兎"),
        Case("がっ", "がく", "学校"),
        Case("ぱっ", "はつ", "head and tail together")
    ])
    func recognizesRegularAlternations(_ testCase: Case) {
        #expect(Sandhi.isVariant(testCase.variant, of: testCase.listed),
                "\(testCase.variant) from \(testCase.listed): \(testCase.why)")
    }

    @Test(arguments: [
        Case("はち", "はち", "identical is not an alternation"),
        Case("っ", "ち", "a whole reading is never just っ"),
        Case("はがき", "はかき", "voicing in the MIDDLE is not rendaku"),
        Case("はちぶ", "はっぷん", "different lengths"),
        Case("わけ", "ふん", "an unrelated reading of the same kanji"),
        Case("ぱん", "ふん", "the head changed AND the second mora did"),
        Case("はつ", "はち", "ち -> つ is not gemination"),
        Case("ふん", "ぷん", "unvoicing is not an alternation - direction matters"),
        Case("はち", "はっ", "un-geminating is not an alternation either"),
        // The position lock itself: the head DID voice, and the rest still has to match.
        // Without these two, replacing the final equality with `true` changes no test - the
        // earlier guard already rejects every other negative here before reaching it.
        Case("がき", "かく", "head voiced, tail differs by more than gemination"),
        Case("だっさ", "だつし", "tail geminated, a middle mora differs"),
        Case("こころ", "しん", "a different reading entirely"),
        // Rendaku, excluded on measurement: accepting these cost 32 author-graded corpus
        // positions and gained none, because a voiced initial is also what a WRONG analysis
        // of a word-initial token produces and this seam cannot see the word boundary.
        Case("がき", "かき", "rendaku: 落書き, but also a misread bare 書き"),
        Case("づち", "つち", "rendaku: 金槌, but also a misread bare 槌"),
        Case("ずね", "すね", "rendaku: 向こう脛, but also a misread bare 脛"),
        Case("びと", "ひと", "rendaku: 旅人, but also a misread bare 人")
    ])
    func rejectsEverythingElse(_ testCase: Case) {
        #expect(!Sandhi.isVariant(testCase.variant, of: testCase.listed),
                "\(testCase.variant) from \(testCase.listed): \(testCase.why)")
    }

    @Test func sourceNamesTheListedReadingItCameFrom() {
        #expect(Sandhi.source(of: "ぷん", among: ["ふん", "ぶ", "ぶん"]) == "ふん")
        #expect(Sandhi.source(of: "はっ", among: ["はち", "や"]) == "はち")
        #expect(Sandhi.source(of: "わけ", among: ["ふん", "ぶ", "ぶん"]) == nil)
        #expect(Sandhi.source(of: "ぷん", among: []) == nil)
    }
}

/// Moving a placement row onto the variant. The row must keep its ranges - the surface did
/// not change - and change exactly the one kana the alternation touched.
struct SandhiTransferTests {
    @Test func headHandakuonLandsInTheFirstSpan() {
        // 何分: 何[なん] 分[ふん] -> 分[ぷん]. The row keeps its ranges; one kana changes.
        let row = [FuriganaSpan(range: 0..<1, kana: "ふん"), FuriganaSpan(range: 1..<2, kana: nil)]
        #expect(Sandhi.transfer(row, from: "ふん", to: "ぷん") == [
            FuriganaSpan(range: 0..<1, kana: "ぷん"), FuriganaSpan(range: 1..<2, kana: nil)
        ])
        #expect(Sandhi.transfer(row, from: "ふん", to: "ふん") == nil, "no alternation, no transfer")
    }

    @Test func tailGeminationLandsInTheLastSpan() {
        let row = [FuriganaSpan(range: 0..<1, kana: "に"), FuriganaSpan(range: 1..<2, kana: "じゅう")]
        #expect(Sandhi.transfer(row, from: "にじゅう", to: "にじゅっ") == [
            FuriganaSpan(range: 0..<1, kana: "に"), FuriganaSpan(range: 1..<2, kana: "じゅっ")
        ])
    }

    @Test func headAndTailMoveTogether() {
        let row = [FuriganaSpan(range: 0..<1, kana: "はつ")]
        #expect(Sandhi.transfer(row, from: "はつ", to: "ぱっ") == [
            FuriganaSpan(range: 0..<1, kana: "ぱっ")
        ])
    }

    @Test func rendakuIsNotTransferredBecauseItIsNotRecognized() {
        let row = [FuriganaSpan(range: 0..<1, kana: "つち")]
        #expect(Sandhi.transfer(row, from: "つち", to: "づち") == nil)
    }

    @Test func refusesRatherThanGuessWhenTheRowDoesNotFitTheReading() {
        // An okurigana span (nil kana) at the end carries no kana for a tail change to land in.
        let okurigana = [FuriganaSpan(range: 0..<1, kana: "た"), FuriganaSpan(range: 1..<2, kana: nil)]
        #expect(Sandhi.transfer(okurigana, from: "たつ", to: "たっ") == nil)
        // A row for a DIFFERENT reading of the same form: its first kana is not where the
        // alternation says it should be.
        let wrongRow = [FuriganaSpan(range: 0..<1, kana: "りゅう")]
        #expect(Sandhi.transfer(wrongRow, from: "たつ", to: "だつ") == nil)
        #expect(Sandhi.transfer([], from: "たつ", to: "だつ") == nil)
    }
}

/// The alternation rule where it actually acts: the validator's verdict.
///
/// The fake carries JMdict's REAL readings for these forms, because the whole defect is that
/// the citation list is complete and still does not contain the in-context reading.
private struct CounterDictionary: ReadingDictionary {
    let readingsByForm: [String: [String]] = [
        "分": ["ふん", "ぶ", "ぶん"],
        "八": ["はち", "や", "パー"],
        "書き": ["かき"],
        "達者": ["たっしゃ"]
    ]
    let segmentationByPair: [String: String] = [
        "分|ふん": "0:ふん",
        "書き|かき": "0:か"
    ]

    func readings(forForm form: String) -> [String] { readingsByForm[form] ?? [] }

    func furiganaSegments(form: String, reading: String) -> [FuriganaSpan] {
        guard let raw = segmentationByPair["\(form)|\(reading)"] else { return [] }
        return JmdictFuriganaParser.spans(segmentation: raw, formLength: form.count) ?? []
    }
}

struct ReadingValidatorSandhiTests {
    private let validator = ReadingValidator(dictionary: CounterDictionary())

    /// 午後五時三十八分 rendered ごじさんじゅうはちぶ. Both halves of that came from here:
    /// OpenJTalk produced 八[はっ] 分[ぷん] and the validator called each impossible.
    @Test func keepsAGeminatedReadingTheDictionaryCannotList() {
        #expect(validator.validate(surface: "八", baseForm: nil, ojtReading: "はっ")
                == .consistent(segmentation: nil))
    }

    @Test func keepsAHandakuonReadingTheDictionaryCannotList() {
        // The row moves with the reading rather than being dropped: 分[ぷん], not a bare ぷん
        // with no placement (which would also stop the compound join, gated on rows).
        #expect(validator.validate(surface: "分", baseForm: nil, ojtReading: "ぷん")
                == .consistent(segmentation: [FuriganaSpan(range: 0..<1, kana: "ぷん")]))
    }

    /// The line the corpus drew. 落書き really does read らくがき, and the tier really does
    /// overwrite が with か - but a bare 書き misanalysed as がき is the same shape, and this
    /// seam sees neither neighbour. Measured over 18 books, admitting rendaku here broke 32
    /// author-graded positions and repaired none, so it stays out and 書き stays repaired.
    @Test func stillRepairsRendakuBecauseItCannotBeToldFromAMisreading() {
        #expect(validator.validate(surface: "書き", baseForm: nil, ojtReading: "がき")
                == .impossible(repair: ReadingRepair(
                    reading: "かき",
                    segmentation: [FuriganaSpan(range: 0..<1, kana: "か"),
                                   FuriganaSpan(range: 1..<2, kana: nil)])))
    }

    /// The rule must not become "keep whatever OpenJTalk said". A reading that is not a
    /// regular alternation of anything listed is still impossible and still repaired - this
    /// is the 351-occurrence 分 わけ → ふん repair the corpus depends on.
    @Test func stillRepairsAReadingThatIsNotAnAlternation() {
        #expect(validator.validate(surface: "分", baseForm: nil, ojtReading: "わけ")
                == .impossible(repair: ReadingRepair(
                    reading: "ふん",
                    segmentation: [FuriganaSpan(range: 0..<1, kana: "ふん")])))
    }

    /// 口が達者 is たっしゃ and OpenJTalk says だっしゃ. Excluding rendaku is what keeps this
    /// one repaired - it is the same shape as 金槌's づち and nothing at this seam separates
    /// them.
    @Test func stillRepairsAWrongVoicingOfAWordThatNeverRendakus() {
        #expect(validator.validate(surface: "達者", baseForm: nil, ojtReading: "だっしゃ")
                == .impossible(repair: ReadingRepair(reading: "たっしゃ", segmentation: nil)))
    }
}
