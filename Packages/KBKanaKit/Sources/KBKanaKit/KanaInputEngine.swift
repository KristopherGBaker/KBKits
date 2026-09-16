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
// The keystroke conversion rules, the sokuon rule, the ん rule and the longest-match
// lookback, are derived from ios/TKMKanaInput.m in
// https://github.com/davidsansome/tsurukame. Rewritten in Swift as a pure function of the
// text, the range and the typed character, with no UITextFieldDelegate. See NOTICE.

/// Converts romaji to kana as it is typed, one character at a time.
///
/// The half of the problem ``KanaConverter`` does not solve. Converting a finished string
/// is straightforward; converting while someone is still typing means deciding, on every
/// keystroke, whether what is on screen has become a syllable yet, and doing it without a
/// text field to hold state in.
///
/// Deliberately not a `UITextFieldDelegate`. This is a pure function of the text, the range
/// being replaced and the character being typed, so it can be tested without a view and
/// used from any input control. The delegate that calls it belongs to the UI layer.
public struct KanaInputEngine: Sendable, Hashable {
    /// Which script to produce.
    ///
    /// Typing an uppercase letter produces katakana whatever this is set to, which is how
    /// someone answering in hiragana enters a katakana word without changing a setting.
    public var alphabet: KanaAlphabet

    public init(alphabet: KanaAlphabet = .hiragana) {
        self.alphabet = alphabet
    }

    /// What a field should contain after a keystroke.
    public struct Change: Sendable, Hashable {
        /// The complete new contents of the field.
        public let text: String

        /// Where the caret goes, as an offset in characters.
        public let caret: Int

        public init(text: String, caret: Int) {
            self.text = text
            self.caret = caret
        }
    }

    /// Works out what a keystroke should do.
    ///
    /// - Parameters:
    ///   - range: the range of characters being replaced, in character offsets. Empty for a
    ///     plain insertion.
    ///   - input: what is being inserted. Empty for a deletion.
    ///   - text: what the field contains now.
    /// - Returns: the field's new contents, or `nil` when nothing special applies and the
    ///   keystroke should be left to happen as typed.
    public func change(replacing range: Range<Int>, with input: String, in text: String) -> Change? {
        let characters = Array(text)
        guard range.lowerBound >= 0, range.upperBound <= characters.count else { return nil }

        // Typing a vowel over a selection replaces it outright. Without this the selection
        // is deleted and the vowel is left as a Latin letter, because the lookback below
        // sees a range it cannot reason about.
        if !range.isEmpty, input.count == 1, let vowel = replacementForLoneVowel(input) {
            var result = characters
            result.replaceSubrange(range, with: vowel)
            return Change(text: String(result), caret: range.lowerBound + vowel.count)
        }

        // A deletion, or a paste over a selection, is the field's own business.
        guard range.isEmpty, input.count == 1, let typed = input.first else { return nil }
        let position = range.lowerBound

        if position > 0 {
            let previous = characters[position - 1]
            let wantsKatakana = previous.isUppercase || alphabet == .katakana

            // A doubled consonant is a sokuon. The first of the pair becomes っ and the
            // typed character stays, to be matched as the start of the next syllable.
            if lowercased(typed) == lowercased(previous),
               !RomajiCharacters.syllabicNasals.contains(lowercased(typed)),
               RomajiCharacters.consonants.contains(lowercased(typed)) {
                var result = characters
                result[position - 1] = wantsKatakana ? "ッ" : "っ"
                result.insert(typed, at: position)
                return Change(text: String(result), caret: position + 1)
            }

            // An `n` with nothing that can follow it is ん. `n` itself is excluded because
            // `nn` is how ん is spelled outright, and `y` and the vowels because they
            // combine.
            if lowercased(typed) != "n",
               RomajiCharacters.syllabicNasals.contains(lowercased(previous)),
               !RomajiCharacters.canFollowN.contains(lowercased(typed)) {
                var result = characters
                result[position - 1] = wantsKatakana ? "ン" : "ん"
                result.insert(typed, at: position)
                return Change(text: String(result), caret: position + 1)
            }
        }

        // Longest match first, looking back from the character just typed. `kya` has to win
        // over `ya`, and it only can if the longest candidate is tried first.
        let longestLookback = min(RomajiTable.longestKey - 1, position)
        for lookback in stride(from: longestLookback, through: 0, by: -1) {
            let start = position - lookback
            let candidate = String(characters[start ..< position]) + String(typed)
            guard let replacement = replacement(for: candidate) else { continue }

            var result = characters
            result.replaceSubrange(start ..< position, with: replacement)
            return Change(text: String(result), caret: start + replacement.count)
        }

        return nil
    }

    /// The kana for a single vowel, honouring case and the configured script.
    private func replacementForLoneVowel(_ input: String) -> String? {
        guard let character = input.first,
              RomajiCharacters.vowels.contains(lowercased(character)) else { return nil }
        return replacement(for: input)
    }

    /// Looks a candidate up, deciding hiragana or katakana from its first letter.
    private func replacement(for candidate: String) -> String? {
        guard let kana = RomajiTable.entries[candidate.lowercased()] else { return nil }
        let wantsKatakana = candidate.first?.isUppercase == true || alphabet == .katakana
        return wantsKatakana ? KanaConverter.toKatakana(kana) : kana
    }

    private func lowercased(_ character: Character) -> Character {
        character.lowercased().first ?? character
    }
}
