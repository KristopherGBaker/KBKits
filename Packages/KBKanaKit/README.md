# KBKanaKit

KBKanaKit converts romaji to kana and measures edit distance: the two pieces a Japanese-input quiz needs that no Apple
API provides. It has no dependencies and does not need Foundation, so it is portable and quick to test.

**What it is not.**

- **Not a Japanese language pipeline.** No tokenizing, no readings, no furigana, no dictionary. Those are
  `KBJapaneseKit` and `KBDictionaryKit`.
- **Not an answer checker.** Deciding whether an answer is close enough, and what to say about it, is policy that
  belongs to whatever asked the question. This library converts and measures; it does not judge.
- **Not a keyboard.** No `UITextField` delegate and no UI of any kind. The consumer owns the text field and calls in.

## Install

KBKanaKit is a product of the KBKits package:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBKanaKit", package: "KBKits")
    ])
]
```

## Quick start

```swift
import KBKanaKit

KanaConverter.convert("katsu").text                      // "かつ"
KanaConverter.convert("konpyu-ta-", to: .katakana).text  // "コンピューター"

let partial = KanaConverter.convert("kats")
partial.text                 // "か": the unfinished syllable is dropped
partial.convertedEverything  // false

"watre".damerauLevenshteinDistance(to: "water")  // 1
"watre".levenshteinDistance(to: "water")         // 2
```

For a live text field, ask the engine what each keystroke should do:

```swift
let engine = KanaInputEngine(alphabet: .hiragana)
if let change = engine.change(replacing: 1..<1, with: "a", in: "k") {
    // change.text == "か", change.caret == 1
} else {
    // nil: let the keystroke happen as typed
}
```

## Transliteration

It comes in the two shapes it is needed in. `KanaConverter.convert(_:to:)` takes a whole string, which is what an
answer checker wants. `KanaInputEngine.change(replacing:with:in:)` takes one keystroke, as a character range, the
inserted text and the field's current text, and returns the field's new contents and caret (in character offsets), or
nil when the keystroke should happen as typed. They agree at the point that matters: type a word a character at a time,
convert the result, and you get what converting the whole word gives.

The table carries 291 spellings: Hepburn (`shi`, `chi`, `tsu`), Kunrei (`si`, `ti`, `tu`), the wapuro conventions an
IME expects (`nn` for ん, `x` or `l` for a small kana, `-` for the katakana long vowel), and a number of spellings that
are simply what someone reaches for under time pressure. Around it sit the rules a table cannot express: a doubled
consonant is a sokuon, an `n` with nothing that can follow it is ん, an uppercase letter means katakana, and a trailing
unfinished syllable is dropped rather than left as Latin text.

Text that is already kana passes through, so a string typed half on a Japanese keyboard and half on a Latin one
converts correctly.

### `nn` and ん

`nn` commits to ん as soon as it is complete, so `annai` gives あんあい and not あんない. That is standard: every Japanese
IME does it, and getting あんない needs `annnai`. It is carried over deliberately rather than improved on, because it is
what a user's fingers already expect. The place to be forgiving about it is an answer checker, not here.

## Edit distance

Levenshtein and Damerau-Levenshtein distances over `Character`, so an answer checker can tell a typo from a different
word, and a rare kanji outside the basic plane counts as one character rather than two. Use the Damerau form for
anything a person typed: swapping two adjacent letters is the commonest mistake there is, and plain Levenshtein charges
two edits for it. That is the difference between "watre" being accepted as "water" and being marked wrong. The Damerau
form is the optimal string alignment variant, linear in memory.

## Main types

| Type | Role |
|---|---|
| `KanaConverter` | Whole-string conversion (`convert(_:to:)`), folding between the scripts (`toKatakana(_:)`, `toHiragana(_:)`), and `isKana(_:)` |
| `KanaConverter.Result` | The converted `text`, and `convertedEverything`, false when the input ended mid-syllable |
| `KanaInputEngine` | One keystroke at a time, for a live text field; returns a `KanaInputEngine.Change` |
| `KanaAlphabet` | `hiragana` or `katakana` |
| `StringProtocol.levenshteinDistance(to:)` | Edit distance in characters |
| `StringProtocol.damerauLevenshteinDistance(to:)` | The same, counting a transposition of adjacent characters as one edit |

## Invariants

- Conversion is a pure function of its input. No state, no locale, no clock.
- Conversion is total: any input produces output, and anything unconvertible passes through rather than being dropped,
  except a trailing unfinished syllable.
- Conversion is idempotent. Kana in, the same kana out.
- No spelling in the table is a prefix of another, which is what the longest-match lookup rests on and why ん is
  spelled `nn`.
- Edit distance operates on `Character`, so a non-BMP character or a combining mark counts once.
- Typing an uppercase letter produces katakana whatever the engine's `alphabet` is, which is how someone answering in
  hiragana enters a katakana word without changing a setting.

## Licensing

KBKanaKit contains code derived from [Tsurukame](https://github.com/davidsansome/tsurukame), under the Apache License
2.0. The replacement table and the rules around it are ported from `ios/TKMKanaInput.m`, and four sweeping tests from
`ios/Tests/TKMKanaInputTest.m`. The derived files keep their license headers and say that they were modified. Nothing
to do with `UITextField` was ported, and the Levenshtein helper is reimplemented over `Character` rather than UTF-16 code
units.

`NOTICE` in this folder lists each derived file and what changed, including the two table entries that differ from the
original for IME parity (`la` is ぁ, and `xtsu` is added beside `ltsu`). `LICENSE-Apache-2.0.txt` is the license text.
An app that ships KBKanaKit should carry both.

## Tests

From the repository root:

```sh
swift test --filter KBKanaKitTests
```
