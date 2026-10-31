import Foundation

/// A parsed Markdown document: its blocks in source order.
///
/// A plain value. It holds no swift-markdown node and no reference to the source string;
/// every block and inline carries the `MarkdownSourceRange` it was parsed from, so a caller
/// holding the source can map anything here back onto it.
public struct MarkdownDocument: Sendable, Equatable {
    /// The top-level blocks, in source order.
    public var blocks: [MarkdownBlock]

    /// A document of these blocks.
    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }
}

/// One block of a document.
public indirect enum MarkdownBlock: Sendable, Equatable {
    /// An ATX (`## Title`) or setext heading; `level` is 1 through 6.
    case heading(level: Int, content: [MarkdownInline], source: MarkdownSourceRange)
    /// A paragraph.
    case paragraph(content: [MarkdownInline], source: MarkdownSourceRange)
    /// A block quote, holding blocks of its own (paragraphs, lists, further quotes).
    case blockQuote(blocks: [MarkdownBlock], source: MarkdownSourceRange)
    /// An ordered or unordered list. Nested lists live inside an item's `blocks`.
    case list(MarkdownList, source: MarkdownSourceRange)
    /// A GFM table.
    case table(MarkdownTable, source: MarkdownSourceRange)
    /// A fenced or indented code block. Never inline-parsed.
    case code(MarkdownCodeBlock, source: MarkdownSourceRange)
    /// A thematic break (`***`, `---`, `___`).
    case thematicBreak(source: MarkdownSourceRange)
    /// A raw HTML block, kept as its literal text. Nothing here interprets HTML.
    case html(String, source: MarkdownSourceRange)

    /// Where this block came from, trailing line endings excluded.
    public var source: MarkdownSourceRange {
        switch self {
        case let .heading(_, _, source), let .paragraph(_, source), let .blockQuote(_, source),
             let .list(_, source), let .table(_, source), let .code(_, source),
             let .thematicBreak(source), let .html(_, source):
            source
        }
    }
}

/// An ordered or unordered list.
public struct MarkdownList: Sendable, Equatable {
    /// Bullets, or numbers counting up from `start`.
    public enum Kind: Sendable, Equatable {
        case unordered
        case ordered(start: Int)
    }

    /// Bullets or numbers.
    public var kind: Kind
    /// The items, in order.
    public var items: [MarkdownListItem]

    /// A list of `kind` holding `items`.
    public init(kind: Kind, items: [MarkdownListItem]) {
        self.kind = kind
        self.items = items
    }
}

/// One item of a list.
public struct MarkdownListItem: Sendable, Equatable {
    /// The GFM task state (`- [ ]` / `- [x]`), or nil for an ordinary item.
    public var task: MarkdownTaskState?
    /// The item's blocks: usually one paragraph, then any nested lists.
    public var blocks: [MarkdownBlock]
    /// Where the item came from, its marker included.
    public var source: MarkdownSourceRange

    /// An item holding `blocks`.
    public init(task: MarkdownTaskState?, blocks: [MarkdownBlock], source: MarkdownSourceRange) {
        self.task = task
        self.blocks = blocks
        self.source = source
    }
}

/// Whether a GFM task item is ticked.
public enum MarkdownTaskState: Sendable, Equatable {
    case unchecked
    case checked
}

/// A GFM table: a header row, body rows, and a per-column alignment.
public struct MarkdownTable: Sendable, Equatable {
    /// One entry per column; nil where the delimiter row gives none (`---`).
    public var alignments: [MarkdownColumnAlignment?]
    /// The header row.
    public var header: MarkdownTableRow
    /// The body rows, in order.
    public var rows: [MarkdownTableRow]

    /// A table with this header, body and alignment.
    public init(alignments: [MarkdownColumnAlignment?], header: MarkdownTableRow, rows: [MarkdownTableRow]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    /// The column count: the widest of the alignments, the header and every row.
    public var columnCount: Int {
        ([alignments.count, header.cells.count] + rows.map(\.cells.count)).max() ?? 0
    }
}

/// How a table column's delimiter row aligns it (`:--`, `:-:`, `--:`).
public enum MarkdownColumnAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// One row of a table.
public struct MarkdownTableRow: Sendable, Equatable {
    /// The cells, in column order.
    public var cells: [MarkdownTableCell]
    /// Where the row came from.
    public var source: MarkdownSourceRange

    /// A row of `cells`.
    public init(cells: [MarkdownTableCell], source: MarkdownSourceRange) {
        self.cells = cells
        self.source = source
    }
}

/// One cell of a table: inline content, formatting and tokens included.
public struct MarkdownTableCell: Sendable, Equatable {
    /// The cell's inline content.
    public var content: [MarkdownInline]
    /// Where the cell came from.
    public var source: MarkdownSourceRange

    /// A cell holding `content`.
    public init(content: [MarkdownInline], source: MarkdownSourceRange) {
        self.content = content
        self.source = source
    }
}

/// A code block's contents.
public struct MarkdownCodeBlock: Sendable, Equatable {
    /// The first word of a fence's info string (`swift` in ```` ```swift ````); nil when a
    /// fence has none and always nil for indented code.
    public var language: String?
    /// The code, verbatim: internal newlines and indentation kept, the one trailing newline
    /// the parser appends removed.
    public var code: String
    /// Fenced (```` ``` ```` or `~~~`) rather than indented by four spaces.
    public var isFenced: Bool

    /// A code block holding `code`.
    public init(language: String?, code: String, isFenced: Bool) {
        self.language = language
        self.code = code
        self.isFenced = isFenced
    }
}
