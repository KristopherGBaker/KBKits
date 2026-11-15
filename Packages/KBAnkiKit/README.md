# KBAnkiKit

KBAnkiKit reads and writes Anki `.apkg` decks. It reads note types, decks, notes, per-note deck membership and media
from a package, and writes a deck of new cards that another Anki can import. It knows the file format and nothing else.

**What it is not.**

- **Not a card model.** There is no study type, no FSRS state and no mapping to any app's cards. A consumer reads an
  `AnkiCollection` and decides what a note becomes. That is why this is a library and not app code: two apps that share
  nothing but the file format can both use it.
- **Not a scheduler.** Export writes new cards only. Anki and FSRS do not share a memory model, so any interval written
  here would be a guess dressed as data.
- **Not a sync client.** No AnkiWeb, no collection merging.
- **Export writes no media.** Reading media is supported; export writes an empty `media` manifest and no media bodies,
  because the exporter's notes are plain text. Reading and writing are deliberately asymmetric here.

## Install

KBAnkiKit is a product of the KBKits package:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBAnkiKit", package: "KBKits")
    ])
]
```

Its dependencies (ZIPFoundation, zstd, SQLite off Apple platforms, swift-crypto on Android) are declared in the root
`Package.swift`; see [Dependencies](#dependencies).

## Quick start

Read a deck:

```swift
import KBAnkiKit

let collection = try AnkiPackageReader().read(contentsOf: deckURL)
for note in collection.notes {
    guard let noteType = collection.noteType(for: note) else { continue }
    let word = note.value(of: "Word", in: noteType) ?? ""
    let cleaned = AnkiFieldText.cleaned(word)
    print(cleaned.text, cleaned.audioFileNames, note.deckIDs)
}

let media = try AnkiPackageReader().readMedia(contentsOf: deckURL)
let audio = try media.data(named: "sensei.mp3")   // nil when the manifest has no such name
```

Write one:

```swift
let draft = AnkiDeckDraft(
    deckName: "Japanese::Words",
    noteType: AnkiNoteTypeDraft(
        name: "Word",
        fieldNames: ["Word", "Meaning"],
        templates: [AnkiCardTemplate(name: "Recognition", question: "{{Word}}",
                                     answer: "{{FrontSide}}<hr id=answer>{{Meaning}}")]
    ),
    notes: [AnkiNoteDraft(fields: ["先生", "teacher"], tags: ["n5"])]
)
try AnkiPackageWriter().write(draft, to: outputURL)
```

Every reading and writing method throws `AnkiError`, a typed error that is also a `LocalizedError`, so a dialog can show
it.

## Main types

| Type | Role |
| --- | --- |
| `AnkiPackageReader` | `read(contentsOf:)`, an `.apkg` on disk to an `AnkiCollection`; `readMedia(contentsOf:)`, its media |
| `AnkiCollection` | What an import sees: `noteTypes`, `decks`, `notes`, and `noteType(for:)` |
| `AnkiNote` | One note: `guid`, its type's `noteTypeID`, positional `fields`, `tags`, `deckIDs`, and `value(of:in:)` |
| `AnkiNoteType` | The named, ordered field list that gives a note's values meaning, with `index(of:)` |
| `AnkiDeck` | A deck's `id` and `name`; nesting is spelled in the name with `::` (`Japanese::Core 2k`) |
| `AnkiMedia` | A package's media: `names`, one file's bytes by name with `data(named:)`, `forEachBody(named:_:)` and `byteCount(of:)` |
| `AnkiFieldText` | Takes one raw field apart: `cleaned(_:)` and `splittingFurigana(_:)` |
| `AnkiPackageWriter` | `write(_:to:timestamp:)`, an `AnkiDeckDraft` to an `.apkg` |
| `AnkiDeckDraft` | What export takes: one deck name, one `AnkiNoteTypeDraft`, its `AnkiNoteDraft` notes |
| `AnkiNoteTypeDraft`, `AnkiCardTemplate`, `AnkiNoteDraft` | The note type (fields, templates, CSS `styling`), a template's question and answer in Anki's `{{Field}}` syntax, and a note's positional fields, tags and optional `guid` |
| `AnkiError` | Every failure |

## Invariants

- **Fields are positional.** A note stores values, not names; `AnkiNoteType.fieldNames` is the only thing that maps
  them. Never pass one without the other. Use `note.value(of:in:)` rather than indexing.
- **A note is not a card.** Anki generates one card per template, so a note with two templates is two cards. Counting
  notes and counting cards give different numbers.
- **Deck membership is per note, read from the cards table.** `AnkiNote.deckIDs` holds all the distinct decks that
  note's own cards touch, deduplicated and sorted ascending, for both schema 11 and schema 18. It may be empty (a note
  with no cards). A note whose cards span several decks lists every one of them, and the library selects no canonical
  or primary deck: a consumer that needs one applies its own selection policy.
- **Reads accept short notes and refuse long ones.** Fewer fields than the type declares is normal (a field added
  later). More means the two disagree about the format, and every mapping past that point would be off by one, so it
  throws `AnkiError.fieldCountMismatch`.
- **Export is reproducible.** The same draft and the same `timestamp` write byte-identical files. JSON keys are sorted,
  and ids come from one counter seeded by the timestamp. This is what makes "the deck changed" distinguishable from
  "the exporter ran again".
- **Ids are unique across the collection.** Anki ids are epoch milliseconds that double as primary keys, so they are
  allocated from a counter, never computed twice.
- **Export checks the draft first.** A draft with no notes throws `AnkiError.emptyDeck`, because a file that imports as
  nothing is worse than saying so, and a note whose field count differs from its note type's throws
  `AnkiError.fieldCountMismatch`. To let a receiving collection recognize a note it already has, pass its `guid` in
  the `AnkiNoteDraft`; nil lets the writer mint one.

## Format notes

An `.apkg` is a zip holding a SQLite collection plus media. Anki has shipped three names for that collection:

| Entry | Schema | Read | Written |
| --- | --- | --- | --- |
| `collection.anki2` | 11, note types as JSON in `col.models` | yes | yes |
| `collection.anki21` | 18, note types in their own tables | yes | no |
| `collection.anki21b` | 18, zstd-compressed | yes | no |

Export writes schema 11 deliberately: every Anki that opens `.apkg` files reads it, while schema 18 files are rejected
by older versions, and an export exists to be opened by someone else's Anki.

`collection.anki21b` is what a current Anki writes by default, so it is read rather than refused: refusing it would
refuse most decks people actually have. Decompression is streamed, because `ZSTD_getFrameContentSize` reports
"unknown" for frames written by a streaming compressor, which is exactly what Anki uses.

Which schema a file uses is decided by looking for the tables, not by trusting a version column: the version says what
wrote the file, the tables say what is in it.

### The `unicase` collation

A schema 18 collection declares its names `COLLATE unicase`, a collation Anki registers itself, so every connection
here registers one too, before its first statement. Without it the `fields` table cannot be read at all: it is
`WITHOUT ROWID`, so the table is its own primary-key index, and SQLite has no access path and reports "no query
solution". Registering after a failed statement does not help, because the schema has already been parsed.

The comparison is Anki's own: Rust's `unicase` crate at the version Anki pins (2.6.0), whose fold table
`UnicaseFold.swift` carries. It is generated from the crate by `Tools/generate-unicase-fold.sh` at the repository root,
and `--check` confirms the committed table still matches. So `Straße` and `STRASSE` are one name, and the order agrees
with the index Anki wrote, down to the crate's quirks: `ﬃ` folds to `iff`, not `ffi`, because that is the order the
crate's fold iterator yields.

## Media

`readMedia(contentsOf:)` returns an `AnkiMedia`: the referenced media names in manifest order, and `data(named:)` to
pull one file's bytes. The bytes are extracted on demand, one entry at a time, so listing a deck's media never unpacks
it and a corrupt entry only fails the call that asks for it.

For more than one file, use `forEachBody(named:_:)`. `data(named:)` opens the package on every call, and ZIPFoundation
finds an entry by scanning the central directory, so a loop over a real deck's media is quadratic: sizing the 4,354
files of the Kaishi 1.5k deck that way took 46 seconds, against 0.14 seconds with the directory indexed once.
`forEachBody` shares one opened package and holds one body at a time, so a deck's audio never has to be in memory at
once. A name missing from the manifest throws rather than being skipped, so a caller copying media cannot report success
over a card whose audio never arrived. `byteCount(of:)` totals the decompressed bodies themselves, never the sizes the
manifest claims.

The `media` manifest arrives in two shapes, and both are read: the legacy JSON object (`{"0":"sensei.mp3"}`) and the
current binary protobuf-wire message (a repeated `{name, size, sha1}` entry, list order being the numbered zip index).
The binary form is parsed by a small hand-written varint reader that skips fields it does not know; there is no
protobuf dependency.

zstd handling goes by content, not by manifest shape: a body that begins with the zstd magic (`28 B5 2F FD`) is
decompressed with the same codec used for the collection, and anything else is returned as stored. A legacy manifest
can therefore carry a compressed body and a binary manifest a plain one; the bytes decide.

## Field text

A field in a real deck is not plain text: it carries HTML, media referenced by filename, entities, and in Japanese decks
a reading written inline as `漢字[かんじ]`. `AnkiFieldText.cleaned(_:)` takes one apart into `text`, `audioFileNames`
(from `[sound:NAME]`) and `imageFileNames` (from `<img src="NAME">`), reporting media by name and leaving the caller to
decide what a reference means.

The order it works in is load-bearing. Media markers come out before any tag strip, or `[sound:x.mp3]` survives as
literal text inside a meaning. `<img>` is read before the strip, because its filename is an attribute the strip would
discard. Block tags become a line break rather than nothing, or two sentences run into one word no dictionary holds.
Entities decode after tags are gone, or an escaped `&lt;b&gt;` becomes a real tag that the strip then eats.

`AnkiFieldText.splittingFurigana(_:)` splits a field written in Anki's inline furigana convention into its base text
and its reading: `先生[せんせい]` gives `先生` and `せんせい`. A group attaches to the run of text since the last space,
so `日本語[にほんご]を 勉強[べんきょう]します` is two groups. A bracket that never closes is left alone and contributes no
reading.

This lives here rather than in a consumer because it is knowledge of the format. A second copy in an app is a copy that
drifts.

## Known limitations

These are deliberate and independently audited, not oversights:

- **Card templates are not read back.** Export writes them; import ignores them, because an import here produces study
  cards rather than reproducing Anki's.
- **`col.crt` is UTC midnight, not Anki's local 04:00 rollover.** An `.apkg` is an import payload: its notes merge into
  a destination collection that counts days from its own `crt`, so this value never reaches a scheduler. Matching Anki
  exactly would make an export's bytes depend on the exporting machine's time zone.

## Dependencies

All are declared in the KBKits root `Package.swift`.

**ZIPFoundation**, from the fork `KristopherGBaker/ZIPFoundation`, required exactly as `0.9.21-kits.1`
(upstream's `development` branch plus in-memory archives on Android). MisakiSwift requires the same fork, and SwiftPM
keys package identity on the URL's last path component, so the URL and requirement here must stay compatible with
MisakiSwift's. An app that also depends on upstream `weichsel/ZIPFoundation` conflicts with KBKits. The root README's
"Dependencies on forks" explains the versioning.

The target declares ZIPFoundation directly, and that is required. Leaning on another product for it and importing
ZIPFoundation transitively compiles, and `swift test` even links, because a test executable pulls in every transitive
product. A consuming app's test bundle then fails with undefined ZIPFoundation symbols, because this target's own object
files reference them and nothing linked the library for it.

**zstd** comes from upstream's own SwiftPM manifest (`facebook/zstd`, product `libzstd`), so it is the reference
implementation rather than a third-party wrapper. zstd is dual-licensed BSD/GPLv2 and taken under BSD-3-Clause (see
the root `NOTICE`). It was needed because no codec already in KBKits reads zstd: SWCompression ships Deflate, BZip2,
LZMA, XZ and LZ4, and Apple's Compression framework has LZFSE, LZ4, LZMA and zlib.

**SQLite** comes from the platform (`import SQLite3`) on Apple platforms and from `swiftlang/swift-toolchain-sqlite` on
Android and Linux, where the NDK exposes no SQLite header or link target. The C API is identical either way. It is not
GRDB, which KBDictionaryKit uses and only on Apple platforms: reaching it from here would tie an Anki library to the
Japanese dictionary's dependency, which is not worth it for a handful of statements.

**SHA-1** for a note's checksum and guid comes from CryptoKit on Apple platforms and from `swift-crypto` on Android,
from the same range KBCore uses.

## Tests

From the repository root:

```sh
swift test --filter KBAnkiKitTests
```

The tests build their own `.apkg` fixtures, zstd-compressed collections included, and walk the collation against Rust
`unicase` 2.6.0's folds (`Resources/unicase-2.6.0-folds.tsv`). The real-deck suite reads
`~/Downloads/Kaishi.1.5k.apkg` and is skipped when that file is absent.
