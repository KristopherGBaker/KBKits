import Foundation

/// A contiguous reader selection spanning one or more words/sentences — the unit the
/// study loop turns into cards (PRD §Requirements A1). Produced by the passage-selection
/// surface (issue 004) and consumed by card generation (issue 005). UTF-16 offsets are the
/// persistable span (stable across launches, unlike `String.Index`); the segment range
/// records which sentences the selection covers.
public struct Passage: Sendable, Hashable, Codable {
    /// The document this selection came from, if any (`nil` for ad-hoc text).
    public let documentID: DocumentID?
    /// The selected text itself — already normalized for reading/speaking.
    public let text: String
    /// The selection's span in the document's source text (UTF-16 offsets).
    public let sourceRange: DocRange?
    /// The inclusive sentence-index range the selection covers.
    public let segmentRange: ClosedRange<Int>?
    /// A human-readable language name for prompts (e.g. "Japanese"); `nil` if unknown.
    public let language: String?
    /// Optional surrounding text supplied to the model for reference only.
    public let context: String?

    public init(
        documentID: DocumentID? = nil,
        text: String,
        sourceRange: DocRange? = nil,
        segmentRange: ClosedRange<Int>? = nil,
        language: String? = nil,
        context: String? = nil
    ) {
        self.documentID = documentID
        self.text = text
        self.sourceRange = sourceRange
        self.segmentRange = segmentRange
        self.language = language
        self.context = context
    }
}

public extension Passage {
    /// Build a passage covering an inclusive range of a document's segments (the unit the
    /// selection surface produces — PRD A1). The text is the segments' spoken text joined by
    /// spaces; the source range spans from the first segment's lower bound to the last's
    /// upper bound. Out-of-range indices are clamped; an empty document yields `nil`.
    static func from(
        document: Document,
        segmentRange range: ClosedRange<Int>,
        language: String? = nil,
        context: String? = nil
    ) -> Passage? {
        let segments = document.segments
        guard !segments.isEmpty else { return nil }
        let lower = max(0, min(range.lowerBound, segments.count - 1))
        let upper = max(lower, min(range.upperBound, segments.count - 1))
        let slice = segments[lower...upper]
        let text = slice.map(\.text).joined(separator: " ")
        let sourceRange = DocRange(lower: slice.first!.sourceRange.lower,
                                   upper: slice.last!.sourceRange.upper)
        return Passage(
            documentID: document.id,
            text: text,
            sourceRange: sourceRange,
            segmentRange: lower...upper,
            language: language,
            context: context)
    }

    /// Build a passage for the single sentence at `segmentIndex` (sentence-granular capture).
    static func sentence(
        in document: Document,
        at segmentIndex: Int,
        language: String? = nil
    ) -> Passage? {
        from(document: document, segmentRange: segmentIndex...segmentIndex, language: language)
    }
}
