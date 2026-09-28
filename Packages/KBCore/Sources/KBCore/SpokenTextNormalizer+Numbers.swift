import Foundation

/// Number-shaped passes: ranges, fractions, decimals, grouped/plain integers, and
/// the 4-digit-year heuristic. Ported from abogen's `_normalize_grouped_numbers`.
/// Order matters — ranges and fractions claim their separators before the plain
/// integer pass would split them.
extension SpokenTextNormalizer {

    static func normalizeNumbers(_ text: String, yearStyle: Bool) -> String {
        guard text.contains(where: { $0.isNumber }) else { return text }
        var out = text
        out = replaceRanges(out)
        out = replaceFractions(out)
        out = replaceDecimals(out)
        out = replaceGroupedAndPlain(out, yearStyle: yearStyle)
        return out
    }

    // MARK: Ranges  (5-10 / 5–10 / "12 14" → "five to ten")

    private static let rangeSeparators = "-‐‑–—−"

    private static func replaceRanges(_ text: String) -> String {
        // Dash-separated: digits, optional spaces, a range dash, optional spaces, digits.
        let dash = #"(?<![\w.,])(-?\d{1,3}(?:,\d{3})+|\d+)\s*[-‐‑–—−]\s*(-?\d{1,3}(?:,\d{3})+|\d+)(?![\w./])"#
        var out = replaceMatches(in: text, pattern: dash) { groups in
            guard let left = coerceInt(groups[1]), let right = coerceInt(groups[2]),
                  let lw = EnglishNumberWords.cardinal(left),
                  let rw = EnglishNumberWords.cardinal(right) else { return nil }
            return "\(lw) to \(rw)"
        }
        // Space-separated pair of bare integers, e.g. "pages 12 14".
        let spaced = #"(?<![\w./-])(\d+)\s+(\d+)(?![\w./-])"#
        out = replaceMatches(in: out, pattern: spaced) { groups in
            guard let left = coerceInt(groups[1]), let right = coerceInt(groups[2]),
                  let lw = EnglishNumberWords.cardinal(left),
                  let rw = EnglishNumberWords.cardinal(right) else { return nil }
            return "\(lw) to \(rw)"
        }
        return out
    }

    // MARK: Fractions  (3/4 → "three quarters")

    private static func replaceFractions(_ text: String) -> String {
        let pattern = #"(?<![\w])(-?\d+)\s*[/⁄]\s*(-?\d+)(?![\w/⁄])"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            guard let num = coerceInt(groups[1]), let den = coerceInt(groups[2]) else { return nil }
            return fractionWords(numerator: num, denominator: den)
        }
    }

    static func fractionWords(numerator: Int, denominator: Int) -> String? {
        guard denominator != 0, abs(denominator) <= 100 else { return nil }
        guard let numWords = EnglishNumberWords.cardinal(abs(numerator)) else { return nil }
        let absNum = abs(numerator)
        let denWord: String?
        switch denominator {
        case 1: denWord = ""
        case 2: denWord = absNum == 1 ? "half" : "halves"
        case 4: denWord = absNum == 1 ? "quarter" : "quarters"
        default:
            guard let base = EnglishNumberWords.ordinal(denominator) else { return nil }
            denWord = absNum == 1 ? base : pluralizeFraction(base)
        }
        guard let denWord else { return nil }
        if denWord.isEmpty {
            // Denominator 1 → just the integer.
            return EnglishNumberWords.cardinal(numerator)
        }
        let signed = numerator < 0 ? "minus \(numWords)" : numWords
        return "\(signed) \(denWord)"
    }

    private static func pluralizeFraction(_ base: String) -> String {
        if base == "half" { return "halves" }
        if base.hasSuffix("f") { return String(base.dropLast()) + "ves" }
        if base.hasSuffix("fe") { return String(base.dropLast(2)) + "ves" }
        return base + "s"
    }

    // MARK: Decimals  (4.5 → "four point five")

    private static func replaceDecimals(_ text: String) -> String {
        let pattern = #"(?<![\w./-])(-?(?:\d{1,3}(?:,\d{3})+|\d+))\.(\d+)(?![\w.])"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            let intPart = groups[1].replacingOccurrences(of: ",", with: "")
            let fracPart = groups[2]
            let negative = intPart.hasPrefix("-")
            let core = negative ? String(intPart.dropFirst()) : intPart
            guard let intValue = Int(core), let intWords = EnglishNumberWords.cardinal(intValue) else { return nil }
            let trimmed = String(fracPart.reversed().drop(while: { $0 == "0" }).reversed())
            if trimmed.isEmpty {
                return negative ? "minus \(intWords)" : intWords
            }
            let digitWords = trimmed.compactMap { ch -> String? in
                guard let digit = ch.wholeNumberValue else { return nil }
                return EnglishNumberWords.ones[digit]
            }
            guard digitWords.count == trimmed.count else { return nil }
            let spoken = "\(intWords) point \(digitWords.joined(separator: " "))"
            return negative ? "minus \(spoken)" : spoken
        }
    }

    // MARK: Grouped + plain integers (with the year heuristic)

    private static func replaceGroupedAndPlain(_ text: String, yearStyle: Bool) -> String {
        // Trailing "." is allowed (sentence end) unless it begins a decimal (\.\d),
        // which the decimal pass already consumed.
        let pattern = #"(?<![\w/-])(?<!\.\d)(?<!\.)(-?(?:\d{1,3}(?:,\d{3})+|\d+))(?![\w/-])(?!\.\d)"#
        return replaceMatches(in: text, pattern: pattern, withContext: true) { groups, range, full in
            let token = groups[1]
            let bare = token.replacingOccurrences(of: ",", with: "")
            guard let value = Int(bare) else { return nil }

            // Year heuristic: a bare 4-digit 1000–9999 reads as a year unless an
            // "address" sits nearby without a year marker (BC/AD/…).
            if yearStyle, !token.contains(","),
               token.count == 4, value >= 1000, value <= 9999,
               shouldReadAsYear(in: full, at: range) {
                if let year = yearWords(value) { return year }
            }
            return EnglishNumberWords.cardinal(value)
        }
    }

    private static func shouldReadAsYear(in text: String, at range: Range<String.Index>) -> Bool {
        let window = contextWindow(text, around: range, radius: 60).lowercased()
        let hasYearMarker = window.range(of: #"\b(bc|ad|bce|ce|b\.c\.|a\.d\.)\b"#,
                                         options: .regularExpression) != nil
        let hasAddress = window.range(of: #"\baddress(es)?\b"#, options: .regularExpression) != nil
        return !(hasAddress && !hasYearMarker)
    }

    /// Common American year pronunciation. 1995 → "nineteen ninety-five",
    /// 1905 → "nineteen oh five", 2000 → "two thousand", 2009 → "two thousand
    /// nine", 2010 → "twenty ten". Century-round years (1900) → "nineteen hundred".
    static func yearWords(_ value: Int) -> String? {
        guard value >= 1000, value <= 9999 else { return nil }
        if value == 2000 { return "two thousand" }
        if value >= 2001, value <= 2009 {
            return "two thousand \(EnglishNumberWords.ones[value % 10])"
        }
        let firstTwo = value / 100
        let lastTwo = value % 100
        guard let head = EnglishNumberWords.twoDigitWords(firstTwo) else { return nil }
        if lastTwo == 0 { return "\(head) hundred" }
        if lastTwo < 10 { return "\(head) oh \(EnglishNumberWords.ones[lastTwo])" }
        guard let tail = EnglishNumberWords.twoDigitWords(lastTwo) else { return nil }
        return "\(head) \(tail)"
    }

    static func coerceInt(_ token: String) -> Int? {
        let cleaned = token.replacingOccurrences(of: ",", with: "")
        return Int(cleaned)
    }
}
