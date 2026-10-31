import Foundation
import KBMarkdown
import SwiftUI
import Testing
@testable import KBMarkdownUI

/// The editor's styling pass on a fixture string, straight onto text storage: no window,
/// no text view.
@Suite("Editor styling pass")
struct EditorStylingTests {
    static let fixture = """
    # Title *it*

    Body **bold** `code` [link](https://e.x) [A1].

    - item

    > quote

    ```swift
    let x = 1
    ```
    """

    static let style = MarkdownEditorStyle(
        fontSize: 13,
        textColor: Color(red: 0, green: 0, blue: 0),
        markerColor: Color(red: 0.5, green: 0.5, blue: 0.5),
        linkColor: Color(red: 0, green: 0, blue: 1),
        accentColor: Color(red: 0, green: 0.6, blue: 0))

    private func styled() throws -> NSTextStorage {
        let storage = NSTextStorage(string: Self.fixture)
        let highlighter = MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()]))
        Self.style.apply(highlighter.highlights(in: Self.fixture), to: storage)
        return storage
    }

    /// The UTF-16 offset of the first `needle` in the fixture.
    private func offset(of needle: String, after start: String? = nil) -> Int {
        let source = Self.fixture as NSString
        let from = start.map { source.range(of: $0).location } ?? 0
        let found = source.range(of: needle, range: NSRange(location: from, length: source.length - from))
        precondition(found.location != NSNotFound, "fixture lacks \(needle)")
        return found.location
    }

    private func font(_ storage: NSTextStorage, at index: Int) -> PlatformFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont
    }

    private func color(
        _ storage: NSTextStorage, _ key: NSAttributedString.Key = .foregroundColor, at index: Int
    ) -> PlatformColor? {
        storage.attribute(key, at: index, effectiveRange: nil) as? PlatformColor
    }

    @Test("styling never changes a character")
    func roundTrips() throws {
        #expect(try styled().string == Self.fixture)
    }

    @Test("a heading line is heading-sized and bold; its hash is dimmed; emphasis inside composes")
    func heading() throws {
        let storage = try styled()
        let title = try #require(font(storage, at: offset(of: "Title")))
        #expect(title.pointSize == Self.style.headingSize(level: 1))
        #expect(title.isBold)
        #expect(sameColor(color(storage, at: 0), Self.style.markerColor))
        let italic = try #require(font(storage, at: offset(of: "it*")))
        #expect(italic.isItalic && italic.isBold)
        #expect(italic.pointSize == Self.style.headingSize(level: 1))
    }

    @Test("strong content is bold at body size; its markers are dimmed")
    func strong() throws {
        let storage = try styled()
        let bold = try #require(font(storage, at: offset(of: "bold")))
        #expect(bold.isBold)
        #expect(bold.pointSize == 13)
        #expect(sameColor(color(storage, at: offset(of: "**bold")), Self.style.markerColor))
        #expect(sameColor(color(storage, at: offset(of: "bold")), Self.style.textColor))
        let body = try #require(font(storage, at: offset(of: "Body")))
        #expect(!body.isBold && !body.isItalic)
    }

    @Test("inline and fenced code are monospaced over a background")
    func code() throws {
        let storage = try styled()
        #expect(isMonospaced(try #require(font(storage, at: offset(of: "code`")))))
        #expect(color(storage, .backgroundColor, at: offset(of: "code`")) != nil)
        #expect(isMonospaced(try #require(font(storage, at: offset(of: "let x")))))
        #expect(!isMonospaced(try #require(font(storage, at: offset(of: "Body")))))
        #expect(sameColor(color(storage, at: offset(of: "swift")), Self.style.accentColor))
    }

    @Test("link text is link-coloured and underlined; its destination is dimmed")
    func link() throws {
        let storage = try styled()
        let index = offset(of: "link]")
        #expect(sameColor(color(storage, at: index), Self.style.linkColor))
        let underline = storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue)
        #expect(sameColor(color(storage, at: offset(of: "https://e.x")), Self.style.markerColor))
    }

    @Test("list markers, quote markers and tokens take the accent; tokens are backed")
    func markersAndTokens() throws {
        let storage = try styled()
        #expect(sameColor(color(storage, at: offset(of: "- item")), Self.style.accentColor))
        #expect(sameColor(color(storage, at: offset(of: "> quote")), Self.style.accentColor))
        let token = offset(of: "[A1]")
        var range = NSRange()
        let background = storage.attribute(.backgroundColor, at: token, effectiveRange: &range)
        #expect(background != nil)
        #expect(range == NSRange(location: token, length: 4))
        #expect(sameColor(color(storage, at: token), Self.style.accentColor))
    }

    @Test("a pass resets what the previous pass styled")
    func resetsStaleStyles() throws {
        let storage = try styled()
        Self.style.apply([], to: storage)
        let title = try #require(font(storage, at: offset(of: "Title")))
        #expect(title.pointSize == 13 && !title.isBold)
        #expect(storage.attribute(.backgroundColor, at: offset(of: "[A1]"), effectiveRange: nil) == nil)
        #expect(storage.string == Self.fixture)
    }

    @Test("highlights past the end of a shorter string are clamped, not a crash")
    func clampsRanges() {
        let storage = NSTextStorage(string: "ab")
        let beyond = MarkdownHighlight(role: .strong, source: MarkdownSourceRange(utf16: 1..<99))
        Self.style.apply([beyond], to: storage)
        #expect((storage.attribute(.font, at: 1, effectiveRange: nil) as? PlatformFont)?.isBold == true)
    }
}

/// Whether `color` is `expected` in sRGB, within rounding.
func sameColor(_ color: PlatformColor?, _ expected: Color?) -> Bool {
    guard let color, let expected else { return false }
    #if canImport(UIKit)
    func rgb(_ item: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        item.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue]
    }
    return zip(rgb(color), rgb(UIColor(expected))).allSatisfy { abs($0 - $1) < 0.01 }
    #else
    guard let lhs = color.usingColorSpace(.sRGB), let rhs = NSColor(expected).usingColorSpace(.sRGB) else {
        return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.01
        && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
        && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
    #endif
}

func isMonospaced(_ font: PlatformFont) -> Bool {
    #if canImport(UIKit)
    font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    #else
    font.isFixedPitch
    #endif
}
