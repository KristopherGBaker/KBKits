import Foundation
import Markdown

/// Converts swift-markdown's source locations (1-based line, 1-based UTF-8 byte column) to
/// UTF-16 offsets, and holds the source's UTF-16 units for the scans the highlighter does.
///
/// A map can stand for a tail of a longer text (a streaming document's open block): `base` is
/// the UTF-16 offset the tail starts at, and the ranges it makes are offsets into the whole
/// text. A location with no line (line 0, which cmark gives some split nodes) stays at offset
/// 0 whatever the base, as it would in a parse of the whole text. `units` and the line
/// helpers the highlighter uses are relative to the tail; it always maps from 0.
struct SourceMap {
    /// The source as UTF-16 code units.
    let units: [UInt16]
    /// The whole-text UTF-16 offset `units` starts at.
    let base: Int
    /// The UTF-8 offset each line starts at. cmark ends a line at `\n`, `\r\n` or `\r`.
    private let lineStarts: [Int]
    /// The UTF-16 offset of each UTF-8 offset, with one extra entry for the end.
    private let utf16Offsets: [Int]

    init(_ source: String, base: Int = 0) {
        self.base = base
        units = Array(source.utf16)
        var starts = [0]
        var offsets: [Int] = []
        var copy = source
        copy.withUTF8 { bytes in
            offsets.reserveCapacity(bytes.count + 1)
            var utf16 = 0
            for index in bytes.indices {
                let byte = bytes[index]
                offsets.append(utf16)
                // A scalar's lead byte counts its UTF-16 width: two for a four-byte scalar.
                if byte & 0xC0 != 0x80 { utf16 += byte >= 0xF0 ? 2 : 1 }
                if byte == 0x0A || (byte == 0x0D && (index + 1 == bytes.count || bytes[index + 1] != 0x0A)) {
                    starts.append(index + 1)
                }
            }
            offsets.append(utf16)
        }
        lineStarts = starts
        utf16Offsets = offsets
    }

    /// The UTF-16 offset of `location`, clamped into the source.
    func offset(_ location: SourceLocation) -> Int {
        let line = location.line - 1
        guard line >= 0 else { return 0 }
        guard line < lineStarts.count else { return base + units.count }
        let byte = min(max(lineStarts[line] + location.column - 1, 0), utf16Offsets.count - 1)
        return base + utf16Offsets[byte]
    }

    /// `range` in UTF-16 offsets.
    func range(_ range: SourceRange) -> MarkdownSourceRange {
        let lower = offset(range.lowerBound)
        return MarkdownSourceRange(utf16: lower..<max(lower, offset(range.upperBound)))
    }

    /// `range` with any trailing line endings dropped. cmark ends some blocks (setext
    /// headings, indented code, thematic breaks) at column 1 of the following line.
    func trimmingLineEnds(_ range: MarkdownSourceRange) -> MarkdownSourceRange {
        var upper = range.utf16.upperBound
        while upper > range.utf16.lowerBound, let last = unit(at: upper - 1), Self.isLineEnd(last) { upper -= 1 }
        return MarkdownSourceRange(utf16: range.utf16.lowerBound..<upper)
    }

    /// The unit at whole-text `offset`, or nil outside this map.
    func unit(at offset: Int) -> UInt16? {
        let index = offset - base
        return units.indices.contains(index) ? units[index] : nil
    }

    /// The offset where the line holding `offset` starts.
    func lineStart(containing offset: Int) -> Int {
        var index = min(offset, units.count)
        while index > 0, !Self.isLineEnd(units[index - 1]) { index -= 1 }
        return index
    }

    /// The offset where the line holding `offset` ends, its line ending excluded.
    func lineEnd(containing offset: Int) -> Int {
        var index = offset
        while index < units.count, !Self.isLineEnd(units[index]) { index += 1 }
        return index
    }

    /// The offset where the next line starts after the line holding `offset`, or nil at
    /// the last line.
    func nextLineStart(after offset: Int) -> Int? {
        var index = lineEnd(containing: offset)
        guard index < units.count else { return nil }
        if units[index] == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
        return index + 1
    }

    static func isLineEnd(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }

    /// A space or a tab.
    static func isSpace(_ unit: UInt16) -> Bool {
        unit == UInt16(ascii: " ") || unit == UInt16(ascii: "\t")
    }

    /// For each UTF-16 offset in `text` (a text node's resolved string), the source offset it
    /// came from inside `source`, plus `source`'s upper bound for the end.
    ///
    /// Exact when the text is the source slice verbatim, which is the common case. Where
    /// escapes or entities make them differ, each text unit is matched to the next equal
    /// source unit (skipping a `\` or an entity's tail); a unit with no equal source unit
    /// (an entity such as `&copy;`) maps to where the scan stands.
    func offsets(of text: String, in source: MarkdownSourceRange) -> [Int] {
        let textUnits = Array(text.utf16)
        let lower = source.utf16.lowerBound
        let upper = min(source.utf16.upperBound, base + units.count)
        // Every positioned range lies inside the map; only line-0 ranges (at 0) fall before a
        // tail's base, and those are empty, so they search nothing, as in a whole-text map.
        if lower >= base, textUnits.count == upper - lower,
           textUnits.elementsEqual(units[(lower - base)..<(upper - base)]) {
            return Array(lower...upper)
        }
        var map: [Int] = []
        map.reserveCapacity(textUnits.count + 1)
        var cursor = lower
        for unit in textUnits {
            if cursor >= base, cursor < upper,
               let found = units[(cursor - base)..<(upper - base)].firstIndex(of: unit) {
                map.append(found + base)
                cursor = found + base + 1
            } else {
                map.append(cursor)
            }
        }
        map.append(upper)
        return map
    }
}

extension UInt16 {
    /// The UTF-16 unit of an ASCII character, for comparing against `SourceMap.units`.
    init(ascii scalar: Unicode.Scalar) {
        self.init(UInt8(ascii: scalar))
    }
}
