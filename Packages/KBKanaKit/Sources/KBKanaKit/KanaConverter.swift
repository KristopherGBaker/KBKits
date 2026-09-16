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
// The conversion rules around the table, the sokuon rule for a doubled consonant, the ん
// rule, the longest-match lookback, the uppercase-means-katakana convention and the dropping
// of a trailing unfinished syllable, are derived from ios/TKMKanaInput.m in
// https://github.com/davidsansome/tsurukame. Rewritten in Swift as pure functions with no
// UIKit and no text field, with the script folding done by codepoint arithmetic rather than
// through Foundation. See NOTICE.

/// Turns romaji into kana, the way an IME would.
///
/// No Apple API does this and no good package does either, which is why it is here. The
/// replacement table and the rules around it come from Tsurukame, where they were arrived
/// at over years of real answers being typed at a quiz. See NOTICE.
public enum KanaConverter {
    /// What a conversion produced.
    public struct Result: Sendable, Hashable {
        /// The converted text.
        public let text: String

        /// Whether every character became kana.
        ///
        /// `false` when the input ended mid-syllable, as `kats` does. The trailing letters
        /// are dropped rather than left in, because an answer checker comparing against a
        /// reading wants kana or nothing, and a caller that wants to know whether the user
        /// finished typing has this flag to ask.
        public let convertedEverything: Bool

        public init(text: String, convertedEverything: Bool) {
            self.text = text
            self.convertedEverything = convertedEverything
        }
    }

    /// Converts a whole string at once.
    ///
    /// - Parameters:
    ///   - romaji: what the user typed. Text that is already kana passes through untouched,
    ///     so a string half typed on a Japanese keyboard and half on a Latin one converts
    ///     correctly.
    ///   - alphabet: which script to produce.
    public static func convert(
        _ romaji: String,
        to alphabet: KanaAlphabet = .hiragana
    ) -> Result {
        let input = Array(romaji)

        // Built forward into `characters` rather than by splicing a shared buffer. The old
        // shape replaced a middle range of the whole array on every match, which shifts the
        // unprocessed tail each time and makes conversion quadratic in the input length.
        // Here the only mutations are on the tail of `characters`: a match trims the trailing
        // romaji it consumed and appends the kana, and everything already finalised stays put.
        //
        // This is behaviour-preserving. A successful table match or a sokuon can only ever
        // involve ASCII romaji, so the kana already in `characters` never participates in a
        // later match, which is why building forward gives the same answer as the in-place
        // splice it replaces.
        var characters: [Character] = []
        characters.reserveCapacity(input.count)

        for typed in input {
            // A doubled consonant is a sokuon: the FIRST of the pair becomes っ and the
            // second stays to be matched as the start of the next syllable. `kitte` is き,
            // then っ from the first `t`, then て.
            if let previous = characters.last {
                let current = lowercased(typed)
                if current == lowercased(previous),
                   !RomajiCharacters.syllabicNasals.contains(current),
                   RomajiCharacters.consonants.contains(current) {
                    characters[characters.count - 1] = "っ"
                    characters.append(typed)
                    continue
                }
            }

            // Longest match wins, and it is anchored at the character just typed rather
            // than scanning forwards. `kya` has to beat `ka` even though `ka` matched two
            // characters earlier, and it does because this looks back from the end.
            var length = min(RomajiTable.longestKey, characters.count + 1)
            var matched = false
            while length > 0 {
                let candidate = (String(characters.suffix(length - 1)) + String(typed)).lowercased()
                if let replacement = RomajiTable.entries[candidate] {
                    characters.removeLast(length - 1)
                    characters.append(contentsOf: replacement)
                    matched = true
                    break
                }
                length -= 1
            }
            if !matched {
                characters.append(typed)
            }
        }

        // Anything still spelled `n` or `m` had nothing to combine with, so it is ん.
        for index in characters.indices
        where RomajiCharacters.syllabicNasals.contains(lowercased(characters[index])) {
            characters[index] = "ん"
        }

        // A trailing run of unconverted letters is an unfinished syllable. Dropping it is
        // what makes `kats` read as かつ in progress rather than as かつs.
        var convertedEverything = true
        while let last = characters.last, last.isLetter, last.isASCII {
            characters.removeLast()
            convertedEverything = false
        }

        let text = String(characters)
        return Result(
            text: alphabet == .katakana ? toKatakana(text) : text,
            convertedEverything: convertedEverything
        )
    }

    /// Converts hiragana to katakana, leaving everything else alone.
    ///
    /// Done by codepoint arithmetic rather than through `applyingTransform`, which is
    /// Foundation and would make this package platform-bound for no gain. The two scripts
    /// sit at a fixed offset of 0x60 across their whole range, small kana included.
    public static func toKatakana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            // U+3041 ぁ to U+3096 ゖ. The range stops short of the iteration marks at
            // U+3099 and above, which have no katakana counterpart at this offset.
            guard (0x3041 ... 0x3096).contains(scalar.value),
                  let katakana = Unicode.Scalar(scalar.value + 0x60) else {
                return scalar
            }
            return katakana
        }))
    }

    /// Converts katakana to hiragana, leaving everything else alone.
    ///
    /// The direction an answer checker needs: WaniKani accepts a reading typed in either
    /// script, so both sides are folded to hiragana before they are compared.
    public static func toHiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            // U+30A1 ァ to U+30F6 ヶ. Deliberately excludes ヷ to ヺ and the long vowel mark
            // ー at U+30FC, none of which has a hiragana counterpart.
            guard (0x30A1 ... 0x30F6).contains(scalar.value),
                  let hiragana = Unicode.Scalar(scalar.value - 0x60) else {
                return scalar
            }
            return hiragana
        }))
    }

    /// Whether every character is kana, or one of the marks that goes with kana.
    ///
    /// The question an answer checker asks before comparing a typed reading: Latin
    /// characters in the box mean the user typed a meaning where a reading was wanted, and
    /// that deserves a different message from being wrong.
    public static func isKana(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            // Hiragana, katakana, the long vowel mark, and the two iteration marks.
            case 0x3041 ... 0x3096, 0x309D ... 0x309E, 0x30A1 ... 0x30FA, 0x30FC ... 0x30FE:
                true
            default:
                false
            }
        }
    }

    private static func lowercased(_ character: Character) -> Character {
        character.lowercased().first ?? character
    }
}
