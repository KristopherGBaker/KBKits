# KBMarkdownKit

KBMarkdownKit is a Markdown foundation for SwiftUI apps. It parses CommonMark plus GFM into a `Sendable` block model
with a source range on every block and inline, turns caller-registered patterns into inline tokens (citations,
mentions), renders the model in SwiftUI, and edits Markdown source in a plain-text editor that styles it as it is typed.
Apple's swift-markdown (cmark-gfm underneath) does the parsing.

**What it is not.** It does not render HTML, load images, fetch links, or highlight code syntax (a fenced block's
language is carried, and a caller can replace the block with its own view). It is not a rich-text editor: the editor
edits Markdown source, and that string is the only truth. It knows no app's tokens; a caller registers patterns. It does
not import documents.

## Install

KBMarkdownKit is two products of the KBKits package:

- **`KBMarkdown`**: the model, the parser, token recognizers, the streaming document and the source highlighter.
  Foundation and swift-markdown only; no SwiftUI, UIKit or AppKit.
- **`KBMarkdownUI`**: `MarkdownView` (the renderer), `MarkdownEditor` (the source editor), and `MarkdownEditorPreview`
  with `MarkdownEditorModePicker` (edit, preview or split). iOS 26 and macOS 26.

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBMarkdown", package: "KBKits"),
        .product(name: "KBMarkdownUI", package: "KBKits")
    ])
]
```

swift-markdown is declared at `from: "0.6.0"`, so a graph that already holds it resolves one copy.

## Quick start

Parse and render:

```swift
import KBMarkdown
import KBMarkdownUI
import SwiftUI

struct NoteView: View {
    let source: String

    var body: some View {
        ScrollView {
            MarkdownView(source: source)
                .padding()
        }
    }
}
```

`MarkdownView` does not scroll on its own. Put it in a `ScrollView`, where its `LazyVStack` builds only the blocks on
screen. Text is selectable.

Edit with a live preview:

```swift
struct NoteEditor: View {
    @State private var text = "# Title\n\nSome *text*."
    @State private var mode = MarkdownEditorPreview.Mode.split

    var body: some View {
        MarkdownEditorPreview(text: $text, mode: $mode)
            .toolbar { MarkdownEditorModePicker(mode: $mode) }
    }
}
```

## Tokens

A `MarkdownTokenRecognizer` is a regular expression (Swift `Regex` syntax) and a kind. Its optional `value` closure maps
a match to the token's value, or returns nil to leave the match as text; by default the value is the matched text. The
initializer throws when the pattern is not a valid regular expression.

```swift
extension MarkdownTokenKind {
    static let citation: Self = "citation"
}

let citations = try MarkdownTokenRecognizer(kind: .citation, pattern: #"\[([A-Z][0-9]+)\]"#) { match in
    match.captures[1]
}
let parser = MarkdownParser(recognizers: [citations])
let document = parser.parse("As shown in [A3].")   // a .token(kind: .citation, value: "A3", ...)

MarkdownView(
    document,
    tokenPresentation: { token in
        MarkdownTokenPresentation(text: AttributedString("[\(token.value)]"), accessibilityLabel: "Source \(token.value)")
    },
    onTokenTap: { token in showSource(token.value) }
)
```

`MarkdownTokenMatch` gives the mapper the whole match as `text` and the capture groups as `captures`, `captures[0]` being
the whole match. Pass the same parser to `MarkdownEditor` or `MarkdownEditorPreview` and the editor highlights the
tokens too.

## Streaming

`MarkdownStreamingDocument` is for text that only grows, such as a streamed model reply. Each `update(_:)` keeps the
finished top-level blocks and re-parses only the open trailing one; `parsedRanges` records what each update parsed.

```swift
var streaming = MarkdownStreamingDocument(parser: parser)
for await partial in replyText {
    document = streaming.update(partial)
}
```

## Main types

**Model and parsing (`KBMarkdown`)**

- `MarkdownParser` and `MarkdownDocument(parsing:recognizers:)`: source in, document out. Pure, synchronous,
  `Sendable`, never fails, so a parse can run off the main actor.
- `MarkdownDocument`: its `blocks` in source order.
- `MarkdownBlock`: heading, paragraph, block quote, list, table, code, thematic break and HTML, each with its `source`.
- `MarkdownList` and `MarkdownListItem` (nesting, `MarkdownTaskState` for task items), `MarkdownTable` (header, rows,
  per-column `MarkdownColumnAlignment?`, inline cells), and `MarkdownCodeBlock` (language, verbatim code, fenced or
  indented).
- `MarkdownInline`: text, emphasis, strong, strikethrough, code, link (destination), image (destination and alt,
  rendered as a link), soft and hard breaks, HTML, and `.token(kind:value:source:)`. `plainText` is the text a reader
  sees, and `tokens` lists the tokens inside an inline.
- `MarkdownSourceRange`: a UTF-16 range, with `utf16`, `nsRange` and `range(in:)`.
- `MarkdownTokenRecognizer`, `MarkdownTokenKind`, `MarkdownTokenMatch` and `MarkdownToken`: a pattern plus a mapper
  that turns matches in text into tokens, and the token a renderer hands to a caller's closures.
- `MarkdownStreamingDocument`: the same document for text that only grows.
- `MarkdownSourceHighlighter` and `MarkdownHighlight`: the roles an editor styles (markers, headings, emphasis, code,
  links, list and quote markers, tokens, HTML), at source ranges.

**SwiftUI (`KBMarkdownUI`)**

- `MarkdownView`: the renderer, from a `MarkdownDocument` or from `source:` with a `parser:`. It takes a `style`, a
  `codeBlock` override, a `tokenPresentation`, `onTokenTap` and `onLinkTap` (nil opens links with the system).
- `MarkdownStyle`: the renderer's fonts, spacing and colors. Every default comes from the system (Dynamic Type text
  styles, semantic colors).
- `MarkdownTokenPresentation`: how a token shows: attributed text, a VoiceOver label, and whether the default capsule
  is drawn. `standard(for:)` is the default, the token's value in a capsule.
- `MarkdownEditor` and `MarkdownEditorStyle`: the source editor over a `Binding<String>`, with a `parser`, a `style`
  and a `debounce` (150 ms by default), and its theme. A color left nil follows the platform's semantic color.
- `MarkdownEditorPreview` and `MarkdownEditorModePicker`: the editor, the rendered preview, or both side by side, over
  one string. The preview is re-parsed from the string, debounced and off the main actor. The picker's labels ship in
  English and Japanese.

## Notes

- **Every range is UTF-16 offsets into the parsed string**, the unit of `NSString`, `NSRange` and every text view.
  Block ranges exclude trailing line endings. Ranges are exact for every node swift-markdown positions; a soft break
  (which it does not position) spans the gap between its neighbors. A token after an escape or entity is aligned to its
  source characters.
- **Tokens come from text only.** Never from inline code, code blocks, HTML, or link or image content, so never from a
  URL. Where matches overlap, the earlier match wins, then the earlier recognizer. A mapper returning nil leaves the
  match as text.
- **Bare `http(s)://` URLs in text are links** (GFM extended autolinks, which swift-markdown leaves as text), with
  trailing punctuation and an unbalanced `)` excluded. `www.` is not.
- **The model holds no swift-markdown node** and no source string; it is a plain `Equatable` value, safe to send
  anywhere.
- **The editor never changes a character.** Styling sets attributes on the text storage only, so it never moves the
  selection or lands on the undo stack. It runs from a debounced parse off the main actor and is dropped when the text
  changed meanwhile. While an input method has marked text (a Japanese composition), nothing restyles and an outside
  text change is refused. It is a `UITextView` on iOS and an `NSTextView` on macOS, TextKit 2 on both. Smart quotes and
  dashes are off, so typed source stays as typed.
- **A token renders inside its paragraph's `Text`**, so it wraps and selects with the text. A `Text` cannot host
  arbitrary views, so a caller supplies a token's look as attributed text (`MarkdownTokenPresentation`) and chooses the
  default capsule (a `TextRenderer`) or none. Tokens are tappable when `onTokenTap` is given (a private link scheme the
  view's `openURL` handler decodes), and VoiceOver reads the caller's label.
- **A fenced-block override returns `AnyView?`**: nil keeps the default monospaced panel. This is how a `mermaid` fence
  becomes a diagram.
- **Code and tables scroll sideways only when they overflow.** Content that fits carries no scroll view, which also
  lets `ImageRenderer` draw it.
- **A streaming document equals a whole parse.** `update(source)` returns exactly `parser.parse(source)`, ranges
  included, for every prefix. A block is kept once another top-level block has started after it on a finished line;
  text that does not extend the last source resets. When in doubt, text stays open: link reference definitions that
  could reach a kept block, or a paragraph a table split off (swift-markdown gives it no position), parse the whole
  text instead.
- **Performance bound (debug, Apple silicon):** parsing and highlighting 2,000 lines, and a full editor pass (parse,
  highlight, every attribute written), each stay under 150 ms. Tests enforce both.

## Android

`KBMarkdown` is written to the Android bar (Foundation and swift-markdown only), but no Android cross-compile has been
run for it yet.

## Tests

From the repository root:

```sh
swift test --filter KBMarkdownTests
swift test --filter KBMarkdownUITests
```

Swift Testing only. The renderer is rasterized with `ImageRenderer` and its PNGs written to a fresh temporary
directory; set `KBMARKDOWN_SNAPSHOT_DIR=/some/dir` to keep them. The editor tests drive a real `NSTextView`
(`insertText`, `setMarkedText`, undo) without a window, except the undo test, which needs one.
