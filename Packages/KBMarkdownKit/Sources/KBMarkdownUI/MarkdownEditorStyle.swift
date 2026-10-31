import Foundation
import KBMarkdown
import SwiftUI

/// How the source editor styles Markdown as it is typed. Every colour left nil follows the
/// platform's semantic colour (label, secondary label, link, accent), so light and dark
/// appearance work without the caller choosing anything.
public struct MarkdownEditorStyle: Sendable, Equatable {
    /// The body text size, in points.
    public var fontSize: CGFloat
    /// Heading sizes as multiples of `fontSize`, levels 1 through 6.
    public var headingScales: [CGFloat]
    /// Ordinary text. Nil: the platform label colour.
    public var textColor: Color?
    /// Syntax markers (`#`, `*`, fences, link destinations). Nil: the secondary label colour.
    public var markerColor: Color?
    /// Link text. Nil: the platform link colour.
    public var linkColor: Color?
    /// List and quote markers, a fence's language, and tokens. Nil: the accent colour.
    public var accentColor: Color?
    /// How strongly a token's background is tinted with the accent, 0 through 1.
    public var tokenBackgroundOpacity: Double
    /// How strongly inline and block code is backed with the secondary colour, 0 through 1.
    public var codeBackgroundOpacity: Double

    /// The platform's body size at the default text size: 17 points on iOS, 13 on macOS.
    public static let defaultFontSize: CGFloat = {
        #if canImport(UIKit)
        17
        #else
        13
        #endif
    }()

    /// A style; every argument has a system default.
    public init(
        fontSize: CGFloat = MarkdownEditorStyle.defaultFontSize,
        headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1.05, 1],
        textColor: Color? = nil,
        markerColor: Color? = nil,
        linkColor: Color? = nil,
        accentColor: Color? = nil,
        tokenBackgroundOpacity: Double = 0.16,
        codeBackgroundOpacity: Double = 0.1
    ) {
        self.fontSize = fontSize
        self.headingScales = headingScales
        self.textColor = textColor
        self.markerColor = markerColor
        self.linkColor = linkColor
        self.accentColor = accentColor
        self.tokenBackgroundOpacity = tokenBackgroundOpacity
        self.codeBackgroundOpacity = codeBackgroundOpacity
    }

    /// The size of a level-`level` heading.
    public func headingSize(level: Int) -> CGFloat {
        guard !headingScales.isEmpty else { return fontSize }
        return fontSize * headingScales[min(max(level, 1), headingScales.count) - 1]
    }
}

// MARK: - Applying

extension MarkdownEditorStyle {
    /// Styles `text` (the Markdown source) with `highlights`, attributes only: the characters
    /// are never touched, so the string round-trips exactly. Every pass first resets the
    /// whole range to the base font and colour, so a stale style from the previous pass
    /// (a heading that is no longer one) cannot survive.
    public func apply(_ highlights: [MarkdownHighlight], to text: NSMutableAttributedString) {
        let resolved = ResolvedEditorStyle(self)
        let length = text.length
        text.beginEditing()
        defer { text.endEditing() }
        text.setAttributes(resolved.baseAttributes, range: NSRange(location: 0, length: length))
        for highlight in highlights {
            let lower = min(highlight.source.utf16.lowerBound, length)
            let upper = min(highlight.source.utf16.upperBound, length)
            guard upper > lower else { continue }
            resolved.apply(highlight.role, to: text, range: NSRange(location: lower, length: upper - lower))
        }
    }

    /// The attributes of unstyled text, which a text view types with.
    func baseAttributes() -> [NSAttributedString.Key: Any] {
        ResolvedEditorStyle(self).baseAttributes
    }
}

/// The style with its colours resolved to platform colours, for one pass.
private struct ResolvedEditorStyle {
    let style: MarkdownEditorStyle
    let baseFont: PlatformFont
    let text: PlatformColor
    let marker: PlatformColor
    let link: PlatformColor
    let accent: PlatformColor

    init(_ style: MarkdownEditorStyle) {
        self.style = style
        baseFont = PlatformFont.systemFont(size: style.fontSize)
        text = style.textColor.map(PlatformColor.init) ?? .markdownText
        marker = style.markerColor.map(PlatformColor.init) ?? .markdownSecondary
        link = style.linkColor.map(PlatformColor.init) ?? .markdownLink
        accent = style.accentColor.map(PlatformColor.init) ?? .markdownAccent
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: text]
    }

    func apply(_ role: MarkdownHighlight.Role, to string: NSMutableAttributedString, range: NSRange) {
        switch role {
        case let .heading(level):
            let size = style.headingSize(level: level)
            transformFonts(in: string, range: range) { font in
                PlatformFont.systemFont(size: size).adding(bold: true, italic: font.isItalic)
            }
        case .emphasis:
            transformFonts(in: string, range: range) { $0.adding(italic: true) }
        case .strong:
            transformFonts(in: string, range: range) { $0.adding(bold: true) }
        case .strikethrough:
            string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode, .codeBlock:
            transformFonts(in: string, range: range) { font in
                PlatformFont.monospaced(size: font.pointSize).adding(bold: font.isBold)
            }
            string.addAttribute(.backgroundColor, value: codeBackground, range: range)
        case .html:
            transformFonts(in: string, range: range) { PlatformFont.monospaced(size: $0.pointSize) }
            string.addAttribute(.foregroundColor, value: marker, range: range)
        case .link:
            string.addAttribute(.foregroundColor, value: link, range: range)
            string.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .marker, .linkDestination:
            string.addAttribute(.foregroundColor, value: marker, range: range)
        case .listMarker, .quoteMarker, .codeLanguage:
            string.addAttribute(.foregroundColor, value: accent, range: range)
            transformFonts(in: string, range: range) { $0.adding(bold: true) }
        case .token:
            string.addAttribute(.foregroundColor, value: accent, range: range)
            string.addAttribute(.backgroundColor, value: tokenBackground, range: range)
        }
    }

    private var codeBackground: PlatformColor { marker.withAlphaComponent(style.codeBackgroundOpacity) }
    private var tokenBackground: PlatformColor { accent.withAlphaComponent(style.tokenBackgroundOpacity) }

    /// Replaces each font run in `range` with `transform` of it, so nested styles compose:
    /// italic inside a heading keeps the heading's size.
    private func transformFonts(
        in string: NSMutableAttributedString, range: NSRange, _ transform: (PlatformFont) -> PlatformFont
    ) {
        string.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? PlatformFont ?? baseFont
            string.addAttribute(.font, value: transform(font), range: subrange)
        }
    }
}
