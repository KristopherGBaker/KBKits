# KBJapaneseKit

The Japanese reading pipeline: Open JTalk morphology, the JMdict furigana tier that validates
and repairs those readings for display, pitch accent, and the on-first-use Open JTalk dictionary
download.

**What it is not.** Display and study only. No speech synthesis lives here; a synthesis package
is a separate concern and is not part of KBKits.

## Key types

- `JapaneseReader`: the entry point. Text in, `JapaneseTextAnalysis` out.
- `JapaneseReader.Word`: one analyzed word carrying surface, base form, and pitch accent. Accent
  is a nested `PitchAccent` (nucleus plus mora count, kept inseparable) and an `AccentPhraseChain`
  typed value that says whether the word begins a phrase, attaches to the previous word, or
  starts a new one.
- `MoraSplitter`: pure string logic that splits a kana reading into moras (the unit pitch
  notation is drawn over): small kana fuse with the preceding kana, while ー, っ/ッ, and ん/ン are
  each their own mora. Dictionary-free and lossless: joining the result reproduces the input.
- `AccentPhrase`: the grouping of words a single pitch pattern is drawn over. `group(_:)` walks
  each `JapaneseReader.Word.phraseChain`, opening a phrase on `beginsPhrase`/`startsNewPhrase` and
  extending it on `attachesToPrevious`. Non-empty by construction, so `head` (first word) and its
  forwarded `accent` are always defined.
- `JapaneseFurigana` / `FuriganaTier`: reading assignment, and the tier that repairs it.
- `OpenJTalkDictionary` / `StoreError`: the on-first-use download.

## Invariants

- **Furigana is validated against JMdict before display.** Morphology alone gets readings wrong
  in ways a reader notices; the tier repairs what it can and marks what it cannot.
- **Pitch accent crosses this seam.** Open JTalk computes accent on every parse and MisakiSwift
  reads it back per word; `JapaneseReader.Word` carries the nucleus, mora count, and accent-phrase
  chaining through so a consumer can render pitch without importing the frontend. Accent is
  meaningless without its mora count, so the two are bundled and never handed out separately.
- **Moras, not characters; phrases, not words.** Pitch notation draws over moras and belongs to
  the accent phrase, so `MoraSplitter` and `AccentPhrase` supply both as pure functions. An
  `AccentPhrase` never re-resolves accent: it forwards its head word's, keeping the frontend's
  analysis the single source of truth. Grouping is closed over the three chain states, and no
  word is ever dropped, duplicated, or reordered.
- **Sole declarer of MisakiSwift and SWCompression.**
- **No MLX is linked.** This package takes the `MisakiJapanese` product, which is the Open JTalk
  reading path alone. SwiftPM still RESOLVES the fork's MLX packages, and they are listed in the
  root `NOTICE`, but nothing here compiles or links against them, which is what keeps this
  package in the ordinary `swift test` loop and able to cross-compile.

## MisakiSwift is pinned to a BRANCH, not a tag

The root `Package.swift` pins `https://github.com/KristopherGBaker/MisakiSwift` to the
`feat/japanese-g2p` branch, because the fork carries no tag yet. That pin **must become a tagged
version before KBKits is released**: a branch pin floats under every consumer, and SwiftPM will
not accept one at all from a package resolved by version. No version is invented here in the
meantime. See README.md at the repository root, section "Before a release".

## The runtime dictionary is BSD-licensed, and you must reproduce its notices

`OpenJTalkDictionary` downloads `open_jtalk_dic_utf_8-1.11.tar.gz` from the pinned Open JTalk
v1.11.1 release on first use, verifies it against a pinned SHA-256, and installs it atomically.
It is not committed here, and it is not Apache-2.0: it is a three-part work under three
three-clause BSD notices, for NAIST, the UniDic Consortium, and Open JTalk with the Nagoya
Institute of Technology.

The archive's own `COPYING` is the authoritative text, and the extractor writes it out with the
dictionary rather than filtering it. Once the dictionary reaches a user's device your app has
redistributed it, so **reproduce all three notices in full in your documentation or About
material**, keep the non-endorsement clauses intact, and leave `COPYING` in place. Detail is in
the root `NOTICE` and in `Licenses/OpenJTalk-Dictionary-NOTICES.md`.

Furigana repair reads `KBDictionaryKit`, whose bundled databases are CC BY-SA 4.0. **Credit the
data in your About screen** as `Packages/KBDictionaryKit/README.md` describes.

## Testing

`KBJapaneseKitTests` declares `KBJapaneseKit`, `KBCore`, `KBDictionaryKit`, `KBReadingKit` and
`MisakiJapanese` directly, one per module the tests import themselves. The suites that need a
real Open JTalk dictionary read its path from `OJT_DICT_DIR` and nothing else, so they SKIP with
a reason when it is unset rather than reaching into any application's container:

```sh
OJT_DICT_DIR=/path/to/open_jtalk_dic_utf_8-1.11 swift test
```

The download tests build a small `tar.gz` in a temporary directory, so the real
download, stage, extract and install path runs offline against a real archive.
