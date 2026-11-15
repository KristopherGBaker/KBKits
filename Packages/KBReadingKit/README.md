# KBReadingKit

KBReadingKit turns a `KBCore` `Document` into what a reader draws: words with their UTF-16 spans, styling,
links, and furigana. It holds the furigana rules that decide what ruby a reader actually sees (the
dictionary compound join, spanning ruby for jukujikun, the nearest-reading and commonest-reading rules,
author-ruby propagation, reader corrections and reading provenance) and the value model a renderer reads
from (`ReaderContent`, `ReaderParagraph`, `KaraokeWord`, `RubySegment`, `KaraokeParagraph` and the
`KaraokeBlock` cases).

**What it is not.** Not UI. It holds no `View`, and no Apple UI framework is imported anywhere in it. A UI
library draws these types; nothing here draws anything, which is what lets a non-Apple host run the same
pipeline over the same values. It also does no Japanese analysis of its own: readings, dictionary payloads
and pitch arrive through closures, usually the ones `KBJapaneseKit`'s `JapaneseFurigana` builds.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBReadingKit", package: "KBKits"),
        .product(name: "KBCore", package: "KBKits")
    ])
]
```

KBReadingKit depends on `KBCore` and Foundation, and on nothing else. Name `KBCore` too if your code builds
`Document` values itself (Swift's member import visibility only shows members of modules a target imports).

## Quick start

```swift
import KBCore
import KBReadingKit

let id = DocumentID("note")
let text = "猫が好きです。"
let document = Document(
    id: id,
    title: "Note",
    textHash: TextHashing.sha256Hex(text),
    segments: [
        TextSegment(
            id: SegmentID(documentID: id, sentenceIndex: 0),
            documentID: id,
            sentenceIndex: 0,
            text: text,
            sourceRange: DocRange(lower: 0, upper: text.utf16.count)
        )
    ],
    chapters: []  // no chapters: one paragraph per segment
)

let content = ReaderContent.build(from: document)
for word in content.words(inSegment: 0) {
    let ruby = word.ruby.map { "\($0.text)[\($0.reading ?? "")]" }.joined()
    print(word.id, word.text, word.utf16Lower, word.utf16Upper, ruby)
}
```

With no closures, a CJK token's reading comes from the tokenizer's Latin transcription (on Apple,
`CFStringTokenizer` plus ICU's Latin-to-Hiragana), which is the system dictionary's first reading and
sometimes wrong (私 as わたくし). For real Japanese readings, pass the closures from
`JapaneseFurigana.providers(dictionary:)`; the `KBJapaneseKit` README shows the full call.

## Building reader content

`ReaderContent.build(from:window:reading:gloss:baseForm:readingPayload:pitch:annotations:annotatedPayload:compoundReadings:corrections:readingCorroborated:authorRuby:segmenter:)`
is the one entry point. Every parameter after `from:` is optional, and leaving one nil keeps the build
exactly as it is without that feature.

| Parameter | What it supplies |
|---|---|
| `window` | A range of segment indices to tokenize. Paragraphs, `segmentRange`s and `karaokeBlocks` always cover the whole document; segments outside the window carry no words. Paint the resume window first, then swap in the full build. |
| `reading`, `baseForm` | Per-surface reading and lemma, the fallback for tokens the sentence analysis could not place. Memoized per surface for the build. |
| `gloss` | The English source word for a katakana loanword (コミュニケーション as "communication"). Asked only for pure-katakana tokens. |
| `readingPayload` | The dictionary tier's final reading and placement spans for a surface (`ReadingPayload`). |
| `annotations`, `annotatedPayload` | One in-context analysis per sentence, aligned onto the display tokens, and the tier over that in-context reading. Display readings come from here. |
| `compoundReadings` | A joined form's dictionary readings with spans. Turns on the compound join. |
| `corrections` | Reader-chosen readings, `[sentenceIndex: [RubyCorrection]]`. |
| `readingCorroborated` | Whether the dictionary accounts for a reading of a surface. Turns on author-ruby propagation. |
| `authorRuby` | An `AuthorRubyIndex` to use instead of deriving one from the document. For test harnesses; apps pass nil. |
| `pitch` | Per-word `[MoraPitch]` for a segment's words, given in order. |
| `segmenter` | The `CJKWordSegmenter` passed to tokenization. Defaults to the platform one. |

Per segment, the build tokenizes `displayText` (`KaraokeWord.tokenize`), then applies author-ruby
propagation, then the segment's corrections, then pitch. Code blocks and tables are never tokenized: they
become `KaraokeBlock.codeBlock` and `.table` with their verbatim text.

The result:

- `paragraphs: [ReaderParagraph]` and `karaokeBlocks: [KaraokeBlock]` (paragraphs interleaved with retained
  images, code blocks and tables, built once so a view does not rebuild them on every highlight tick).
- `words(inSegment:)`: one sentence's words, exactly as the reader renders them. A focus view should use this
  rather than re-tokenizing, which would drop every reading feature.
- `paragraphID(containing:)`, `activeWordID(segmentIndex:offsets:)`, `activeWordIDs(segmentIndex:offsets:)`,
  and the `HighlightState` forms `activeWordID(for:)` and `activeWordIDs(for:)` (main actor).
- `KaraokeBlock.wordCount` tells a windowed build from a full one, and `hashRenderedContent(into:)` folds in
  word ids and ruby readings, so a change detector also sees a corrected reading.

`ReaderContent.applyingCorrections(_:to:)` and `ReaderContent.applyingAuthorRuby(_:corroborated:to:)` are
public so a host that renders through `KaraokeWord.tokenize` directly (the Android bridge) shares the one
implementation of those rules.

## The value model

- `KaraokeWord`: one rendered word. `id` is `"<segmentIndex>.<wordIndex>"`. It carries `utf16Lower` and
  `utf16Upper` within its segment, `traits`, `url` (a Markdown link), `ruby`, `gloss`, and `tightLeading`
  (no gap before it, for the right side of a dash split).
- `RubySegment`: one run of a word's text with an optional `reading`. `reading == nil` is a plain run (kana,
  okurigana, punctuation). The segments of a word always concatenate back to its text. It also carries
  `baseForm` (the lemma, which a study feature keys off), `pitch`, and `provenance`.
- `ReadingProvenance`: how a reading was settled (`source`), what was rendered (`chosen`), and every
  dictionary reading (`candidates`). `Source` is `.dictionary`, `.heuristic` (a considered guess),
  `.analysis` (the sentence analysis chose among several listed readings) or `.authorRuby`.
  `invitesChoice` is true only for a heuristic pick with alternatives; `hasAlternatives` is true whenever
  there is more than one candidate. Most kanji words list several readings, so only guesses invite a choice:
  marking every word with alternatives would mark half a book.
- `KaraokeParagraph`, `KaraokeBlock`, `KaraokeImage`, `KaraokeCodeBlock`, `KaraokeTable`.
- `RubyCorrection`: a reader's chosen reading for one occurrence: `utf16Lower`, `utf16Upper`, the `surface`
  recorded when it was chosen, and the `reading`.
- `AuthorRubyIndex`: the readings the author gave, per document (`init(document:)` or
  `init(rubied:)`).
- `RubyMetrics.size(forBase:)`: the one ruby point size rule, about half the base and at least 9.
- `VerticalMetrics` and `VerticalRubySplit`: column geometry for vertical (縦書き) text, in `Double`, and the
  slice of a reading that belongs to the part of a word on each side of a column break, apportioned by
  position.

## How a token's furigana is resolved

For each display token, in order of precedence:

1. **Author ruby.** A `RubyRun` from the source wins over everything for the characters it covers. Kanji it
   does not cover are filled from the paths below; kana it does not cover render plain. When an author's
   run straddles two tokens (走り出す split as 走り + 出す), the tokens merge into one word so the reading
   appears once.
2. **The dictionary-confirmed okurigana join.** The tokenizer splits okurigana off a kanji (一+つ, 俄+か), so
   the kanji alone validates to the wrong reading (いち, not ひと). The merged surface (up to two following
   kana-only tokens, longest first) is offered to the dictionary tier, and the join applies only when the
   pair has placement spans and all its kana sits over the kanji token. Tokens and offsets stay unmerged;
   only the ruby changes. Groups touched by author ruby are skipped.
3. **The in-context annotation.** A token the sentence analysis placed takes its reading, lemma and tier
   input from the sentence, never from re-analyzing its surface alone. Re-analysis can re-tokenize: 静か alone
   becomes 静+か, and the joined reading doubles the か.
4. **The dictionary tier** (`readingPayload`), then the per-surface `reading`, then the tokenizer's Latin
   transcription.

Before any of this, runs of unplaced tokens are re-offered to the analysis as one surface. If the analysis
places the merge, it is one word: `２人` tokenizes as `２|人` but is the single word ふたり, so 人 would
otherwise render ひと. Only runs the aligner rejected are probed, only when it placed something, and only up
to a bounded length.

Placement spans from the dictionary drive per-kanji ruby only when they tile the surface exactly.
Otherwise the reading is aligned over the kanji runs: matching leading and trailing kana is trimmed, and a
mixed kanji and kana core is split per kanji run (広く with ひろく renders 広[ひろ]く).

## The compound join

The tokenizer and the analysis both split compounds JMdict holds as one entry, and each half is read alone:
運転手 split as 運転|手 renders うんてんて, a nonword. When `compoundReadings` is supplied, a second pass asks
the dictionary what readings the joined form has. It is decided by the dictionary, never by re-analyzing the
merged surface, so it is safe on in-context-annotated tokens.

- **Runs.** Maximal runs of adjacent, gapless, author-ruby-free tokens are scanned longest sub-run first and
  without overlap (歴史博物館 before 博物館). A form the dictionary knows is consumed even when left alone, and
  shorter sub-runs inside it are not tried.
- **Heteronym protection.** The key is the reading each token actually rendered in the first pass, with
  katakana folded to hiragana. A run whose rendering is already one of the joined form's readings is left
  alone. Script variants of one reading (いまいち, イマイチ) count once.
- **Settling a replacement**, in decreasing confidence: exactly one reading; several readings with exactly
  one placement row; the **nearest reading**, the candidate sharing the longest leading kana with what the
  page renders (日本人 rendered にっぽん + ひと becomes にっぽんじん, not にほんじん), with ties declined; and the
  **commonest reading**, the dictionary's first reading, but only when the rendering shares nothing with any
  candidate (安心 rendered やすこころ). The last two are reported `.heuristic`, so they invite correction.
- **The nearest-reading tradeoff** is deliberate. It will sometimes pick a contextually wrong reading: 十分
  becomes じゅうぶん where a passage may mean じゅっぷん. The alternative is not "no reading" but the nonword
  already on the page (じゅうふん), so a real reading that may be wrong in context is the smaller error. The
  candidate list stays on the provenance so a reader can choose.
- **Placement.** The settled reading is placed per kanji when its JmdictFurigana spans distribute across the
  tokens (博物館 as 博[はく]物[ぶつ]館[かん]). When there is no row, or the row is one indivisible span such as
  jukujikun (二日 as ふつか), the run collapses into one word with one **spanning ruby** over the whole run. It
  keeps the run's full offset span, so highlighting, find and scroll anchors still resolve. Putting the whole
  reading on the first token was measured and was never right: it renders 二[ふつか]日.

### The run's shape

A run's tail tokens are kanji-only. Its head may also be an okurigana-headed token (kanji first, then only
kanji and kana letters: 生き, 考え, 読み), so 生き|方 is a candidate run and 生き方 renders 生[い]き 方[かた]
rather than reading 方 alone as ほう. Separators that sit in the kana blocks (・, ゠) and the spacing sound
marks (゛, ゜) do not count as kana letters.

Such a run is held to a stricter standard than an all-kanji one. It is replaced only when the settled
reading's JmdictFurigana row distributes per token, because a spanning ruby would put kana over kana. And it
is refused outright when the reading would absorb okurigana the text still spells in the next token:
受け取/うけとり before a separate らし would render うけとりらして, where the word is うけとらして.

## Author-ruby propagation

A publisher rubies a name once, on its first appearance. Rendering later occurrences from the analysis makes
the page contradict itself (沙名子 as さなこ, then すななご four lines later). When `readingCorroborated` is
supplied, a run whose surface the author rubied takes the author's reading, behind two gates:

- The author gave that surface **exactly one** reading in the whole document. A surface read two ways is not
  indexed. This keeps out polysemous words whose ruby is context-specific (私 as わたくし).
- The reading the analysis produced is one **no dictionary form accounts for** (`readingCorroborated` returns
  false): 司波 read つかさなみ. 覗 read のぞ is left alone, because 覗く accounts for it.

A multi-word run collapses into one word. The analysis reading stays as a candidate on `.authorRuby`
provenance, which does not invite a choice. The index is derived per document at build time and never
cached, so a reading from one book cannot reach another. An `AuthorRubyIndex` rejects pairs with an empty
side, a base with no kanji, a reading that is not all kana, or a reading equal to its base.

## Reader corrections

A `RubyCorrection` applies only where the word's span equals the correction's offsets **and** its text still
equals the recorded `surface`. Keying on the span makes it per occurrence (十分 corrected in one sentence
leaves another 十分 alone). The surface check is the last defense when a text hash missed a change: a
correction recorded against 十分 is never written onto a 五分 at the same offsets. A correction spanning
several tokens (日本|人) collapses them into one word. The chosen reading is placed okurigana-correct, and the
word keeps its provenance and lemma, so it can be corrected again. Corrections apply after author ruby, so a
reader's choice is never overwritten by the author's reading on the next build.

## Pitch

Pitch belongs to the accent phrase, not the word: 端 and 橋 both read はし and differ only once a particle
joins them (low-HIGH-HIGH against low-HIGH-low). So the `pitch` closure receives a segment's word surfaces
in order, after tokenization, and returns one pattern per word. A nil closure, a count mismatch or a nil
entry leaves a word's ruby untouched. A pattern is split across the word's reading-bearing segments by mora;
if the moras do not spell those readings exactly, the word is left without pitch rather than marked on the
wrong mora.

## Invariants

- **No Apple UI import.** No SwiftUI, UIKit, AppKit or CoreGraphics, at any depth.
- **`KBCore` alone.** One dependency, so the whole pipeline cross-compiles.
- **Tiling.** A word's ruby segments concatenate to its text, and words keep the spans the tokenizer gave
  them, merged only where a rule above says so.
- **Off by default.** Each feature is behind its closure or parameter, and leaving it nil renders exactly what
  the build rendered without it.

## Platforms

On Apple platforms the default segmenter is `CFStringTokenizer`. Elsewhere it is KBCore's per-character
`ScalarCJKSegmenter`, on which the compound join cannot fire (運転手 reads うんてんて), so a non-Apple host
passes a real word segmenter through `segmenter:`.

## Testing

```sh
swift test --filter KBReadingKitTests
```

`KBReadingKitTests` declares both `KBReadingKit` and `KBCore` directly, because `MemberImportVisibility` only
shows members of modules a target imports itself, and these tests build their own `Document` and
`TextSegment` values. `KBJapaneseKitTests` adds cross-library tests that build a real `ReaderContent` with the
furigana tier.
