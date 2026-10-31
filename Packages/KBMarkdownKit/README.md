# KBMarkdownKit

The shared Markdown foundation: a `Sendable` block model parsed from CommonMark plus GFM, with
a source range on every block and inline; caller-registered inline tokens (citations, mentions);
a SwiftUI renderer; and a plain-text source editor that styles Markdown as it is typed.
swift-markdown (Apple, cmark-gfm underneath) does the parsing.

**What it is NOT.** It does not render HTML, load images, fetch links, or highlight code syntax
(a fenced block's language is carried, and a caller can replace the block with its own view).
It is not a rich-text editor: the editor edits Markdown SOURCE, and that string is the only
truth. It knows no app's tokens; a caller registers patterns. It does not import documents.

## Targets

- **`KBMarkdown`**: model, parser, token recognizers, source highlighter. Foundation and
  swift-markdown only; no SwiftUI, UIKit or AppKit.
- **`KBMarkdownUI`**: `MarkdownView` (renderer), `MarkdownEditor` (source editor),
  `MarkdownEditorPreview` and `MarkdownEditorModePicker` (edit, preview or split). iOS 26 and
  macOS 26.

## Key types

- `MarkdownParser` / `MarkdownDocument(parsing:recognizers:)`: source in, document out. Pure,
  synchronous, `Sendable`, never fails.
- `MarkdownStreamingDocument`: the same document for text that only grows (a streamed reply).
  `update(_:)` keeps finished top-level blocks and re-parses only the open trailing one;
  `parsedRanges` records what each update parsed.
- `MarkdownDocument`, `MarkdownBlock` (heading, paragraph, block quote, list, table, code,
  thematic break, HTML), `MarkdownList` / `MarkdownListItem` (nesting, task state),
  `MarkdownTable` (header, rows, per-column `MarkdownColumnAlignment?`, inline cells),
  `MarkdownCodeBlock` (language, verbatim code, fenced or indented).
- `MarkdownInline`: text, emphasis, strong, strikethrough, code, link (destination), image
  (destination + alt, rendered as a link), soft and hard breaks, HTML, and
  `.token(kind:value:source:)`.
- `MarkdownSourceRange`: a UTF-16 range (`utf16`, `nsRange`, `range(in:)`).
- `MarkdownTokenRecognizer` / `MarkdownTokenKind` / `MarkdownToken`: a regex plus a mapper that
  turns matches in text into tokens.
- `MarkdownSourceHighlighter` / `MarkdownHighlight`: the roles an editor styles, at source ranges.
- `MarkdownView`, `MarkdownStyle`, `MarkdownTokenPresentation`: the renderer, its theme, and how
  a token shows.
- `MarkdownEditor`, `MarkdownEditorStyle`: the source editor and its theme.

## Invariants

- **Every range is UTF-16 offsets into the parsed string**, the unit of `NSString`, `NSRange` and
  every text view. Block ranges exclude trailing line endings. Exact for every node
  swift-markdown positions; a soft break (which it does not) spans the gap between its
  neighbours. A token after an escape or entity is aligned to its source characters.
- **Tokens come from TEXT only.** Never from inline code, code blocks, HTML, or link or image
  content, so never from a URL. Overlaps: the earlier match wins, then the earlier recognizer.
  A mapper returning nil leaves the match as text.
- **Bare `http(s)://` URLs in text are links** (GFM extended autolinks, which swift-markdown
  leaves as text), trailing punctuation and an unbalanced `)` excluded. `www.` is not.
- **The model holds no swift-markdown node** and no source string; it is a plain `Equatable`
  value, safe to send anywhere.
- **The editor never changes a character.** Styling sets attributes on the text storage only,
  so it never moves the selection or lands on the undo stack. It runs from a debounced parse
  off the main actor and is dropped when the text changed meanwhile. While an input method has
  marked text (a Japanese composition), nothing restyles and an outside text change is refused.
  TextKit 2 on both platforms; smart quotes and dashes are off, so typed source stays as typed.
- **A token renders inside its paragraph's `Text`**, so it wraps and selects with the text. A
  `Text` cannot host arbitrary views, so a caller supplies a token's look as attributed text
  (`MarkdownTokenPresentation`) and chooses the default capsule (a `TextRenderer`) or none.
  Tokens are tappable when `onTokenTap` is given (a private link scheme the view's `openURL`
  handler decodes) and VoiceOver reads the caller's label.
- **A fenced-block override returns `AnyView?`**: nil keeps the default monospaced panel.
- **Code and tables scroll sideways only when they overflow**; content that fits carries no
  scroll view (which also lets `ImageRenderer` draw it).
- **Performance bound (debug, Apple silicon):** parsing and highlighting 2,000 lines, and a full
  editor pass (parse, highlight, every attribute written), each stay under 150 ms. Tests enforce
  both.
- **A streaming document equals a whole parse.** `update(source)` returns exactly
  `parser.parse(source)`, ranges included, for every prefix. A block is kept once another
  top-level block has started after it on a finished line; text that does not extend the last
  source resets. When in doubt text stays open: link reference definitions that could reach a
  kept block, or a paragraph a table split off (swift-markdown gives it no position), parse
  the whole text instead.
- **swift-markdown is declared at `from: "0.6.0"`**, so a graph that already holds it resolves
  one copy.

## Android

`KBMarkdown` is written to the Android bar (Foundation and swift-markdown only), but no Android
cross-compile has been run for it yet.

## Testing

`cd Packages/KBMarkdownKit && swift test`. Swift Testing only. The renderer is rasterized with
`ImageRenderer` and its PNGs written to a fresh temp directory; set
`KBMARKDOWN_SNAPSHOT_DIR=/some/dir` to keep them. The editor tests drive a real `NSTextView`
(insertText, setMarkedText, undo) without a window, except the undo test, which needs one.
