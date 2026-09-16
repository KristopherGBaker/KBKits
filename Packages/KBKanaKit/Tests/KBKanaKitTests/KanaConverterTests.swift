import Testing

@testable import KBKanaKit

@Suite("Converting whole strings")
struct KanaConverterTests {
    @Test(
        "the basic syllables convert",
        arguments: [
            ("a", "あ"), ("ka", "か"), ("sa", "さ"), ("ta", "た"), ("na", "な"),
            ("ha", "は"), ("ma", "ま"), ("ya", "や"), ("ra", "ら"), ("wa", "わ"),
            ("ga", "が"), ("za", "ざ"), ("da", "だ"), ("ba", "ば"), ("pa", "ぱ")
        ]
    )
    func basicSyllables(_ romaji: String, _ kana: String) {
        #expect(KanaConverter.convert(romaji).text == kana)
    }

    @Test(
        "both Hepburn and Kunrei spellings are accepted",
        arguments: [
            ("shi", "し"), ("si", "し"),
            ("chi", "ち"), ("ti", "ち"),
            ("tsu", "つ"), ("tu", "つ"),
            ("fu", "ふ"), ("hu", "ふ"),
            ("ji", "じ"), ("zi", "じ"),
            ("sha", "しゃ"), ("sya", "しゃ")
        ]
    )
    func romanisationSchemes(_ romaji: String, _ kana: String) {
        // Both are taught, and a quiz that accepts only one is wrong about half the time
        // for half its users.
        #expect(KanaConverter.convert(romaji).text == kana)
    }

    @Test(
        "digraphs beat the shorter spelling inside them",
        arguments: [
            ("kya", "きゃ"), ("kyu", "きゅ"), ("kyo", "きょ"),
            ("nya", "にゃ"), ("cha", "ちゃ"), ("ryo", "りょ"), ("jya", "じゃ")
        ]
    )
    func digraphs(_ romaji: String, _ kana: String) {
        // Longest match. `kya` must not become き + や.
        #expect(KanaConverter.convert(romaji).text == kana)
    }

    @Test(
        "a doubled consonant becomes a sokuon",
        arguments: [
            ("kitte", "きって"), ("gakkou", "がっこう"), ("issho", "いっしょ"),
            ("kippu", "きっぷ"), ("matte", "まって"), ("chotto", "ちょっと")
        ]
    )
    func sokuon(_ romaji: String, _ kana: String) {
        #expect(KanaConverter.convert(romaji).text == kana)
    }

    @Test(
        "n becomes ん when nothing can follow it",
        arguments: [
            ("nihon", "にほん"), ("sensei", "せんせい"), ("ginkou", "ぎんこう"),
            ("gunma", "ぐんま"), ("shinbun", "しんぶん"), ("kanji", "かんじ")
        ]
    )
    func syllabicN(_ romaji: String, _ kana: String) {
        #expect(KanaConverter.convert(romaji).text == kana)
    }

    @Test("nn spells ん outright, so na is still reachable")
    func doubledN() {
        // The reason ん is `nn` and not `n`: with `n` as a spelling there would be no way to
        // type な, because the `n` would have committed before the `a` arrived.
        #expect(KanaConverter.convert("nn").text == "ん")
        #expect(KanaConverter.convert("na").text == "な")
    }

    @Test("nn commits to ん immediately, so annai is あんあい and not あんない")
    func doubledNBeforeAVowel() {
        // The wapuro gotcha, and it is standard rather than a defect: `nn` is a spelling of
        // ん in its own right, so it is consumed as soon as it is complete and the vowel
        // after it starts a new syllable. Getting あんない needs `annnai` or a kana keyboard.
        //
        // This behaviour is carried over deliberately rather than improved on. It is what
        // every Japanese IME does, so it is what a user's fingers already expect, and the
        // place to be forgiving about it is the answer checker, not the transliterator.
        #expect(KanaConverter.convert("annai").text == "あんあい")
        #expect(KanaConverter.convert("annnai").text == "あんない")
        #expect(KanaConverter.convert("konnichiwa").text == "こんいちわ")
        #expect(KanaConverter.convert("konnnichiwa").text == "こんにちわ")
    }

    @Test("m before a consonant becomes ん, because that is what gets typed")
    func mAsSyllabicN() {
        // Not correct romaji. It is what someone who learned the word from a sign types,
        // and marking them wrong for it teaches nothing about Japanese.
        #expect(KanaConverter.convert("shimbun").text == "しんぶん")
        #expect(KanaConverter.convert("sempai").text == "せんぱい")
    }

    @Test("an x or l prefix makes a small kana")
    func smallKana() {
        #expect(KanaConverter.convert("xa").text == "ぁ")
        #expect(KanaConverter.convert("xtu").text == "っ")
        #expect(KanaConverter.convert("ltsu").text == "っ")
    }

    @Test("a hyphen is the katakana long vowel mark")
    func longVowelMark() {
        #expect(KanaConverter.convert("ra-men").text == "らーめん")
    }

    @Test("an unfinished syllable is dropped and reported")
    func unfinishedInput() {
        // `kats` is someone half way through `katsu`. Leaving the `s` in would have an
        // answer checker compare かつs against a reading and call it wrong; dropping it
        // makes the partial answer simply incomplete, which the flag says.
        // Only the trailing run goes: `t` and `s` are both unmatched and both at the end,
        // so かつ is not reached until the `u` arrives.
        let result = KanaConverter.convert("kats")
        #expect(result.text == "か")
        #expect(result.convertedEverything == false)

        let finished = KanaConverter.convert("katsu")
        #expect(finished.text == "かつ")
        #expect(finished.convertedEverything)
    }

    @Test("text that is already kana passes through untouched")
    func kanaPassesThrough() {
        // Someone with a Japanese keyboard types kana directly, and someone who switched
        // half way through produces a mixture. Both have to work.
        #expect(KanaConverter.convert("にほん").text == "にほん")
        #expect(KanaConverter.convert("に hon").text == "に ほん")
    }

    @Test("kanji and punctuation are left alone")
    func nonRomajiIsLeftAlone() {
        #expect(KanaConverter.convert("日本").text == "日本")
        #expect(KanaConverter.convert("a、ka").text == "あ、か")
    }

    @Test("only a TRAILING run of unconverted letters is dropped")
    func onlyTrailingLettersAreDropped() {
        // Dropping them anywhere would quietly delete text from the middle of what someone
        // typed. Dropping only the tail is the difference between "you have not finished
        // this syllable" and "some of your answer is gone".
        #expect(KanaConverter.convert("ka b ka").text == "か b か")
        #expect(KanaConverter.convert("kab").text == "か")
    }

    @Test("an empty string converts to an empty string")
    func emptyInput() {
        let result = KanaConverter.convert("")
        #expect(result.text.isEmpty)
        #expect(result.convertedEverything)
    }

    @Test("converting to katakana produces katakana")
    func katakana() {
        #expect(KanaConverter.convert("konpyu-ta-", to: .katakana).text == "コンピューター")
        #expect(KanaConverter.convert("kitte", to: .katakana).text == "キッテ")
    }

    @Test("uppercase input converts the same as lowercase")
    func caseInsensitivity() {
        #expect(KanaConverter.convert("NIHON").text == KanaConverter.convert("nihon").text)
        #expect(KanaConverter.convert("KiTTe").text == "きって")
    }

    @Test("converting is idempotent: kana in, the same kana out")
    func idempotence() {
        // Worth stating, because the answer checker runs the conversion over input that may
        // already have been converted by the input engine as it was typed.
        for romaji in ["nihon", "kitte", "konnichiwa", "ra-men", "katsu"] {
            let once = KanaConverter.convert(romaji).text
            #expect(KanaConverter.convert(once).text == once, "\(romaji)")
        }
    }
}

@Suite("Script conversion")
struct ScriptConversionTests {
    @Test("hiragana and katakana round-trip through each other")
    func roundTrip() {
        for text in ["にほん", "きって", "ぁぃぅぇぉゃゅょっ", "ゔ"] {
            #expect(KanaConverter.toHiragana(KanaConverter.toKatakana(text)) == text)
        }
    }

    @Test("the long vowel mark is not a hiragana character and is left alone")
    func longVowelMarkIsNotTransformed() {
        // It sits above the katakana block and has no hiragana counterpart at the same
        // offset, so shifting it blindly would produce a character from another script.
        #expect(KanaConverter.toHiragana("ラーメン") == "らーめん")
        #expect(KanaConverter.toKatakana("らーめん") == "ラーメン")
    }

    @Test("characters that are not kana pass through both directions")
    func nonKanaUntouched() {
        #expect(KanaConverter.toKatakana("日本abc") == "日本abc")
        #expect(KanaConverter.toHiragana("日本abc") == "日本abc")
    }

    @Test("kana is recognised, and everything else is not")
    func isKana() {
        #expect(KanaConverter.isKana("にほん"))
        #expect(KanaConverter.isKana("ニホン"))
        #expect(KanaConverter.isKana("ラーメン"))
        #expect(KanaConverter.isKana("にホン"))

        #expect(KanaConverter.isKana("日本") == false)
        #expect(KanaConverter.isKana("nihon") == false)
        #expect(KanaConverter.isKana("にほんa") == false)
        #expect(KanaConverter.isKana("") == false)
    }
}
