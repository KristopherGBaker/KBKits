import Foundation

/// One styled stretch of Markdown SOURCE: what an editor colours as the user types.
public struct MarkdownHighlight: Sendable, Hashable {
    /// What the stretch is.
    public enum Role: Sendable, Hashable {
        /// Syntax a reader does not see: `#`, `*`, `_`, `~~`, backticks, `[`, fences,
        /// a setext underline, a table's delimiter row, a thematic break.
        case marker
        /// A heading line, markers included; the markers also get `.marker`.
        case heading(level: Int)
        /// Emphasised content.
        case emphasis
        /// Strong content.
        case strong
        /// Struck-through content.
        case strikethrough
        /// Inline code, its backticks included.
        case inlineCode
        /// A whole code block, fences included.
        case codeBlock
        /// A fence's language word.
        case codeLanguage
        /// A link's (or image's) visible text.
        case link
        /// A link's `](destination "title")` or an autolink's angle brackets.
        case linkDestination
        /// A list item's marker (`-`, `1.`), task box included.
        case listMarker
        /// A block quote's `>`.
        case quoteMarker
        /// A recognized token.
        case token(MarkdownTokenKind)
        /// Raw HTML.
        case html
    }

    /// What the stretch is.
    public var role: Role
    /// Where it is in the source.
    public var source: MarkdownSourceRange

    /// A highlight of `role` over `source`.
    public init(role: Role, source: MarkdownSourceRange) {
        self.role = role
        self.source = source
    }
}

/// Computes the highlights for Markdown source from one parse.
///
/// Highlights come out in source order, an outer construct before what it contains and a
/// construct's content role before its markers. An editor applying them in order therefore
/// composes nested styles (a bold run inside a heading stays heading-sized) and leaves
/// markers dimmed. Every range is a `MarkdownSourceRange` into the string highlighted.
public struct MarkdownSourceHighlighter: Sendable {
    /// The parser, recognizers included, whose tokens are highlighted.
    public var parser: MarkdownParser

    /// A highlighter parsing with `parser`.
    public init(parser: MarkdownParser = MarkdownParser()) {
        self.parser = parser
    }

    /// The highlights for `source`.
    public func highlights(in source: String) -> [MarkdownHighlight] {
        let parsed = parser.parseWithMap(source)
        return highlights(for: parsed.document, map: parsed.map)
    }

    /// The highlights for `document`, which must have been parsed from `source`.
    public func highlights(for document: MarkdownDocument, in source: String) -> [MarkdownHighlight] {
        highlights(for: document, map: SourceMap(source))
    }

    func highlights(for document: MarkdownDocument, map: SourceMap) -> [MarkdownHighlight] {
        var collector = HighlightCollector(map: map)
        collector.add(document.blocks)
        return collector.highlights
    }
}

// MARK: - Collecting

private struct HighlightCollector {
    let map: SourceMap
    var highlights: [MarkdownHighlight] = []

    init(map: SourceMap) {
        self.map = map
    }

    private mutating func emit(_ role: MarkdownHighlight.Role, _ lower: Int, _ upper: Int) {
        guard upper > lower else { return }
        highlights.append(MarkdownHighlight(role: role, source: MarkdownSourceRange(utf16: lower..<upper)))
    }

    mutating func add(_ blocks: [MarkdownBlock]) {
        for block in blocks { add(block) }
    }

    private mutating func add(_ block: MarkdownBlock) {
        let range = block.source.utf16
        switch block {
        case let .heading(level, content, _):
            emit(.heading(level: level), range.lowerBound, range.upperBound)
            let inner = Self.span(of: content)
            emit(.marker, range.lowerBound, inner?.lowerBound ?? range.upperBound)
            if let inner { emit(.marker, inner.upperBound, range.upperBound) }
            add(content)
        case let .paragraph(content, _):
            add(content)
        case let .blockQuote(blocks, _):
            addQuoteMarkers(in: range)
            add(blocks)
        case let .list(list, _):
            for item in list.items { add(item) }
        case let .table(table, _):
            add(table)
        case let .code(code, _):
            emit(.codeBlock, range.lowerBound, range.upperBound)
            if code.isFenced { addFences(in: range) }
        case .thematicBreak:
            emit(.marker, range.lowerBound, range.upperBound)
        case .html:
            emit(.html, range.lowerBound, range.upperBound)
        }
    }

    private mutating func add(_ item: MarkdownListItem) {
        let range = item.source.utf16
        var markerEnd = item.blocks.first?.source.utf16.lowerBound ?? range.upperBound
        while markerEnd > range.lowerBound, Self.isSpace(map.units[markerEnd - 1]) { markerEnd -= 1 }
        emit(.listMarker, range.lowerBound, markerEnd)
        add(item.blocks)
    }

    private mutating func add(_ table: MarkdownTable) {
        for cell in table.header.cells { add(cell.content) }
        // The delimiter row is the line after the header.
        if let delimiter = map.nextLineStart(after: table.header.source.utf16.lowerBound) {
            emit(.marker, delimiter, map.lineEnd(containing: delimiter))
        }
        for row in table.rows {
            for cell in row.cells { add(cell.content) }
        }
    }

    /// Each line's leading `>` characters (and the spaces between nested ones). The first
    /// line starts at the quote itself, which may sit after a list marker.
    private mutating func addQuoteMarkers(in range: Range<Int>) {
        var lineStart: Int? = range.lowerBound
        var first = true
        while let start = lineStart, start < range.upperBound {
            var index = start
            if !first { while index < range.upperBound, Self.isSpace(map.units[index]) { index += 1 } }
            var end = index
            let quote = UInt16(ascii: ">")
            while end < range.upperBound, map.units[end] == quote || (end > index && Self.isSpace(map.units[end])) {
                end += 1
            }
            while end > index, Self.isSpace(map.units[end - 1]) { end -= 1 }
            emit(.quoteMarker, index, end)
            first = false
            lineStart = map.nextLineStart(after: start)
        }
    }

    /// A fenced block's opening fence (its language word apart) and closing fence.
    private mutating func addFences(in range: Range<Int>) {
        let openingEnd = min(map.lineEnd(containing: range.lowerBound), range.upperBound)
        var fenceEnd = range.lowerBound
        let fence = map.units[fenceEnd]
        while fenceEnd < openingEnd, map.units[fenceEnd] == fence { fenceEnd += 1 }
        emit(.marker, range.lowerBound, fenceEnd)
        var wordStart = fenceEnd
        while wordStart < openingEnd, Self.isSpace(map.units[wordStart]) { wordStart += 1 }
        var wordEnd = wordStart
        while wordEnd < openingEnd, !Self.isSpace(map.units[wordEnd]) { wordEnd += 1 }
        emit(.codeLanguage, wordStart, wordEnd)
        emit(.marker, wordEnd, openingEnd)

        let closingStart = map.lineStart(containing: range.upperBound)
        guard closingStart > openingEnd else { return }
        var index = closingStart
        while index < range.upperBound, Self.isSpace(map.units[index]) { index += 1 }
        let rest = map.units[index..<range.upperBound]
        if !rest.isEmpty, rest.allSatisfy({ $0 == fence || Self.isSpace($0) }) {
            emit(.marker, index, range.upperBound)
        }
    }

    // MARK: Inlines

    private mutating func add(_ inlines: [MarkdownInline]) {
        for inline in inlines { add(inline) }
    }

    private mutating func add(_ inline: MarkdownInline) {
        let range = inline.source.utf16
        switch inline {
        case let .emphasis(children, _):
            addWrapped(.emphasis, range, children, outer: .marker)
        case let .strong(children, _):
            addWrapped(.strong, range, children, outer: .marker)
        case let .strikethrough(children, _):
            addWrapped(.strikethrough, range, children, outer: .marker)
        case .code:
            emit(.inlineCode, range.lowerBound, range.upperBound)
            let backtick = UInt16(ascii: "`")
            var ticks = 0
            while range.lowerBound + ticks < range.upperBound, map.units[range.lowerBound + ticks] == backtick {
                ticks += 1
            }
            emit(.marker, range.lowerBound, range.lowerBound + ticks)
            emit(.marker, max(range.lowerBound + ticks, range.upperBound - ticks), range.upperBound)
        case let .link(_, children, _):
            addLink(range, children, prefix: .marker)
        case let .image(_, children, _):
            addLink(range, children, prefix: .marker)
        case let .token(kind, _, _):
            emit(.token(kind), range.lowerBound, range.upperBound)
        case .html:
            emit(.html, range.lowerBound, range.upperBound)
        case .text, .softBreak, .lineBreak:
            break
        }
    }

    /// Emphasis, strong and strikethrough: the content role over the whole run, then the
    /// delimiters on either side of the children as markers.
    private mutating func addWrapped(
        _ role: MarkdownHighlight.Role,
        _ range: Range<Int>,
        _ children: [MarkdownInline],
        outer: MarkdownHighlight.Role
    ) {
        emit(role, range.lowerBound, range.upperBound)
        guard let inner = Self.span(of: children) else {
            emit(outer, range.lowerBound, range.upperBound)
            return
        }
        emit(outer, range.lowerBound, inner.lowerBound)
        emit(outer, inner.upperBound, range.upperBound)
        add(children)
    }

    /// A link or image: its text as `.link`, the bracket before as `prefix`, the destination
    /// part after as `.linkDestination`. A bare autolink is all text.
    private mutating func addLink(
        _ range: Range<Int>, _ children: [MarkdownInline], prefix: MarkdownHighlight.Role
    ) {
        guard let inner = Self.span(of: children) else {
            emit(.linkDestination, range.lowerBound, range.upperBound)
            return
        }
        emit(.link, inner.lowerBound, inner.upperBound)
        emit(prefix, range.lowerBound, inner.lowerBound)
        emit(.linkDestination, inner.upperBound, range.upperBound)
        add(children)
    }

    /// The source span `inlines` cover together, or nil when there are none.
    private static func span(of inlines: [MarkdownInline]) -> Range<Int>? {
        guard let first = inlines.first, let last = inlines.last else { return nil }
        let lower = first.source.utf16.lowerBound
        return lower..<max(lower, last.source.utf16.upperBound)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        SourceMap.isSpace(unit)
    }
}
