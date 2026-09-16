# KBKanaKit

Romaji-to-kana transliteration and edit distance.

## What it is

The two pieces of machinery a Japanese-input quiz needs and that no Apple API provides.

**Transliteration, in both the shapes it is needed in.** `KanaConverter.convert` takes a
whole string, which is what an answer checker wants. `KanaInputEngine.change` takes one
keystroke and returns what the field should contain, which is what a text field wants while
someone is still typing. They agree at the point that matters: type a word a character at a
time, convert the result, and you get what converting the whole word gives.

The table carries 290 spellings: Hepburn (`shi`, `chi`, `tsu`), Kunrei (`si`, `ti`, `tu`),
the wapuro conventions an IME expects (`nn` for ん, `x` or `l` for a small kana, `-` for the
katakana long vowel), and a number of spellings that are simply what someone reaches for
under time pressure. Around it sit the rules a table cannot express: a doubled consonant is
a sokuon, an `n` with nothing that can follow it is ん, an uppercase letter means katakana,
and a trailing unfinished syllable is dropped rather than left as Latin text.

**Edit distance.** Levenshtein and Damerau-Levenshtein over `Character`, so an answer
checker can tell a typo from a different word, and so a rare kanji outside the basic plane
counts as one character rather than two. Use the Damerau form for anything a person typed:
swapping two adjacent letters is the commonest mistake there is and plain Levenshtein
charges two edits for it, which is the difference between "watre" being accepted as "water"
and being marked wrong.

Zero dependencies, Foundation not required, so it is portable and instant to test.

## What it is NOT

- **Not a Japanese language pipeline.** No tokenizing, no readings, no furigana, no
  dictionary. Those are `KBJapaneseKit` and `KBDictionaryKit`.
- **Not an answer checker.** Deciding whether an answer is close enough, and what to say
  about it, is policy that belongs to whatever asked the question. This package converts and
  measures; it does not judge.
- **Not a keyboard.** No `UITextField` delegate and no UI of any kind. The consumer owns the
  text field and calls in.

## Key types

| Type | Role |
|---|---|
| `KanaConverter` | Whole-string conversion, and folding between the two scripts |
| `KanaInputEngine` | One keystroke at a time, for a live text field |
| `KanaAlphabet` | Hiragana or katakana |
| `String.levenshteinDistance(to:)` | Edit distance in characters |
| `String.damerauLevenshteinDistance(to:)` | The same, counting a transposition as one edit |

## Invariants

- Conversion is a pure function of its input. No state, no locale, no clock.
- Conversion is total: any input produces output, and anything unconvertible passes through
  rather than being dropped, except a trailing unfinished syllable.
- Conversion is idempotent. Kana in, the same kana out.
- No spelling in the table is a prefix of another, which is what the longest-match lookup
  rests on and why ん is spelled `nn`.
- Edit distance operates on `Character`, so a non-BMP character or a combining mark counts
  once.

## One behaviour worth knowing about

`nn` commits to ん as soon as it is complete, so `annai` gives あんあい and not あんない.
That is standard: every Japanese IME does it, and getting あんない needs `annnai`. It is
carried over deliberately rather than improved on, because it is what a user's fingers
already expect. The place to be forgiving about it is an answer checker, not here.

## Provenance

The replacement table and the rules around it are ported from `ios/TKMKanaInput.m` in
[Tsurukame](https://github.com/davidsansome/tsurukame), Apache 2.0, along with the four
sweeping tests from `ios/Tests/TKMKanaInputTest.m`. The files that are derived keep their
licence headers and say that they were modified. What is not ported is anything to do with
`UITextField`.
