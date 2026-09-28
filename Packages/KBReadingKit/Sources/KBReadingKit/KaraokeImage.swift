public import KBCore
public import Foundation

/// An image retained from the source document, rendered inline in the reading
/// surface between paragraphs. Carries no spoken text — it sits in the flow as a
/// non-interactive block, so the karaoke highlight/follow-scroll skip over it.
public struct KaraokeImage: Identifiable, Sendable, Hashable {
    public let id: String
    public let data: Data
    public let altText: String?
    /// height / width of the source image, captured at import (orientation-corrected) and threaded
    /// from `DocumentImage`. Lets the iOS cell reader size an unrealized image cell *exactly* — the
    /// fix for image-book resume. `nil` for pre-metadata documents or formats ImageIO can't read
    /// (e.g. SVG); the reader then uses a viewport-fraction placeholder.
    public let aspectRatio: Double?
    public init(id: String, data: Data, altText: String?, aspectRatio: Double? = nil) {
        self.id = id
        self.data = data
        self.altText = altText
        self.aspectRatio = aspectRatio
    }
}

/// A verbatim code block (M5) in the reading surface: the literal `code` (newlines +
/// indentation preserved) rendered monospaced in a code panel, and crucially NOT
/// tokenized into `KaraokeWord`s — there's no per-word karaoke for code. `id` is the
/// code segment's index (the scroll anchor, parallel to a paragraph's first-segment id).
/// `styleRuns` is reserved for a future syntax-highlight pass (colored runs); M5 keeps it
/// empty and never renders it.
public struct KaraokeCodeBlock: Identifiable, Sendable, Hashable {
    public let id: Int
    public let code: String
    public let styleRuns: [StyleRun]
    public init(id: Int, code: String, styleRuns: [StyleRun] = []) {
        self.id = id
        self.code = code
        self.styleRuns = styleRuns
    }
}

/// A verbatim GFM table (M6) in the reading surface: the rendered aligned-text `text`
/// (newlines preserved) rendered monospaced in a panel, and crucially NOT tokenized into
/// `KaraokeWord`s — there's no per-word karaoke for a table. `id` is the table segment's
/// index (the scroll anchor, parallel to a paragraph's first-segment id).
public struct KaraokeTable: Identifiable, Sendable, Hashable {
    public let id: Int
    public let text: String
    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// One block in the reading surface, in source order: a paragraph of words, an image, a
/// verbatim code block, or a verbatim table. Lets the reader interleave non-prose blocks
/// between paragraphs without disturbing the per-paragraph scroll anchors (rows keep their
/// integer segment id).
public enum KaraokeBlock: Identifiable, Sendable {
    case paragraph(KaraokeParagraph)
    case image(KaraokeImage)
    case codeBlock(KaraokeCodeBlock)
    case table(KaraokeTable)

    public var id: String {
        switch self {
        case let .paragraph(paragraph): return "p\(paragraph.id)"
        case let .image(image): return "img:\(image.id)"
        case let .codeBlock(code): return "code:\(code.id)"
        case let .table(table): return "table:\(table.id)"
        }
    }

    /// How many words this block carries, which is what distinguishes a WINDOWED build from a
    /// full one: `ReaderContent.build` always emits every paragraph, and only varies whether the
    /// paragraph has words. Any view-level change detection that ignores this cannot tell the two
    /// apart, keeps the windowed content, and leaves the page blank past the window forever.
    public var wordCount: Int {
        switch self {
        case let .paragraph(paragraph): return paragraph.words.count
        case .image, .codeBlock, .table: return 0
        }
    }

    /// Fold this block's RENDERED content into `hasher` - the word ids and the ruby readings, not
    /// just the count.
    ///
    /// The count alone distinguishes a windowed build from a full one, but not a build where a
    /// word's ruby CHANGED and nothing else did, which is exactly what a reader's chosen reading
    /// produces: same blocks, same ids, same word count, different reading. A change detector
    /// blind to that leaves the corrected ruby off the screen.
    public func hashRenderedContent(into hasher: inout Hasher) {
        hasher.combine(id)
        guard case let .paragraph(paragraph) = self else {
            hasher.combine(0)
            return
        }
        hasher.combine(paragraph.words.count)
        for word in paragraph.words {
            hasher.combine(word.id)
            for segment in word.ruby {
                hasher.combine(segment.text)
                hasher.combine(segment.reading)
            }
        }
    }
}
