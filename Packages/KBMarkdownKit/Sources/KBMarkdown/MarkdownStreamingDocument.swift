import Foundation

/// A document parsed from text that only grows, such as a streamed model reply.
///
/// Each `update(_:)` returns exactly what `parser.parse(source)` would, source ranges
/// included, but re-parses only the open trailing block. A top-level block counts as finished
/// once another top-level block has started after it on a line that has ended: CommonMark
/// never reopens a closed block, so no later text can change it (a closed fence, a list or
/// quote that a following block ended, a paragraph past any setext underline, table delimiter
/// or lazy continuation). Finished blocks are kept, and the next parse starts at the line
/// where the open block starts, its ranges mapped straight to whole-text offsets.
///
/// When in doubt, text stays open:
/// - Link reference definitions reach across blocks. When one could join or leave the picture
///   (`]:` in the open text while kept text holds a `]`, or `]:` in kept text while the open
///   text holds a `]`), the whole text is parsed and the kept blocks are taken from that parse.
/// - swift-markdown gives a paragraph that a table splits off no position, and its inlines
///   positions on the first line of the text it parsed. While one is open the whole text is
///   parsed, and it is kept only together with its table.
/// - A block with a range reaching the end of the text stays open, since that range may be
///   clamped there (swift-markdown puts some inlines of a multi-line task item past their line).
public struct MarkdownStreamingDocument: Sendable {
    /// The parser every update runs.
    private let parser: MarkdownParser

    /// Every source range a parse covered, in whole-text UTF-16 offsets, oldest first. A
    /// window into the work done, for tests.
    public private(set) var parsedRanges: [MarkdownSourceRange] = []

    /// The last source updated to, and the document returned for it.
    private var source = ""
    private var document = MarkdownDocument(blocks: [])
    /// The finished blocks, with whole-text ranges.
    private var kept: [MarkdownBlock] = []
    /// The UTF-16 offset of the line where the open text starts; everything before it is kept.
    private var keptEnd = 0
    /// Whether the kept text holds a `]` (it could use a definition) or a `]:` (it could
    /// define one).
    private var keptHasBracket = false
    private var keptHasDefinition = false

    /// A streaming document parsed with `parser`.
    public init(parser: MarkdownParser = MarkdownParser()) {
        self.parser = parser
    }

    /// The document `source` holds. When `source` extends the last source, only the open
    /// trailing block is re-parsed; anything else resets and parses the whole text.
    public mutating func update(_ source: String) -> MarkdownDocument {
        if source.utf8.count == self.source.utf8.count, source.utf8.elementsEqual(self.source.utf8) {
            return document
        }
        if !source.utf8.starts(with: self.source.utf8) { reset() }
        self.source = source

        let units = source.utf16
        let openStart = units.index(units.startIndex, offsetBy: keptEnd)
        let open = source[openStart...]
        let openHasBracket = open.utf8.contains(UInt8(ascii: "]"))
        let openHasDefinition = Self.containsDefinitionMarker(open.utf8)
        if (openHasDefinition && keptHasBracket) || (keptHasDefinition && openHasBracket) { reset() }

        var blocks = parse(source, from: keptEnd)
        // A tail parse cannot reproduce an unpositioned paragraph's inline positions (see
        // above), so parse the whole text while one is open.
        if keptEnd > 0, blocks.contains(where: \.holdsUnpositionedBlock) {
            reset()
            blocks = parse(source, from: 0)
        }
        document = MarkdownDocument(blocks: kept + blocks)
        keep(blocks, in: source)
        return document
    }

    /// The blocks of `source` from UTF-16 offset `start` on, with whole-text ranges.
    private mutating func parse(_ source: String, from start: Int) -> [MarkdownBlock] {
        let units = source.utf16
        parsedRanges.append(MarkdownSourceRange(utf16: start..<units.count))
        return parser.parse(String(source[units.index(units.startIndex, offsetBy: start)...]), base: start).blocks
    }

    /// Moves the finished leading `blocks` into `kept`; the open text then starts at the line
    /// where the first block left out starts.
    private mutating func keep(_ blocks: [MarkdownBlock], in source: String) {
        guard blocks.count >= 2 else { return }
        let units = source.utf16
        let lower = units.index(units.startIndex, offsetBy: keptEnd)
        func index(_ offset: Int) -> String.UTF16View.Index { units.index(lower, offsetBy: offset - keptEnd) }

        // A line still being typed can be read differently once it is longer (a lone `|`
        // after a table is a paragraph until `| 1` makes it a row), so nothing counts as
        // finished until the line the last block starts on has ended.
        let lastStart = blocks[blocks.count - 1].source.utf16.lowerBound
        guard lastStart >= keptEnd, units[index(lastStart)...].contains(where: SourceMap.isLineEnd) else { return }

        var count = 0
        var boundary = keptEnd
        var position = 0
        while position < blocks.count - 1 {
            // A block with no position (a paragraph a table split off) goes with the block
            // after it: that block's range starts where the unpositioned one does.
            var end = position
            while end < blocks.count - 1, blocks[end].source.utf16.isEmpty { end += 1 }
            guard end < blocks.count - 1 else { break }
            // A range reaching the end of the text may be clamped there and grow with it:
            // swift-markdown puts some inlines of a multi-line task item past their line.
            guard blocks[position...end].allSatisfy({ $0.furthestOffset < units.count }) else { break }
            guard let following = blocks[(end + 1)...].first(where: { !$0.source.utf16.isEmpty }) else { break }
            let nextStart = following.source.utf16.lowerBound
            guard nextStart > boundary, nextStart < units.count else { break }
            var lineStart = index(nextStart)
            while lineStart > lower, !SourceMap.isLineEnd(units[units.index(before: lineStart)]) {
                units.formIndex(before: &lineStart)
            }
            let next = keptEnd + units.distance(from: lower, to: lineStart)
            guard next > boundary, next >= blocks[end].source.utf16.upperBound else { break }
            count = end + 1
            boundary = next
            position = end + 1
        }
        guard count > 0 else { return }
        let newlyKept = units[lower..<index(boundary)]
        keptHasBracket = keptHasBracket || newlyKept.contains(UInt16(ascii: "]"))
        keptHasDefinition = keptHasDefinition || Self.containsDefinitionMarker(newlyKept)
        kept += blocks[..<count]
        keptEnd = boundary
    }

    private mutating func reset() {
        kept = []
        keptEnd = 0
        keptHasBracket = false
        keptHasDefinition = false
    }

    /// Whether `units` holds `]:`, which every link reference definition's label ends with.
    private static func containsDefinitionMarker<C: Collection>(_ units: C) -> Bool
        where C.Element: BinaryInteger {
        var previous: C.Element?
        for unit in units {
            if unit == C.Element(UInt8(ascii: ":")), previous == C.Element(UInt8(ascii: "]")) { return true }
            previous = unit
        }
        return false
    }
}

// MARK: - Walking ranges

extension MarkdownBlock {
    /// Whether this block, or any block or list item inside it, has an empty range, which only
    /// a node swift-markdown gave no position has.
    var holdsUnpositionedBlock: Bool {
        if source.utf16.isEmpty { return true }
        switch self {
        case let .blockQuote(blocks, _):
            return blocks.contains(where: \.holdsUnpositionedBlock)
        case let .list(list, _):
            return list.items.contains { item in
                item.source.utf16.isEmpty || item.blocks.contains(where: \.holdsUnpositionedBlock)
            }
        case .heading, .paragraph, .table, .code, .thematicBreak, .html:
            return false
        }
    }

    /// The largest offset any range in this block reaches, its inlines included.
    var furthestOffset: Int {
        switch self {
        case let .heading(_, content, source), let .paragraph(content, source):
            max(source.utf16.upperBound, content.furthestOffset)
        case let .blockQuote(blocks, source):
            blocks.reduce(source.utf16.upperBound) { max($0, $1.furthestOffset) }
        case let .list(list, source):
            list.items.reduce(source.utf16.upperBound) { result, item in
                item.blocks.reduce(max(result, item.source.utf16.upperBound)) { max($0, $1.furthestOffset) }
            }
        case let .table(table, source):
            ([table.header] + table.rows).reduce(source.utf16.upperBound) { result, row in
                row.cells.reduce(max(result, row.source.utf16.upperBound)) { cellResult, cell in
                    max(cellResult, cell.source.utf16.upperBound, cell.content.furthestOffset)
                }
            }
        case let .code(_, source), let .thematicBreak(source), let .html(_, source):
            source.utf16.upperBound
        }
    }
}

extension MarkdownInline {
    /// The largest offset any range in this inline reaches, its children included.
    var furthestOffset: Int {
        switch self {
        case let .emphasis(children, source), let .strong(children, source), let .strikethrough(children, source),
             let .link(_, children, source), let .image(_, children, source):
            max(source.utf16.upperBound, children.furthestOffset)
        case .text, .code, .softBreak, .lineBreak, .html, .token:
            source.utf16.upperBound
        }
    }
}

extension [MarkdownInline] {
    var furthestOffset: Int {
        reduce(0) { Swift.max($0, $1.furthestOffset) }
    }
}
