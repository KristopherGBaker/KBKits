# KBJapaneseKit

KBJapaneseKit reads Japanese text for display and study. It wraps Open JTalk morphology (each word's
surface, base form, in-context reading and pitch accent), validates and repairs those readings against JMdict
before they are shown as furigana, computes per-mora pitch patterns, and downloads the Open JTalk dictionary
on first use. Its `JapaneseFurigana` wiring plugs straight into `KBReadingKit`'s `ReaderContent.build`.

**What it is not.** Display and study only. No speech synthesis lives here; synthesis is a separate concern
and is not part of KBKits.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBJapaneseKit", package: "KBKits"),
        .product(name: "KBDictionaryKit", package: "KBKits"),
        .product(name: "KBReadingKit", package: "KBKits")
    ])
]
```

`KBJapaneseKit` depends on `KBCore`, `KBDictionaryKit`, the `MisakiJapanese` product of the MisakiSwift fork,
and, on Apple platforms, SWCompression. Name `KBDictionaryKit` and `KBReadingKit` too when your code uses
their types, as below. Two licensing obligations come with it: see [Licensing](#licensing).

## Quick start

Download the dictionary once, then read a sentence:

```swift
import KBJapaneseKit

let openJTalk = OpenJTalkDictionary(applicationSupportSubdirectory: "MyApp/openjtalk")
try await openJTalk.ensureAvailable()   // pass onProgress: for byte progress

guard let reader = JapaneseReader() else { return }   // nil until a dictionary is configured
for word in reader.furiganaWords(in: "八百屋で端が見える。") {
    print(word.surface, word.baseForm, word.reading, word.accent.nucleus, word.accent.moraCount)
}
```

Render a document with furigana, the dictionary tier and pitch:

```swift
import KBCore
import KBDictionaryKit
import KBJapaneseKit
import KBReadingKit

let store = JMDictStore(databaseURL: fullJMdictURL)
let furigana = JapaneseFurigana.providers(dictionary: store.isReady ? store : nil)
let content = ReaderContent.build(
    from: document,
    reading: furigana.reading,
    gloss: furigana.gloss,
    baseForm: furigana.baseForm,
    readingPayload: furigana.payload,
    pitch: furigana.pitch,
    annotations: furigana.annotations,
    annotatedPayload: furigana.annotatedPayload,
    compoundReadings: furigana.compoundReadings,
    readingCorroborated: furigana.readingCorroborated
)
```

## The dictionary: `OpenJTalkDictionary`

Open JTalk needs its UTF-8 dictionary on disk, and it is not bundled. `OpenJTalkDictionary` is an actor that
fetches it on first use:

- `init(applicationSupportSubdirectory:)` names the folder under Application Support (for example
  `"MyApp/openjtalk"`). Each app names its own; a shared library has no business writing to another app's.
- `ensureAvailable(onProgress:)` downloads `open_jtalk_dic_utf_8-1.11.tar.gz` (about 23 MB) from the pinned
  Open JTalk v1.11.1 release, verifies it against a pinned SHA-256, extracts it, installs it, points the
  frontend at it (`JapaneseTextAnalysis.useDictionary(at:)`), and returns its directory. On later calls it
  finds the installed copy and only configures it.
- `existingDictionaryDirectory` is the installed directory, or nil, without downloading.
- `OpenJTalkDictionary.requiredFiles` are the four files the frontend loads: `sys.dic`, `matrix.bin`,
  `char.bin`, `unk.dic`.

**Installation is all or nothing.** "Installed" means all four files plus a completion marker. Extraction
happens in a staging directory beside the final one, the marker is written there after the files are checked,
and one rename moves it into place. A download killed halfway leaves the final directory absent or exactly as
it was, never a partial dictionary that passes the presence check and then fails to load. A leftover staging
directory is deleted, never reused.

**Errors are structured.** `StoreError` is `.downloadFailed(DownloadFailure)` (`digestMismatch`, `http`,
`badURL`, `other`), `.extractFailed(ExtractFailure)` (`incompleteDictionary(missing:)`, `unreadableArchive`,
`installFailed`), `.unsupportedPlatform` or `.applicationSupportUnavailable`. A digest mismatch means the pin
or the upstream artifact changed, so a retry will not help; an HTTP or transport failure is worth retrying.
`StoreError` is a `LocalizedError`, so `errorDescription` is ready to show. Cancellation surfaces as
`CancellationError`, unchanged, and is not a download failure. There is no temporary-directory fallback when
Application Support cannot be resolved: the installed dictionary is about 100 MB, and a location the system
may reclaim would mean a silent re-download on every launch.

An app that already has a dictionary on disk skips the actor and calls
`JapaneseTextAnalysis.useDictionary(at:)` itself. `JapaneseTextAnalysis.isDictionaryConfigured` says whether
one is set.

## Morphology: `JapaneseReader`

`JapaneseReader()` returns a reader over the process-wide configured dictionary, or nil when none is
configured. Callers treat nil as "no Japanese analysis available" and fall back, never as an error.
`JapaneseReader(dictionaryDirectory:)` bypasses the global, for tools handed a path. Readers are cheap
`Sendable` wrappers over a shared frontend; make one per build pass.

- `furiganaWords(in:)`: every word with its in-context `reading`, from one analysis of the whole sentence.
  This is the pass display furigana must come from. Re-analyzing a surface alone can re-tokenize it: 静か
  alone becomes 静+か, and the joined reading doubles the か. Words with no reading (punctuation) carry `""`,
  so the surfaces still tile the line.
- `words(in:)`: surface, base form, accent and phrase chaining, with `reading` empty.
- `furiganaReading(for:)` and `baseForm(for:)`: per-surface fallbacks (読んだ has the base form 読む).

`JapaneseReader.Word` carries `surface`, `baseForm`, `reading`, `accent` and `phraseChain`. Accent is a nested
`PitchAccent` (`nucleus`, 1-based, 0 for heiban, and `moraCount`, with `isHeiban`). The two are bundled and
never handed out separately, because a nucleus is meaningless without the mora count it indexes into: 3 is
final-accented on a three-mora word and impossible on a two-mora one. `AccentPhraseChain` is a typed value:
`.beginsPhrase`, `.attachesToPrevious` or `.startsNewPhrase`.

### Reading rules

- **The displayed reading reconciles `pron` and `read`.** Open JTalk's `pron` has the correct sound changes
  (八百 as はっぴゃく) and its `read` has orthographic long vowels (方 as ほう, not the phonetic ほお). Either one
  alone regresses one case or the other.
- **A reading that is not kana is dropped.** Open JTalk answers with its pause symbol 、 for a token it cannot
  pronounce, which drew a comma as furigana over a kanji. An empty reading renders no ruby, which is the
  honest answer. Long vowels and katakana survive; one bad character discards the whole reading.
- **Digits before a counter are read as kanji numerals** (`CounterNumerals`). Open JTalk reads 5年 as とし and
  五年 as ねん, ２人 as ひと and 二人 as ふたり. For one analysis call, a digit run (1 to 9999, no leading zero)
  directly before a counter from a closed list (人, 年, 月, 日, 時, 分, 歳 and others) is rewritten as a kanji
  numeral, and the words are mapped back onto the original text. The rewrite never reaches the document,
  speech or persistence.
- **Surfaces are restored to the caller's characters.** Open JTalk rewrites what it reports (half-width Latin
  widened, numerals converted), which would break alignment for the whole sentence. Where the character count
  is preserved, the original characters are sliced back in.

## The furigana tier

Morphology alone gets readings wrong in ways a reader notices, so readings are validated against JMdict
before display. The tier repairs what it can and leaves alone what it cannot judge. It changes the displayed
reading only; spoken text and document identity never pass through it.

The policy is `KBDictionaryKit`'s `ReadingValidator`: keep Open JTalk's reading when the dictionary
corroborates it or does not know the word, and override only when the reading is impossible for a form the
dictionary knows exactly. A wrong override is worse than a missed fix. Placement spans ride along only when
the exact final (form, reading) pair has a JmdictFurigana row; spans are never fabricated. When Open JTalk
cannot read a rare kanji at all (啣, 縊, 瞠), or answers with only the token's okurigana (搔い read い), the
dictionary is asked for a reading instead. The result's `candidates` let a reader pick another reading.

- `FuriganaTier.payloadProvider(dictionary:reading:baseForm:)`: the per-surface tier, or nil when there is no
  dictionary (nil keeps the build identical to the untiered path, with no store queries).
- `FuriganaTier.annotatedPayloadProvider(dictionary:)`: the tier over a known in-context reading.
- `FuriganaTier.liveProvider(dictionary:)`: the per-surface tier over the live reader, or nil without one.
- `FuriganaAlignment.align(surfaces:words:)`: maps one sentence's analysis onto the caller's display tokens by
  character offset. A token whose edges both fall on analysis boundaries gets a `TokenAnnotation`; a token
  that straddles a word boundary gets nil, and later tokens resynchronize. When the two tilings do not cover
  the same text, the result is empty, not all nil, so a caller can tell "the analysis does not describe this
  text" from "tiled, placed nothing".

## Wiring it up: `JapaneseFurigana`

`JapaneseFurigana.providers(dictionary:reader:)` assembles every closure a Japanese document needs, in the
right order, so an app does not have to. All are `Sendable`, so build them once and hand them to a detached
tokenization pass.

| Member | What it is |
|---|---|
| `annotations` | One in-context analysis per sentence, aligned onto the caller's tokens. Display readings come from here. |
| `annotatedPayload` | The tier over that in-context reading. |
| `reading`, `baseForm`, `payload` | Per-surface fallbacks for tokens the aligner could not place, and for callers with no sentence. |
| `gloss` | The English source word of a katakana loanword. |
| `pitch` | Per-word pitch patterns for a tokenized sentence. |
| `compoundReadings` | A joined form's readings with spans, memoized, for the compound join. |
| `readingCorroborated` | The dictionary corroboration gate, memoized, for author-ruby propagation. |

- A nil `dictionary` turns the tier, the gloss, the compound join and the corroboration gate off, and costs
  no dictionary queries.
- A nil reader (`reader: nil`, or the default `JapaneseReader()` with no dictionary configured) gives only
  the gloss. The reader still works, with the tokenizer's own readings.
- `compoundReadings` and `readingCorroborated` refuse the bundled seed (`JMDictStore.isUsingBundledSeed`). A
  46-entry dictionary is worse than none here: sparse coverage can let the join override a reading that full
  coverage would have left alone, and "not corroborated" is the branch that acts.

## Pitch accent

Open JTalk computes accent on every parse, and `JapaneseReader.Word` carries it across this seam so a consumer
can draw pitch without importing the frontend.

- **Moras, not characters.** `MoraSplitter.moras(in:)` splits a kana reading into moras, the unit pitch
  notation is drawn over. A small kana fuses with the kana before it (きゃ, ファ), while ー, っ/ッ and ん/ン are
  each a mora of their own: コーヒー is four moras, きって three, にほん three. It needs no dictionary, and
  joining the result reproduces the input.
- **Phrases, not words.** `AccentPhrase.group(_:)` walks each word's `phraseChain`, opening a phrase on
  `.beginsPhrase` or `.startsNewPhrase` and extending it on `.attachesToPrevious`. A phrase is never empty, so
  `head` and its forwarded `accent` are always defined. A phrase never re-resolves accent; it forwards its head
  word's, so the frontend's analysis stays the single source of truth. No word is dropped, duplicated or
  reordered.
- **Patterns.** `PitchPattern.patterns(for:reading:)` levels each phrase's whole mora run from its head's
  nucleus with the two-level Tokyo pattern, then slices it back to each word, so the drop can land on a mora a
  later word (a particle) contributes. Heiban: first mora low, the rest high, no drop. Atamadaka: first mora
  high, the rest low, drop after the first. Nucleus n of 2 or more: first mora low, moras 2 to n high, the rest
  low, drop after mora n. A word with no reading keeps an empty pattern.
- `PitchPattern.patterns(in:using:)` runs the whole chain over text. `alignedPatterns(forSurfaces:using:)`
  maps patterns onto the caller's word split and returns nil for a word the analysis cannot spell exactly: a
  mark on the wrong mora teaches the wrong word.

Pitch cannot be a per-word closure. 端 (heiban) and 橋 (odaka) both read はし and are both low-HIGH alone;
they differ only once a particle joins the phrase, 端が low-HIGH-HIGH and 橋が low-HIGH-low. A closure given
only 端 cannot see the が.

```swift
let phrases = AccentPhrase.group(reader.words(in: "橋が見える"))
let patterns = PitchPattern.patterns(in: "橋が見える", using: reader)   // one [MoraPitch] per word
let moras = MoraSplitter.moras(in: "きって")                          // ["き", "っ", "て"]
```

## Threading

`JapaneseReader`, `JapaneseFurigana` and its closures, and the tier providers are `Sendable`. The providers
memoize behind a `Mutex`, so one provider serves one document build from any task. `OpenJTalkDictionary` is an
actor. The dictionary location is process-global in MisakiSwift, and that global has no synchronization of its
own. `JapaneseTextAnalysis` is the only code in KBKits that reads or writes it, always under one lock, and it
deliberately exposes no mutable static of its own. `useDictionary(at:)` writes nothing when the directory is
unchanged.

## Platforms

On Apple platforms the dictionary downloads and unpacks in pure Swift (SWCompression's gzip and tar), so it
works on iOS, where there is no `Process` and no `tar`. Elsewhere there is no download path:
`ensureAvailable` throws `StoreError.unsupportedPlatform`, and the host ships the dictionary (an Android asset,
for example) and calls `JapaneseTextAnalysis.useDictionary(at:)`.

**No MLX is linked.** This library takes the fork's `MisakiJapanese` product, which is the Open JTalk reading
path alone, with no mlx-swift and no CoreFoundation. SwiftPM still resolves the fork's MLX packages, and they
are listed in the root `NOTICE`, but nothing here compiles or links against them, which keeps this library in
the ordinary `swift test` loop and able to cross-compile. MisakiSwift is required at its exact `1.1.0-kits.1` tag (see
the root README, "Dependencies on forks"). An app that also depends on upstream `mlalma/MisakiSwift`
conflicts with KBKits.

## Licensing

**The runtime dictionary is BSD-licensed, and you must reproduce its notices.** It is not committed here and
it is not Apache-2.0: it is a three-part work under three three-clause BSD notices, for NAIST, the UniDic
Consortium, and Open JTalk with the Nagoya Institute of Technology. The archive's own `COPYING` is the
authoritative text, and the extractor writes it out with the dictionary rather than filtering it. Once the
dictionary reaches a user's device your app has redistributed it, so **reproduce all three notices in full in
your documentation or About material**, keep the non-endorsement clauses intact, and leave `COPYING` in place.
Detail is in the root `NOTICE` and in `Licenses/OpenJTalk-Dictionary-NOTICES.md`.

**The dictionary data is CC BY-SA 4.0.** Furigana repair reads `KBDictionaryKit`, whose bundled databases are
CC BY-SA 4.0. **Credit the data in your About screen** as `Packages/KBDictionaryKit/README.md` describes.

## Testing

```sh
swift test --filter KBJapaneseKitTests
OJT_DICT_DIR=/path/to/open_jtalk_dic_utf_8-1.11 swift test --filter KBJapaneseKitTests
```

`KBJapaneseKitTests` declares `KBJapaneseKit`, `KBCore`, `KBDictionaryKit`, `KBReadingKit` and `MisakiJapanese`
directly, one per module the tests import themselves. The suites that need a real Open JTalk dictionary read
its path from `OJT_DICT_DIR` and nothing else, so they skip with a reason when it is unset rather than reaching
into any application's container. The download tests build a small `tar.gz` in a temporary directory, so the
real download, stage, extract and install path runs offline against a real archive. Cross-library tests build
a real `ReaderContent` to show the furigana tier survives `KBReadingKit`'s tokenizer.
