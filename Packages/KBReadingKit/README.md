# KBReadingKit

The SwiftUI-free reading pipeline: word tokenization, the furigana rules that decide what ruby
a reader actually sees (the dictionary compound join, jukujikun spanning ruby, the
nearest-reading and commonest-reading rules, reading provenance), and the value model a
renderer draws from (`ReaderContent`/`ReaderParagraph`, `KaraokeWord`, `KaraokeParagraph`,
`KaraokeBlock`/`KaraokeImage`/`KaraokeCodeBlock`/`KaraokeTable`).

**What it is not.** Not UI. It holds no `View`, and no Apple UI framework is imported anywhere
in it. A UI package draws these types; nothing here draws anything, which is what lets a
non-Apple host run the same pipeline over the same values. It depends on `KBCore` and
Foundation, and on nothing else.

## Key types

- `KaraokeWord.tokenize(...)`: the reading entry point, including the `compoundReadings:` join
  seam a dictionary is injected through.
- `ReaderContent.build(...)`: text and author ruby in, a renderable paragraph model out.
- `RubySegment` and `ReadingProvenance`: one ruby run, and where its reading came from.
- `KaraokeParagraph`, `KaraokeBlock` and the block value types.

## The compound join's run shape

A run is a gapless, author-ruby-free stretch of display tokens whose JOINED form the dictionary
knows. Its tail tokens are kanji-only; its HEAD may also be an okurigana-headed token (kanji
first, then kana: 生き, 考え, 読み), so the tokens 生き|方 form a candidate run and 生き方 renders
生[い]き 方[かた] rather than reading 方 alone as ほう.

Such a run is held to a stricter standard than an all-kanji one. It is replaced only when the
settled reading's JmdictFurigana row distributes per token, because a whole-run spanning ruby
would put kana over kana. And it is refused outright when the reading would ABSORB okurigana the
text still spells in the next token: 受け取/うけとり before a separate らし renders
うけとりらして, where the word is うけとらして.

## Invariants

- **No Apple UI import.** No SwiftUI, UIKit, AppKit or CoreGraphics, at any depth.
- **`KBCore` alone.** One dependency, so the whole pipeline cross-compiles.
- **Rendering is a MOVE, not a rewrite.** The output is byte-identical to the pipeline this was
  extracted from.

## Testing

`swift test` from the repository root runs this package with the rest. `KBReadingKitTests`
declares both `KBReadingKit` and `KBCore` directly, because `MemberImportVisibility` only
surfaces members of modules a target imports itself and these tests build their own `Document`
and `TextSegment` values.
