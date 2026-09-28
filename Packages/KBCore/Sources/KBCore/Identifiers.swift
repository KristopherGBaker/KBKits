import Foundation

/// Stable identity for an imported document. Derived from the document's content
/// hash at import so re-importing the same file resolves to the same id.
public struct DocumentID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Stable identity for one synthesizable segment (a sentence), derived from its
/// position in the document's flattened reading order. Stable across launches
/// for the same document text (§3.2).
public struct SegmentID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let documentID: DocumentID
    public let sentenceIndex: Int
    public init(documentID: DocumentID, sentenceIndex: Int) {
        self.documentID = documentID
        self.sentenceIndex = sentenceIndex
    }
    public var description: String { "\(documentID.rawValue)#\(sentenceIndex)" }
}

/// Identity for a chapter within a document.
public struct ChapterID: Hashable, Sendable, Codable {
    public let documentID: DocumentID
    public let index: Int
    public init(documentID: DocumentID, index: Int) {
        self.documentID = documentID
        self.index = index
    }
}

/// Identity for a paragraph within a document.
public struct ParagraphID: Hashable, Sendable, Codable {
    public let documentID: DocumentID
    public let index: Int
    public init(documentID: DocumentID, index: Int) {
        self.documentID = documentID
        self.index = index
    }
}

/// Half-open UTF-16 offset range into a piece of text. The persistable form of a
/// span — UTF-16 offsets are stable across launches, unlike `String.Index`
/// (§3.2). Used for word spans within a segment and for a segment's location in
/// the document's source text.
public struct UTF16Range: Hashable, Sendable, Codable {
    public let lower: Int
    public let upper: Int
    public init(lower: Int, upper: Int) {
        self.lower = lower
        self.upper = upper
    }
    public var length: Int { upper - lower }
    public var isEmpty: Bool { upper <= lower }
}

/// A span within a segment's own text, identifying a word for highlighting.
public typealias WordOffsets = UTF16Range

/// A span within the document's source text, for navigation/bookmarks.
public typealias DocRange = UTF16Range
