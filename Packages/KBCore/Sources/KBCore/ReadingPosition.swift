public import Foundation

/// A persisted reading position. Stored as **segment index + optional within-
/// segment UTF-16 word offset + the document text hash** — never a
/// `String.Index` (§3.2). On load, the hash is checked against the live document
/// so a changed/reimported file degrades gracefully (resume to the segment if
/// still valid, else to the start) instead of jumping to a wrong spot.
public struct ReadingPosition: Sendable, Hashable, Codable {
    public let documentID: DocumentID
    public let sentenceIndex: Int
    /// UTF-16 offset of the active word within the segment, if any.
    public let wordOffsetUTF16: Int?
    /// Document text hash captured when the position was saved.
    public let textHash: String
    public let updatedAt: Date

    public init(
        documentID: DocumentID,
        sentenceIndex: Int,
        wordOffsetUTF16: Int?,
        textHash: String,
        updatedAt: Date
    ) {
        self.documentID = documentID
        self.sentenceIndex = sentenceIndex
        self.wordOffsetUTF16 = wordOffsetUTF16
        self.textHash = textHash
        self.updatedAt = updatedAt
    }

    /// Resolve this position against a freshly loaded document. Returns a valid
    /// segment index to resume at: the saved index when the hash matches and the
    /// index is in range, otherwise 0 (start over).
    public func resolvedSegmentIndex(in document: Document) -> Int {
        guard textHash == document.textHash,
              document.segments.indices.contains(sentenceIndex)
        else { return 0 }
        return sentenceIndex
    }
}
