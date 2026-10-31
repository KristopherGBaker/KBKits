import Foundation

/// One piece of inline content inside a heading, paragraph or table cell.
public indirect enum MarkdownInline: Sendable, Equatable {
    /// Literal text, escapes and entities already resolved (`\*` is `*`, `&amp;` is `&`).
    case text(String, source: MarkdownSourceRange)
    /// `*emphasis*` or `_emphasis_`.
    case emphasis([MarkdownInline], source: MarkdownSourceRange)
    /// `**strong**` or `__strong__`.
    case strong([MarkdownInline], source: MarkdownSourceRange)
    /// `~~strikethrough~~` (GFM).
    case strikethrough([MarkdownInline], source: MarkdownSourceRange)
    /// `` `inline code` ``, its text verbatim. Never searched for tokens.
    case code(String, source: MarkdownSourceRange)
    /// A link: inline (`[text](url)`), reference, autolink (`<https://...>`) or a bare
    /// `http(s)://` URL in text (a GFM extended autolink). Its content is never searched for
    /// tokens, so a token pattern cannot match inside a URL shown as link text.
    case link(destination: String?, content: [MarkdownInline], source: MarkdownSourceRange)
    /// An image (`![alt](src)`). Modelled like a link: a destination and its alt content.
    /// Nothing here loads it; the renderer shows it as a link.
    case image(destination: String?, alt: [MarkdownInline], source: MarkdownSourceRange)
    /// A soft line break inside a paragraph; reads as a space.
    case softBreak(source: MarkdownSourceRange)
    /// A hard line break (two trailing spaces or a backslash).
    case lineBreak(source: MarkdownSourceRange)
    /// Raw inline HTML, kept as its literal text.
    case html(String, source: MarkdownSourceRange)
    /// A match of a caller-registered `MarkdownTokenRecognizer` inside text.
    case token(kind: MarkdownTokenKind, value: String, source: MarkdownSourceRange)

    /// Where this inline came from.
    public var source: MarkdownSourceRange {
        switch self {
        case let .text(_, source), let .emphasis(_, source), let .strong(_, source),
             let .strikethrough(_, source), let .code(_, source), let .link(_, _, source),
             let .image(_, _, source), let .softBreak(source), let .lineBreak(source),
             let .html(_, source), let .token(_, _, source):
            source
        }
    }

    /// The text a reader sees, without Markdown syntax. A token reads as its value, a soft
    /// break as a space, a hard break as a newline.
    public var plainText: String {
        switch self {
        case let .text(text, _), let .code(text, _), let .html(text, _), let .token(_, text, _):
            text
        case let .emphasis(children, _), let .strong(children, _), let .strikethrough(children, _),
             let .link(_, children, _), let .image(_, children, _):
            Self.plainText(of: children)
        case .softBreak:
            " "
        case .lineBreak:
            "\n"
        }
    }

    /// The tokens in this inline and any it contains, in source order.
    public var tokens: [MarkdownToken] {
        switch self {
        case let .token(kind, value, source):
            [MarkdownToken(kind: kind, value: value, source: source)]
        case let .emphasis(children, _), let .strong(children, _), let .strikethrough(children, _),
             let .link(_, children, _), let .image(_, children, _):
            children.flatMap(\.tokens)
        case .text, .code, .softBreak, .lineBreak, .html:
            []
        }
    }

    /// The text a reader sees across `inlines`.
    public static func plainText(of inlines: [MarkdownInline]) -> String {
        inlines.map(\.plainText).joined()
    }
}

/// A token inline as one value, which is what a renderer hands to a caller's closures.
public struct MarkdownToken: Sendable, Hashable {
    /// Which recognizer produced it.
    public var kind: MarkdownTokenKind
    /// What the recognizer's mapper made of the match.
    public var value: String
    /// Where the match is in the source.
    public var source: MarkdownSourceRange

    /// A token of `kind` with `value`, found at `source`.
    public init(kind: MarkdownTokenKind, value: String, source: MarkdownSourceRange) {
        self.kind = kind
        self.value = value
        self.source = source
    }
}
