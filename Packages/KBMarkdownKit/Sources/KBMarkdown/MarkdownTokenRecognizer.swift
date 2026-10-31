import Foundation

/// The caller's name for a kind of token, such as `"citation"`.
///
/// Extend it with static members for the kinds an app recognizes:
/// `extension MarkdownTokenKind { static let citation: Self = "citation" }`.
public struct MarkdownTokenKind: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// One regular-expression match handed to a recognizer's mapper.
public struct MarkdownTokenMatch: Sendable, Equatable {
    /// The whole matched text.
    public var text: String
    /// The capture groups, `captures[0]` being the whole match; nil for a group that did
    /// not participate.
    public var captures: [String?]

    /// A match of `text` with these captures.
    public init(text: String, captures: [String?]) {
        self.text = text
        self.captures = captures
    }
}

/// A caller-registered pattern that turns matches inside TEXT into `.token` inlines.
///
/// Recognizers run over text nodes only: never inside inline code, code blocks, raw HTML,
/// or link and image content (so never inside a URL, autolinked or not). Where two
/// recognizers' matches overlap, the one starting first wins, and on a tie the one
/// registered first.
public struct MarkdownTokenRecognizer: Sendable {
    /// The kind every token this recognizer produces carries.
    public let kind: MarkdownTokenKind
    /// The regular expression, in Swift `Regex` syntax.
    public let pattern: String
    let value: @Sendable (MarkdownTokenMatch) -> String?

    /// A recognizer of `kind` for `pattern`. `value` maps a match to the token's value, or
    /// returns nil to leave that match as plain text; by default it is the matched text.
    /// Throws when `pattern` is not a valid regular expression.
    public init(
        kind: MarkdownTokenKind,
        pattern: String,
        value: @escaping @Sendable (MarkdownTokenMatch) -> String? = { $0.text }
    ) throws {
        // Compiled here only to reject a bad pattern at registration. `Regex` is not
        // Sendable, so the parser compiles its own copy per parse.
        _ = try Regex(pattern)
        self.kind = kind
        self.pattern = pattern
        self.value = value
    }
}

/// A recognizer with its pattern compiled, for the length of one parse.
struct CompiledTokenRecognizer {
    let kind: MarkdownTokenKind
    let regex: Regex<AnyRegexOutput>
    let value: @Sendable (MarkdownTokenMatch) -> String?

    init?(_ recognizer: MarkdownTokenRecognizer) {
        guard let regex = try? Regex(recognizer.pattern) else { return nil }
        self.kind = recognizer.kind
        self.regex = regex
        self.value = recognizer.value
    }
}

/// A token found in a text node, in UTF-16 offsets into that node's string.
struct TokenHit {
    let lower: Int
    let upper: Int
    let kind: MarkdownTokenKind
    let value: String
}

extension [CompiledTokenRecognizer] {
    /// Every non-overlapping token in `text`, in order.
    func hits(in text: String) -> [TokenHit] {
        var found: [(hit: TokenHit, order: Int)] = []
        for (order, recognizer) in enumerated() {
            for match in text.matches(of: recognizer.regex) where !match.range.isEmpty {
                let captures = match.output.map { $0.substring.map(String.init) }
                let tokenMatch = MarkdownTokenMatch(text: String(text[match.range]), captures: captures)
                guard let value = recognizer.value(tokenMatch) else { continue }
                let lower = text.utf16.distance(from: text.startIndex, to: match.range.lowerBound)
                let upper = text.utf16.distance(from: text.startIndex, to: match.range.upperBound)
                found.append((TokenHit(lower: lower, upper: upper, kind: recognizer.kind, value: value), order))
            }
        }
        found.sort { ($0.hit.lower, $0.order) < ($1.hit.lower, $1.order) }
        var hits: [TokenHit] = []
        for candidate in found where candidate.hit.lower >= (hits.last?.upper ?? 0) {
            hits.append(candidate.hit)
        }
        return hits
    }
}
