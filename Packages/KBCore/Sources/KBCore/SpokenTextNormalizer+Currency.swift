import Foundation

/// Currency pass: `$5` → "five dollars", `$5 million` → "five million dollars",
/// `$0.99` → "ninety-nine cents", `$2.50` → "two dollars, fifty cents". Ported
/// from abogen's `_replace_currency`. Runs before the generic number pass so the
/// symbol-attached amount is consumed first.
extension SpokenTextNormalizer {

    /// Spoken names for one currency symbol: main unit (singular) plus its sub-unit
    /// in singular and plural forms (cent/cents, penny/pence, yen/yen).
    struct CurrencyNames {
        let unit: String
        let sub: String
        let subPlural: String
    }

    private static let currencyNames: [Character: CurrencyNames] = [
        "$": CurrencyNames(unit: "dollar", sub: "cent", subPlural: "cents"),
        "£": CurrencyNames(unit: "pound", sub: "penny", subPlural: "pence"),
        "€": CurrencyNames(unit: "euro", sub: "cent", subPlural: "cents"),
        "¥": CurrencyNames(unit: "yen", sub: "yen", subPlural: "yen")
    ]

    static func normalizeCurrency(_ text: String) -> String {
        guard text.contains(where: { "$£€¥".contains($0) }) else { return text }
        let pattern = #"([$£€¥])\s*(\d{1,3}(?:,\d{3})*(?:\.\d+)?)(?:\s+(hundred|thousand|million|billion|trillion))?"#
        return replaceMatches(in: text, pattern: pattern, options: [.caseInsensitive]) { groups in
            guard let symbol = groups[1].first, let names = currencyNames[symbol] else { return nil }
            let amount = groups[2].replacingOccurrences(of: ",", with: "")
            let magnitude = groups[3].lowercased()
            if !magnitude.isEmpty {
                return magnitudeCurrency(amount: amount, magnitude: magnitude, unitPlural: pluralUnit(names.unit))
            }
            return plainCurrency(amount: amount, names: names)
        }
    }

    private static func pluralUnit(_ unit: String) -> String {
        unit == "yen" ? "yen" : unit + "s"
    }

    private static func magnitudeCurrency(amount: String, magnitude: String, unitPlural: String) -> String? {
        let spoken: String
        if amount.contains(".") {
            let parts = amount.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let intValue = Int(parts[0]),
                  let intWords = EnglishNumberWords.cardinal(intValue) else { return nil }
            let digitWords = parts[1].compactMap { $0.wholeNumberValue.map { EnglishNumberWords.ones[$0] } }
            guard digitWords.count == parts[1].count else { return nil }
            spoken = "\(intWords) point \(digitWords.joined(separator: " "))"
        } else {
            guard let value = Int(amount), let words = EnglishNumberWords.cardinal(value) else { return nil }
            spoken = words
        }
        return "\(spoken) \(magnitude) \(unitPlural)"
    }

    private static func plainCurrency(amount: String, names: CurrencyNames) -> String? {
        let unitPlural = pluralUnit(names.unit)
        if amount.contains(".") {
            let parts = amount.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let dollars = Int(parts[0]) else { return nil }
            let centsStr = String((parts[1] + "00").prefix(2))
            let cents = Int(centsStr) ?? 0
            // Sub-dollar amounts read as just cents (avoid "zero dollars").
            if dollars == 0, cents > 0 {
                guard let centsWords = EnglishNumberWords.cardinal(cents) else { return nil }
                let unit = cents == 1 ? names.sub : names.subPlural
                return "\(centsWords) \(unit)"
            }
            guard let dollarsWords = EnglishNumberWords.cardinal(dollars) else { return nil }
            let dollarUnit = dollars == 1 ? names.unit : unitPlural
            if cents == 0 { return "\(dollarsWords) \(dollarUnit)" }
            guard let centsWords = EnglishNumberWords.cardinal(cents) else { return nil }
            let centUnit = cents == 1 ? names.sub : names.subPlural
            return "\(dollarsWords) \(dollarUnit), \(centsWords) \(centUnit)"
        }
        guard let value = Int(amount), let words = EnglishNumberWords.cardinal(value) else { return nil }
        let unit = value == 1 ? names.unit : unitPlural
        return "\(words) \(unit)"
    }
}
