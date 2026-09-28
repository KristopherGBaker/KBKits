import Foundation
import Testing
import KBDictionaryKit
@testable import KBJapaneseKit

/// The rewrite itself: which digit runs qualify and what they become.
struct CounterNumeralRewriteTests {
    private func normalized(_ text: String) -> String? {
        CounterNumerals.normalize(text)?.text
    }

    @Test func digitsBeforeACounterAreRewritten() {
        #expect(normalized("入社５年の27歳") == "入社五年の二十七歳")
        #expect(normalized("２人で行った") == "二人で行った")
        #expect(normalized("入社３年目") == "入社三年目")
        #expect(normalized("10月20日") == "十月二十日")
        #expect(normalized("2024年") == "二千二十四年")
        #expect(normalized("100回") == "百回")
    }

    @Test func digitsWithNoCounterAreLeftAlone() {
        // The rewrite changes what the analyser sees, so it must only fire where a digit is
        // really a quantity. R2-D2, a page range and a bare number are not.
        #expect(normalized("Ｒ２－Ｄ２は今探している") == nil)
        #expect(normalized("123") == nil)
        #expect(normalized("2024") == nil)
        #expect(normalized("第3の男") == nil, "の is not a counter")
    }

    @Test func theBoundsAreDeliberate() {
        #expect(normalized("05分") == nil, "a leading zero is a clock face, not the number five")
        #expect(normalized("0人") == nil)
        #expect(normalized("12345人") == nil, "beyond four digits a run is rarely a quantity")
        #expect(normalized("9999人") == "九千九百九十九人")
    }

    @Test func kanjiNumeralsFollowJapaneseWriting() {
        #expect(CounterNumerals.kanjiNumeral(1) == "一")
        #expect(CounterNumerals.kanjiNumeral(10) == "十", "十, never 一十")
        #expect(CounterNumerals.kanjiNumeral(11) == "十一")
        #expect(CounterNumerals.kanjiNumeral(20) == "二十")
        #expect(CounterNumerals.kanjiNumeral(27) == "二十七")
        #expect(CounterNumerals.kanjiNumeral(100) == "百")
        #expect(CounterNumerals.kanjiNumeral(305) == "三百五")
        #expect(CounterNumerals.kanjiNumeral(1000) == "千")
        #expect(CounterNumerals.kanjiNumeral(2024) == "二千二十四")
        #expect(CounterNumerals.kanjiNumeral(0) == nil)
        #expect(CounterNumerals.kanjiNumeral(10000) == nil)
    }
}

/// Mapping the analysis back onto the original text. This is where an offset bug would live,
/// so every case pins the SURFACES, which must still tile the original exactly.
struct CounterNumeralProjectionTests {
    private func project(
        _ original: String, _ analysed: [(String, String)]
    ) -> [CounterNumerals.Projected] {
        let normalized = CounterNumerals.normalize(original)!
        #expect(analysed.map(\.0).joined() == normalized.text,
                "the fixture must tile the normalized text, or it is testing nothing")
        return CounterNumerals.project(analysed.map { (surface: $0.0, reading: $0.1) },
                                       replacements: normalized.replacements,
                                       original: original)
    }

    private func tiles(_ projected: [CounterNumerals.Projected], _ original: String) {
        #expect(projected.map(\.surface).joined() == original)
    }

    @Test func aWholeWordReadingSpansTheDigitAndTheCounter() {
        // 二人 analyses as ONE word ふたり, which overlaps the rewrite, so the group maps back
        // to ２人 and keeps the whole-word reading. No per-kanji rule produces this.
        let out = project("２人で行った", [("二人", "ふたり"), ("で", "で"), ("行っ", "いっ"), ("た", "た")])
        tiles(out, "２人で行った")
        #expect(out[0].surface == "２人")
        #expect(out[0].reading == "ふたり")
    }

    @Test func aSplitNumeralIsMergedBackIntoTheDigits() {
        // 二十七 is analysed as 二十 + 七. Neither half has an original to map to; together they
        // are exactly "27". The digits carry no ruby, and 歳 keeps さい - the reported defect.
        let out = project("27歳", [("二十", "にじゅう"), ("七", "なな"), ("歳", "さい")])
        tiles(out, "27歳")
        #expect(out.map(\.surface) == ["27", "歳"])
        #expect(out[0].reading == "", "digits alone carry no kanji to draw ruby over")
        #expect(out[1].reading == "さい")
    }

    @Test func textAroundTheRewriteKeepsItsOwnReadings() {
        let out = project("入社５年の27歳",
                          [("入社", "にゅうしゃ"), ("五", "ご"), ("年", "ねん"), ("の", "の"),
                           ("二十", "にじゅう"), ("七", "なな"), ("歳", "さい")])
        tiles(out, "入社５年の27歳")
        #expect(out.map(\.surface) == ["入社", "５", "年", "の", "27", "歳"])
        #expect(out.map(\.reading) == ["にゅうしゃ", "", "ねん", "の", "", "さい"])
    }

    @Test func twoRewritesInOneLineBothMapBack() {
        let out = project("10月20日",
                          [("十", "じゅう"), ("月", "がつ"), ("二十", "にじゅう"), ("日", "にち")])
        tiles(out, "10月20日")
        #expect(out.map(\.surface) == ["10", "月", "20", "日"])
        #expect(out.map(\.reading) == ["", "がつ", "", "にち"])
    }

    @Test func aWordSpanningTheCounterAndTheDigitsAfterIt() {
        // 四月一日 analyses 一日 as one word ついたち, spanning the second rewrite entirely.
        let out = project("４月１日に会う",
                          [("四", "よ"), ("月", "つき"), ("一日", "ついたち"), ("に", "に"),
                           ("会う", "あう")])
        tiles(out, "４月１日に会う")
        #expect(out.map(\.surface) == ["４", "月", "１日", "に", "会う"])
        #expect(out[2].reading == "ついたち")
    }
}

/// A reading that is not kana is not a reading.
struct KanaOnlyReadingTests {
    @Test func punctuationIsNotAReading() {
        // Open JTalk answers with its pause symbol for a token it cannot pronounce, and it was
        // reaching the page: 重就 rendered 重[、], a COMMA drawn as furigana.
        #expect(JapaneseReader.kanaOnly("、") == "")
        #expect(JapaneseReader.kanaOnly("、し") == "", "one bad character discards the reading")
        #expect(JapaneseReader.kanaOnly("ひしげ甸") == "", "a kanji is not a reading either")
    }

    @Test func realReadingsSurvive() {
        #expect(JapaneseReader.kanaOnly("はっぷん") == "はっぷん")
        #expect(JapaneseReader.kanaOnly("コーヒー") == "コーヒー", "katakana and ー are kana")
        #expect(JapaneseReader.kanaOnly("") == "")
    }
}

/// The per-surface path is the one that produced the commas, over the REAL analyser.
@Suite("KanaOnlyLive: no punctuation reaches the page as furigana",
       .enabled(if: ProcessInfo.processInfo.environment["OJT_DICT_DIR"] != nil,
                "set OJT_DICT_DIR to an unpacked open_jtalk_dic_utf_8 directory to run"))
struct KanaOnlyLiveTests {
    @Test func noRenderedReadingIsPunctuation() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OJT_DICT_DIR"])
        let reader = try #require(JapaneseReader(dictionaryDirectory: URL(fileURLWithPath: path)))
        // Bare verb stems the analyser cannot pronounce in isolation - the shape that produced
        // 這[、] 191 times in one book.
        for surface in ["這", "描", "醒", "棄", "踏", "抜", "吐", "掴", "叩"] {
            let reading = reader.furiganaReading(for: surface)
            #expect(reading != "、", "\(surface) rendered a comma as its furigana")
            if let reading {
                #expect(reading.unicodeScalars.allSatisfy {
                    (0x3041...0x309F).contains($0.value) || (0x30A1...0x30FF).contains($0.value)
                }, "\(surface) -> \(reading) is not kana")
            }
        }
    }
}

/// Ruby for a kanji the ANALYSER cannot read at all.
struct UnreadableKanjiTests {
    private struct Fake: ReadingDictionary {
        let table: [String: [String]]
        func readings(forForm form: String) -> [String] { table[form] ?? [] }
        func furiganaSegments(form: String, reading: String) -> [FuriganaSpan] { [] }
    }

    @Test func anInflectedFormCarriesTheReadingBack() {
        // 啣え: the analyser is silent, JMdict knows 啣える(くわえる), so the surface reads くわえ.
        let validator = ReadingValidator(dictionary: Fake(table: ["啣える": ["くわえる"]]))
        #expect(validator.readingWhenUnreadable(surface: "啣え")?.repair.reading == "くわえ")
    }

    /// The tokenizer splits 啣えた into 啣 + えた, so what reaches the dictionary is the kanji
    /// ALONE. Requiring okurigana to strip left 啣 bare on screen while 腮, 劃, 瞠, 陋 and 恬
    /// around it all gained ruby.
    @Test func aBareKanjiIsLookedUpThroughItsInflectedForm() {
        let validator = ReadingValidator(dictionary: Fake(table: ["啣える": ["くわえる"]]))
        #expect(validator.readingWhenUnreadable(surface: "啣")?.repair.reading == "くわ")
    }

    @Test func anExactFormIsUsedDirectly() {
        let validator = ReadingValidator(dictionary: Fake(table: ["劃": ["かく"]]))
        #expect(validator.readingWhenUnreadable(surface: "劃")?.repair.reading == "かく")
    }

    /// Open JTalk echoes the okurigana it recognises when it does not know the kanji: 搔い -> い.
    /// Non-empty, so it slipped past the emptiness guard, and then nothing could be placed over
    /// 搔 - the kanji stayed bare while 瞠 and 縊 beside it were rescued.
    @Test func aReadingThatIsOnlyTheOkuriganaCountsAsUnreadable() {
        #expect(FuriganaTier.isOkuriganaOnly(reading: "い", surface: "搔い"))
        #expect(FuriganaTier.isOkuriganaOnly(reading: "って", surface: "縊って"))
        #expect(!FuriganaTier.isOkuriganaOnly(reading: "かい", surface: "搔い"), "a real reading")
        #expect(!FuriganaTier.isOkuriganaOnly(reading: "みる", surface: "見る"))
        #expect(!FuriganaTier.isOkuriganaOnly(reading: "みは", surface: "瞠"), "no okurigana at all")
    }

    /// A rescued reading arrives with its alternatives, so a reader who disagrees can correct
    /// it in one tap. 曝 reads さらし here and the author wanted さ; both are real.
    @Test func theAlternativesComeWithIt() {
        let validator = ReadingValidator(dictionary: Fake(table: ["曝": ["さらし", "ばく"]]))
        let rescued = validator.readingWhenUnreadable(surface: "曝")
        #expect(rescued?.repair.reading == "さらし")
        #expect(rescued?.candidates == ["さらし", "ばく"])
    }

    /// Nothing is invented. A form the dictionary does not know leaves the token bare, which is
    /// what 陀多 and 踴 must keep doing.
    @Test func anUnknownFormStaysBare() {
        let validator = ReadingValidator(dictionary: Fake(table: [:]))
        #expect(validator.readingWhenUnreadable(surface: "踴") == nil)
        #expect(validator.readingWhenUnreadable(surface: "かな") == nil, "no kanji, nothing to do")
        #expect(validator.readingWhenUnreadable(surface: "") == nil)
    }
}
