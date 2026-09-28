import Foundation

/// Title/suffix abbreviations, dotted acronyms, footnote stripping, URLs, and the
/// `St.` Street-vs-Saint disambiguation. Ported from abogen's
/// `expand_titles_and_suffixes` / `_normalize_dotted_acronyms`.
extension SpokenTextNormalizer {

    private static let titleAbbreviations: [String: String] = [
        "mr": "Mister", "mrs": "Missus", "ms": "Miz", "dr": "Doctor",
        "prof": "Professor", "rev": "Reverend", "gen": "General",
        "sgt": "Sergeant", "lt": "Lieutenant", "col": "Colonel", "capt": "Captain"]

    private static let suffixAbbreviations: [String: String] = [
        "jr": "Junior", "sr": "Senior"]

    static func expandTitlesAndSuffixes(_ text: String) -> String {
        var out = text
        out = expandSaintVsStreet(out)
        let titleKeys = titleAbbreviations.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        out = replaceMatches(in: out, pattern: #"\b("# + titleKeys + #")\."#, options: [.caseInsensitive]) { groups in
            guard let full = titleAbbreviations[groups[1].lowercased()] else { return nil }
            return matchCasing(template: groups[1], replacement: full)
        }
        let suffixKeys = suffixAbbreviations.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        out = replaceMatches(in: out, pattern: #"\b("# + suffixKeys + #")\."#, options: [.caseInsensitive]) { groups in
            guard let full = suffixAbbreviations[groups[1].lowercased()] else { return nil }
            return matchCasing(template: groups[1], replacement: full)
        }
        return out
    }

    /// "St." is Saint when it *precedes* a capitalized name ("St. Peter"), Street
    /// when it *follows* one ("Main St."). The address pass already handled the
    /// trailing-Street case; here we only expand the leading-Saint case.
    private static func expandSaintVsStreet(_ text: String) -> String {
        let pattern = #"\bSt\.\s+(?=[A-Z][a-z])"#
        return replaceMatches(in: text, pattern: pattern) { _ in "Saint " }
    }

    /// Collapse dotted acronyms so the synthesizer doesn't say "dot": "U.S.A." →
    /// "USA", "p.m." is left to the time pass (lowercase, not matched here).
    static func normalizeDottedAcronyms(_ text: String) -> String {
        guard text.contains(".") else { return text }
        let pattern = #"\b(?:[A-Z]\.){1,}[A-Z]\.?(?=\W|$)"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            groups[0].replacingOccurrences(of: ".", with: "")
        }
    }

    /// Strip footnote markers: bracketed `[12]` outright, and a trailing reference
    /// digit glued to a word ("sentence12" → "sentence"). Conservative: only acts
    /// on a letter-run immediately followed by digits at a word boundary.
    static func stripFootnotes(_ text: String) -> String {
        guard text.contains(where: { $0.isNumber }) else { return text }
        var out = replaceMatches(in: text, pattern: #"\[\d+\]"#) { _ in "" }
        out = replaceMatches(in: out, pattern: #"\b([A-Za-z]{2,})(\d{1,3})\b"#) { groups in
            // Only strip when it reads like a footnote ref, not a model name (avoid
            // "MP3" etc.). Heuristic: lowercase word + short trailing number.
            guard groups[1] == groups[1].lowercased() else { return nil }
            return groups[1]
        }
        return out
    }

    /// Speak a URL/domain as "example dot com" so the synthesizer doesn't choke on
    /// the punctuation. Requires an http(s)/www prefix or a multi-label domain to
    /// avoid eating decimals and dotted acronyms.
    static func normalizeURLs(_ text: String) -> String {
        guard text.range(of: #"https?://|www\."#, options: .regularExpression) != nil else { return text }
        let pattern = #"(https?://)?(www\.)([a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+)(/[^\s]*)?"#
        var out = replaceMatches(in: text, pattern: pattern) { groups in
            spokenDomain(groups[3])
        }
        let bare = #"(https?://)([a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+)(/[^\s]*)?"#
        out = replaceMatches(in: out, pattern: bare) { groups in
            spokenDomain(groups[2])
        }
        return out
    }

    private static func spokenDomain(_ domain: String) -> String? {
        var host = domain
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.replacingOccurrences(of: ".", with: " dot ")
    }

    /// Capitalization matcher: ALL-CAPS → upper, Titlecase → capitalized, else the
    /// replacement as-is (already capitalized in our maps).
    static func matchCasing(template: String, replacement: String) -> String {
        if template == template.uppercased() && template != template.lowercased() {
            return replacement.uppercased()
        }
        return replacement
    }
}
