import Foundation
import KBMarkdown
import Testing

@Suite("Source ranges (UTF-16)")
struct SourceRangeTests {
    @Test("every top-level block maps back to its exact source text")
    func blockRanges() {
        let source = "# Title\n\nA *para*.\n\n> quote\n> more\n\n- one\n- two\n\n"
            + "```swift\ncode\n```\n\n| a |\n|---|\n| 1 |\n\n***"
        let blocks = MarkdownParser().parse(source).blocks
        #expect(blocks.map { slice(source, $0.source) } == [
            "# Title",
            "A *para*.",
            "> quote\n> more",
            "- one\n- two",
            "```swift\ncode\n```",
            "| a |\n|---|\n| 1 |",
            "***"
        ])
    }

    @Test("setext headings and indented code end before the next line, not after it")
    func trailingLineEndsTrimmed() {
        let source = "Title\n===\n\n    code\n\nafter"
        let blocks = MarkdownParser().parse(source).blocks
        #expect(blocks.map { slice(source, $0.source) } == ["Title\n===", "code", "after"])
    }

    @Test("list items, nested items, table rows and cells map back exactly")
    func nestedRanges() throws {
        let source = "- one\n  - two\n    - three\n\n| h1 | h2 |\n|----|----|\n| *c* | d |"
        let blocks = MarkdownParser().parse(source).blocks
        let outer = try #require(list(blocks[0]))
        #expect(slice(source, outer.items[0].source) == "- one\n  - two\n    - three")
        let middle = try #require(outer.items[0].blocks.last.flatMap(list))
        #expect(slice(source, middle.items[0].source) == "- two\n    - three")
        let inner = try #require(middle.items[0].blocks.last.flatMap(list))
        #expect(slice(source, inner.items[0].blocks[0].source) == "three")

        guard case let .table(table, _) = blocks[1] else { Issue.record("expected a table"); return }
        #expect(slice(source, table.header.source) == "| h1 | h2 |")
        #expect(slice(source, table.rows[0].source) == "| *c* | d |")
        #expect(table.rows[0].cells.map { slice(source, $0.content[0].source) } == ["*c*", "d"])
    }

    @Test("inline ranges cover their syntax: emphasis with markers, code with backticks, links whole")
    func inlineRanges() throws {
        let source = "a **b** `c` [d](https://e.x) ~~f~~"
        let parsed = content(try onlyBlock(source))
        let nonText = parsed.filter { if case .text = $0 { false } else { true } }
        #expect(nonText.map { slice(source, $0.source) } == ["**b**", "`c`", "[d](https://e.x)", "~~f~~"])
    }

    @Test("token ranges are exact UTF-16 ranges, past multi-byte text and emoji")
    func tokenRangesNonASCII() throws {
        let source = "日本語の報告 😀 [A1] と [B2]。\n\n> 引用 🇯🇵 [C3]"
        let parser = MarkdownParser(recognizers: [try citationRecognizer()])
        let blocks = parser.parse(source).blocks
        var found = tokens(content(blocks[0]))
        if case let .blockQuote(inner, _) = blocks[1] { found += tokens(content(inner[0])) }
        #expect(found.map { slice(source, $0.source) } == ["[A1]", "[B2]", "[C3]"])
        let nsSource = source as NSString
        #expect(found.map { nsSource.substring(with: $0.source.nsRange) } == ["[A1]", "[B2]", "[C3]"])
    }

    @Test("a token after escapes and entities still lands on its source text")
    func tokenAfterEscapes() throws {
        let source = #"\*x\* &amp; &copy; [A1] end"#
        let parsed = content(try onlyBlock(source, parser: MarkdownParser(recognizers: [try citationRecognizer()])))
        let token = try #require(tokens(parsed).first)
        #expect(slice(source, token.source) == "[A1]")
    }

    @Test("CRLF line endings map ranges correctly")
    func crlf() throws {
        let source = "# One\r\n\r\npara [A1]\r\n\r\n- item"
        let blocks = MarkdownParser(recognizers: [try citationRecognizer()]).parse(source).blocks
        #expect(blocks.map { slice(source, $0.source) } == ["# One", "para [A1]", "- item"])
        #expect(tokens(content(blocks[1])).map { slice(source, $0.source) } == ["[A1]"])
    }

    @Test("text pieces around a token tile the text's source")
    func textAroundToken() throws {
        let source = "before [A1] after"
        let parsed = content(try onlyBlock(source, parser: MarkdownParser(recognizers: [try citationRecognizer()])))
        #expect(parsed.map { slice(source, $0.source) } == ["before ", "[A1]", " after"])
    }
}
