import Foundation
import Markdown

/// Parses Markdown source into a `MarkdownDocument`.
///
/// CommonMark plus the GFM extensions (tables, strikethrough, task items, autolinks), parsed
/// by swift-markdown. Pure and synchronous: no swift-markdown node escapes a parse, and the
/// parser is a `Sendable` value, so a parse can run off the main actor.
public struct MarkdownParser: Sendable {
    /// The token recognizers run over text, in priority order.
    public var recognizers: [MarkdownTokenRecognizer]

    /// A parser running `recognizers` over text nodes.
    public init(recognizers: [MarkdownTokenRecognizer] = []) {
        self.recognizers = recognizers
    }

    /// The document `source` holds. Never fails: any string is some Markdown document.
    public func parse(_ source: String) -> MarkdownDocument {
        parseWithMap(source).document
    }

    /// The document `source` holds as the tail of a longer text that starts `base` UTF-16
    /// units in, with every range an offset into that whole text.
    func parse(_ source: String, base: Int) -> MarkdownDocument {
        parseWithMap(source, base: base).document
    }

    /// The document and the source map built for it, for the highlighter's scans. With a
    /// `base`, `source` is a tail of a longer text and the ranges are offsets into it.
    func parseWithMap(_ source: String, base: Int = 0) -> (document: MarkdownDocument, map: SourceMap) {
        let map = SourceMap(source, base: base)
        let lowering = Lowering(map: map, recognizers: recognizers.compactMap(CompiledTokenRecognizer.init))
        let parsed = Markdown.Document(parsing: source)
        return (MarkdownDocument(blocks: lowering.blocks(of: parsed)), map)
    }
}

extension MarkdownDocument {
    /// The document `source` holds, parsed with `recognizers`.
    public init(parsing source: String, recognizers: [MarkdownTokenRecognizer] = []) {
        self = MarkdownParser(recognizers: recognizers).parse(source)
    }
}

// MARK: - Lowering

/// Lowers swift-markdown's tree to the model, converting every range as it goes.
private struct Lowering {
    let map: SourceMap
    let recognizers: [CompiledTokenRecognizer]

    func blocks(of container: any Markup) -> [MarkdownBlock] {
        container.children.compactMap(block)
    }

    private func blockRange(_ markup: any Markup, fallback: Int = 0) -> MarkdownSourceRange {
        guard let range = markup.range else { return MarkdownSourceRange(utf16: fallback..<fallback) }
        return map.trimmingLineEnds(map.range(range))
    }

    private func block(_ markup: any Markup) -> MarkdownBlock? {
        let source = blockRange(markup)
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, content: inlines(of: heading, in: source), source: source)
        case is Markdown.Paragraph:
            return .paragraph(content: inlines(of: markup, in: source), source: source)
        case is BlockQuote:
            return .blockQuote(blocks: blocks(of: markup), source: source)
        case let list as OrderedList:
            let ordered = MarkdownList(kind: .ordered(start: Int(list.startIndex)), items: items(of: list))
            return .list(ordered, source: source)
        case is UnorderedList:
            return .list(MarkdownList(kind: .unordered, items: items(of: markup)), source: source)
        case let table as Markdown.Table:
            return .table(self.table(table, in: source), source: source)
        case let code as CodeBlock:
            return .code(codeBlock(code, in: source), source: source)
        case is ThematicBreak:
            return .thematicBreak(source: source)
        case let html as HTMLBlock:
            return .html(Self.droppingFinalNewline(html.rawHTML), source: source)
        default:
            // Block directives and other extensions are off by default; nothing else reaches here.
            return nil
        }
    }

    private func items(of list: any Markup) -> [MarkdownListItem] {
        list.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            let task: MarkdownTaskState? = switch item.checkbox {
            case .checked: .checked
            case .unchecked: .unchecked
            case nil: nil
            }
            return MarkdownListItem(task: task, blocks: blocks(of: item), source: blockRange(item))
        }
    }

    private func table(_ table: Markdown.Table, in source: MarkdownSourceRange) -> MarkdownTable {
        let alignments: [MarkdownColumnAlignment?] = table.columnAlignments.map { alignment in
            switch alignment {
            case .left: .leading
            case .center: .center
            case .right: .trailing
            case nil: nil
            }
        }
        let rowRange = { (row: any Markup) in blockRange(row, fallback: source.utf16.lowerBound) }
        let cells = { (row: any Markup) -> [MarkdownTableCell] in
            row.children.map { cell in
                let range = blockRange(cell, fallback: rowRange(row).utf16.lowerBound)
                return MarkdownTableCell(content: inlines(of: cell, in: range), source: range)
            }
        }
        let header = MarkdownTableRow(cells: cells(table.head), source: rowRange(table.head))
        let rows = table.body.rows.map { MarkdownTableRow(cells: cells($0), source: rowRange($0)) }
        return MarkdownTable(alignments: alignments, header: header, rows: Array(rows))
    }

    private func codeBlock(_ code: CodeBlock, in source: MarkdownSourceRange) -> MarkdownCodeBlock {
        // swift-markdown does not say which kind of code block it parsed; the source does. An
        // indented block's range starts after its indentation, a fenced one's at the fence.
        let first = map.unit(at: source.utf16.lowerBound) ?? 0
        let isFenced = first == UInt16(ascii: "`") || first == UInt16(ascii: "~")
        let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
        return MarkdownCodeBlock(language: language, code: Self.droppingFinalNewline(code.code), isFenced: isFenced)
    }

    private static func droppingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Inlines

    /// The inline children of `container`, which spans `containerRange`. A child without a
    /// range of its own (swift-markdown gives soft breaks none) spans the gap between its
    /// neighbours. `recognize` is false inside links and images.
    private func inlines(
        of container: any Markup, in containerRange: MarkdownSourceRange, recognize: Bool = true
    ) -> [MarkdownInline] {
        let children = Array(container.children)
        var result: [MarkdownInline] = []
        var cursor = containerRange.utf16.lowerBound
        for (index, child) in children.enumerated() {
            let range: MarkdownSourceRange
            if let childRange = child.range {
                range = map.range(childRange)
            } else {
                let next = children[(index + 1)...].lazy.compactMap(\.range).first.map { map.offset($0.lowerBound) }
                range = MarkdownSourceRange(utf16: cursor..<max(cursor, next ?? containerRange.utf16.upperBound))
            }
            cursor = range.utf16.upperBound
            result += inline(child, in: range, recognize: recognize)
        }
        return result
    }

    private func inline(_ markup: any Markup, in source: MarkdownSourceRange, recognize: Bool) -> [MarkdownInline] {
        switch markup {
        case let text as Markdown.Text:
            return textInlines(text.string, in: source, recognize: recognize)
        case is Emphasis:
            return [.emphasis(inlines(of: markup, in: source, recognize: recognize), source: source)]
        case is Strong:
            return [.strong(inlines(of: markup, in: source, recognize: recognize), source: source)]
        case is Strikethrough:
            return [.strikethrough(inlines(of: markup, in: source, recognize: recognize), source: source)]
        case let code as InlineCode:
            return [.code(code.code, source: source)]
        case let link as Markdown.Link:
            let content = inlines(of: link, in: source, recognize: false)
            return [.link(destination: link.destination, content: content, source: source)]
        case let image as Markdown.Image:
            let alt = inlines(of: image, in: source, recognize: false)
            return [.image(destination: image.source, alt: alt, source: source)]
        case is SoftBreak:
            return [.softBreak(source: source)]
        case is LineBreak:
            return [.lineBreak(source: source)]
        case let html as InlineHTML:
            return [.html(html.rawHTML, source: source)]
        default:
            // An inline this model has no case for (a symbol link, an attribute span): keep
            // what it says rather than drop it.
            let text = markup.format()
            return text.isEmpty ? [] : [.text(text, source: source)]
        }
    }

    /// A text node, split around any bare URLs (GFM extended autolinks, which swift-markdown
    /// leaves as text) and any tokens the recognizers find in the rest. Inside a link
    /// (`recognize` false) the text is kept whole.
    private func textInlines(_ text: String, in source: MarkdownSourceRange, recognize: Bool) -> [MarkdownInline] {
        guard recognize else { return [.text(text, source: source)] }
        let urls = BareURL.ranges(in: text)
        let tokens = recognizers.isEmpty ? [] : recognizers.hits(in: text).filter { hit in
            !urls.contains { $0.lowerBound < hit.upper && hit.lower < $0.upperBound }
        }
        let hits = (tokens.map { InlineHit.token($0) } + urls.map { InlineHit.url($0) }).sorted { $0.lower < $1.lower }
        guard !hits.isEmpty else { return [.text(text, source: source)] }

        let offsets = map.offsets(of: text, in: source)
        let units = text.utf16
        func slice(_ lower: Int, _ upper: Int) -> String {
            let start = units.index(units.startIndex, offsetBy: lower)
            let end = units.index(start, offsetBy: upper - lower)
            return String(text[start..<end])
        }
        // The source span of text units lower..<upper: from the first unit's source offset
        // to just past the last unit's, which stays exact around escapes.
        func span(_ lower: Int, _ upper: Int) -> MarkdownSourceRange {
            let start = offsets[lower]
            let end = upper == units.count ? offsets[upper] : offsets[upper - 1] + 1
            return MarkdownSourceRange(utf16: start..<max(start, end))
        }

        var result: [MarkdownInline] = []
        var position = 0
        for hit in hits {
            if hit.lower > position {
                result.append(.text(slice(position, hit.lower), source: span(position, hit.lower)))
            }
            let range = span(hit.lower, hit.upper)
            switch hit {
            case let .token(token):
                result.append(.token(kind: token.kind, value: token.value, source: range))
            case .url:
                let url = slice(hit.lower, hit.upper)
                result.append(.link(destination: url, content: [.text(url, source: range)], source: range))
            }
            position = hit.upper
        }
        if position < units.count {
            result.append(.text(slice(position, units.count), source: span(position, units.count)))
        }
        return result
    }
}

/// A token or a bare URL found in a text node, in UTF-16 offsets into its string.
private enum InlineHit {
    case token(TokenHit)
    case url(Range<Int>)

    var lower: Int {
        switch self {
        case let .token(hit): hit.lower
        case let .url(range): range.lowerBound
        }
    }

    var upper: Int {
        switch self {
        case let .token(hit): hit.upper
        case let .url(range): range.upperBound
        }
    }
}

/// GFM's extended autolinks for `http://` and `https://` (the `www.` form is not
/// recognized): the URL runs to whitespace or `<`, minus trailing punctuation and an
/// unbalanced closing parenthesis.
enum BareURL {
    static func ranges(in text: String) -> [Range<Int>] {
        guard text.contains("://") else { return [] }
        var result: [Range<Int>] = []
        for match in text.matches(of: #/https?:\/\/[^\s<]+/#) {
            var url = text[match.range]
            while let last = url.last, ".,:;!?'\"*_~".contains(last)
                || (last == ")" && url.count(where: { $0 == "(" }) < url.count(where: { $0 == ")" })) {
                url = url.dropLast()
            }
            guard !url.hasSuffix("://") else { continue }
            let lower = text.utf16.distance(from: text.startIndex, to: url.startIndex)
            result.append(lower..<(lower + url.utf16.count))
        }
        return result
    }
}
