import KBMarkdown
import Testing

@Suite("Source highlighter")
struct HighlighterTests {
    private static let fixture = """
    ## Heading *it*

    Body **bold** and _em_ with `code` and [link](https://e.x) [A1] ~~old~~.

    > quoted
    > > nested

    - item
      1. [ ] task

    ```swift
    let x = 1
    ```
    """

    private func highlights() throws -> [(role: MarkdownHighlight.Role, text: String)] {
        let highlighter = MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()]))
        return highlighter.highlights(in: Self.fixture).map { ($0.role, slice(Self.fixture, $0.source)) }
    }

    private func texts(_ role: MarkdownHighlight.Role) throws -> [String] {
        try highlights().filter { $0.role == role }.map(\.text)
    }

    @Test("a heading line is styled whole and its hashes are markers")
    func heading() throws {
        #expect(try texts(.heading(level: 2)) == ["## Heading *it*"])
        #expect(try texts(.marker).contains("## "))
        #expect(try texts(.emphasis).contains("*it*"))
    }

    @Test("emphasis and strong cover their run; their delimiters are markers")
    func emphasisMarkers() throws {
        #expect(try texts(.strong) == ["**bold**"])
        #expect(try texts(.emphasis) == ["*it*", "_em_"])
        let markers = try texts(.marker)
        #expect(markers.filter { $0 == "**" }.count == 2)
        #expect(markers.filter { $0 == "_" }.count == 2)
        #expect(markers.filter { $0 == "~~" }.count == 2)
        #expect(try texts(.strikethrough) == ["~~old~~"])
    }

    @Test("inline code and fenced code are code; fences and backticks are markers")
    func code() throws {
        #expect(try texts(.inlineCode) == ["`code`"])
        #expect(try texts(.codeBlock) == ["```swift\nlet x = 1\n```"])
        #expect(try texts(.codeLanguage) == ["swift"])
        #expect(try texts(.marker).filter { $0 == "```" }.count == 2)
        #expect(try texts(.marker).filter { $0 == "`" }.count == 2)
    }

    @Test("a link's text is the link; its destination part is dimmed")
    func links() throws {
        #expect(try texts(.link) == ["link"])
        #expect(try texts(.linkDestination) == ["](https://e.x)"])
        #expect(try texts(.marker).contains("["))
    }

    @Test("list markers include the task box; quote markers are each line's >")
    func listAndQuoteMarkers() throws {
        #expect(try texts(.listMarker) == ["-", "1. [ ]"])
        #expect(try texts(.quoteMarker) == [">", "> >", ">"])
    }

    @Test("registered tokens are highlighted at their source")
    func tokens() throws {
        #expect(try texts(.token(.citation)) == ["[A1]"])
    }

    @Test("a token inside code is not highlighted as a token")
    func tokenInCode() throws {
        let highlighter = MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()]))
        let roles = highlighter.highlights(in: "`[A1]`\n\n```\n[B2]\n```").map(\.role)
        #expect(!roles.contains(.token(.citation)))
    }

    @Test("highlighting a parsed document equals highlighting its source")
    func documentAndSourceAgree() throws {
        let parser = MarkdownParser(recognizers: [try citationRecognizer()])
        let highlighter = MarkdownSourceHighlighter(parser: parser)
        #expect(highlighter.highlights(for: parser.parse(Self.fixture), in: Self.fixture)
            == highlighter.highlights(in: Self.fixture))
    }
}
