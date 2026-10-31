import Foundation
import KBMarkdown
import SwiftUI

/// What the renderer needs from its caller while building text.
struct RenderContext {
    let style: MarkdownStyle
    let codeBlock: (_ language: String?, _ code: String) -> AnyView?
    let tokenPresentation: (MarkdownToken) -> MarkdownTokenPresentation?
    /// Whether tokens carry a tap link (there is a tap callback to receive it).
    let tokensTappable: Bool

    func presentation(for token: MarkdownToken) -> MarkdownTokenPresentation {
        tokenPresentation(token) ?? .standard(for: token)
    }
}

/// A token's tap target: a link in a private scheme that the view's `openURL` handler
/// decodes back into the token.
enum TokenLink {
    static let scheme = "x-kbmarkdown-token"

    static func url(for token: MarkdownToken) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "token"
        components.queryItems = [
            URLQueryItem(name: "kind", value: token.kind.rawValue),
            URLQueryItem(name: "value", value: token.value),
            URLQueryItem(name: "lower", value: String(token.source.utf16.lowerBound)),
            URLQueryItem(name: "upper", value: String(token.source.utf16.upperBound))
        ]
        return components.url
    }

    static func token(from url: URL) -> MarkdownToken? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let item = { (name: String) in items.first { $0.name == name }?.value }
        guard let kind = item("kind"), let value = item("value"),
              let lower = item("lower").flatMap(Int.init), let upper = item("upper").flatMap(Int.init),
              lower <= upper else { return nil }
        return MarkdownToken(
            kind: MarkdownTokenKind(rawValue: kind), value: value,
            source: MarkdownSourceRange(utf16: lower..<upper))
    }
}

/// Marks a token run so `TokenCapsuleRenderer` draws a capsule behind it.
struct TokenCapsuleAttribute: TextAttribute {
    var tint: Color
}

/// Draws each run carrying `TokenCapsuleAttribute` over a tinted capsule, then the text.
struct TokenCapsuleRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let capsule = run[TokenCapsuleAttribute.self] {
                    let bounds = run.typographicBounds.rect.insetBy(dx: -1, dy: -1)
                    context.fill(Capsule().path(in: bounds), with: .color(capsule.tint.opacity(0.18)))
                }
                context.draw(run)
            }
        }
    }
}

/// Builds the `Text` for a run of inlines: one attributed string, or (when it holds tokens)
/// attributed pieces joined around each token's own `Text`.
struct InlineTextBuilder {
    let context: RenderContext

    /// The inlines as one attributed string; a token is its presentation's text, linked for
    /// tapping when the context has a tap callback.
    func attributedString(_ inlines: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines { append(inline, intent: [], link: nil, to: &result) }
        return result
    }

    /// The inlines as `Text`, and whether any token in it wants a capsule.
    func text(_ inlines: [MarkdownInline]) -> (text: Text, hasCapsules: Bool) {
        guard inlines.contains(where: { !$0.tokens.isEmpty }) else {
            return (Text(attributedString(inlines)), false)
        }
        var pieces: [Text] = []
        var pending = AttributedString()
        var hasCapsules = false
        func visit(_ inline: MarkdownInline, intent: InlinePresentationIntent) {
            switch inline {
            case let .token(kind, value, source):
                if !pending.characters.isEmpty { pieces.append(Text(pending)) }
                pending = AttributedString()
                let token = MarkdownToken(kind: kind, value: value, source: source)
                let presentation = context.presentation(for: token)
                hasCapsules = hasCapsules || presentation.showsCapsule
                pieces.append(tokenText(token, presentation))
            case let .emphasis(children, _):
                children.forEach { visit($0, intent: intent.union(.emphasized)) }
            case let .strong(children, _):
                children.forEach { visit($0, intent: intent.union(.stronglyEmphasized)) }
            case let .strikethrough(children, _):
                children.forEach { visit($0, intent: intent.union(.strikethrough)) }
            default:
                append(inline, intent: intent, link: nil, to: &pending)
            }
        }
        inlines.forEach { visit($0, intent: []) }
        if !pending.characters.isEmpty { pieces.append(Text(pending)) }
        let joined = pieces.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
        return (joined, hasCapsules)
    }

    private func tokenText(_ token: MarkdownToken, _ presentation: MarkdownTokenPresentation) -> Text {
        var content = presentation.text
        if presentation.showsCapsule {
            // Thin spaces inside the capsule, so it does not hug the glyphs.
            content = AttributedString("\u{2009}") + content + AttributedString("\u{2009}")
            content.foregroundColor = content.foregroundColor ?? context.style.tokenTint
        }
        if context.tokensTappable, let url = TokenLink.url(for: token) { content.link = url }
        var text = Text(content).accessibilityLabel(presentation.accessibilityLabel)
        if presentation.showsCapsule {
            text = text.customAttribute(TokenCapsuleAttribute(tint: context.style.tokenTint))
        }
        return text
    }

    private func append(
        _ inline: MarkdownInline, intent: InlinePresentationIntent, link: URL?, to result: inout AttributedString
    ) {
        func piece(_ string: String, _ intent: InlinePresentationIntent, background: Color? = nil) {
            var piece = AttributedString(string)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let background { piece.backgroundColor = background }
            if let link { piece.link = link }
            result += piece
        }
        switch inline {
        case let .text(string, _), let .html(string, _):
            piece(string, intent)
        case let .code(code, _):
            piece(code, intent.union(.code), background: context.style.codeBackground)
        case let .emphasis(children, _):
            children.forEach { append($0, intent: intent.union(.emphasized), link: link, to: &result) }
        case let .strong(children, _):
            children.forEach { append($0, intent: intent.union(.stronglyEmphasized), link: link, to: &result) }
        case let .strikethrough(children, _):
            children.forEach { append($0, intent: intent.union(.strikethrough), link: link, to: &result) }
        case let .link(destination, children, _):
            let url = destination.flatMap(URL.init(string:)) ?? link
            children.forEach { append($0, intent: intent, link: url, to: &result) }
        case let .image(destination, alt, _):
            // Images render as links: the alt text (or the destination) pointing at the source.
            let url = destination.flatMap(URL.init(string:)) ?? link
            let label = MarkdownInline.plainText(of: alt)
            var image = AttributedString(label.isEmpty ? (destination ?? "") : label)
            if !intent.isEmpty { image.inlinePresentationIntent = intent }
            if let url { image.link = url }
            result += image
        case .softBreak:
            piece(" ", intent)
        case .lineBreak:
            piece("\n", intent)
        case let .token(kind, value, source):
            let token = MarkdownToken(kind: kind, value: value, source: source)
            var content = context.presentation(for: token).text
            if context.tokensTappable, let url = TokenLink.url(for: token) { content.link = url }
            result += content
        }
    }
}
