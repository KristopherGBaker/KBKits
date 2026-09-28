import Foundation

/// A tiny, dependency-free English integer→words speller — the Swift replacement
/// for abogen's Python `num2words`. Covers cardinals and ordinals up to the
/// quintillion range (well past anything a sentence will hold), which is all the
/// `SpokenTextNormalizer` passes need. American style (no "and": "one hundred
/// five", not "one hundred and five") so it matches the Kokoro reference voice.
public enum EnglishNumberWords {

    static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen"]

    static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety"]

    /// Scale words indexed by group-of-three (0 = units, 1 = thousand, …).
    static let scales = [
        "", "thousand", "million", "billion", "trillion", "quadrillion",
        "quintillion"]

    /// Spell a (possibly negative) integer as cardinal words, e.g. 1204 →
    /// "one thousand two hundred four", -7 → "minus seven". Returns nil only for
    /// magnitudes beyond the supported scales.
    public static func cardinal(_ value: Int) -> String? {
        if value == 0 { return "zero" }
        let negative = value < 0
        let magnitude = value.magnitude
        guard let words = cardinalGroups(UInt64(magnitude)) else { return nil }
        return negative ? "minus \(words)" : words
    }

    /// The two-or-fewer-digit core ("twenty-three", "seven", "fifteen"). Public so
    /// the year pass can splice "nineteen ninety-five" out of two such cores.
    public static func twoDigitWords(_ value: Int) -> String? {
        guard value >= 0, value < 100 else { return nil }
        if value < 20 { return ones[value] }
        let ten = tens[value / 10]
        let one = value % 10
        return one == 0 ? ten : "\(ten)-\(ones[one])"
    }

    private static func cardinalGroups(_ value: UInt64) -> String? {
        if value == 0 { return "zero" }
        var groups: [UInt64] = []
        var remaining = value
        while remaining > 0 {
            groups.append(remaining % 1000)
            remaining /= 1000
        }
        guard groups.count <= scales.count else { return nil }

        var parts: [String] = []
        for index in stride(from: groups.count - 1, through: 0, by: -1) {
            let group = groups[index]
            guard group > 0 else { continue }
            guard let groupWords = threeDigitWords(Int(group)) else { return nil }
            let scale = scales[index]
            parts.append(scale.isEmpty ? groupWords : "\(groupWords) \(scale)")
        }
        return parts.joined(separator: " ")
    }

    private static func threeDigitWords(_ value: Int) -> String? {
        guard value > 0, value < 1000 else { return nil }
        if value < 100 { return twoDigitWords(value) }
        let hundreds = value / 100
        let remainder = value % 100
        let head = "\(ones[hundreds]) hundred"
        guard remainder > 0 else { return head }
        guard let tail = twoDigitWords(remainder) else { return nil }
        return "\(head) \(tail)"
    }

    // MARK: - Ordinals

    private static let onesOrdinal = [
        "zeroth", "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
        "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth"]

    private static let tensOrdinal = [
        "", "", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth"]

    /// Spell a positive integer as an ordinal, e.g. 15 → "fifteenth", 21 →
    /// "twenty-first", 100 → "one hundredth". Returns nil for non-positive values
    /// or magnitudes beyond the supported scales.
    public static func ordinal(_ value: Int) -> String? {
        guard value > 0 else { return nil }
        if value < 20 { return onesOrdinal[value] }
        if value < 100 {
            let one = value % 10
            if one == 0 { return tensOrdinal[value / 10] }
            return "\(tens[value / 10])-\(onesOrdinal[one])"
        }
        // For larger values, spell the cardinal then make the final word ordinal.
        guard let cardinal = cardinal(value) else { return nil }
        return ordinalizeFinalWord(cardinal)
    }

    /// Turn the last word of a cardinal phrase into its ordinal ("one hundred" →
    /// "one hundredth", "two thousand" → "two thousandth").
    private static func ordinalizeFinalWord(_ cardinal: String) -> String {
        var words = cardinal.split(separator: " ").map(String.init)
        guard let last = words.last else { return cardinal }
        let pieces = last.split(separator: "-").map(String.init)
        let lastPiece = pieces.last ?? last
        let ordinalPiece = ordinalizeWord(lastPiece)
        if pieces.count > 1 {
            words[words.count - 1] = pieces.dropLast().joined(separator: "-") + "-" + ordinalPiece
        } else {
            words[words.count - 1] = ordinalPiece
        }
        return words.joined(separator: " ")
    }

    private static func ordinalizeWord(_ word: String) -> String {
        let exceptions = ["one": "first", "two": "second", "three": "third",
                          "five": "fifth", "eight": "eighth", "nine": "ninth",
                          "twelve": "twelfth"]
        if let mapped = exceptions[word] { return mapped }
        if word.hasSuffix("y") { return String(word.dropLast()) + "ieth" }
        return word + "th"
    }
}
