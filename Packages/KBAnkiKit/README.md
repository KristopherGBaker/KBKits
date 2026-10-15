# KBAnkiKit

Reading and writing Anki `.apkg` decks.

## What it is

- `AnkiPackageReader`: an `.apkg` on disk to an `AnkiCollection`: note types, decks,
  notes, and per-note deck membership. `readMedia(contentsOf:)` additionally lists a
  package's media and pulls one file's bytes by referenced name, on demand.
- `AnkiPackageWriter`: an `AnkiDeckDraft` to an `.apkg` another Anki can import.
- The value types either side needs: `AnkiNoteType`, `AnkiNote` (with its `deckIDs`),
  `AnkiDeck`, `AnkiMedia`, and the `*Draft` shapes for export.

## What it is NOT

- **Not a card model.** There is no study type, no FSRS state and no mapping to any
  app's cards here. A consumer reads an `AnkiCollection` and decides what a note
  becomes. That is the whole reason this is a Kit and not app code: two apps sharing
  nothing but the file format can both use it.
- **Not a scheduler.** Export writes NEW cards only. Anki and FSRS do not share a
  memory model, so any interval written here would be a guess dressed as data.
- **Not a sync client.** No AnkiWeb, no collection merging.
- **Export writes no media.** Reading media is supported; export writes an empty
  `media` manifest and no media bodies, because the exporter's notes are plain text.
  Reading and writing are deliberately asymmetric here.

## Key types

| Type | Role |
| --- | --- |
| `AnkiCollection` | What an import sees: note types, decks, notes |
| `AnkiNote` | One note: `guid`, its type's id, positional `fields`, `tags`, `deckIDs` |
| `AnkiNoteType` | The named, ordered field list that gives those values meaning |
| `AnkiMedia` | A package's media: names, and one file's bytes by name on demand |
| `AnkiDeckDraft` | One deck, one note type, its notes: what export takes |
| `AnkiError` | Every failure, `LocalizedError` so a dialog can show it |

## Invariants

- **Fields are positional.** A note stores values, not names; `AnkiNoteType.fieldNames`
  is the only thing that maps them. Never pass one without the other. Use
  `note.value(of:in:)` rather than indexing.
- **A note is not a card.** Anki generates one card per template, so a note with two
  templates is two cards. Counting notes and counting cards give different numbers.
- **Deck membership is per note, read from the cards table.** `AnkiNote.deckIDs` holds
  all the distinct decks that note's own cards touch, deduped and sorted ascending, for
  both schema 11 and schema 18. It may be empty (a note with no cards). A note whose
  cards span several decks lists every one of them, and the package selects no
  canonical or primary deck: a consumer needing one applies its own selection policy.
- **Reads accept short notes, refuse long ones.** Fewer fields than the type declares
  is normal (a field added later). More means the two disagree about the format, and
  every mapping past that point would be off by one, so it throws.
- **Export is reproducible.** The same draft and the same `timestamp` write
  byte-identical files. JSON keys are sorted and ids come from one counter seeded by
  the timestamp. This is what makes "the deck changed" distinguishable from "the
  exporter ran again".
- **Ids are unique across the collection.** Anki ids are epoch milliseconds that
  double as primary keys, so they are allocated from a counter, never computed twice.

## Format notes

An `.apkg` is a zip holding a SQLite collection plus media. Anki has shipped three
names for that collection:

| Entry | Schema | Read | Written |
| --- | --- | --- | --- |
| `collection.anki2` | 11, note types as JSON in `col.models` | yes | yes |
| `collection.anki21` | 18, note types in their own tables | yes | no |
| `collection.anki21b` | 18, zstd-compressed | yes | no |

Export writes schema 11 deliberately: every Anki that opens `.apkg` files reads it,
while schema 18 files are rejected by older versions, and an export exists to be
opened by someone else's Anki.

`collection.anki21b` is what a current Anki writes by default, so it is read rather
than refused: refusing it would refuse most decks people actually have. Decompression
is streamed, because `ZSTD_getFrameContentSize` reports "unknown" for frames written
by a streaming compressor, which is exactly what Anki uses.

Which schema a file uses is decided by looking for the tables, not by trusting a
version column: the version says what wrote the file, the tables say what is in it.

A schema 18 collection declares its names `COLLATE unicase`, a collation Anki registers
itself, so every connection here registers one too, before its first statement. Without
it the `fields` table cannot be read at all: it is `WITHOUT ROWID`, so the table is its
own primary-key index, and SQLite has no access path and reports "no query solution".
Registering after a failed statement does not help, because the schema has already been
parsed. The comparison is Anki's own: Rust's `unicase` at the version Anki pins (2.6.0),
whose fold table `UnicaseFold.swift` carries, generated from the crate by
`Tools/generate-unicase-fold.sh` (`--check` confirms the committed table still matches).
So `Straße` and `STRASSE` are one name, and the order agrees with the index Anki wrote,
down to the crate's quirks: `ﬃ` folds to `iff`, not `ffi`, because that is the order the
crate's fold iterator yields.

## Media

`readMedia(contentsOf:)` returns an `AnkiMedia`: the referenced media names, and
`data(named:)` to pull one file's bytes. The bytes are extracted on demand, one entry
at a time, so listing a deck's media never unpacks it and a corrupt entry only fails
the call that asks for it.

The `media` manifest arrives in two shapes and both are read: the legacy JSON object
(`{"0":"sensei.mp3"}`) and the current binary protobuf-wire message (a repeated
`{name, size, sha1}` entry, list order being the numbered zip index). The binary form
is parsed by a small hand-written varint reader that skips fields it does not know;
there is no protobuf dependency.

zstd handling is by CONTENT, not by manifest shape: a body that begins with the zstd
magic (`28 B5 2F FD`) is decompressed with the same codec used for the collection, and
anything else is returned as stored. A legacy manifest can therefore carry a compressed
body and a binary manifest a plain one; the bytes decide.

## Field text

A field in a real deck is not plain text: it carries HTML, media referenced by
filename, entities, and in Japanese decks a reading written inline as `漢字[かんじ]`.
`AnkiFieldText` takes one apart, reporting media by NAME and leaving the caller to
decide what a reference means.

The order it works in is load-bearing. Media markers come out before any tag strip,
or `[sound:x.mp3]` survives as literal text inside a meaning. `<img>` is read before
the strip, because its filename is an attribute the strip would discard. Block tags
become a line break rather than nothing, or two sentences run into one word no
dictionary holds. Entities decode after tags are gone, or an escaped `&lt;b&gt;`
becomes a real tag that the strip then eats.

This lives here rather than in a consumer because it is knowledge of the FORMAT. A
second copy in an app is a copy that drifts.

## Known limitations

These are deliberate and independently audited, not oversights:

- **Card templates are not read back.** Export writes them; import ignores them,
  because an import here produces study cards rather than reproducing Anki's.
- **`col.crt` is UTC midnight, not Anki's local 04:00 rollover.** An `.apkg` is an
  import payload: its notes merge into a destination collection that counts days from
  its own `crt`, so this value never reaches a scheduler. Matching Anki exactly would
  make an export's bytes depend on the exporting machine's time zone.

## Dependencies

All declared in the KBKits root `Package.swift`.

**ZIPFoundation**, from the fork `KristopherGBaker/ZIPFoundation` on its `kits-android`
branch. MisakiSwift pins the same fork, and SwiftPM keys package identity on the URL's
last path component, so the URL and branch here stay character-identical to
MisakiSwift's. It is a branch pin, so it has to move to a tag before KBKits is released
(README.md, "Before a release").

The target declares ZIPFoundation directly, and that is required. Leaning on another
product for it and importing ZIPFoundation transitively COMPILES, and `swift test`
even links, because a test executable pulls in every transitive product. A consuming
app's test bundle then fails with undefined ZIPFoundation symbols, because this
target's own object files reference them and nothing linked the library for it.

zstd comes from **upstream's own SwiftPM manifest** (`facebook/zstd`, product
`libzstd`), so it is the reference implementation rather than a third-party wrapper.
zstd is dual-licensed BSD/GPLv2 and taken under BSD-3-Clause (see NOTICE). It was
needed because no codec already here reads zstd: SWCompression ships Deflate, BZip2,
LZMA, XZ and LZ4, and Apple's Compression framework has LZFSE, LZ4, LZMA and zlib.

SQLite comes from the platform (`import SQLite3`) on Apple platforms and from
`swiftlang/swift-toolchain-sqlite` on Android and Linux, where the NDK exposes no SQLite
header or link target. The C API is identical either way. It is not GRDB, which is
KBDictionaryKit's and Apple-only there: reaching it from here would tie an Anki package
to the Japanese dictionary's dependency, which is not worth it for a handful of
statements.

SHA-1 for a note's checksum and guid comes from CryptoKit on Apple platforms and from
`swift-crypto`, the range KBCore already declares, on Android.
