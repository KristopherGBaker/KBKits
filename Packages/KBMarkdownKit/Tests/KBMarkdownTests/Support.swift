import KBMarkdown
import Testing

/// The source text `range` covers.
func slice(_ source: String, _ range: MarkdownSourceRange) -> String {
    guard let bounds = range.range(in: source) else { return "<out of range \(range)>" }
    return String(source[bounds])
}

/// The only block of `source`, which the test expects to hold exactly one.
func onlyBlock(_ source: String, parser: MarkdownParser = MarkdownParser()) throws -> MarkdownBlock {
    let blocks = parser.parse(source).blocks
    try #require(blocks.count == 1, "expected one block, got \(blocks.count): \(blocks)")
    return blocks[0]
}

/// The inline content of a paragraph or heading block.
func content(_ block: MarkdownBlock) -> [MarkdownInline] {
    switch block {
    case let .paragraph(content, _), let .heading(_, content, _): content
    default: []
    }
}

/// Every token in `inlines`, in order.
func tokens(_ inlines: [MarkdownInline]) -> [MarkdownToken] {
    inlines.flatMap(\.tokens)
}

/// A `[A1]`-style citation recognizer whose value is the label inside the brackets.
func citationRecognizer() throws -> MarkdownTokenRecognizer {
    try MarkdownTokenRecognizer(kind: "citation", pattern: #"\[([A-Z][0-9]+)\]"#) { $0.captures[1] }
}

extension MarkdownTokenKind {
    static let citation: Self = "citation"
}

/// The list of a list block.
func list(_ block: MarkdownBlock) -> MarkdownList? {
    if case let .list(list, _) = block { return list }
    return nil
}
