import Testing
import KBCore

/// Spec for a segment in the boundary fixture: its block style and which paragraph
/// (by an arbitrary group key) it belongs to. Consecutive segments sharing a key
/// are one paragraph; chapters are passed as groups of keys.
private struct SegSpec {
    let block: BlockStyle
    init(_ block: BlockStyle = .body) { self.block = block }
}

/// Build a `Document` with explicit chapter → paragraph structure. `chapters` is a
/// list of chapters; each chapter is a list of paragraphs; each paragraph is a list
/// of segment specs (its sentences). Segment indices are assigned in reading order.
private func boundaryDoc(_ chapters: [[[SegSpec]]]) -> Document {
    let id = DocumentID("d")
    var segments: [TextSegment] = []
    var chapterModels: [Chapter] = []
    var segIndex = 0
    var paragraphOrdinal = 0
    for (cIdx, chapter) in chapters.enumerated() {
        var paragraphs: [Paragraph] = []
        for paragraph in chapter {
            let start = segIndex
            for spec in paragraph {
                segments.append(TextSegment(
                    id: SegmentID(documentID: id, sentenceIndex: segIndex),
                    documentID: id, sentenceIndex: segIndex, text: "s\(segIndex).",
                    sourceRange: DocRange(lower: 0, upper: 3), blockStyle: spec.block))
                segIndex += 1
            }
            paragraphs.append(Paragraph(
                id: ParagraphID(documentID: id, index: paragraphOrdinal),
                segmentRange: start..<segIndex))
            paragraphOrdinal += 1
        }
        chapterModels.append(Chapter(
            id: ChapterID(documentID: id, index: cIdx), title: nil, paragraphs: paragraphs))
    }
    return Document(id: id, title: "t", textHash: "h", segments: segments, chapters: chapterModels)
}

// MARK: - Boundary classification

@Test func firstSegmentHasNoBoundary() {
    let doc = boundaryDoc([[[SegSpec(), SegSpec()]]])
    #expect(doc.boundary(before: 0) == nil)
}

@Test func outOfRangeIndexHasNoBoundary() {
    let doc = boundaryDoc([[[SegSpec()]]])
    #expect(doc.boundary(before: 5) == nil)
}

@Test func sameParagraphIsSentenceBoundary() {
    // One chapter, one paragraph, two sentences.
    let doc = boundaryDoc([[[SegSpec(), SegSpec()]]])
    #expect(doc.boundary(before: 1) == .sentence)
}

@Test func newParagraphIsParagraphBoundary() {
    // One chapter, two paragraphs of one sentence each.
    let doc = boundaryDoc([[[SegSpec()], [SegSpec()]]])
    #expect(doc.boundary(before: 1) == .paragraph)
}

@Test func headingParagraphIsHeadingBoundary() {
    // Body paragraph, then a heading paragraph.
    let doc = boundaryDoc([[[SegSpec()], [SegSpec(.heading(level: 2))]]])
    #expect(doc.boundary(before: 1) == .heading)
}

@Test func newChapterIsChapterBoundary() {
    // Two chapters, one paragraph/sentence each.
    let doc = boundaryDoc([[[SegSpec()]], [[SegSpec()]]])
    #expect(doc.boundary(before: 1) == .chapter)
}

@Test func chapterBoundaryWinsOverHeading() {
    // New chapter that opens with a heading still classifies as a chapter break.
    let doc = boundaryDoc([[[SegSpec()]], [[SegSpec(.heading(level: 1))]]])
    #expect(doc.boundary(before: 1) == .chapter)
}

@Test func sentencesInsideAHeadingStayHeadingThenSentence() {
    // A heading paragraph with two sentences: the gap into the second is same-paragraph.
    let doc = boundaryDoc([[[SegSpec()], [SegSpec(.heading(level: 1)), SegSpec(.heading(level: 1))]]])
    #expect(doc.boundary(before: 1) == .heading)   // body → heading paragraph
    #expect(doc.boundary(before: 2) == .sentence)  // within the heading paragraph
}

// MARK: - Durations + pacing

@Test func sentenceBoundaryHasNoExtraPause() {
    #expect(SegmentBoundary.sentence.pauseDuration(pace: .normal) == 0)
}

@Test func normalPaceUsesBaseDurations() {
    #expect(SegmentBoundary.paragraph.pauseDuration(pace: .normal) == 0.35)
    #expect(SegmentBoundary.heading.pauseDuration(pace: .normal) == 0.6)
    #expect(SegmentBoundary.chapter.pauseDuration(pace: .normal) == 1.0)
}

@Test func offPaceDisablesAllPauses() {
    for boundary in SegmentBoundary.allCases {
        #expect(boundary.pauseDuration(pace: .off) == 0)
    }
}

@Test func paceMultipliersScaleDurations() {
    #expect(SegmentBoundary.chapter.pauseDuration(pace: .short) == 0.5)   // 1.0 * 0.5
    #expect(SegmentBoundary.chapter.pauseDuration(pace: .long) == 1.75)   // 1.0 * 1.75
    #expect(SegmentBoundary.paragraph.pauseDuration(pace: .short) == 0.175)
}

@Test func documentPauseDurationCombinesBoundaryAndPace() {
    let doc = boundaryDoc([[[SegSpec()]], [[SegSpec()]]])   // chapter break before index 1
    #expect(doc.pauseDuration(before: 1, pace: .normal) == 1.0)
    #expect(doc.pauseDuration(before: 1, pace: .off) == 0)
    #expect(doc.pauseDuration(before: 0, pace: .normal) == 0)   // first segment: no pause
}

@Test func readingPaceMultipliersAreOrdered() {
    #expect(ReadingPace.off.multiplier == 0)
    #expect(ReadingPace.short.multiplier < ReadingPace.normal.multiplier)
    #expect(ReadingPace.normal.multiplier < ReadingPace.long.multiplier)
}
