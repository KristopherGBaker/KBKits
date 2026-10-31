import KBMarkdown
import SwiftUI

/// How `MarkdownView` lays out and types a document. Every default comes from the system
/// (Dynamic Type text styles, semantic colours), so an unthemed view looks native.
public struct MarkdownStyle: Sendable {
    /// Paragraphs, list items, quotes and table cells.
    public var bodyFont: Font
    /// Heading fonts, levels 1 through 6; a deeper level uses the last.
    public var headingFonts: [Font]
    /// Code blocks and inline code.
    public var codeFont: Font
    /// Space between blocks.
    public var blockSpacing: CGFloat
    /// Space between list items.
    public var listItemSpacing: CGFloat
    /// The width a list marker column takes.
    public var listMarkerWidth: CGFloat
    /// A block quote's rule.
    public var quoteRuleColor: Color
    /// The panel behind a code block.
    public var codeBackground: Color
    /// The default token capsule's tint.
    public var tokenTint: Color

    /// A style; every argument has a system default.
    public init(
        bodyFont: Font = .body,
        headingFonts: [Font] = [
            .largeTitle.bold(), .title.bold(), .title2.bold(), .title3.bold(), .headline, .subheadline.bold()
        ],
        codeFont: Font = .system(.callout, design: .monospaced),
        blockSpacing: CGFloat = 12,
        listItemSpacing: CGFloat = 4,
        listMarkerWidth: CGFloat = 22,
        quoteRuleColor: Color = .secondary.opacity(0.5),
        codeBackground: Color = .secondary.opacity(0.12),
        tokenTint: Color = .accentColor
    ) {
        self.bodyFont = bodyFont
        self.headingFonts = headingFonts
        self.codeFont = codeFont
        self.blockSpacing = blockSpacing
        self.listItemSpacing = listItemSpacing
        self.listMarkerWidth = listMarkerWidth
        self.quoteRuleColor = quoteRuleColor
        self.codeBackground = codeBackground
        self.tokenTint = tokenTint
    }

    /// The font of a level-`level` heading.
    public func headingFont(level: Int) -> Font {
        guard !headingFonts.isEmpty else { return bodyFont }
        return headingFonts[min(max(level, 1), headingFonts.count) - 1]
    }
}

/// How one token shows inside a paragraph.
///
/// A token renders inside its paragraph's `Text`, which is what keeps it in the text's line
/// breaking and selection; a `Text` cannot host arbitrary views, so the caller supplies the
/// token's content as attributed text (any font, colour or SwiftUI text attribute) and
/// chooses whether the default capsule is drawn behind it.
public struct MarkdownTokenPresentation {
    /// What the token shows.
    public var text: AttributedString
    /// What VoiceOver reads for it.
    public var accessibilityLabel: String
    /// Draw the capsule behind it, tinted with `MarkdownStyle.tokenTint`.
    public var showsCapsule: Bool

    /// A presentation of `text`, read as `accessibilityLabel`.
    public init(text: AttributedString, accessibilityLabel: String, showsCapsule: Bool = true) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel
        self.showsCapsule = showsCapsule
    }

    /// The default: the token's value in a capsule, read as its value.
    public static func standard(for token: MarkdownToken) -> MarkdownTokenPresentation {
        MarkdownTokenPresentation(text: AttributedString(token.value), accessibilityLabel: token.value)
    }
}
