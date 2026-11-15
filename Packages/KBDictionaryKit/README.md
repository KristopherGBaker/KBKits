# KBDictionaryKit

KBDictionaryKit looks up Japanese words in JMdict and kanji in KANJIDIC2. It holds the read-only dictionary
stores, the value types behind a reader's meaning popover and kanji cards, and the policy that validates and
repairs a morphological analyzer's readings against the dictionary (the brain of `KBJapaneseKit`'s furigana
tier).

Two SQLite databases ship inside it: a small curated JMdict seed and a trimmed KANJIDIC2. A full JMdict is
about 66 MB, so it is not bundled: an app builds or downloads one and passes its URL.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBDictionaryKit", package: "KBKits")
    ])
]
```

It depends on `KBCore` and, on Apple platforms only, GRDB. Linking it ships the bundled databases, which are
CC BY-SA 4.0 data you must credit (see [Licensing](#the-bundled-data-is-cc-by-sa-40-and-you-must-credit-it)).

## Quick start

```swift
import Foundation
import KBDictionaryKit

// A full JMdict in Application Support when the app has one; the bundled seed otherwise.
let fullDictionary = URL.applicationSupportDirectory.appending(path: "MyApp/jmdict.sqlite")
let words = JMDictStore(databaseURL: fullDictionary)
if words.isUsingBundledSeed {
    // Tell the person the dictionary is not installed, rather than that a word has no entry.
}

// 食べました is looked up as 食べる.
for entry in words.lookup(deinflecting: "食べました") {
    print(entry.headword, entry.primaryReading ?? "", entry.senses.first?.glosses ?? [])
}

// Kanji cards for a word, in order, skipping kana and duplicates.
let kanji = KanjiStore()
for card in kanji.entries(in: "学校") {
    print(card.character, card.onReadings, card.kunReadings, card.glossLine)
}
```

## Word lookup: `JMDictStore`

`JMDictStore` is the policy layer and what callers use. `init(databaseURL:)` opens the best dictionary
available, in this order:

1. The full dictionary at `databaseURL`, when the file exists and carries the schema the queries need.
2. The bundled seed, when there is no URL, no file, or the file is malformed. A database that opens but lacks
   the schema is treated exactly like a missing one, so `isReady` never reports a store that then fails
   every lookup.
3. An empty store, when neither opens. Lookups return nothing and the caller shows "no entry".

`isReady` answers "did a database open", and it is true for the seed too. `isUsingBundledSeed` answers "is
this only the seed". The seed holds a few dozen entries, so a caller that treats `isReady` as "lookup works"
would offer lookups that miss on almost every word. Say which case it is.

Lookups:

- `lookup(form:limit:)`: entries whose kanji headword or kana reading matches exactly. Default limit 8.
- `lookup(deinflecting:limit:)`: the exact form first, then `Deinflector` candidates (読んだ as 読む,
  食べました as 食べる, 高かった as 高い), returning the first that hits. Never worse than a plain lookup.
- `lookup(base:surface:)`: the base form first (from an analyzer such as Open JTalk), then the surface, for
  tokens with no morphological base (numbers, names, particles).
- `englishGloss(forKatakana:)`: the English source word of a katakana loanword (コミュニケーション as
  "communication"). Nil for wasei-eigo, non-English loans and native katakana, which the build excludes, and
  nil when the dictionary predates the gloss column.
- `kanaReadings(forForm:)`: every kana form of every entry listing the form as a headword or variant (無暗
  resolves to むやみ through the 無闇/無暗 entry). The lean path the validator calls per kanji token.
- `kanaReadings(forFormsStartingWith:limit:)` and `corroborates(form:reading:limit:)`: whether any entry
  whose kanji form begins with `form` has a reading beginning with `reading`, both folded to hiragana. 覗
  read のぞ is accounted for by 覗く, 撫 read な by 撫でる. False is the interesting answer: a kun concatenation
  over a name (司波 read つかさなみ) that no dictionary form supports. The default limit, 4000, sits above the
  worst case in the shipping JMdict (大 heads 1,890 readings), because truncation can only fail to
  corroborate, and failing to corroborate is the branch that acts.
- `furiganaSegments(form:reading:)`: per-character placement spans for the exact (form, reading) pair from
  JmdictFurigana, tiling the whole form, with nil kana at okurigana positions. Exact pair only: a base form's
  reading never transfers to a surface unchecked (来る is くる, but 来た is きた). Empty when the pair is
  unknown or the dictionary predates the `furigana` table.

Value types: `JMDictEntry` (`id`, `kanjiForms`, `kanaForms`, `senses`, plus `headword` and
`primaryReading`), `JMDictSense` (`pos`, `glosses`), `FuriganaSpan` (`range` over characters, `kana`), and
`JmdictFuriganaParser`, which parses the dataset's `kanji|reading|segmentation` lines.

## Kanji lookup: `KanjiStore`

`KanjiStore()` opens the bundled KANJIDIC2. `init(databaseURL:)` points it at another build (a test fixture,
or a fuller build an app ships). An override that opens but lacks the `kanji` table falls back to the bundled
database, so a caller is never handed blank cards.

- `entry(for:)` takes a `Character` and returns nil for a character outside the shipped set (a rare variant,
  a name-only character) or one that is not a kanji.
- `entries(in:)` returns every kanji in a word in order, skipping kana, punctuation and characters with no
  entry, and collapsing duplicates (人人 is one card). The iteration mark 々 is not asked about.
- `isReady` false means the caller should not offer kanji cards at all.

A `KanjiEntry` is one character as a learner studies it, a different unit from a word. `onReadings` are in
KANJIDIC's katakana. `kunReadings` keep KANJIDIC's convention verbatim: a dot separates the part the
character covers from its okurigana (`まな.ぶ`), and a hyphen marks a prefix or suffix position. It also has
`meanings` (most common first, and `glossLine` joins them), `strokeCount`, `grade` (1 to 6 for kyōiku kanji,
8 for the rest of the jōyō set, 9 and 10 for name-use characters) and `frequency` (newspaper rank, nil outside
the top 2,500).

## Reading validation: `ReadingValidator`

`ReadingValidator(dictionary:)` judges one analyzer reading against a `ReadingDictionary` (`JMDictStore`
conforms; tests pass fakes). `validate(surface:baseForm:ojtReading:)` returns a `ReadingVerdict`:

- `.consistent(segmentation:)`: the dictionary corroborates the reading. Keep it.
- `.impossible(repair:)`: the dictionary knows this exact surface, and the reading matches nothing it lists.
  Apply the `ReadingRepair` (its first reading, with spans only when that exact pair has a row).
- `.unknown`: the dictionary does not know the surface. Leave the analyzer alone.

```swift
let validator = ReadingValidator(dictionary: words)
switch validator.validate(surface: "行衛", baseForm: "行衛", ojtReading: "ゆきえ") {
case .consistent:
    break                                   // keep the analyzer's reading
case .impossible(let repair):
    print(repair?.reading ?? "")            // ゆくえ
case .unknown:
    break                                   // the dictionary has nothing to say
}
```

The rules, in order:

1. **Kana-only surfaces** (する, コーヒー) read as themselves and are always consistent.
2. **Exact corroboration**: the reading is one the dictionary lists for the surface. Contextual choices such
   as 行った as いった or おこなった are both correct, so both are kept.
3. **Inflected corroboration**: a base form's reading is carried to the surface by swapping the kana tail
   (行く いく for 行った gives いった). An unsound transfer (来る くる for 来た gives くた) fails the comparison,
   so inflected surfaces are never overridden.
4. **Sandhi corroboration**: the reading is a listed one with a regular change a neighbor caused, which a
   dictionary never lists. Handakuon on the first mora (分 ふん as ぷん in 三十分, 本 ほん as ぽん in 三本) and
   gemination on the last (八 はち as はっ in 八分) are accepted. Without this, 五時三十八分 was "repaired" to
   ごじさんじゅうはちぶ. Rendaku (か to が) is deliberately not accepted: on a measured corpus it only cost
   correct readings, because a rendaku reading is also an ordinary word-initial reading and telling them apart
   needs a word boundary this seam does not have. 連声, vowel fusion and irregular counter forms are not
   modeled.
5. **Impossible**: the dictionary knows the exact surface and none of the above matched.
6. **Unknown** otherwise.

A wrong override is worse than a missed fix, so every ambiguity leans away from `.impossible`.

`validate(surface:ojtReading:baseForm:)` takes the base form as a closure, because deriving it costs a second
analyzer pass and it is needed only when the exact check misses. `detailed(surface:ojtReading:baseForm:)`
also returns the candidate readings for the surface, which a reading-choice affordance needs.

`readingWhenUnreadable(surface:)` is for a surface the analyzer could not read at all (rare or old-form
kanji such as 啣, 縊, 瞠). It asks the dictionary, mostly through the inflected form (啣え from 啣える), and
returns the reading with all candidates so a reader can correct it. A form the dictionary does not know
returns nil; nothing is invented.

`Sandhi.isVariant(_:of:)`, `Sandhi.source(of:among:)` and `Sandhi.transfer(_:from:to:)` expose the sandhi
test and move a placement row onto the variant reading. `Deinflector.candidates(for:)` over-generates base
forms, most specific first, and lets the dictionary filter them. It is single-step: common inflections, not
nested ones such as ていた or させられる.

## Design notes

- **Read-only.** Nothing here writes a dictionary. `Tools/build-jmdict.swift` and `Tools/build-kanjidic.swift`
  at the repository root build them, offline, from the published sources.
- **Depends only on KBCore and GRDB**, so it stays off any playback or speech path and is testable on its own.
- **A curated seed ships as a bundled resource**, so a fresh checkout works before a full dictionary exists.
  KANJIDIC2 ships whole, because the filtered database is small enough (332 KB for about 3,100 characters).
- **The database is behind `JMDictStorage`, and everything above it is pure Swift.** Deinflection, the
  base-then-surface fallback and furigana segmentation parsing are policy and never touch SQL.
  `SQLiteJMDictStorage` (GRDB) and `EmptyJMDictStorage` implement it, and `JMDictStore(storage:)` accepts
  any implementation, including a test fake. Kanji storage has the same shape: `KanjiStorage`,
  `SQLiteKanjiStorage`, `EmptyKanjiStorage`.
- **A missing dictionary is not an error.** Every storage method returns empty rather than throwing, because a
  miss and an unavailable dictionary look the same to a reader.
- **Nothing here prints.** A lookup term is what a person is reading and a database path carries their home
  directory, so diagnostics go to `Logger` with `privacy: .private` (the term is not collected at all) and
  never to stdout. `StdoutPrivacyTests` captures fd 1 during a forced open failure and a forced query failure
  and fails if either string appears.
- **Resource lookup never names the enclosing package.** Both bundled databases are found through
  `Bundle.module` on Apple platforms and through a target-keyed `PackageResourceLocator` call elsewhere, so the
  target survives being copied into a differently named package. `KBKitsResourceLayoutTests` pins that from
  inside KBKits.
- **Threading.** `JMDictStore` and `KanjiStore` are `Sendable` final classes. The SQLite storages read through
  GRDB's `DatabaseQueue`, so one store can be shared across tasks.

## Platforms

GRDB is declared `.when(platforms:)` for the Apple platforms only, and `KBDictionaryKit` is the only KBKits
target that depends on it (`KBJapaneseKit` reaches it through this library). GRDB's CSQLite links the system
sqlite3, and the Android NDK ships no SQLite headers or library. So on Android `SQLiteJMDictStorage` and
`SQLiteKanjiStorage` compile out, `JMDictStore(databaseURL:)` and `KanjiStore(databaseURL:)` fall back to the
empty storages, lookups return nothing, and the caller shows "no entry". The initializers keep their URL
parameter, so callers need no conditional compilation. A future Android backend implements `JMDictStorage`'s
five members and nothing above it changes.

## The bundled data is CC BY-SA 4.0, and you must credit it

`Sources/KBDictionaryKit/Resources/jmdict-seed.sqlite` and `Sources/KBDictionaryKit/Resources/kanjidic.sqlite`
are not under the repository's Apache-2.0 license. They are derived from JMdict and JmdictFurigana (EDRDG and
James Breen; Doublevil) and from KANJIDIC2 (EDRDG), all under CC BY-SA 4.0.

If you link this library, you ship that data, which means you redistribute it. **Credit the data in your About
screen**: name JMdict and the Electronic Dictionary Research and Development Group with James Breen, name
KANJIDIC2 and EDRDG, name JmdictFurigana and Doublevil, say the data is licensed CC BY-SA 4.0 with a link to
the license, and say that it has been modified. The root `NOTICE` has the exact wording, the source URLs, the
snapshot the committed files were built from, every transformation applied, and the rebuild procedure. The
license text is in `Licenses/CC-BY-SA-4.0.txt`. A full JMdict your app builds or downloads is the same data
under the same license.

## Rebuilding the databases

Both scripts run from the repository root with no package dependencies (raw sqlite3, system `gunzip`), so a
rebuild is reproducible from the published sources alone:

```sh
# Full JMdict, roughly 66 MB. Not committed; an app caches or ships its own.
# Without an output path it writes build/jmdict.sqlite.
swift Tools/build-jmdict.swift out.sqlite

# The committed 28 KB seed.
swift Tools/build-jmdict.swift --seed \
    Packages/KBDictionaryKit/Sources/KBDictionaryKit/Resources/jmdict-seed.sqlite

# The committed 332 KB KANJIDIC2, filtered to the characters a reader meets.
swift Tools/build-kanjidic.swift \
    Packages/KBDictionaryKit/Sources/KBDictionaryKit/Resources/kanjidic.sqlite
```

`build-jmdict.swift` expects `data/JMdict_e.gz` and `data/JmdictFurigana.txt` (override the second with
`JMDICT_FURIGANA_PATH`). A missing JmdictFurigana file is a warning, and the database is built with no
`furigana` rows. Seed mode needs no source files: its entries and fixture furigana rows are embedded in the
script. `build-kanjidic.swift` expects `data/kanjidic2.xml.gz` (override with `KANJIDIC_PATH`) and keeps only
characters with a school grade, a frequency rank or an old-JLPT level, and only the fields a study card uses.

The JMdict schema is `entry(id, senses_json)`, `entry_form(entry_id, form, is_kanji)` and
`furigana(form, reading, segmentation)`. `SQLiteJMDictStorage` requires the first two. A database without the
gloss column or the `furigana` table still opens and returns no glosses or no spans.
`JmdictFuriganaParser` is the canonical segmentation parser; the build script cannot import the library and
mirrors its validation, so keep the two in sync.

Update the snapshot dates in `NOTICE` whenever you refresh either source: an attribution that names the wrong
snapshot is a broken attribution.

## Testing

```sh
swift test --filter KBDictionaryKitTests
KB_FULL_JMDICT=/path/to/jmdict.sqlite swift test --filter KBDictionaryKitTests
```

Suites that assert against real dictionary data carry `.enabled(if: DictionaryTestSupport.seedIsAvailable)`,
so they skip where there is no SQLite backend rather than vanishing from the run. `JMDictStorageSeamTests`
drives the policy with a fake storage and runs everywhere. Set `KB_FULL_JMDICT` to a full database to enable
the suites that need one.
