import Testing
@testable import KBJapaneseKit

/// Mora splitting is pure string logic with no dictionary, so this suite always runs. The
/// suite name contains "Mora" so `--filter Mora` selects it. Each case pins mora COUNT and the
/// exact split, and every case is checked for losslessness (assertion 10).
@Suite("Mora splitting")
struct MoraSplitterTests {

    @Test("はし splits into two moras")
    func hashiTwoMoras() {
        #expect(MoraSplitter.moras(in: "はし") == ["は", "し"])
    }

    @Test("きょう splits as きょ + う, two moras")
    func kyouCombinesSmallYo() {
        #expect(MoraSplitter.moras(in: "きょう") == ["きょ", "う"])
    }

    @Test("とうきょう is four moras")
    func toukyouFourMoras() {
        let moras = MoraSplitter.moras(in: "とうきょう")
        #expect(moras == ["と", "う", "きょ", "う"])
        #expect(moras.count == 4)
    }

    @Test("コーヒー is four moras, each ー its own element")
    func coffeeLongVowels() {
        let moras = MoraSplitter.moras(in: "コーヒー")
        #expect(moras == ["コ", "ー", "ヒ", "ー"])
        #expect(moras.count == 4)
    }

    @Test("きって is three moras, っ its own element")
    func sokuonOwnMora() {
        let moras = MoraSplitter.moras(in: "きって")
        #expect(moras == ["き", "っ", "て"])
        #expect(moras.count == 3)
    }

    @Test("にほん is three moras, ん its own element")
    func moraicNasalOwnMora() {
        let moras = MoraSplitter.moras(in: "にほん")
        #expect(moras == ["に", "ほ", "ん"])
        #expect(moras.count == 3)
    }

    @Test("katakana small kana combine: ファ and ティ are one mora each")
    func katakanaSmallKanaCombine() {
        #expect(MoraSplitter.moras(in: "ファ") == ["ファ"])
        #expect(MoraSplitter.moras(in: "ティ") == ["ティ"])
    }

    @Test("empty string is zero moras")
    func emptyString() {
        #expect(MoraSplitter.moras(in: "") == [])
    }

    @Test("a kana-free string is one mora per character")
    func kanaFreeString() {
        let moras = MoraSplitter.moras(in: "abc")
        #expect(moras == ["a", "b", "c"])
        #expect(moras.count == 3)
    }

    @Test("splitting is lossless: joined moras equal the input")
    func lossless() {
        for input in ["はし", "きょう", "とうきょう", "コーヒー", "きって", "にほん",
                      "ファ", "ティ", "", "abc", "ゃ", "aゃ"] {
            #expect(MoraSplitter.moras(in: input).joined() == input)
        }
    }

    // Degeneracy defeats: a small kana combines ONLY when preceded by kana.

    @Test("a leading small kana stands alone")
    func leadingSmallKana() {
        #expect(MoraSplitter.moras(in: "ゃ") == ["ゃ"])
    }

    @Test("a small kana after a non-kana does not combine")
    func smallKanaAfterNonKana() {
        #expect(MoraSplitter.moras(in: "aゃ") == ["a", "ゃ"])
    }
}

@Suite("MoraSplitter, standalone moras cannot absorb a small kana")
struct MoraSplitterStandaloneTests {

    /// ー, っ and ん are each a whole mora and have no consonant for a small kana to
    /// palatalise, so a small kana after one of them opens a new mora. These sequences are
    /// not ordinary Japanese, but a splitter that fuses them is wrong about why fusion
    /// happens at all, and the same flaw shows up on real input.
    @Test("a small kana after a standalone mora does not fuse")
    func standaloneMorasDoNotAbsorb() {
        #expect(MoraSplitter.moras(in: "ーゃ") == ["ー", "ゃ"])
        #expect(MoraSplitter.moras(in: "っゃ") == ["っ", "ゃ"])
        #expect(MoraSplitter.moras(in: "ッャ") == ["ッ", "ャ"])
        #expect(MoraSplitter.moras(in: "んゃ") == ["ん", "ゃ"])
        #expect(MoraSplitter.moras(in: "ンャ") == ["ン", "ャ"])
    }

    /// The ordinary case still fuses, so the fix did not simply disable combining.
    @Test("an ordinary kana still takes a small kana")
    func ordinaryKanaStillFuses() {
        #expect(MoraSplitter.moras(in: "きゃ") == ["きゃ"])
        #expect(MoraSplitter.moras(in: "しゅ") == ["しゅ"])
        #expect(MoraSplitter.moras(in: "きょう") == ["きょ", "う"])
        #expect(MoraSplitter.moras(in: "ファ") == ["ファ"])
    }

    /// Reconstruction must stay lossless for the sequences above.
    @Test("splitting stays lossless across standalone moras")
    func losslessAcrossStandalone() {
        for text in ["ーゃ", "っゃ", "んゃ", "きゃっ", "コーヒーゃ"] {
            #expect(MoraSplitter.moras(in: text).joined() == text)
        }
    }
}

@Suite("MoraSplitter, block punctuation is not kana")
struct MoraSplitterBlockPunctuationTests {

    /// The Hiragana and Katakana Unicode blocks contain more than letters. A block-range test
    /// lets punctuation absorb a small kana, which is how ・ャ became one mora. Only kana
    /// LETTERS can carry a small kana.
    @Test("punctuation inside the kana blocks cannot absorb a small kana")
    func blockPunctuationDoesNotAbsorb() {
        #expect(MoraSplitter.moras(in: "・ャ") == ["・", "ャ"])   // U+30FB middle dot
        #expect(MoraSplitter.moras(in: "゠ャ") == ["゠", "ャ"])   // U+30A0 double hyphen
        #expect(MoraSplitter.moras(in: "ヽャ") == ["ヽ", "ャ"])   // U+30FD iteration mark
        #expect(MoraSplitter.moras(in: "ゝゃ") == ["ゝ", "ゃ"])   // U+309D iteration mark
    }

    /// Latin and kanji were already handled, but pin them so the letter-range narrowing
    /// cannot regress them.
    @Test("non-kana still cannot absorb a small kana")
    func nonKanaDoesNotAbsorb() {
        #expect(MoraSplitter.moras(in: "aゃ") == ["a", "ゃ"])
        #expect(MoraSplitter.moras(in: "本ゃ") == ["本", "ゃ"])
    }

    /// The narrowing must not break ordinary fusion at the edges of the letter ranges.
    @Test("kana letters across both scripts still fuse")
    func kanaLettersStillFuse() {
        #expect(MoraSplitter.moras(in: "きゃ") == ["きゃ"])
        #expect(MoraSplitter.moras(in: "ぁぃ") == ["ぁ", "ぃ"])
        #expect(MoraSplitter.moras(in: "ヴィ") == ["ヴィ"])
        #expect(MoraSplitter.moras(in: "ファ") == ["ファ"])
        #expect(MoraSplitter.moras(in: "コーヒー") == ["コ", "ー", "ヒ", "ー"])
    }
}
