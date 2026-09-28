import Foundation

/// A single occurrence of a search query inside a document: which sentence it's in,
/// and the UTF-16 span within that sentence's `displayText`. The reader tokenizes
/// `displayText` into `KaraokeWord`s, so this span maps straight onto their UTF-16
/// offsets — the reader turns each match into the set of words to tint.
public struct DocumentMatch: Sendable, Hashable {
    public let segmentIndex: Int
    public let range: UTF16Range
    public init(segmentIndex: Int, range: UTF16Range) {
        self.segmentIndex = segmentIndex
        self.range = range
    }
}

/// In-book "find in page": scans a loaded `Document` for every occurrence of a
/// query, in reading order. Pure and synchronous — the open document is already in
/// memory, so a debounce plus this call is enough and no persisted index is needed
/// (cross-book search uses `SearchStore`'s index instead).
public enum DocumentTextSearch {
    /// Every occurrence of `query` across the document's segments, in reading order.
    /// Case/diacritic/width-insensitive (`TextSearchNormalizer.matchOptions`).
    /// Searches `displayText` so the returned spans align with the reader's word
    /// offsets. Empty/whitespace queries yield no matches.
    public static func matches(in document: Document, query: String) -> [DocumentMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [DocumentMatch] = []
        for segment in document.segments {
            appendMatches(of: trimmed, in: segment.displayText,
                          segmentIndex: segment.sentenceIndex, into: &result)
        }
        return result
    }

    /// Collect every non-overlapping occurrence of `query` in `text`, converting each
    /// `Range<String.Index>` into a UTF-16 offset span (what the reader indexes by).
    private static func appendMatches(
        of query: String, in text: String, segmentIndex: Int, into result: inout [DocumentMatch]
    ) {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: TextSearchNormalizer.matchOptions,
                                     range: searchStart..<text.endIndex) {
            let lower = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
            let upper = text.utf16.distance(from: text.startIndex, to: found.upperBound)
            result.append(DocumentMatch(segmentIndex: segmentIndex,
                                        range: UTF16Range(lower: lower, upper: upper)))
            // Advance past this match; step one character on a zero-width match so a
            // width-insensitive fold that compares equal to "" can't spin forever.
            searchStart = found.upperBound > found.lowerBound
                ? found.upperBound
                : text.index(after: found.lowerBound)
        }
    }
}
