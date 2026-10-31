import KBMarkdown
import Testing

@Suite("Streaming document")
struct StreamingDocumentTests {
    /// One fixture per block kind, each streamed a character at a time.
    static let blockFixtures: [String] = [
        "# One\n\n## Two ##\n\nA paragraph\nover two lines.\n\n###### Six\nright after",
        "Title\n===\n\npara\nSub\n---\n\nnot a heading\n\n---\n\nend",
        "- [ ] todo\n- [x] done\n  - nested\n    1. deep\n    2. deeper\n- plain\n\nafter\n\n* other\n+ marker",
        "- a\n\n- b\n\n  continued\n\n\n- c\n\nafter\n\n1. x\n2. y\n\n3) z",
        "intro\n\n| a | b |\n|:--|--:|\n| 1 | 2 |\n| **3** | `4` |\nlazy row\n\nafter\n\n| h |\n|---|\n| r |\n|\n\nend",
        "```swift\nlet x = 1\n\n\nlet y = 2\n```\n\ntext\n\n~~~\n```\nnot closed\n\n\nstill code",
        "> quote\nlazy line\n> more\n\n> > nested\n> back\n\nafter\n> again\n\n>\n> - item\ncontinued",
        "para\n\n---\n\n***\ntext\n___\n\n- - -\n\n_ _ _ x",
        "# 見出し 😀\n\n日本語の段落 🇯🇵 です。\n\n- 項目 👍🏽\n- 二\n\n> 引用 👨‍👩‍👧\n\n| 列 | 😀 |\n|---|---|\n| あ | い |\n\n終わり",
        "    indented\n\n    code\n\npara\n\n<div>\nhtml\n</div>\n\n<!-- c\n\n-->\nafter",
        "# CRLF\r\n\r\npara\r\n\r\n- a\r\n- b\r\n\r\nend [A1]",
        // Every inline kind: emphasis, strong, strikethrough, code, links, autolinks, images, and soft and hard breaks.
        "*em* _em_ **strong** __strong__ ~~struck~~ `code` ``a ` b``\n\n[link](https://e.x \"T\") and ![alt](i.png)\n\n"
            + "<https://auto.example/path> and <mail@example.com> and https://bare.example\n\n"
            + "soft\nbreak\n\nhard  \nbreak and\\\nbackslash break\n\n~~**mixed *nest***~~ end"
    ]

    /// Fixtures where text stays open, or the whole text is parsed, longer than the block
    /// structure alone needs: link reference definitions (they reach across blocks), a
    /// paragraph a table splits off (swift-markdown gives it no position), and a multi-line
    /// task item (swift-markdown puts its later inlines past their line).
    static let conservativeFixtures: [String] = [
        "See [foo] and [bar][].\n\n# H\n\n[foo]: https://e.x \"T\"\n\nmore [foo]\n\n> [bar]: /b\n\nend [bar] [baz]\n\n[baz]:\n/z",
        "intro\n\nafter\n| h |\n|---|\n| r |\n\n- a\n  b\n  | x |\n  |---|\n\nend",
        "- [ ] task\n  wraps here\n- [x] done\nlazy\n\n# Next\n\ntext"
    ]

    @Test(
        "every prefix of every fixture parses exactly as a whole parse does",
        arguments: blockFixtures + conservativeFixtures
    )
    func everyPrefix(source: String) throws {
        let parser = MarkdownParser(recognizers: [try citationRecognizer()])
        var streaming = MarkdownStreamingDocument(parser: parser)
        for count in 0...source.count {
            let prefix = String(source.prefix(count))
            let document = streaming.update(prefix)
            #expect(document == parser.parse(prefix), "prefix \(count): \(prefix.debugDescription)")
        }
    }

    @Test("a finished block is not parsed again once the next block starts", arguments: blockFixtures)
    func finishedBlocksStayParsed(source: String) {
        let parser = MarkdownParser()
        var streaming = MarkdownStreamingDocument(parser: parser)
        var finishedEnd = 0
        for count in 1...source.count {
            let prefix = String(source.prefix(count))
            let blocks = streaming.update(prefix).blocks
            let parsed = streaming.parsedRanges.last?.utf16.lowerBound ?? 0
            #expect(parsed >= finishedEnd, "prefix \(count) re-parsed from \(parsed), a block ended at \(finishedEnd)")
            // A block is finished once the next one starts on a line that has ended.
            let lastLine = blocks.last.map { Array(prefix.utf16)[$0.source.utf16.lowerBound...] } ?? []
            if blocks.count >= 2, lastLine.contains(where: { $0 == 10 || $0 == 13 }) {
                finishedEnd = blocks[blocks.count - 2].source.utf16.upperBound
            }
        }
        #expect(streaming.parsedRanges.count == source.count)
    }

    @Test("only the open block is parsed once the next block's first line ends")
    func onlyTrailingParsed() {
        var streaming = MarkdownStreamingDocument()
        _ = streaming.update("# One\n\npara two\n")
        _ = streaming.update("# One\n\npara two\n\n- a\n")
        _ = streaming.update("# One\n\npara two\n\n- a\n- b")
        #expect(streaming.parsedRanges.map(\.utf16) == [0..<16, 7..<21, 17..<24])
    }

    @Test("a closed fence holding blank lines finishes only when the next block's line ends")
    func fenceFinishes() {
        var streaming = MarkdownStreamingDocument()
        let fence = "```\na\n\n\nb\n```"
        _ = streaming.update(fence)
        _ = streaming.update(fence + "\n\nnext\n")
        _ = streaming.update(fence + "\n\nnext\nline")
        #expect(streaming.parsedRanges.map(\.utf16.lowerBound) == [0, 0, 15])
    }

    @Test("a paragraph a table split off is parsed whole until the table finishes, then kept")
    func splitParagraphKept() {
        let parser = MarkdownParser()
        var streaming = MarkdownStreamingDocument(parser: parser)
        let head = "intro\n\nafter\n| h |\n|---|\n\n# Next\n\n"
        _ = streaming.update("intro\n\n")
        _ = streaming.update("intro\n\nafter\n| h |\n|---|\n")
        #expect(streaming.parsedRanges.last?.utf16.lowerBound == 0)
        _ = streaming.update(head + "more\n")
        let source = head + "more\nx"
        #expect(streaming.update(source) == parser.parse(source))
        #expect(streaming.parsedRanges.last?.utf16.lowerBound == head.utf16.count)
    }

    @Test("a source that does not extend the last one resets and parses whole")
    func nonExtensionResets() {
        let parser = MarkdownParser()
        var streaming = MarkdownStreamingDocument(parser: parser)
        _ = streaming.update("# A\n\npara\n\nmore\n")
        _ = streaming.update("# A\n\npara\n\nmore\ntext")
        #expect(streaming.parsedRanges.last?.utf16.lowerBound == 11)

        let replaced = "# B\n\nother"
        #expect(streaming.update(replaced) == parser.parse(replaced))
        #expect(streaming.parsedRanges.last?.utf16 == 0..<replaced.utf16.count)

        let shorter = "# B"
        #expect(streaming.update(shorter) == parser.parse(shorter))
        #expect(streaming.parsedRanges.last?.utf16 == 0..<3)
    }

    @Test("the same source again returns the same document without parsing")
    func sameSource() {
        var streaming = MarkdownStreamingDocument()
        let first = streaming.update("# A\n\nb")
        #expect(streaming.update("# A\n\nb") == first)
        #expect(streaming.parsedRanges.count == 1)
    }

    @Test("a definition after a finished block turns its reference into a link")
    func laterDefinition() {
        let parser = MarkdownParser()
        var streaming = MarkdownStreamingDocument(parser: parser)
        let source = "[foo]\n\npara\n\n[foo]: /u\n\n[foo] again"
        _ = streaming.update("[foo]\n\npara\n\n")
        let document = streaming.update(source)
        #expect(document == parser.parse(source))
        guard case let .paragraph(content, _) = document.blocks[0], case .link? = content.first else {
            Issue.record("expected the first paragraph to be a link: \(document.blocks)")
            return
        }
    }
}
