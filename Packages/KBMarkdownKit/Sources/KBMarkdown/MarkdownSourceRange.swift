import Foundation

/// Where a block or inline came from in the Markdown source, in UTF-16 code units.
///
/// UTF-16 because that is the unit of `NSString`, `NSRange` and every text view, which is
/// what an editor maps a range back onto. `String.Index(utf16Offset:in:)` turns one into a
/// `String` index when that is wanted instead; `range(in:)` does it for both bounds.
public struct MarkdownSourceRange: Sendable, Hashable {
    /// The UTF-16 offsets into the source string, lower bound inclusive.
    public var utf16: Range<Int>

    /// A range over these UTF-16 offsets.
    public init(utf16: Range<Int>) {
        self.utf16 = utf16
    }

    /// The same range as an `NSRange`, for `NSString` and text storage APIs.
    public var nsRange: NSRange {
        NSRange(location: utf16.lowerBound, length: utf16.count)
    }

    /// The same range as `String` indices into `source`, or nil when it does not fit.
    public func range(in source: String) -> Range<String.Index>? {
        guard utf16.upperBound <= source.utf16.count else { return nil }
        let lower = String.Index(utf16Offset: utf16.lowerBound, in: source)
        let upper = String.Index(utf16Offset: utf16.upperBound, in: source)
        return lower..<upper
    }
}

extension MarkdownSourceRange: CustomStringConvertible {
    public var description: String { "\(utf16.lowerBound)..<\(utf16.upperBound)" }
}
