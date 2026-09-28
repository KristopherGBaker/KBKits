import Foundation

/// A span of **author-supplied** furigana (ruby) within a segment's display text —
/// the reading an imported source already carried (Aozora `漢字《かな》` now; EPUB
/// `<ruby>` later). Like `StyleRun`, it's a half-open UTF-16 offset span into
/// `TextSegment.displayText` (§3.2: positions persist as UTF-16 offsets, never
/// `Range<String.Index>`), plus the author's kana `reading` for that base span.
///
/// Source ruby takes precedence over the OpenJTalk-generated reading when the reader
/// annotates a word (see `KaraokeWord.rubySegments`). In Phase 3 a kana reading is also
/// baked into the spoken `text` at import (`substituting`), so a ruby'd segment speaks
/// the author's reading and its content hash changes. Persisted additively
/// (`decodeIfPresent(...) ?? []`), so pre-ruby documents decode to `[]`.
public struct RubyRun: Sendable, Hashable, Codable {
    public let lower: Int        // UTF-16 offset into displayText
    public let upper: Int        // exclusive
    public let reading: String   // author kana over `[lower, upper)`

    public init(lower: Int, upper: Int, reading: String) {
        self.lower = lower
        self.upper = upper
        self.reading = reading
    }

    /// The runs overlapping the display span `[lower, upper)`, clipped to it and
    /// rebased to span-local offsets (so a caller can tokenize/clip per word or per
    /// sentence). Mirrors the `StyleRun` clipping the builder applies per sentence.
    public static func rebased(_ runs: [RubyRun], lower: Int, upper: Int) -> [RubyRun] {
        runs.compactMap { run in
            let clampedLower = max(run.lower, lower), clampedUpper = min(run.upper, upper)
            guard clampedLower < clampedUpper else { return nil }
            return RubyRun(lower: clampedLower - lower, upper: clampedUpper - lower, reading: run.reading)
        }
    }

    /// True when `reading` is non-empty and every unicode scalar sits in the
    /// Hiragana (`0x3040–0x309F`) or Katakana (`0x30A0–0x30FF`) block — the only
    /// readings the spoken text substitutes (Phase 3). Those ranges already cover
    /// the chōonpu `ー` (0x30FC) and the kana iteration marks (ゝゞ/ヽヾ); a reading
    /// carrying latin, digits, or annotation is left as the base kanji instead.
    public var readingIsKana: Bool {
        guard !reading.isEmpty else { return false }
        return reading.unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    /// Replace each run's UTF-16 base span in `sentence` with its kana `reading`
    /// (Phase 3 spoken text), leaving the display base for any run whose reading is
    /// not kana (`readingIsKana == false`). `runs` are sentence-local, ascending, and
    /// non-overlapping (as `rebased` produces). Splicing walks the ORIGINAL UTF-16
    /// offsets left-to-right and copies each gap verbatim, so an earlier replacement
    /// that changes the UTF-16 length never shifts a later run's span.
    public static func substituting(_ runs: [RubyRun], in sentence: String) -> String {
        guard !runs.isEmpty else { return sentence }
        let source = sentence as NSString
        let length = source.length
        var result = ""
        var cursor = 0
        for run in runs.sorted(by: { $0.lower < $1.lower }) {
            let lower = min(max(run.lower, 0), length)
            let upper = min(max(run.upper, lower), length)
            guard lower >= cursor else { continue }   // defensive: skip any overlap
            result += source.substring(with: NSRange(location: cursor, length: lower - cursor))
            let base = source.substring(with: NSRange(location: lower, length: upper - lower))
            result += run.readingIsKana ? run.reading : base
            cursor = upper
        }
        result += source.substring(with: NSRange(location: cursor, length: length - cursor))
        return result
    }
}
