# KBCore

KBCore is the shared vocabulary of the KBKits reading libraries: the document model, text and script
primitives, reading position and timing, and a few utilities with no better home. `KBReadingKit`,
`KBDictionaryKit` and `KBJapaneseKit` all build on it, and an app uses it to hand them a document.

**What it is not.** Not a grab bag. A type earns its place here by being needed by two libraries that must
agree on it. If only one library needs it, it belongs there.

## Install

Add KBKits and name the `KBCore` product:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBCore", package: "KBKits")
    ])
]
```

On Apple platforms KBCore links nothing beyond the SDK. On Android it links swift-crypto (see
[Platforms](#platforms)).

## Quick start

Build a one-sentence document, split its text into words, and check a saved position against it:

```swift
import Foundation
import KBCore

let id = DocumentID("sample")
let text = "The quick brown fox."
let segment = TextSegment(
    id: SegmentID(documentID: id, sentenceIndex: 0),
    documentID: id,
    sentenceIndex: 0,
    text: text,
    sourceRange: DocRange(lower: 0, upper: text.utf16.count)
)
let document = Document(
    id: id,
    title: "Sample",
    textHash: TextHashing.sha256Hex(text),
    segments: [segment],
    chapters: [
        Chapter(
            id: ChapterID(documentID: id, index: 0),
            title: nil,
            paragraphs: [Paragraph(id: ParagraphID(documentID: id, index: 0), segmentRange: 0..<1)]
        )
    ]
)

// Word spans as UTF-16 offsets into the text.
for token in WordTokenizer.tokenize(text) {
    print(token.text, token.offsets.lower, token.offsets.upper)
}

// A saved position resumes only against a document whose hash still matches.
let saved = ReadingPosition(
    documentID: id, sentenceIndex: 0, wordOffsetUTF16: nil,
    textHash: document.textHash, updatedAt: Date()
)
let resumeAt = saved.resolvedSegmentIndex(in: document)  // 0 if the hash changed
```

## The document model

- `Document`: one normalized document. `segments` is the canonical flattened reading order; playback
  iterates it. `chapters` and their `Paragraph`s are a navigation hierarchy that refers to segments by
  index, so text is stored once. `images` holds retained `DocumentImage`s anchored between segments, and
  `source` (`DocumentSource`) says whether it was imported or is a user note.
- `TextSegment`: one sentence. `text` is the spoken form (what a synthesizer says and what timing offsets
  index into). `displayText` is what a reader shows, and defaults to `text`. `styleRuns`, `rubyRuns`
  (author furigana), `blockStyle` and `listInfo` describe the display side.
- IDs: `DocumentID`, `SegmentID`, `ChapterID`, `ParagraphID`.
- Spans: `UTF16Range`, with the aliases `WordOffsets` and `DocRange`. Positions are always UTF-16 offsets,
  never `String.Index`, so they persist and stay `Sendable`. `String.range(fromUTF16:)` turns one back into
  a `Range<String.Index>`.
- Styling: `StyleRun`, `TextTraits`, `BlockStyle`, `ListInfo`, `TaskState`.
- `RubyRun`: an author-supplied furigana span over `displayText` (Aozora `漢字《かな》`, EPUB `<ruby>`).
  `RubyRun.rebased(_:lower:upper:)` clips runs to a span, and `RubyRun.substituting(_:in:)` bakes kana
  readings into spoken text.
- Older persisted documents decode unchanged: fields added later (`displayText`, `styleRuns`, `rubyRuns`,
  `images`, `source` and others) take their defaults when absent.

## Reading position and timing

- `ReadingPosition`: segment index, optional word offset, and the document hash captured at save time.
  `resolvedSegmentIndex(in:)` returns the saved index only when the hash matches and the index is in range,
  and 0 otherwise.
- `HighlightTimeline` and `WordToken`: when each word of a segment is spoken. `wordIndex(atSourceTime:)` is a
  binary search with no per-call allocation. `TimingProvenance`, `TimingConfidence`, `ProviderID` and
  `DerivationStrategy` record where a timeline came from.
- `HighlightState`: the one `@MainActor` `@Observable` object a reader UI watches for the active segment and
  word.
- `SegmentBoundary` and `ReadingPace`: the structural pause before a segment (`Document.boundary(before:)`,
  `Document.pauseDuration(before:pace:)`).
- `Passage` and `ReferenceReanchor`: a reader selection, and re-finding a reference after a note's text
  changed.
- `StreakSummary`, `ActivityDay`, `ActivityEvent`, `ActivityKind`: a reading streak from a set of active days.
- `KBCore.schemaVersion`: the schema version of serialized artifacts. Bumping it invalidates persisted data
  whose shape changed.

## Text and script

- `WordTokenizer`: splits text into word spans. Space-delimited text splits on whitespace, and on en dashes,
  em dashes and horizontal bars (marking the right side `tightLeading`). Hyphens are not split. Text with kana
  or CJK ideographs goes through a `CJKWordSegmenter`. Pass `transcription: true` for each CJK token's Latin
  transcription.
- `CJKWordSegmenter`: the word-boundary seam for scripts written without spaces. `CoreFoundationCJKSegmenter`
  (Apple only) uses `CFStringTokenizer` and is the reference. `ScalarCJKSegmenter` is a portable placeholder
  that splits per character and returns no transcription.
- `MixedScriptSegmenter`: splits a sentence into Japanese and English runs (`runs(in:)`, `isMixed(_:)`), so a
  mixed sentence can be voiced per script. Short all-caps initialisms (up to `acronymMaxLength`, 4) stay on
  the Japanese side, so they are read as letter names (API as エーピーアイ).
- `SpokenTextNormalizer`: rewrites spoken text so numbers, dates, currency, abbreviations and acronyms are
  pronounced, with per-pass `Options`. It is not length-preserving: "1995" becomes "nineteen ninety-five".
- `SpokenTextAlignment`: maps a non-length-preserving spoken form back onto display words
  (`align(display:spoken:)`, `remap(timeline:display:spoken:)`), so a highlight stays on the right word.
- `SpokenTextTransform`: length-preserving spoken-only changes, such as hyphenated compounds to spaces.
- `SpokenTextSubstitution`: user pronunciation overrides. English matches whole words, Japanese matches exact
  substrings, and the longest term wins.
- `EnglishNumberWords`: cardinals and ordinals, American style.
- `DocumentTextSearch` and `TextSearchNormalizer`: find in a document, case-, diacritic- and width-insensitive
  but not kana-insensitive (それ and ソレ stay distinct).

## Japanese reading values

These live here because both the analysis (`KBJapaneseKit`) and the renderer (`KBReadingKit`, or an app's
UI) need them, and neither should import the other to name them.

- `MoraPitch` and `PitchLevel`: one mora and its pitch, at one of two levels. `isDrop` marks the accent nucleus
  (pitch falls after this mora). It is the only thing that tells an odaka word from a heiban one, so a
  renderer must never discard it.
- `ReadingPayload` and `ReadingSpan`: a token's final display reading, optional per-character placement
  spans (nil `kana` at okurigana positions), and the `candidates` the dictionary lists.
- `TokenAnnotation`: the reading and base form the sentence analysis produced for a display token, with its
  `parts`.

## Utilities

- `TextHashing.sha256Hex(_:)`: lowercase-hex SHA-256 of UTF-8 text. It derives document IDs, validates
  persisted positions, and stamps `TimingProvenance.textHash`.
- `FileDownloader.download(_:to:sha256:onProgress:)`: one on-first-use download path with an HTTP status
  check, throttled `DownloadProgress`, and an atomic move into place. `sha256` has no default, so every call
  states its trust. When it is set, the file is hashed and compared before anything at the destination is
  touched. Failures are `FileDownloader.DownloadError` (`badURL`, `http`, `digestMismatch`).
- `PackageResourceLocator`: finds a SwiftPM resource file without touching `Bundle.module`, whose generated
  accessor traps when there is no bundle (as in an Android APK). Prefer `url(targetName:resource:extension:)`:
  it is keyed to the target name, so a target keeps finding its resources when it is copied into a package
  with a different name.

```swift
let destination = URL.applicationSupportDirectory.appending(path: "MyApp/model.bin")
try await FileDownloader.download(
    "https://example.com/model.bin",
    to: destination,
    sha256: "<pinned lowercase hex digest>"
) { progress in
    print(progress.receivedMB, progress.expectedMB ?? 0)
}
```

## Invariants

- **No Apple UI frameworks.** KBCore is the layer the others depend on, so it stays free of SwiftUI, UIKit
  and AppKit. It imports Foundation and, for `HighlightState`, Observation.
- **No dependencies on Apple platforms.** The one dependency, swift-crypto, is declared
  `.when(platforms: [.android])`, because CryptoKit does not exist there and `TextHashing` is load-bearing.
  swift-crypto produces the same digests as CryptoKit.
- **`CJKWordSegmenter` is the one platform seam.** Word segmentation for space-less scripts is
  `CFStringTokenizer` on Apple and has no portable equivalent, so it is injectable: `WordTokenizer.tokenize`,
  `SpokenTextAlignment.align` and `remap` take a `segmenter:`. Its output is load-bearing: word spans drive
  reader layout, the proportional timing deriver and the reading pacer, so swapping it moves where highlights
  land. Implementations must return spans that tile the input, with no gap and no overlap.
- **No app types.** If an app concept needs to reach a library, it moves down here first.
- **`Document.textHash` is the contract for persisted positions.** A saved position is valid only against a
  document whose hash still matches.

## Platforms

KBKits targets iOS 26 and macOS 26. KBCore also compiles for Android, with two differences.
`WordTokenizer.platformCJKSegmenter` is `ScalarCJKSegmenter` there (per-character segmentation, no
transcription), so a host that needs word-level CJK spans passes its own `CJKWordSegmenter`. And
`TextHashing` uses swift-crypto instead of CryptoKit.

## Testing

From the repository root:

```sh
swift test --filter KBCoreTests
```

Tests that depend on the reference CJK segmenter (word-level spans, romaji) use
`@Test(.enabled(if: hasReferenceCJKSegmenter))`, so off Apple platforms they are reported as skipped
rather than dropped.
