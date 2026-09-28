import Foundation

/// Re-anchors a document reference (a card's `sourceSentenceIndex`, a bookmark, a capture
/// mark, or a frozen reading position) against a freshly re-segmented document after a
/// `.userNote`'s text was edited and its `text_hash` bumped (PRD C6 / §Milestones Stage 3.5).
///
/// Pure + `Sendable` so it lives here in `KBCore` and is unit-testable without MLX (the
/// `swift test` loop can't build the Kokoro stack). The matching is a SEARCH over the new
/// segments' spoken `text`, keyed on the snapshot text the reference carried — so card
/// CONTENT is never lost (cards always store their own `sourceText`); only the cheap
/// "jump to source" hint is re-derived. Bookmarks/positions fall back to a fuzzy match.
public enum ReferenceReanchor {
    /// The result of re-anchoring a single reference against the re-segmented document.
    public enum Outcome: Sendable, Hashable {
        /// The reference still resolves to its original index — nothing changed.
        case kept(index: Int)
        /// A match was found at a different index — the reference moved.
        case moved(from: Int, to: Int)
        /// No good match — the reference is orphaned (its source passage is gone).
        case orphaned(from: Int)

        /// The resolved index a kept/moved reference should now point at (`nil` for orphans).
        public var resolvedIndex: Int? {
            switch self {
            case let .kept(index): return index
            case let .moved(_, to): return to
            case .orphaned: return nil
            }
        }

        /// Whether the reference changed index (moved) — for explicit move surfacing.
        public var didMove: Bool { if case .moved = self { return true }; return false }

        /// Whether the reference lost its source — for explicit orphan surfacing.
        public var isOrphaned: Bool { if case .orphaned = self { return true }; return false }
    }

    // MARK: - Exact-ish search (cards)

    /// Find the segment index whose spoken text best contains `sourceText`, preferring the
    /// `hint` index when it still matches (stable when an edit happened elsewhere). Cards use
    /// this: their stored `sourceText` makes the re-find cheap and near-perfect.
    ///
    /// `sourceText` may span several sentences (a captured range), so we match a segment when
    /// it is contained in the snapshot or the snapshot is contained in it, after normalizing
    /// whitespace. Returns `nil` only when no segment shares the text at all.
    public static func searchIndex(
        forSourceText sourceText: String,
        in segments: [TextSegment],
        hint: Int? = nil
    ) -> Int? {
        let needle = normalize(sourceText)
        guard !needle.isEmpty else { return nil }
        // 1. The hint still matches — keep it (an edit elsewhere shouldn't move this card).
        if let hint, segments.indices.contains(hint),
           textMatches(normalize(segments[hint].text), needle) {
            return hint
        }
        // 2. First exact-equal segment, else first containment match, in reading order.
        var containment: Int?
        for segment in segments {
            let hay = normalize(segment.text)
            if hay == needle { return segment.sentenceIndex }
            if containment == nil, textMatches(hay, needle) { containment = segment.sentenceIndex }
        }
        return containment
    }

    /// Re-anchor a card's `sourceSentenceIndex` (PRD C6). Cards carry `sourceText`, so this is
    /// the exact-ish search — content is never lost regardless of the outcome.
    public static func reanchorCard(
        sourceText: String?,
        oldIndex: Int?,
        in segments: [TextSegment]
    ) -> Outcome {
        let from = oldIndex ?? -1
        guard let sourceText, let found = searchIndex(forSourceText: sourceText, in: segments, hint: oldIndex)
        else { return .orphaned(from: from) }
        return found == oldIndex ? .kept(index: found) : .moved(from: from, to: found)
    }

    // MARK: - Fuzzy match (bookmarks / capture marks / reading position)

    /// Default similarity below which a fuzzy match is treated as an orphan rather than a move.
    public static let fuzzyThreshold = 0.6

    /// Re-anchor a bookmark / capture mark / reading position by FUZZY sentence-match (PRD
    /// Stage 3.5). These carry only a short snapshot (or none), so we score every segment by
    /// token-overlap similarity to `sourceText` and keep the best above `threshold`:
    /// keep (same index) / move (different index) / orphan (no segment clears the bar).
    public static func fuzzyReanchor(
        sourceText: String?,
        oldIndex: Int,
        in segments: [TextSegment],
        threshold: Double = fuzzyThreshold
    ) -> Outcome {
        guard let sourceText else { return passthrough(oldIndex: oldIndex, in: segments) }
        let needle = normalize(sourceText)
        guard !needle.isEmpty else { return passthrough(oldIndex: oldIndex, in: segments) }
        // Exact containment short-circuits to a definite match (covers a clean re-segment).
        if let exact = searchIndex(forSourceText: sourceText, in: segments, hint: oldIndex) {
            return exact == oldIndex ? .kept(index: exact) : .moved(from: oldIndex, to: exact)
        }
        var bestIndex: Int?
        var bestScore = 0.0
        for segment in segments {
            let score = similarity(needle, normalize(segment.text))
            if score > bestScore { bestScore = score; bestIndex = segment.sentenceIndex }
        }
        guard let bestIndex, bestScore >= threshold else { return .orphaned(from: oldIndex) }
        return bestIndex == oldIndex ? .kept(index: bestIndex) : .moved(from: oldIndex, to: bestIndex)
    }

    /// When there's nothing to match on, keep the index if it's still in range, else orphan.
    private static func passthrough(oldIndex: Int, in segments: [TextSegment]) -> Outcome {
        segments.indices.contains(oldIndex) ? .kept(index: oldIndex) : .orphaned(from: oldIndex)
    }

    // MARK: - Primitives

    /// Collapse whitespace + lowercase so trivial edits (re-wrapping, casing) don't break a match.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether two normalized strings match by containment (either direction). A captured
    /// passage may span several sentences, so the snapshot can be longer than one segment.
    private static func textMatches(_ hay: String, _ needle: String) -> Bool {
        hay == needle || hay.contains(needle) || needle.contains(hay)
    }

    /// Token-overlap (Jaccard) similarity of two normalized strings, in `0...1`. Cheap,
    /// order-insensitive, and good enough to tell a reworded-but-same sentence from a
    /// deleted one.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " "))
        let rhsTokens = Set(rhs.split(separator: " "))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return Double(intersection) / Double(union)
    }
}
