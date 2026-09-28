import Foundation

/// Dates, times, and address-abbreviation passes. English-default ordering
/// (month-day-year). Ported from abogen's `_normalize_dates` / `_normalize_times`
/// / `_normalize_address_abbreviations`.
extension SpokenTextNormalizer {

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"]

    private static let monthAbbrev: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12]

    static func normalizeDates(_ text: String) -> String {
        var out = text
        // ISO-ish: YYYY/MM/DD or YYYY-MM-DD → "Month Dayth, year".
        let iso = #"\b(\d{4})[/-](\d{1,2})[/-](\d{1,2})\b"#
        out = replaceMatches(in: out, pattern: iso) { groups in
            guard let year = Int(groups[1]), let month = Int(groups[2]), let day = Int(groups[3]),
                  (1...12).contains(month), (1...31).contains(day),
                  let ordinal = EnglishNumberWords.ordinal(day),
                  let yearWords = yearWords(year) ?? EnglishNumberWords.cardinal(year) else { return nil }
            return "\(monthNames[month - 1]) \(ordinal), \(yearWords)"
        }
        // Month name + day + year: "December 15, 2025".
        let monthAlt = #"Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?"#
            + #"|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?"#
        let mdy = #"\b("# + monthAlt + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s*,\s*(\d{4})\b"#
        out = replaceMatches(in: out, pattern: mdy, options: [.caseInsensitive]) { groups in
            let key = groups[1].lowercased().replacingOccurrences(of: ".", with: "")
            guard let month = monthAbbrev[key], let day = Int(groups[2]), let year = Int(groups[3]),
                  let ordinal = EnglishNumberWords.ordinal(day),
                  let yearWords = yearWords(year) ?? EnglishNumberWords.cardinal(year) else { return nil }
            return "\(monthNames[month - 1]) \(ordinal), \(yearWords)"
        }
        return out
    }

    static func normalizeTimes(_ text: String) -> String {
        // Strip the dots inside a meridian and ensure a space: "5 p.m." → "5 pm".
        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b"#
        return replaceMatches(in: text, pattern: pattern, options: [.caseInsensitive]) { groups in
            let hour = groups[1]
            let minute = groups[2]
            let meridian = groups[3].lowercased().replacingOccurrences(of: ".", with: "")
            return minute.isEmpty ? "\(hour) \(meridian)" : "\(hour):\(minute) \(meridian)"
        }
    }

    static func normalizeAddressAbbreviations(_ text: String) -> String {
        let mapping: [String: String] = [
            "st": "Street", "rd": "Road", "ave": "Avenue",
            "blvd": "Boulevard", "ln": "Lane"]
        // Only a trailing address abbr (followed by end/punctuation) and only after a
        // word — so "St." as a sentence-leading "Saint" is left to the titles pass.
        let pattern = #"(\b\w+\s+)(St|Rd|Ave|Blvd|Ln)\.(?=\s*(?:,|\.|!|\?|$))"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            guard let full = mapping[groups[2].lowercased()] else { return nil }
            return groups[1] + matchCasing(template: groups[2], replacement: full)
        }
    }
}
