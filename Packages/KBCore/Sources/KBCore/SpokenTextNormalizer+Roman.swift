import Foundation

/// Context-gated Roman-numeral conversion. The hard part is *not* mangling the
/// pronoun "I" or stray capitals — abogen converts only when a strong cardinal
/// context precedes ("Chapter IV" → "Chapter Four", "part iii" → "part three",
/// "phase-IV" → "phase four") or when a multi-letter all-caps token is
/// unambiguous. Ported (trimmed) from abogen's `_normalize_roman_numerals`.
extension SpokenTextNormalizer {

    /// Words that, when they precede a Roman numeral, make it a cardinal section
    /// label rather than the pronoun "I" or an initial.
    private static let cardinalContexts: Set<String> = [
        "chapter", "part", "section", "act", "scene", "book", "volume", "phase",
        "stage", "step", "level", "appendix", "figure", "table", "lesson",
        "unit", "episode", "round", "grade", "class", "tier", "movement"]

    private static let romanValues: [Character: Int] = [
        "i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]

    static func normalizeRomanNumerals(_ text: String) -> String {
        var out = text
        // "Chapter IV", "part iii", "Section Xii" — context word + Roman token.
        let contextKeys = cardinalContexts.joined(separator: "|")
        let spaced = #"\b("# + contextKeys + #")([ \t]+)([IVXLCDMivxlcdm]{1,7})\b"#
        out = replaceMatches(in: out, pattern: spaced, options: [.caseInsensitive]) { groups in
            guard cardinalContexts.contains(groups[1].lowercased()),
                  let value = romanToInt(groups[3]), value <= 200,
                  let words = EnglishNumberWords.cardinal(value) else { return nil }
            return "\(groups[1])\(groups[2])\(capitalizeFirst(words))"
        }
        // Hyphen/colon-joined: "phase-IV", "Act: II".
        let joined = #"\b("# + contextKeys + #")([-–—:])([IVXLCDMivxlcdm]{1,7})\b"#
        out = replaceMatches(in: out, pattern: joined, options: [.caseInsensitive]) { groups in
            guard cardinalContexts.contains(groups[1].lowercased()),
                  let value = romanToInt(groups[3]), value <= 200,
                  let words = EnglishNumberWords.cardinal(value) else { return nil }
            let sep = groups[2] == ":" ? ": " : " "
            return "\(groups[1])\(sep)\(capitalizeFirst(words))"
        }
        // Name suffix ordinals: "Bob Smith II" → "Bob Smith the second".
        out = replaceNameSuffixOrdinals(out)
        return out
    }

    private static func replaceNameSuffixOrdinals(_ text: String) -> String {
        // A capitalized word followed by a 2+ letter Roman token at a word edge.
        let pattern = #"\b([A-Z][a-z]+)\s+(I{2,3}|IV|VI{0,3}|IX|XI{0,2})\b"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            guard let value = romanToInt(groups[2]), value <= 20,
                  let ordinal = EnglishNumberWords.ordinal(value) else { return nil }
            return "\(groups[1]) the \(ordinal)"
        }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Strict Roman→Int: parses then round-trips through `intToRoman` so malformed
    /// tokens ("IIII", "VV") and ordinary words are rejected.
    static func romanToInt(_ token: String) -> Int? {
        let lower = token.lowercased()
        guard !lower.isEmpty, lower.allSatisfy({ romanValues[$0] != nil }) else { return nil }
        var total = 0
        var prev = 0
        for char in lower.reversed() {
            guard let value = romanValues[char] else { return nil }
            if value < prev { total -= value } else { total += value; prev = value }
        }
        guard total > 0, intToRoman(total) == lower else { return nil }
        return total
    }

    private static func intToRoman(_ value: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"),
            (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"),
            (5, "v"), (4, "iv"), (1, "i")]
        var remaining = value
        var out = ""
        for (amount, symbol) in table {
            while remaining >= amount { out += symbol; remaining -= amount }
        }
        return out
    }
}
