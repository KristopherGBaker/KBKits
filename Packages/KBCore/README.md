# KBCore

The shared vocabulary every other package speaks: the document model, text and script
primitives, reading position and timing, and a few utilities with no better home.

**What it is not.** Not a grab bag. A type earns its place here by being needed by two packages
that must agree on it. If only one package needs it, it belongs there.

## Key types

- `Document` / `Chapter` / `Paragraph` / `TextSegment`: the normalized document model, plus
  their IDs. `segments` is the canonical flattened reading order; playback iterates it.
- `ReadingPosition`, `HighlightTimeline`, `SpokenTextAlignment`: where the reader is, and how
  spoken audio lines up with text.
- `WordTokenizer`, `MixedScriptSegmenter`, `Script`, `RubyRun`: text and script primitives.
- `CJKWordSegmenter` / `CoreFoundationCJKSegmenter` / `ScalarCJKSegmenter`: the word-boundary
  seam for scripts written without inter-word spaces.
- `SpokenTextNormalizer` / `SpokenTextSubstitution`: what gets said versus what is written.
- `FileDownloader` / `DownloadError` / `DownloadProgress`.
- `PackageResourceLocator`: a resource-bundle lookup that returns nil instead of trapping, keyed
  to a TARGET name so a target survives being copied into another package.
- `TextHashing`: the document hash that validates persisted positions against a live document.

## Invariants

- **No Apple UI frameworks.** KBCore is the layer everything else can depend on, so it stays
  free of SwiftUI and platform services.
- **No dependencies on Apple platforms.** The one pin, swift-crypto, is declared
  `.when(platforms: [.android])`, because `CryptoKit` does not exist there and
  `TextHashing` is load-bearing. An Apple build still links nothing beyond the SDK. This
  was previously stated as "depends on nothing", which was not true off Apple.
- **`CJKWordSegmenter` is the one platform seam.** Word segmentation for space-less scripts
  is `CFStringTokenizer` on Apple and has no portable equivalent, so it is injectable.
  Its output is load-bearing rather than incidental: word spans drive reader layout, the
  proportional timing deriver, and the pacer, so swapping it moves where highlights land.
  Implementations must return spans that TILE the input, with no gap and no overlap.
- **No app types.** If an app concept needs to cross into a Kit, it moves down here first.
- **`Document.textHash` is the contract for persisted positions.** A saved position is only
  valid against a document whose hash still matches.

## Used by

Everything. It is the only package that may be depended on by all the others.
