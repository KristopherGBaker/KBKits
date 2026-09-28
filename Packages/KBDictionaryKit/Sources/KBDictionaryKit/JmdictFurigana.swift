import Foundation

/// One span of a dictionary form's characters with its furigana kana. `range` is over
/// the form's `Character` positions; `kana` is nil at okurigana positions (the
/// character reads as itself, so it takes no ruby).
public struct FuriganaSpan: Sendable, Hashable {
    public let range: Range<Int>
    public let kana: String?

    public init(range: Range<Int>, kana: String?) {
        self.range = range
        self.kana = kana
    }
}

/// Parser for the JmdictFurigana dataset (Doublevil, CC BY-SA 4.0): lines of
/// `kanji|reading|segmentation`, where segmentation is `;`-separated
/// `<idx>(-<endIdx>):<kana>` over character indices of the kanji form. Okurigana
/// positions are simply absent from the segmentation and become nil-kana
/// single-character spans, so the output always tiles the whole form.
///
/// This is the canonical implementation; `Tools/build-jmdict.swift` runs standalone
/// (it cannot import this package) and mirrors the same validation — keep them in sync.
public enum JmdictFuriganaParser {
    /// One well-formed dataset line: the raw pieces (as stored in the `furigana` sqlite
    /// table) plus the expanded per-character spans.
    public struct Line: Sendable, Hashable {
        public let form: String
        public let reading: String
        public let segmentation: String
        public let spans: [FuriganaSpan]
    }

    /// Parses one dataset line, returning nil (never throwing) for malformed input:
    /// wrong field count, empty form/reading, or unparseable / out-of-range
    /// segmentation. Strips a UTF-8 BOM if present (the dataset carries one on line 1).
    public static func parseLine(_ rawLine: String) -> Line? {
        var line = rawLine
        if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let form = String(fields[0])
        let reading = String(fields[1])
        let segmentation = String(fields[2])
        guard !form.isEmpty, !reading.isEmpty,
              let spans = spans(segmentation: segmentation, formLength: form.count) else { return nil }
        return Line(form: form, reading: reading, segmentation: segmentation, spans: spans)
    }

    /// Expands a raw segmentation over a form of `formLength` characters into ordered
    /// spans tiling the whole form (okurigana gaps become nil-kana single-character
    /// spans). Returns nil for malformed segmentations: empty, non-numeric or
    /// out-of-range indices, empty kana, or overlapping spans.
    public static func spans(segmentation: String, formLength: Int) -> [FuriganaSpan]? {
        guard !segmentation.isEmpty, formLength > 0 else { return nil }
        var annotated: [(range: Range<Int>, kana: String)] = []
        for item in segmentation.split(separator: ";", omittingEmptySubsequences: false) {
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let kana = String(item[item.index(after: colon)...])
            guard !kana.isEmpty, let range = charRange(item[..<colon], formLength: formLength) else { return nil }
            annotated.append((range, kana))
        }
        var spans: [FuriganaSpan] = []
        var cursor = 0
        for (range, kana) in annotated.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard range.lowerBound >= cursor else { return nil }  // overlapping spans
            while cursor < range.lowerBound {
                spans.append(FuriganaSpan(range: cursor..<(cursor + 1), kana: nil))
                cursor += 1
            }
            spans.append(FuriganaSpan(range: range, kana: kana))
            cursor = range.upperBound
        }
        while cursor < formLength {
            spans.append(FuriganaSpan(range: cursor..<(cursor + 1), kana: nil))
            cursor += 1
        }
        return spans
    }

    /// `<idx>` or `<idx>-<endIdx>` (inclusive) → a half-open character range, nil when
    /// non-numeric, reversed, or out of the form's bounds.
    private static func charRange(_ indexPart: Substring, formLength: Int) -> Range<Int>? {
        let start: Int
        let end: Int
        if let dash = indexPart.firstIndex(of: "-") {
            guard let lower = Int(indexPart[..<dash]),
                  let upper = Int(indexPart[indexPart.index(after: dash)...]) else { return nil }
            start = lower
            end = upper
        } else {
            guard let only = Int(indexPart) else { return nil }
            start = only
            end = only
        }
        guard start >= 0, end >= start, end < formLength else { return nil }
        return start..<(end + 1)
    }
}
