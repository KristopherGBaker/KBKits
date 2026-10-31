#if canImport(UIKit)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformTextView = UITextView

extension UIFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.traitBold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.traitItalic) }

    /// This font with bold and italic added (never removed). Unchanged where the face has
    /// no such variant, as the monospaced system font has no italic.
    func adding(bold: Bool = false, italic: Bool = false) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    static func systemFont(size: CGFloat) -> UIFont { .systemFont(ofSize: size) }
    static func monospaced(size: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

extension UIColor {
    static var markdownText: UIColor { .label }
    static var markdownSecondary: UIColor { .secondaryLabel }
    static var markdownLink: UIColor { .link }
    static var markdownAccent: UIColor { .tintColor }
}

#elseif canImport(AppKit)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformTextView = NSTextView

extension NSFont {
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }

    /// This font with bold and italic added (never removed). Unchanged where the face has
    /// no such variant.
    func adding(bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }

    static func systemFont(size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
    static func monospaced(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

extension NSColor {
    static var markdownText: NSColor { .labelColor }
    static var markdownSecondary: NSColor { .secondaryLabelColor }
    static var markdownLink: NSColor { .linkColor }
    static var markdownAccent: NSColor { .controlAccentColor }
}
#endif
