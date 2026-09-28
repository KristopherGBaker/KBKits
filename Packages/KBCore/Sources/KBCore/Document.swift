public import Foundation

/// One synthesizable unit of text. We synthesize at **sentence granularity**
/// (bounds timing error, gives natural seek/skip points, matches Kokoro's
/// whole-utterance generation — §3.2, CLAUDE.md gotchas).
public struct TextSegment: Identifiable, Sendable, Hashable, Codable {
    public let id: SegmentID
    public let documentID: DocumentID
    /// Position within the document's flattened reading order.
    public let sentenceIndex: Int
    /// The **spoken** text — TTS-normalized, exactly what's synthesized and what
    /// timeline word offsets index into (§3.2). The display/spoken split lives here:
    /// this is the spoken side, `displayText` is what the reader shows.
    public let text: String
    /// The **display** text shown in the reader. Defaults to `text`; diverges when
    /// a source carries formatting or when spoken-only transforms apply. `styleRuns`
    /// index into this.
    public let displayText: String
    /// Inline styling spans (bold/italic/…) as UTF-16 offsets into `displayText`.
    public let styleRuns: [StyleRun]
    /// Author-supplied furigana spans (Aozora `《》` now; EPUB `<ruby>` later) as UTF-16
    /// offsets into `displayText`. The reader shows these readings over their kanji in
    /// preference to the OpenJTalk-generated ones. Additive and optional so old persisted
    /// documents decode unchanged (`decodeIfPresent ?? []`, the `styleRuns` pattern).
    public let rubyRuns: [RubyRun]
    /// Block-level role of this segment's paragraph (heading / blockquote / list).
    public let blockStyle: BlockStyle
    /// Rich list metadata (depth / ordered / ordinal / task) for a markdown `.listItem`
    /// segment (M7a). `nil` for a non-list segment, and for flat list items that don't
    /// populate it (EPUB/txt/PDF) — a `nil` here keeps pre-M7a flat-list behavior. Additive
    /// and optional so old persisted documents decode unchanged.
    public let listInfo: ListInfo?
    /// Where this segment's text sits in the document's source text, for nav.
    public let sourceRange: DocRange

    public init(
        id: SegmentID,
        documentID: DocumentID,
        sentenceIndex: Int,
        text: String,
        sourceRange: DocRange,
        displayText: String? = nil,
        styleRuns: [StyleRun] = [],
        blockStyle: BlockStyle = .body,
        listInfo: ListInfo? = nil,
        rubyRuns: [RubyRun] = []
    ) {
        self.id = id
        self.documentID = documentID
        self.sentenceIndex = sentenceIndex
        self.text = text
        self.displayText = displayText ?? text
        self.styleRuns = styleRuns
        self.rubyRuns = rubyRuns
        self.blockStyle = blockStyle
        self.listInfo = listInfo
        self.sourceRange = sourceRange
    }

    // Back-compat decode: documents saved before the display/spoken split lack
    // `displayText`/`styleRuns`/`blockStyle`, so default them; pre-M7a documents lack
    // `listInfo`, which decodes to `nil` (a flat list item).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SegmentID.self, forKey: .id)
        documentID = try container.decode(DocumentID.self, forKey: .documentID)
        sentenceIndex = try container.decode(Int.self, forKey: .sentenceIndex)
        text = try container.decode(String.self, forKey: .text)
        sourceRange = try container.decode(DocRange.self, forKey: .sourceRange)
        displayText = try container.decodeIfPresent(String.self, forKey: .displayText) ?? text
        styleRuns = try container.decodeIfPresent([StyleRun].self, forKey: .styleRuns) ?? []
        blockStyle = try container.decodeIfPresent(BlockStyle.self, forKey: .blockStyle) ?? .body
        listInfo = try container.decodeIfPresent(ListInfo.self, forKey: .listInfo)
        rubyRuns = try container.decodeIfPresent([RubyRun].self, forKey: .rubyRuns) ?? []
    }
}

/// A paragraph: a contiguous run of segments. Carries no text of its own —
/// it references segment indices into `Document.segments` so text is stored once
/// (and so paragraph breaks render correctly without re-splitting).
public struct Paragraph: Identifiable, Sendable, Hashable, Codable {
    public let id: ParagraphID
    /// Half-open range of indices into `Document.segments`.
    public let segmentRange: Range<Int>
    public init(id: ParagraphID, segmentRange: Range<Int>) {
        self.id = id
        self.segmentRange = segmentRange
    }
}

/// A chapter: a run of paragraphs. Plain-text import produces a single chapter;
/// EPUB/PDF (M4) produce many. (A `Section` layer is deferred to M4 when EPUB
/// spine structure needs it.)
public struct Chapter: Identifiable, Sendable, Hashable, Codable {
    public let id: ChapterID
    public let title: String?
    public let paragraphs: [Paragraph]
    public init(id: ChapterID, title: String?, paragraphs: [Paragraph]) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
    }
    /// Half-open range of segment indices spanned by this chapter.
    public var segmentRange: Range<Int> {
        guard let first = paragraphs.first, let last = paragraphs.last else { return 0..<0 }
        return first.segmentRange.lowerBound..<last.segmentRange.upperBound
    }
}

/// An image retained from the source document (EPUB), rendered inline in the
/// reader between sentences. It carries no spoken text — it's a non-playable
/// block anchored *before* a segment in reading order, so the highlight/timeline
/// (which index `segments` only) are unaffected.
public struct DocumentImage: Identifiable, Sendable, Hashable, Codable {
    /// Stable, content-relative id (the resolved archive path). Also the dedup key:
    /// an image referenced from several places is stored once, at its first anchor.
    public let id: String
    /// The raw image bytes (JPEG/PNG/GIF/…), as found in the source.
    public let data: Data
    /// MIME type derived from the source (e.g. `image/jpeg`); metadata only — the
    /// reader decodes via the platform image loader, which sniffs the bytes.
    public let mediaType: String
    /// Alt text from the source `<img alt>` / `<image>` title, if any.
    public let altText: String?
    /// The segment index this image renders *before* in reading order; equals
    /// `segmentCount` when the image trails all text.
    public let anchorSegmentIndex: Int
    /// Tie-breaker ordering among images sharing an anchor (their source order).
    public let order: Int
    /// Intrinsic, orientation-corrected pixel size captured at import via an ImageIO
    /// header read. Lets the reader size an unrealized image cell exactly (so resume
    /// math is correct) without decoding the bytes. `nil` for pre-metadata documents or
    /// undecodable formats (e.g. SVG) — `Optional` so old JSON blobs decode via
    /// `decodeIfPresent`, no GRDB migration needed. A re-import populates them.
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        id: String,
        data: Data,
        mediaType: String,
        altText: String? = nil,
        anchorSegmentIndex: Int,
        order: Int = 0,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.altText = altText
        self.anchorSegmentIndex = anchorSegmentIndex
        self.order = order
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// height / width from the captured pixel dims, or `nil` when they're absent
    /// (pre-metadata or undecodable) — the reader then uses a placeholder height.
    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelHeight) / Double(pixelWidth)
    }
}

/// Where a `Document` came from — an imported file or a note the user wrote in the
/// built-in editor (PRD C1). Drives whether the note editor is offered and whether the
/// document auto-joins the `notes` system collection (PRD D2). `.imported` carries the
/// source file kind so the library can hint provenance.
public enum DocumentSource: Sendable, Hashable, Codable {
    /// The kind of file an imported document came from.
    public enum FileKind: String, Sendable, Hashable, Codable {
        case txt, epub, pdf, md
    }
    case imported(FileKind)
    case userNote
    /// A web page shared into the app (issue 055): where it came from and when it was
    /// read. Both halves are provenance, and the date is the half that is easy to skip:
    /// a web page is not stable the way a book is, so the URL says what to re-open and
    /// the date says which version of it these words actually are.
    case web(url: URL, retrievedAt: Date)

    /// Whether this document is an editable user note.
    public var isUserNote: Bool { self == .userNote }

    /// The page address for a `.web` document; `nil` for every other source. Lets a
    /// caller offer "open the original" without matching on the case.
    public var webURL: URL? {
        if case let .web(url, _) = self { return url }
        return nil
    }
}

/// A fully imported document: the canonical flat reading order (`segments`) plus
/// a navigation hierarchy (`chapters`/`paragraphs`) that references it by index.
/// Every importer (txt → EPUB/PDF) normalizes to this one shape (§1, §2).
public struct Document: Identifiable, Sendable, Hashable, Codable {
    public let id: DocumentID
    public let title: String
    /// Hash of the full normalized reading text — validates persisted positions
    /// and cached timelines against the live document (§3.2).
    public let textHash: String
    /// Canonical flattened reading order. Playback iterates this.
    public let segments: [TextSegment]
    /// Navigation hierarchy; paragraphs/chapters reference `segments` by index.
    public let chapters: [Chapter]
    /// Retained source images, anchored between segments (EPUB only; empty otherwise).
    public let images: [DocumentImage]
    /// Provenance: imported file vs. user note (PRD C1). Documents saved before this
    /// existed decode as `.imported(.txt)` (the migration backfills the column too).
    public let source: DocumentSource

    public init(
        id: DocumentID,
        title: String,
        textHash: String,
        segments: [TextSegment],
        chapters: [Chapter],
        images: [DocumentImage] = [],
        source: DocumentSource = .imported(.txt)
    ) {
        self.id = id
        self.title = title
        self.textHash = textHash
        self.segments = segments
        self.chapters = chapters
        self.images = images
        self.source = source
    }

    // Back-compat decode: documents saved before image retention lack `images`;
    // documents saved before the source split lack `source` (default `.imported`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DocumentID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        textHash = try container.decode(String.self, forKey: .textHash)
        segments = try container.decode([TextSegment].self, forKey: .segments)
        chapters = try container.decode([Chapter].self, forKey: .chapters)
        images = try container.decodeIfPresent([DocumentImage].self, forKey: .images) ?? []
        source = try container.decodeIfPresent(DocumentSource.self, forKey: .source) ?? .imported(.txt)
    }

    /// A copy carrying a different `source`. Used to stamp `.userNote` onto a note built
    /// through the content-hashed builder without re-deriving the whole document.
    public func withSource(_ source: DocumentSource) -> Document {
        Document(id: id, title: title, textHash: textHash, segments: segments,
                 chapters: chapters, images: images, source: source)
    }

    public var segmentCount: Int { segments.count }

    public func segment(at index: Int) -> TextSegment? {
        segments.indices.contains(index) ? segments[index] : nil
    }

    /// Images anchored before `segmentIndex` (in stable source order), for the reader
    /// to interleave between paragraphs.
    public func images(anchoredBefore segmentIndex: Int) -> [DocumentImage] {
        images.filter { $0.anchorSegmentIndex == segmentIndex }.sorted { $0.order < $1.order }
    }
}
