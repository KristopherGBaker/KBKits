import Foundation

/// Inline text styling retained from formatted sources (EPUB now; PDF later).
/// An `OptionSet` so a span can be e.g. bold *and* italic. Display-only — it never
/// affects what's synthesized (§3.2: the spoken text is separate, see
/// `TextSegment.displayText` vs `.text`).
public struct TextTraits: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = TextTraits(rawValue: 1 << 0)
    public static let italic = TextTraits(rawValue: 1 << 1)
    public static let code = TextTraits(rawValue: 1 << 2)
    public static let strikethrough = TextTraits(rawValue: 1 << 3)
    public static let link = TextTraits(rawValue: 1 << 4)
    // Reserved for later phases: heading, blockquote, listItem, superscript…

    // Encode as the raw bitmask (compact, stable in the JSON payload).
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Block-level role of a segment's paragraph, retained from structured sources
/// (EPUB). Display-only; the text is still spoken normally. Headings carry their
/// level (1…6) for sizing.
public enum BlockStyle: Sendable, Hashable, Codable {
    case body
    case heading(level: Int)
    case blockquote
    case listItem
    /// A verbatim code block (M5): the segment's `displayText` is the literal code
    /// (newlines/indentation preserved, never sentence-segmented), and its spoken
    /// `text` is a short announce marker. The reader renders it as a monospaced,
    /// un-tokenized code panel; the display/spoken split is the announce+skip seam.
    case codeBlock
    /// A verbatim GFM table (M6): the segment's `displayText` is the rendered
    /// aligned-text table (newlines preserved, never sentence-segmented), and its
    /// spoken `text` is a short announce marker. The reader renders it as a
    /// monospaced, un-tokenized panel; same announce+skip seam as `.codeBlock`.
    case table
}

/// A run of styled characters within a segment's **display** text, as a half-open
/// UTF-16 offset span (matching the offset convention used everywhere else, §3.2).
public struct StyleRun: Sendable, Hashable, Codable {
    public let lower: Int        // UTF-16 offset into displayText
    public let upper: Int        // exclusive
    public let traits: TextTraits
    public let url: String?      // destination for a `.link` run; nil otherwise

    public init(lower: Int, upper: Int, traits: TextTraits, url: String? = nil) {
        self.lower = lower
        self.upper = upper
        self.traits = traits
        self.url = url
    }

    /// Traits covering the display span `[wordLower, wordUpper)` — the union of
    /// every run that overlaps it. Lets the reader style per word.
    public static func traits(in runs: [StyleRun], lower wordLower: Int, upper wordUpper: Int) -> TextTraits {
        var traits: TextTraits = []
        for run in runs where run.lower < wordUpper && wordLower < run.upper {
            traits.formUnion(run.traits)
        }
        return traits
    }

    /// The URL of the first `.link` run overlapping the display span
    /// `[wordLower, wordUpper)` (nil if none). A non-`.link` run is ignored even if
    /// it carries a url — the parallel of `traits(in:lower:upper:)` for link taps.
    public static func url(in runs: [StyleRun], lower wordLower: Int, upper wordUpper: Int) -> String? {
        for run in runs
        where run.traits.contains(.link) && run.lower < wordUpper && wordLower < run.upper {
            if let url = run.url { return url }
        }
        return nil
    }
}
