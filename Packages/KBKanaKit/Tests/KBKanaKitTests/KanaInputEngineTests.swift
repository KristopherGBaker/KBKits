// Copyright 2018 David Sansome
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This file has been modified from the original.
// The behavioural sweeps, the sokuon sweep, the ん sweep, their uppercase counterparts and
// the sweep that types the last character of every spelling in the table, are ported from
// ios/Tests/TKMKanaInputTest.m in https://github.com/davidsansome/tsurukame. Rewritten for
// Swift Testing against strings rather than XCTest against a UITextField. See NOTICE.

import Testing

@testable import KBKanaKit

/// The incremental path, ported from `ios/Tests/TKMKanaInputTest.m` in Tsurukame.
///
/// Its four behavioural tests sweep the whole character set and the whole replacement table
/// rather than picking examples, which is a good shape and is kept. What is dropped is
/// everything about `UITextField`: these run against a string.
@Suite("Typing romaji")
struct KanaInputEngineTests {
    private let engine = KanaInputEngine()

    /// Types a string one character at a time, the way a person does.
    private func type(_ input: String, into initial: String = "", using engine: KanaInputEngine) -> String {
        var text = initial
        var caret = text.count
        for character in input {
            if let change = engine.change(replacing: caret ..< caret, with: String(character), in: text) {
                text = change.text
                caret = change.caret
            } else {
                var characters = Array(text)
                characters.insert(character, at: caret)
                text = String(characters)
                caret += 1
            }
        }
        return text
    }

    /// The consonants that make a sokuon when doubled: every consonant except n and m.
    private var sokuonConsonants: [Character] {
        RomajiCharacters.consonants
            .subtracting(RomajiCharacters.syllabicNasals)
            .sorted()
    }

    // MARK: - Ported from the reference

    @Test("typing a consonant twice turns the first into っ")
    func doubledConsonantBecomesSokuon() {
        for consonant in sokuonConsonants {
            let change = engine.change(replacing: 1 ..< 1, with: String(consonant), in: String(consonant))
            #expect(change?.text == "っ\(consonant)", "for \(consonant)")
        }
    }

    @Test("typing an uppercase consonant twice turns the first into ッ")
    func doubledUppercaseConsonantBecomesKatakanaSokuon() {
        // Uppercase is how someone answering in hiragana enters a katakana word without
        // going to find a setting.
        for consonant in sokuonConsonants {
            let upper = Character(consonant.uppercased())
            let change = engine.change(replacing: 1 ..< 1, with: String(upper), in: String(upper))
            #expect(change?.text == "ッ\(upper)", "for \(upper)")
        }
    }

    @Test("typing a consonant after n turns the n into ん")
    func nBeforeAConsonantBecomesN() {
        for nasal in RomajiCharacters.syllabicNasals.sorted() {
            for consonant in sokuonConsonants
            where !RomajiCharacters.canFollowN.contains(consonant) {
                let change = engine.change(
                    replacing: 1 ..< 1,
                    with: String(consonant),
                    in: String(nasal)
                )
                #expect(change?.text == "ん\(consonant)", "\(nasal) then \(consonant)")
            }
        }
    }

    @Test("typing a consonant after an uppercase N turns it into ン")
    func uppercaseNBeforeAConsonantBecomesKatakanaN() {
        for nasal in RomajiCharacters.syllabicNasals.sorted() {
            let upper = Character(nasal.uppercased())
            for consonant in sokuonConsonants
            where !RomajiCharacters.canFollowN.contains(consonant) {
                let change = engine.change(
                    replacing: 1 ..< 1,
                    with: String(consonant),
                    in: String(upper)
                )
                #expect(change?.text == "ン\(consonant)", "\(upper) then \(consonant)")
            }
        }
    }

    @Test("typing the last letter of any spelling in the table completes it")
    func everySpellingCompletes() {
        // The sweep that makes the table's 290 entries reachable rather than merely present.
        for (spelling, kana) in RomajiTable.entries {
            // `n ` is the one spelling whose last character is a space; typing a space is
            // covered by the ん rule above and does not reach the table lookup.
            guard spelling != "n " else { continue }

            let prefix = String(spelling.dropLast())
            let last = String(spelling.suffix(1))
            let change = engine.change(
                replacing: prefix.count ..< prefix.count,
                with: last,
                in: prefix
            )
            #expect(change?.text == kana, "typing \"\(spelling)\"")
        }
    }

    // MARK: - Behaviour the reference had no test for

    @Test("nothing happens on a deletion")
    func deletionIsLeftAlone() {
        #expect(engine.change(replacing: 0 ..< 1, with: "", in: "か") == nil)
    }

    @Test("nothing happens on a paste")
    func pasteIsLeftAlone() {
        // Whole-string conversion is `KanaConverter.convert`, and the caller decides whether
        // a paste should go through it. Converting here would fight the field's own undo.
        #expect(engine.change(replacing: 0 ..< 3, with: "nihon", in: "abc") == nil)
    }

    @Test("typing a vowel over a selection replaces the selection")
    func vowelOverASelection() {
        // Without this the selection is deleted and the vowel is left as a Latin letter,
        // because the lookback has a range it cannot reason about.
        let change = engine.change(replacing: 0 ..< 3, with: "a", in: "xyz")
        #expect(change?.text == "あ")
        #expect(change?.caret == 1)
    }

    @Test("the caret ends up after what was just typed")
    func caretPosition() {
        // A syllable is shorter than the romaji that made it, so the caret has to move back
        // as well as forward. Getting this wrong puts the next character in the wrong place
        // and is invisible until someone types quickly.
        let kya = engine.change(replacing: 2 ..< 2, with: "a", in: "ky")
        #expect(kya?.text == "きゃ")
        #expect(kya?.caret == 2)

        let sokuon = engine.change(replacing: 1 ..< 1, with: "t", in: "t")
        #expect(sokuon?.text == "っt")
        #expect(sokuon?.caret == 2)
    }

    @Test("typing in the middle of the text converts there and leaves the rest alone")
    func typingInTheMiddle() {
        // The lookback is anchored at the caret, not at the end of the string, so a
        // correction made in the middle of an answer converts where it was made.
        let inTheMiddle = engine.change(replacing: 2 ..< 2, with: "a", in: "にほk")
        #expect(inTheMiddle?.text == "にほあk")
        #expect(inTheMiddle?.caret == 3)

        let atTheEnd = engine.change(replacing: 3 ..< 3, with: "a", in: "にほk")
        #expect(atTheEnd?.text == "にほか")
        #expect(atTheEnd?.caret == 3)
    }

    @Test("a trailing n stays an n while there is still a vowel that could follow it")
    func trailingNIsNotCommitted() {
        // The difference between the two paths, and it is right in both. On screen the `n`
        // has to stay, because the next keystroke may be `a` and the answer may be な.
        // Converting the whole string is a decision that the typing has stopped, and only
        // then is the `n` certainly ん.
        #expect(type("nihon", using: engine) == "にほn")
        #expect(type("nihona", using: engine) == "にほな")
        #expect(KanaConverter.convert("nihon").text == "にほん")
    }

    @Test(
        "typing a word and then converting it gives the same answer as converting it whole",
        arguments: ["nihon", "kitte", "sensei", "ra-men", "kanji", "shinbun", "gakkou", "katsu"]
    )
    func incrementalAgreesWithBatch(_ romaji: String) {
        // Two implementations of one idea, and the app runs both: the engine while the user
        // types, then the converter when the answer is submitted. They have to agree at
        // that point, or an answer looks right on screen and is judged against something
        // else.
        let typedThenConverted = KanaConverter.convert(type(romaji, using: engine)).text
        #expect(typedThenConverted == KanaConverter.convert(romaji).text, "\(romaji)")
    }

    @Test("a katakana engine produces katakana")
    func katakanaEngine() {
        let katakana = KanaInputEngine(alphabet: .katakana)
        #expect(type("konpyu-ta-", using: katakana) == "コンピューター")
        #expect(type("kitte", using: katakana) == "キッテ")
    }

    @Test("an out of bounds range is refused rather than trapping")
    func outOfBoundsRange() {
        // The range comes from a text field, which measures in UTF-16 while this measures in
        // characters. A caller that gets the conversion wrong should see nothing happen, not
        // a crash in a review session.
        #expect(engine.change(replacing: 5 ..< 5, with: "a", in: "か") == nil)
        #expect(engine.change(replacing: -1 ..< 0, with: "a", in: "か") == nil)
    }
}

@Suite("Edit distance")
struct LevenshteinTests {
    @Test("the distance to itself is zero")
    func identity() {
        #expect("にほん".levenshteinDistance(to: "にほん") == 0)
        #expect("".levenshteinDistance(to: "") == 0)
    }

    @Test("an empty string is as far away as the other is long")
    func emptyString() {
        #expect("".levenshteinDistance(to: "にほん") == 3)
        #expect("にほん".levenshteinDistance(to: "") == 3)
    }

    @Test(
        "the three edits each cost one",
        arguments: [
            ("かに", "かめ", 1), // substitution
            ("かに", "かにさん", 2), // insertion
            ("かにさん", "かに", 2), // deletion
            ("さる", "かに", 2)
        ]
    )
    func edits(_ first: String, _ second: String, _ distance: Int) {
        #expect(first.levenshteinDistance(to: second) == distance)
    }

    @Test("the distance is symmetric")
    func symmetry() {
        for (first, second) in [("kitten", "sitting"), ("にほん", "にっぽん"), ("", "a")] {
            #expect(first.levenshteinDistance(to: second) == second.levenshteinDistance(to: first))
        }
    }

    @Test("distance counts characters, not UTF-16 code units")
    func nonBMPCharacters() {
        // A rare kanji outside the basic plane is two code units and one character. Counting
        // code units makes a one-character typo look like two edits, which is the difference
        // between an answer being close enough and being wrong. The Objective-C helper this
        // replaces has exactly that bug.
        let withRareKanji = "𠮷野家"
        let withCommonKanji = "吉野家"
        #expect(withRareKanji.levenshteinDistance(to: withCommonKanji) == 1)
        #expect(withRareKanji.count == 3)
    }

    @Test("combining marks count as part of their character")
    func combiningMarks() {
        // が written as か plus a combining mark is one character, and a checker that saw
        // two would treat a correctly spelled answer as a near miss.
        let precomposed = "が"
        let decomposed = "か\u{3099}"
        #expect(precomposed.levenshteinDistance(to: decomposed) == 0)
    }
}

@Suite("Edit distance with transpositions")
struct DamerauLevenshteinTests {
    @Test("swapping two adjacent letters costs one edit, not two")
    func transposition() {
        // The commonest typing mistake there is. Plain Levenshtein charges two, which puts
        // it outside the tolerance for a five letter word and marks a correct answer wrong.
        #expect("water".damerauLevenshteinDistance(to: "watre") == 1)
        #expect("water".levenshteinDistance(to: "watre") == 2)
    }

    @Test("it is optimal string alignment, not unrestricted Damerau-Levenshtein")
    func optimalStringAlignmentNotUnrestricted() {
        // This distinguishes the two algorithms, which the transposition and symmetry cases
        // above cannot: they assert distances the two variants agree on. `CA` to `ABC` is the
        // smallest case where they diverge. Optimal string alignment forbids editing a
        // substring more than once, so it cannot reuse the `C` it already moved and pays 3
        // (insert A, substitute, insert C, or equivalent). Unrestricted Damerau-Levenshtein
        // is free to transpose and then edit again, reaching `ABC` in 2. This package
        // implements optimal string alignment, so it must report 3; a switch to the
        // unrestricted variant would make this fail.
        #expect("CA".damerauLevenshteinDistance(to: "ABC") == 3)
    }

    @Test("it agrees with plain Levenshtein when no transposition is involved")
    func agreesElsewhere() {
        for (first, second) in [
            ("kitten", "sitting"), ("", "abc"), ("abc", ""), ("same", "same"),
            ("mountain", "fountain"), ("a", "b")
        ] {
            #expect(
                first.damerauLevenshteinDistance(to: second)
                    == first.levenshteinDistance(to: second),
                "\(first) to \(second)"
            )
        }
    }

    @Test("the distance to itself is zero and to an empty string is the length")
    func boundaries() {
        #expect("にほん".damerauLevenshteinDistance(to: "にほん") == 0)
        #expect("".damerauLevenshteinDistance(to: "") == 0)
        #expect("にほん".damerauLevenshteinDistance(to: "") == 3)
        #expect("".damerauLevenshteinDistance(to: "にほん") == 3)
    }

    @Test("it is symmetric")
    func symmetry() {
        for (first, second) in [("water", "watre"), ("kitten", "sitting"), ("ab", "ba")] {
            #expect(
                first.damerauLevenshteinDistance(to: second)
                    == second.damerauLevenshteinDistance(to: first)
            )
        }
    }

    @Test("it never exceeds the plain distance")
    func neverWorse() {
        // A transposition is the only case it handles differently, and it handles it more
        // cheaply, so it can only ever be lower.
        for (first, second) in [
            ("water", "watre"), ("abcdef", "badcfe"), ("hello", "olleh"), ("", "x")
        ] {
            #expect(
                first.damerauLevenshteinDistance(to: second)
                    <= first.levenshteinDistance(to: second)
            )
        }
    }
}
