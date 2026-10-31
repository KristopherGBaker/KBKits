import Foundation
import KBMarkdown
import SwiftUI
import Testing
@testable import KBMarkdownUI

/// What the renderer builds before SwiftUI draws it: the attributed text of a paragraph.
@MainActor
@Suite("Renderer model")
struct RendererModelTests {
    private func context(
        tappable: Bool, presentation: @escaping (MarkdownToken) -> MarkdownTokenPresentation? = { _ in nil }
    ) -> RenderContext {
        RenderContext(
            style: MarkdownStyle(), codeBlock: { _, _ in nil }, tokenPresentation: presentation,
            tokensTappable: tappable)
    }

    private func paragraph(_ source: String) throws -> [MarkdownInline] {
        let blocks = MarkdownParser(recognizers: [try citationRecognizer()]).parse(source).blocks
        guard case let .paragraph(content, _) = blocks.first else { return [] }
        return content
    }

    /// The run of `string` holding `needle`.
    private func run(_ string: AttributedString, containing needle: String) -> AttributedString.Runs.Run? {
        string.runs.first { String(string[$0.range].characters).contains(needle) }
    }

    @Test("emphasis, strong, code and strikethrough map to presentation intents; links carry their URL")
    func inlineAttributes() throws {
        let built = InlineTextBuilder(context: context(tappable: false))
            .attributedString(try paragraph("a *em* **st** `cd` ~~sk~~ [ln](https://e.x/p)"))
        #expect(String(built.characters) == "a em st cd sk ln")
        #expect(run(built, containing: "em")?.inlinePresentationIntent == .emphasized)
        #expect(run(built, containing: "st")?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(run(built, containing: "cd")?.inlinePresentationIntent == .code)
        #expect(run(built, containing: "sk")?.inlinePresentationIntent == .strikethrough)
        #expect(run(built, containing: "ln")?.link == URL(string: "https://e.x/p"))
    }

    @Test("an image renders as a link of its alt text")
    func imageAsLink() throws {
        let builder = InlineTextBuilder(context: context(tappable: false))
        let built = builder.attributedString(try paragraph("![a chart](c.png)"))
        #expect(String(built.characters) == "a chart")
        #expect(run(built, containing: "chart")?.link == URL(string: "c.png"))
    }

    @Test("a token shows its value and links back to itself only when tappable")
    func tokenLinks() throws {
        let inlines = try paragraph("see [A1] here")
        let tappable = InlineTextBuilder(context: context(tappable: true)).attributedString(inlines)
        #expect(String(tappable.characters) == "see A1 here")
        let url = try #require(run(tappable, containing: "A1")?.link)
        let token = try #require(TokenLink.token(from: url))
        #expect(token == MarkdownToken(kind: "citation", value: "A1", source: MarkdownSourceRange(utf16: 4..<8)))

        let inert = InlineTextBuilder(context: context(tappable: false)).attributedString(inlines)
        #expect(run(inert, containing: "A1")?.link == nil)
    }

    @Test("a caller's presentation replaces the token's text")
    func callerPresentation() throws {
        let custom = context(tappable: false) { token in
            MarkdownTokenPresentation(
                text: AttributedString("source \(token.value)"), accessibilityLabel: "Source \(token.value)")
        }
        let built = InlineTextBuilder(context: custom).attributedString(try paragraph("x [B2]"))
        #expect(String(built.characters) == "x source B2")
        #expect(InlineTextBuilder(context: custom).text(try paragraph("x [B2]")).hasCapsules)
        let plain = context(tappable: false) { token in
            MarkdownTokenPresentation(
                text: AttributedString(token.value), accessibilityLabel: token.value, showsCapsule: false)
        }
        #expect(!InlineTextBuilder(context: plain).text(try paragraph("x [B2]")).hasCapsules)
    }

    @Test("token links survive values that need escaping")
    func tokenLinkRoundTrip() throws {
        let token = MarkdownToken(kind: "note & more", value: "a/b?c=d 日本", source: MarkdownSourceRange(utf16: 3..<9))
        let url = try #require(TokenLink.url(for: token))
        #expect(TokenLink.token(from: url) == token)
        #expect(TokenLink.token(from: URL(string: "https://example.com")!) == nil)
    }

    @Test("heading fonts clamp to the scale the caller gave")
    func headingFonts() {
        let style = MarkdownStyle(headingFonts: [.title, .body])
        #expect(style.headingFont(level: 1) == .title)
        #expect(style.headingFont(level: 6) == .body)
        #expect(MarkdownStyle(headingFonts: []).headingFont(level: 2) == MarkdownStyle().bodyFont)
    }
}
