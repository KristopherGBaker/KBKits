import KBMarkdown
import Testing

@Suite("Token recognizers")
struct TokenRecognizerTests {
    private func parser() throws -> MarkdownParser {
        MarkdownParser(recognizers: [try citationRecognizer()])
    }

    private func allTokens(_ source: String) throws -> [MarkdownToken] {
        try parser().parse(source).blocks.flatMap(Self.tokens)
    }

    /// Tokens anywhere in a block, nested blocks and table cells included.
    private static func tokens(in block: MarkdownBlock) -> [MarkdownToken] {
        switch block {
        case let .paragraph(content, _), let .heading(_, content, _):
            content.flatMap(\.tokens)
        case let .blockQuote(blocks, _):
            blocks.flatMap(tokens)
        case let .list(list, _):
            list.items.flatMap { $0.blocks.flatMap(tokens) }
        case let .table(table, _):
            ([table.header] + table.rows).flatMap { $0.cells.flatMap { $0.content.flatMap(\.tokens) } }
        case .code, .thematicBreak, .html:
            []
        }
    }

    @Test("a match in text becomes a token with the mapper's value")
    func matchInText() throws {
        let parsed = content(try onlyBlock("Revenue rose [A1] last year.", parser: try parser()))
        #expect(parsed.count == 3)
        guard case let .token(kind, value, _) = parsed[1] else { Issue.record("expected a token"); return }
        #expect(kind == .citation)
        #expect(value == "A1")
        #expect(MarkdownInline.plainText(of: parsed) == "Revenue rose A1 last year.")
    }

    @Test("adjacent tokens stay separate tokens")
    func adjacentTokens() throws {
        let found = try allTokens("See [A1][B2][C3].")
        #expect(found.map(\.value) == ["A1", "B2", "C3"])
    }

    @Test("an inline code span is never searched")
    func skipsCodeSpan() throws {
        #expect(try allTokens("`[A1]` and ``x [B2] y``").isEmpty)
        #expect(try allTokens("`[A1]` but [B2]").map(\.value) == ["B2"])
    }

    @Test("a fenced or indented code block is never searched")
    func skipsCodeBlocks() throws {
        #expect(try allTokens("```\n[A1]\n```\n\n    [B2]").isEmpty)
    }

    @Test("link destinations, link text and autolinked URLs are never searched")
    func skipsLinks() throws {
        #expect(try allTokens("[see](https://e.x/[A1]) <https://e.x/[B2]> https://e.x/[C3] [t [D4]](u)").isEmpty)
        #expect(try allTokens("![[A1]](i.png)").isEmpty)
    }

    @Test("tokens are found inside emphasis, quotes, nested lists, headings and table cells")
    func tokensEverywhereTextIs() throws {
        let source = "# Title [A1]\n\n> *quoted [B2]*\n\n- a\n  - b [C3]\n\n| h |\n|---|\n| **[D4]** |"
        #expect(try allTokens(source).map(\.value) == ["A1", "B2", "C3", "D4"])
    }

    @Test("a mapper returning nil leaves the match as text")
    func mapperDeclines() throws {
        let onlyA = try MarkdownTokenRecognizer(kind: "citation", pattern: #"\[([A-Z][0-9]+)\]"#) {
            $0.captures[1]?.hasPrefix("A") == true ? $0.captures[1] : nil
        }
        let parsed = MarkdownParser(recognizers: [onlyA]).parse("[A1] [B2]")
        #expect(parsed.blocks.flatMap(Self.tokens).map(\.value) == ["A1"])
        #expect(MarkdownInline.plainText(of: content(parsed.blocks[0])) == "A1 [B2]")
    }

    @Test("overlapping recognizers: the earlier match wins, then the earlier registration")
    func overlapPriority() throws {
        let mention = try MarkdownTokenRecognizer(kind: "mention", pattern: #"@\w+"#)
        let wide = try MarkdownTokenRecognizer(kind: "wide", pattern: #"\[A1\] @bo"#)
        let found = MarkdownParser(recognizers: [try citationRecognizer(), wide, mention])
            .parse("x [A1] @bo @cy").blocks.flatMap(Self.tokens)
        #expect(found.map(\.kind.rawValue) == ["citation", "mention", "mention"])
        let wideFirst = MarkdownParser(recognizers: [wide, try citationRecognizer(), mention])
            .parse("x [A1] @bo @cy").blocks.flatMap(Self.tokens)
        #expect(wideFirst.map(\.kind.rawValue) == ["wide", "mention"])
    }

    @Test("the default value is the matched text")
    func defaultValue() throws {
        let hashtag = try MarkdownTokenRecognizer(kind: "tag", pattern: #"#[a-z]+"#)
        let found = MarkdownParser(recognizers: [hashtag]).parse("a #swift b").blocks.flatMap(Self.tokens)
        #expect(found.map(\.value) == ["#swift"])
    }

    @Test("an invalid pattern throws at registration")
    func invalidPattern() {
        #expect(throws: (any Error).self) { try MarkdownTokenRecognizer(kind: "bad", pattern: "([unclosed") }
    }

    @Test("without recognizers the same text is plain")
    func noRecognizers() throws {
        let parsed = content(try onlyBlock("See [A1]."))
        #expect(parsed.count == 1)
        #expect(parsed.flatMap(\.tokens).isEmpty)
    }
}
