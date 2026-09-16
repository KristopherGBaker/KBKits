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
// The character classes the conversion rules turn on, the consonants that make a sokuon and
// the letters that become ん, are derived from ios/TKMKanaInput.m in
// https://github.com/davidsansome/tsurukame. Rewritten in Swift as plain sets rather than
// the Objective-C original. See NOTICE.

/// Which script a conversion produces.
public enum KanaAlphabet: String, Sendable, Hashable, CaseIterable, Codable {
    case hiragana
    case katakana
}

/// Character classes the conversion rules turn on.
///
/// Spelled out here rather than reached for through Foundation's character sets, because
/// what counts as a consonant for the purposes of a doubled-letter sokuon is a decision
/// about romaji input and not a general fact about letters.
enum RomajiCharacters {
    /// Letters that make a sokuon when doubled: `kk` becomes っk.
    ///
    /// Every consonant except the vowels, so `q`, `x` and `l` are in it too. That is
    /// deliberate: `xtu` is a real spelling of っ, and someone typing `qq` has made a typo
    /// either way.
    static let consonants = Set("bcdfghjklmnpqrstvwxyz")

    static let vowels = Set("aeiou")

    /// Letters that become ん when nothing can follow them.
    ///
    /// `m` as well as `n`, because people type `shimbun`. It is not correct romaji and it
    /// is what gets typed.
    static let syllabicNasals: Set<Character> = ["n", "m"]

    /// Letters that may follow an `n` without ending it.
    ///
    /// A vowel can combine with it (`na`), and `y` can (`nya`), and another `n` spells ん
    /// outright. Anything else means the `n` was ん on its own.
    static let canFollowN = Set("aiueony")
}
