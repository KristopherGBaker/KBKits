import KBMarkdown
import Testing

@Suite("Parser: blocks")
struct ParserBlockTests {
    @Test("ATX headings keep their level 1 through 6, setext headings too")
    func headings() throws {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Level \($0)" }.joined(separator: "\n")
            + "\n\nSetext one\n===\n\nSetext two\n---"
        let blocks = MarkdownParser().parse(source).blocks
        let levels = blocks.compactMap { block -> Int? in
            if case let .heading(level, _, _) = block { return level }
            return nil
        }
        #expect(levels == [1, 2, 3, 4, 5, 6, 1, 2])
        #expect(MarkdownInline.plainText(of: content(blocks[2])) == "Level 3")
        #expect(MarkdownInline.plainText(of: content(blocks[7])) == "Setext two")
    }

    @Test("paragraphs split on blank lines and soft breaks read as spaces")
    func paragraphs() {
        let blocks = MarkdownParser().parse("one\ntwo\n\nthree").blocks
        #expect(blocks.count == 2)
        #expect(MarkdownInline.plainText(of: content(blocks[0])) == "one two")
        guard case .paragraph = blocks[1] else { Issue.record("expected a paragraph"); return }
    }

    @Test("a block quote holds blocks, nested quotes and lists included")
    func blockQuotes() throws {
        let block = try onlyBlock("> outer\n>\n> > inner\n>\n> - item")
        guard case let .blockQuote(blocks, _) = block else { Issue.record("expected a quote"); return }
        #expect(blocks.count == 3)
        guard case let .blockQuote(inner, _) = blocks[1] else { Issue.record("expected a nested quote"); return }
        #expect(MarkdownInline.plainText(of: content(inner[0])) == "inner")
        #expect(list(blocks[2])?.items.count == 1)
    }

    @Test("lists nest three deep and keep their kind at every level")
    func nestedLists() throws {
        let source = "- one\n  1. two\n     - three\n- four"
        let outer = try #require(list(try onlyBlock(source)))
        #expect(outer.kind == .unordered)
        #expect(outer.items.count == 2)
        let second = try #require(outer.items[0].blocks.last.flatMap(list))
        #expect(second.kind == .ordered(start: 1))
        let third = try #require(second.items[0].blocks.last.flatMap(list))
        #expect(third.kind == .unordered)
        #expect(MarkdownInline.plainText(of: content(third.items[0].blocks[0])) == "three")
        #expect(MarkdownInline.plainText(of: content(outer.items[1].blocks[0])) == "four")
    }

    @Test("an ordered list keeps its start number")
    func orderedStart() throws {
        let parsed = try #require(list(try onlyBlock("3. c\n4. d")))
        #expect(parsed.kind == .ordered(start: 3))
    }

    @Test("task items carry checked, unchecked, or no task state")
    func taskItems() throws {
        let parsed = try #require(list(try onlyBlock("- [ ] todo\n- [x] done\n- [X] also done\n- plain")))
        #expect(parsed.items.map(\.task) == [.unchecked, .checked, .checked, nil])
        #expect(MarkdownInline.plainText(of: content(parsed.items[0].blocks[0])) == "todo")
    }

    @Test("a table keeps header, rows, alignment and inline formatting in cells")
    func tables() throws {
        let source = "| Name | Score | Note |\n|:-----|:----:|-----:|\n"
            + "| **Ann** | `9` | *ok* [x](https://e.x) |\n| Bo | 7 | ~~no~~ |"
        guard case let .table(table, _) = try onlyBlock(source) else { Issue.record("expected a table"); return }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.columnCount == 3)
        #expect(table.header.cells.map { MarkdownInline.plainText(of: $0.content) } == ["Name", "Score", "Note"])
        #expect(table.rows.count == 2)
        let first = table.rows[0].cells
        guard case .strong = first[0].content.first else { Issue.record("expected strong in a cell"); return }
        guard case .code("9", _) = first[1].content.first else { Issue.record("expected code in a cell"); return }
        guard case .emphasis = first[2].content.first else { Issue.record("expected emphasis in a cell"); return }
        let link = first[2].content.first { if case .link = $0 { true } else { false } }
        guard case let .link(destination, _, _)? = link else { Issue.record("expected a link in a cell"); return }
        #expect(destination == "https://e.x")
        guard case .strikethrough = table.rows[1].cells[2].content.first else {
            Issue.record("expected strikethrough in a cell")
            return
        }
    }

    @Test("a table without alignment has nil alignments")
    func tableWithoutAlignment() throws {
        guard case let .table(table, _) = try onlyBlock("| a | b |\n|---|---|\n| 1 | 2 |") else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [nil, nil])
    }

    @Test("fenced code keeps its language and verbatim text; no language is nil")
    func fencedCode() throws {
        let source = "```swift\nlet x = 1\n  indented\n```\n\n```\nplain *not em*\n```\n\n~~~mermaid\ngraph TD\n~~~"
        let blocks = MarkdownParser().parse(source).blocks
        #expect(blocks.count == 3)
        #expect(blocks.map(\.codeBlock) == [
            MarkdownCodeBlock(language: "swift", code: "let x = 1\n  indented", isFenced: true),
            MarkdownCodeBlock(language: nil, code: "plain *not em*", isFenced: true),
            MarkdownCodeBlock(language: "mermaid", code: "graph TD", isFenced: true)
        ])
    }

    @Test("indented code is code without a language")
    func indentedCode() throws {
        let block = try onlyBlock("    let y = 2\n    y += 1")
        #expect(block.codeBlock == MarkdownCodeBlock(language: nil, code: "let y = 2\ny += 1", isFenced: false))
    }

    @Test("thematic breaks and HTML blocks are their own blocks")
    func breaksAndHTML() {
        let blocks = MarkdownParser().parse("a\n\n***\n\n<div>raw</div>").blocks
        #expect(blocks.count == 3)
        guard case .thematicBreak = blocks[1] else { Issue.record("expected a break"); return }
        guard case let .html(html, _) = blocks[2] else { Issue.record("expected HTML"); return }
        #expect(html == "<div>raw</div>")
    }

    @Test("empty input is an empty document")
    func emptyInput() {
        #expect(MarkdownParser().parse("").blocks.isEmpty)
        #expect(MarkdownParser().parse("  \n\n").blocks.isEmpty)
    }

    @Test("documents compare by value")
    func equatable() {
        #expect(MarkdownDocument(parsing: "# A\n\nb") == MarkdownDocument(parsing: "# A\n\nb"))
        #expect(MarkdownDocument(parsing: "# A") != MarkdownDocument(parsing: "## A"))
    }
}

extension MarkdownBlock {
    var codeBlock: MarkdownCodeBlock? {
        if case let .code(code, _) = self { return code }
        return nil
    }
}
