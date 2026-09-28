import Testing
@testable import KBJapaneseKit

/// Accent-phrase grouping is a pure function over already-parsed words, so this suite builds
/// its `Word` fixtures by hand and needs no dictionary. It asserts the PROPERTY (which words
/// land in which phrase) rather than any internal structure, so it survives a better grouper.
@Suite("Accent-phrase grouping")
struct AccentPhraseTests {

    /// A fixture word carrying a chain flag and an accent, everything else incidental.
    private func word(
        _ surface: String,
        _ chain: JapaneseReader.AccentPhraseChain,
        nucleus: Int = 0,
        moraCount: Int = 0
    ) -> JapaneseReader.Word {
        JapaneseReader.Word(
            surface: surface,
            baseForm: surface,
            accent: JapaneseReader.PitchAccent(nucleus: nucleus, moraCount: moraCount),
            phraseChain: chain
        )
    }

    /// The surfaces of a phrase's words, for asserting membership without pinning structure.
    private func surfaces(_ phrase: AccentPhrase) -> [String] {
        phrase.words.map(\.surface)
    }

    @Test("箸を持つ groups into two phrases: [箸, を] and [持つ]")
    func hashiWoMotsu() {
        let words = [
            word("箸", .beginsPhrase),
            word("を", .attachesToPrevious),
            word("持つ", .startsNewPhrase)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 2)
        #expect(surfaces(phrases[0]) == ["箸", "を"])
        #expect(surfaces(phrases[1]) == ["持つ"])
    }

    @Test("私は学生です groups into two phrases, not one and not four")
    func watashiWaGakusei() {
        let words = [
            word("私", .beginsPhrase),
            word("は", .attachesToPrevious),
            word("学生", .startsNewPhrase),
            word("です", .attachesToPrevious)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 2)
        #expect(surfaces(phrases[0]) == ["私", "は"])
        #expect(surfaces(phrases[1]) == ["学生", "です"])
    }

    @Test("今日はいい天気ですね groups into three phrases")
    func kyouWaIiTenki() {
        let words = [
            word("今日", .beginsPhrase),
            word("は", .attachesToPrevious),
            word("いい", .startsNewPhrase),
            word("天気", .startsNewPhrase),
            word("です", .attachesToPrevious),
            word("ね", .attachesToPrevious)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 3)
        #expect(surfaces(phrases[0]) == ["今日", "は"])
        #expect(surfaces(phrases[1]) == ["いい"])
        #expect(surfaces(phrases[2]) == ["天気", "です", "ね"])
    }

    @Test("赤い花が咲いた groups into three phrases")
    func akaiHanaGaSaita() {
        let words = [
            word("赤い", .beginsPhrase),
            word("花", .startsNewPhrase),
            word("が", .attachesToPrevious),
            word("咲い", .startsNewPhrase),
            word("た", .attachesToPrevious)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 3)
        #expect(surfaces(phrases[0]) == ["赤い"])
        #expect(surfaces(phrases[1]) == ["花", "が"])
        #expect(surfaces(phrases[2]) == ["咲い", "た"])
    }

    @Test("日本語を勉強しています groups into four phrases")
    func nihongoWoBenkyou() {
        let words = [
            word("日本語", .beginsPhrase),
            word("を", .attachesToPrevious),
            word("勉強", .startsNewPhrase),
            word("し", .startsNewPhrase),
            word("て", .attachesToPrevious),
            word("い", .startsNewPhrase),
            word("ます", .attachesToPrevious)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 4)
        #expect(surfaces(phrases[0]) == ["日本語", "を"])
        #expect(surfaces(phrases[1]) == ["勉強"])
        #expect(surfaces(phrases[2]) == ["し", "て"])
        #expect(surfaces(phrases[3]) == ["い", "ます"])
    }

    @Test("flattening phrases reproduces the input word sequence for every fixture")
    func flatteningIsLossless() {
        let fixtures: [[JapaneseReader.Word]] = [
            [word("箸", .beginsPhrase), word("を", .attachesToPrevious), word("持つ", .startsNewPhrase)],
            [word("私", .beginsPhrase), word("は", .attachesToPrevious),
             word("学生", .startsNewPhrase), word("です", .attachesToPrevious)],
            [word("今日", .beginsPhrase), word("は", .attachesToPrevious),
             word("いい", .startsNewPhrase), word("天気", .startsNewPhrase),
             word("です", .attachesToPrevious), word("ね", .attachesToPrevious)]
        ]
        for words in fixtures {
            let flattened = AccentPhrase.group(words).flatMap(\.words)
            #expect(flattened == words)
        }
    }

    @Test("each phrase's head is its first word and its accent is the head's accent")
    func headAndAccent() {
        let words = [
            word("私", .beginsPhrase, nucleus: 0, moraCount: 3),
            word("は", .attachesToPrevious, nucleus: 1, moraCount: 1),
            word("学生", .startsNewPhrase, nucleus: 0, moraCount: 4),
            word("です", .attachesToPrevious, nucleus: 1, moraCount: 2)
        ]
        let phrases = AccentPhrase.group(words)
        for phrase in phrases {
            #expect(phrase.head == phrase.words.first)
            #expect(phrase.accent == phrase.head.accent)
        }
        // The phrase accent comes from the head, not a later attached word.
        #expect(phrases[0].accent == JapaneseReader.PitchAccent(nucleus: 0, moraCount: 3))
        #expect(phrases[1].accent == JapaneseReader.PitchAccent(nucleus: 0, moraCount: 4))
    }

    @Test("empty input yields no phrases")
    func emptyInput() {
        #expect(AccentPhrase.group([]).isEmpty)
    }

    @Test("a leading attaching word still opens a phrase, not dropped")
    func leadingAttachingWord() {
        let words = [
            word("を", .attachesToPrevious),
            word("持つ", .startsNewPhrase)
        ]
        let phrases = AccentPhrase.group(words)
        #expect(phrases.count == 2)
        #expect(surfaces(phrases[0]) == ["を"])
        #expect(surfaces(phrases[1]) == ["持つ"])
        // No word dropped.
        #expect(phrases.flatMap(\.words) == words)
    }

    @Test("a startsNewPhrase word between identical words splits them apart")
    func startsNewPhraseIsNotDegenerate() {
        // Two identically-accented words; the middle one starts a new phrase, so they must
        // NOT collapse into a single phrase. Defeats the trivial all-in-one grouper.
        let earlier = word("同", .beginsPhrase, nucleus: 1, moraCount: 2)
        let later = word("同", .startsNewPhrase, nucleus: 1, moraCount: 2)
        let phrases = AccentPhrase.group([earlier, later])
        #expect(phrases.count == 2)
        #expect(surfaces(phrases[0]) == ["同"])
        #expect(surfaces(phrases[1]) == ["同"])
    }
}
