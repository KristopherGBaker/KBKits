public import Foundation

/// The structural relationship between one segment and the next in reading order —
/// the unit that decides how long a *pause* to insert between them so audiobook
/// playback breathes (a `<break>`-style structural silence). Derived purely from
/// the document's navigation hierarchy (chapters → paragraphs) plus each segment's
/// `blockStyle`, so it's testable without any audio.
///
/// Ordered loosest → longest pause; `sentence` (same paragraph) is the no-extra-
/// pause baseline because the synthesizer already pauses at the period.
public enum SegmentBoundary: Sendable, Hashable, CaseIterable {
    /// Two sentences inside the same paragraph — the baseline; no extra silence.
    case sentence
    /// The next segment begins a new paragraph (within the same chapter).
    case paragraph
    /// The next segment begins a heading / section title.
    case heading
    /// The next segment begins a new chapter.
    case chapter
}

/// How much breathing room to insert at structural boundaries during playback.
/// A user setting (default `.normal`); `.off` disables all inserted pauses. The
/// multiplier scales the per-boundary base durations.
public enum ReadingPace: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case off
    case short
    case normal
    case long

    public var id: String { rawValue }

    /// Scales every boundary's base duration. `.off` is exactly 0 → no inserted
    /// silence at all (the buffers are never scheduled).
    public var multiplier: Double {
        switch self {
        case .off: return 0
        case .short: return 0.5
        case .normal: return 1.0
        case .long: return 1.75
        }
    }
}

extension SegmentBoundary {
    /// Base pause for this boundary at `.normal` pace, in seconds. Sentence is 0:
    /// Kokoro/AVSpeech already pause at the period, so an extra gap there would
    /// double the beat. Tuned for an unhurried-but-not-sleepy audiobook feel.
    public var baseDuration: TimeInterval {
        switch self {
        case .sentence: return 0
        case .paragraph: return 0.35
        case .heading: return 0.6
        case .chapter: return 1.0
        }
    }

    /// The silence to insert at this boundary for the given pace (>= 0). `.off`
    /// (multiplier 0) yields 0 everywhere, disabling inserted pauses.
    public func pauseDuration(pace: ReadingPace) -> TimeInterval {
        max(0, baseDuration * pace.multiplier)
    }
}

extension Document {
    /// Classify the boundary *into* segment `index` — i.e. the structural pause that
    /// belongs **before** segment `index`, relative to `index - 1`. Returns `nil`
    /// for the first segment (no leading pause) or an out-of-range index.
    ///
    /// Pure and derived from the nav hierarchy: a different chapter ⇒ `.chapter`; a
    /// heading-styled segment that opens its run ⇒ `.heading`; a different paragraph
    /// ⇒ `.paragraph`; otherwise same-paragraph ⇒ `.sentence`.
    public func boundary(before index: Int) -> SegmentBoundary? {
        guard index > 0, segments.indices.contains(index) else { return nil }

        if chapterIndex(forSegment: index) != chapterIndex(forSegment: index - 1) {
            return .chapter
        }
        // A heading segment that isn't already inside the previous segment's paragraph
        // starts a section — give it the heading beat (it's also a new paragraph, but
        // headings read with a touch more space than a body paragraph break).
        if case .heading = segments[index].blockStyle,
           paragraphIndex(forSegment: index) != paragraphIndex(forSegment: index - 1) {
            return .heading
        }
        if paragraphIndex(forSegment: index) != paragraphIndex(forSegment: index - 1) {
            return .paragraph
        }
        return .sentence
    }

    /// The pause (seconds) to insert before segment `index` at `pace`; 0 when there's
    /// no boundary, when `index` is the first segment, or when `pace` is `.off`.
    public func pauseDuration(before index: Int, pace: ReadingPace) -> TimeInterval {
        boundary(before: index)?.pauseDuration(pace: pace) ?? 0
    }

    /// Index of the chapter spanning `segment`, or `nil` if none (e.g. a segment
    /// outside every chapter's range — shouldn't happen for a well-formed document).
    func chapterIndex(forSegment segment: Int) -> Int? {
        chapters.firstIndex { $0.segmentRange.contains(segment) }
    }

    /// A document-wide ordinal for the paragraph spanning `segment`, stable across
    /// chapters (chapters are walked in order). `nil` if the segment is in no
    /// paragraph. Two segments compare equal iff they share a paragraph.
    func paragraphIndex(forSegment segment: Int) -> Int? {
        var ordinal = 0
        for chapter in chapters {
            for paragraph in chapter.paragraphs {
                if paragraph.segmentRange.contains(segment) { return ordinal }
                ordinal += 1
            }
        }
        return nil
    }
}
