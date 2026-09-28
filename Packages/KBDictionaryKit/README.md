# KBDictionaryKit

JMdict-backed Japanese word lookup and KANJIDIC2 per-character lookup: the read-only dictionary
stores and the value types behind a reader's meaning popover and kanji cards.

## Key types

- `ReadingDictionary` / `VocabDictionary`: the lookup seams.
- `JMDictStorage`: where the data physically comes from. `SQLiteJMDictStorage` (GRDB) and
  `EmptyJMDictStorage` implement it.
- `JMDictStore`: the policy above that storage, and what callers use.
- `JMDictEntry` / `JMDictSense` / `FuriganaSpan`.
- `KanjiStore` / `KanjiEntry`: per-character readings, meanings, stroke count, grade, frequency.
- `Deinflector`: conjugated form back to a dictionary form.

## Invariants

- **Read-only.** Nothing here writes a dictionary. `Tools/build-jmdict.swift` and
  `Tools/build-kanjidic.swift` at the repository root build them, offline, from the published
  sources.
- **Depends only on KBCore + GRDB**, so it stays off any playback or speech path and is
  `swift test`-able in isolation.
- **A curated seed ships as a bundled resource**, so a fresh checkout works before a full
  dictionary exists. KANJIDIC2 ships whole, because the filtered database is small enough to.
- **The database is behind `JMDictStorage`, and everything above it is pure Swift.**
  Deinflection, the base-then-surface fallback and furigana segmentation parsing are policy
  and never touch SQL. That is what lets the package build for Android, where GRDB cannot go
  at all: `SQLiteJMDictStorage` compiles out and `JMDictStore` falls back to
  `EmptyJMDictStorage`, so lookups return nothing and the caller shows "no entry".
- **A missing dictionary is not an error.** Every storage method returns empty rather than
  throwing, because a miss and an unavailable dictionary look the same to a reader.
- **Nothing here prints.** A lookup term is what a person is reading and a database path carries
  their home directory, so diagnostics go to `Logger` with `privacy: .private` (the term is not
  collected at all) and never to stdout. `StdoutPrivacyTests` captures fd 1 during a forced
  open failure and a forced query failure and fails if either string appears.
- **Resource lookup never names the enclosing package.** Both bundled databases are found
  through `Bundle.module` on Apple platforms and through a TARGET-keyed
  `PackageResourceLocator` call elsewhere, so this target survives being copied into a
  differently named package. `KBKitsResourceLayoutTests` pins that from inside KBKits.

## Sole declarer

GRDB is declared here and reaches other packages transitively. It is declared
`.when(platforms:)` for the Apple platforms only.

## The bundled data is CC BY-SA 4.0, and you must credit it

`Sources/KBDictionaryKit/Resources/jmdict-seed.sqlite` and
`Sources/KBDictionaryKit/Resources/kanjidic.sqlite` are NOT under this repository's Apache-2.0
licence. They are derived from JMdict and JmdictFurigana (EDRDG and James Breen; Doublevil) and
from KANJIDIC2 (EDRDG), all under CC BY-SA 4.0.

If you link this package, you ship that data, which means you redistribute it. **Credit the data
in your About screen**: name JMdict and the Electronic Dictionary Research and Development Group
with James Breen, name KANJIDIC2 and EDRDG, name JmdictFurigana and Doublevil, say the data is
licensed CC BY-SA 4.0 with a link to the licence, and say that it has been modified. The root
`NOTICE` has the exact wording, the source URLs, the snapshot the committed files were built
from, every transformation applied, and the rebuild procedure. The licence text is in
`Licenses/CC-BY-SA-4.0.txt`.

## Rebuilding the databases

Both scripts run from the repository root with no package dependencies (raw sqlite3, system
`gunzip`), so a rebuild is reproducible from the published sources alone:

```sh
# Full JMdict, roughly 66 MB. Not committed; an app caches or ships its own.
swift Tools/build-jmdict.swift out.sqlite

# The committed 28 KB seed.
swift Tools/build-jmdict.swift --seed \
    Packages/KBDictionaryKit/Sources/KBDictionaryKit/Resources/jmdict-seed.sqlite

# The committed 332 KB KANJIDIC2, filtered to the characters a reader meets.
swift Tools/build-kanjidic.swift \
    Packages/KBDictionaryKit/Sources/KBDictionaryKit/Resources/kanjidic.sqlite
```

`build-jmdict.swift` expects `data/JMdict_e.gz` and `data/JmdictFurigana.txt` (override the
second with `JMDICT_FURIGANA_PATH`); `build-kanjidic.swift` expects `data/kanjidic2.xml.gz`.
Update the snapshot dates in `NOTICE` whenever you refresh either source: an attribution that
names the wrong snapshot is a broken attribution.

## Testing

Suites that assert against real dictionary DATA carry
`.enabled(if: DictionaryTestSupport.seedIsAvailable)`, so they SKIP where there is no SQLite
backend rather than vanishing from the run; `JMDictStorageSeamTests` drives the policy with a
fake storage and runs everywhere. Set `KB_FULL_JMDICT` to a full database to enable the suites
that need one.
