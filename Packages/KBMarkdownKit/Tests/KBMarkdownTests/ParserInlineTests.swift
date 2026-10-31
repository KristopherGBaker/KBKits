import KBMarkdown
import Testing

@Suite("Parser: inlines")
struct ParserInlineTests {
    private func inlines(_ source: String) throws -> [MarkdownInline] {
        content(try onlyBlock(source))
    }

    @Test("emphasis, strong and strikethrough wrap their content")
    func emphasisStrongStrike() throws {
        let parsed = try inlines("*em* **strong** ~~gone~~ ***both***")
        guard case let .emphasis(em, _) = parsed[0] else { Issue.record("expected emphasis"); return }
        #expect(MarkdownInline.plainText(of: em) == "em")
        guard case .strong = parsed[2] else { Issue.record("expected strong"); return }
        guard case .strikethrough = parsed[4] else { Issue.record("expected strikethrough"); return }
        guard case let .emphasis(inner, _) = parsed[6], case .strong = inner.first else {
            Issue.record("expected strong inside emphasis")
            return
        }
    }

    @Test("inline code keeps its text verbatim")
    func inlineCode() throws {
        let parsed = try inlines("run `make *all*` now")
        guard case let .code(code, _) = parsed[1] else { Issue.record("expected code"); return }
        #expect(code == "make *all*")
    }

    @Test("links keep their destination; autolinks are links too")
    func links() throws {
        let parsed = try inlines("[docs](https://example.com/a \"t\") and <https://x.dev> and https://y.dev")
        let destinations = parsed.compactMap { inline -> String? in
            if case let .link(destination, _, _) = inline { return destination }
            return nil
        }
        #expect(destinations == ["https://example.com/a", "https://x.dev", "https://y.dev"])
        guard case let .link(_, text, _) = parsed[0] else { Issue.record("expected a link"); return }
        #expect(MarkdownInline.plainText(of: text) == "docs")
    }

    @Test("a bare URL is a link minus trailing punctuation and an unbalanced parenthesis")
    func bareURLs() throws {
        let source = "See https://a.dev/x. Or (https://b.dev/y) or https://c.dev/p_(q) or http:// alone."
        let parsed = try inlines(source)
        let links = parsed.compactMap { inline -> (String?, String)? in
            if case let .link(destination, _, range) = inline { return (destination, slice(source, range)) }
            return nil
        }
        #expect(links.map(\.0) == ["https://a.dev/x", "https://b.dev/y", "https://c.dev/p_(q)"])
        #expect(links.map(\.1) == ["https://a.dev/x", "https://b.dev/y", "https://c.dev/p_(q)"])
        #expect(MarkdownInline.plainText(of: parsed) == source)
    }

    @Test("an image is a link-like inline with a destination and alt content")
    func images() throws {
        let parsed = try inlines("![a *chart*](chart.png)")
        guard case let .image(destination, alt, _) = parsed[0] else { Issue.record("expected an image"); return }
        #expect(destination == "chart.png")
        #expect(MarkdownInline.plainText(of: alt) == "a chart")
    }

    @Test("soft and hard line breaks are distinct")
    func lineBreaks() throws {
        let parsed = try inlines("one\ntwo  \nthree\\\nfour")
        let kinds = parsed.map { inline -> String in
            switch inline {
            case .softBreak: "soft"
            case .lineBreak: "hard"
            default: "other"
            }
        }
        #expect(kinds == ["other", "soft", "other", "hard", "other", "hard", "other"])
        #expect(MarkdownInline.plainText(of: parsed) == "one two\nthree\nfour")
    }

    @Test("escapes and entities resolve in text")
    func escapes() throws {
        #expect(MarkdownInline.plainText(of: try inlines(#"\*not em\* &amp; &copy;"#)) == "*not em* & ©")
    }

    @Test("inline HTML is kept as literal text")
    func inlineHTML() throws {
        let parsed = try inlines("a <kbd>K</kbd> b")
        #expect(parsed.contains { if case .html("<kbd>", _) = $0 { true } else { false } })
    }
}
