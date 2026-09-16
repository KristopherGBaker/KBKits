extension StringProtocol {
    /// The edit distance to another string, in characters.
    ///
    /// Over `Character`, not UTF-16 code units. That matters here: a non-BMP character is
    /// two code units and one character, so a code-unit distance would say two strings
    /// differing by one emoji or one rare kanji were two edits apart rather than one. The
    /// reference implementation this replaces has exactly that bug in its own helper, where
    /// it passes a grapheme count as a UTF-16 buffer length.
    ///
    /// Two rows rather than a full matrix, so the memory is proportional to the shorter
    /// string rather than to the product of the two.
    public func levenshteinDistance(to other: some StringProtocol) -> Int {
        let source = Array(self)
        let target = Array(other)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0 ... target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for (sourceIndex, sourceCharacter) in source.enumerated() {
            current[0] = sourceIndex + 1
            for (targetIndex, targetCharacter) in target.enumerated() {
                let substitution = previous[targetIndex] + (sourceCharacter == targetCharacter ? 0 : 1)
                current[targetIndex + 1] = Swift.min(
                    previous[targetIndex + 1] + 1, // deletion
                    current[targetIndex] + 1, // insertion
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}

extension StringProtocol {
    /// The edit distance to another string, counting a transposition as one edit.
    ///
    /// Damerau-Levenshtein, in its optimal string alignment form. The difference from plain
    /// Levenshtein is one case and it matters more than it sounds: swapping two adjacent
    /// letters is the commonest typing mistake there is, and plain Levenshtein charges two
    /// edits for it. On a five letter word with a tolerance of one, that is the difference
    /// between "watre" being accepted as "water" and being marked wrong.
    ///
    /// Optimal string alignment rather than the unrestricted variant: it forbids editing a
    /// substring more than once, which makes it not quite a metric and makes it linear in
    /// memory. For answer checking, where the two strings are a word long and nearly equal,
    /// the distinction never arises.
    public func damerauLevenshteinDistance(to other: some StringProtocol) -> Int {
        let source = Array(self)
        let target = Array(other)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        // Three rows: the transposition case needs to look two back.
        var twoAgo = [Int](repeating: 0, count: target.count + 1)
        var previous = Array(0 ... target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for (sourceIndex, sourceCharacter) in source.enumerated() {
            current[0] = sourceIndex + 1
            for (targetIndex, targetCharacter) in target.enumerated() {
                let cost = sourceCharacter == targetCharacter ? 0 : 1
                var best = Swift.min(
                    previous[targetIndex + 1] + 1, // deletion
                    current[targetIndex] + 1, // insertion
                    previous[targetIndex] + cost // substitution
                )
                if sourceIndex > 0, targetIndex > 0,
                   sourceCharacter == target[targetIndex - 1],
                   source[sourceIndex - 1] == targetCharacter {
                    best = Swift.min(best, twoAgo[targetIndex - 1] + 1) // transposition
                }
                current[targetIndex + 1] = best
            }
            // Rotate the three preallocated rows rather than allocating a fresh one each
            // source character: what was `current` becomes `previous`, `previous` becomes
            // `twoAgo`, and the row `twoAgo` held is recycled as the next `current`, whose
            // cells are all overwritten before they are read. Two swaps keep each buffer
            // uniquely referenced, so no copy-on-write allocation sneaks back in.
            swap(&twoAgo, &previous)
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}
