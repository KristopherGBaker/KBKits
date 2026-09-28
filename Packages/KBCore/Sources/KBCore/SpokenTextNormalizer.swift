import Foundation

/// Rewrites a sentence's **spoken** form so Kokoro (and AVSpeech) pronounce
/// numbers, years, currency, dates, abbreviations, and acronyms correctly — an
/// orthographic (text→text) port of abogen's `kokoro_text_normalization.py`,
/// run *before* MisakiSwift G2P. Pure and dependency-free so it lives in
/// `KBCore` and is exercised by `swift test`.
///
/// **Unlike `SpokenTextTransform.hyphenatedCompoundsToSpaces`, this is NOT
/// length-preserving** — "1995" → "nineteen ninety-five" expands one display word
/// into several spoken words, so a raw spoken-offset no longer indexes the same
/// display character. The karaoke highlight maps audio timing back to *display*
/// words by UTF-16 offset, so applying this naively would desync the cursor from
/// the first expansion onward. See `SpokenTextAlignment` and the scheduler's
/// timeline remap for how an expanded display token is collapsed back to a single
/// highlighted unit.
public enum SpokenTextNormalizer {

    /// Per-pass on/off switches. All default ON; the orchestrator runs each pass in
    /// a fixed order. Exposed so tests can isolate a pass and callers can dial back
    /// to conservative subsets if a pass ever proves risky on real text.
    public struct Options: Sendable, Equatable {
        public var dates: Bool
        public var times: Bool
        public var dottedAcronyms: Bool
        public var addressAbbreviations: Bool
        public var currency: Bool
        public var numbers: Bool       // grouped/decimal/integer/range/fraction
        public var yearStyle: Bool     // 4-digit year heuristic inside `numbers`
        public var romanNumerals: Bool
        public var titlesAndSuffixes: Bool
        public var footnotes: Bool     // strip [12] and trailing ref digits
        public var urls: Bool
        public var capsTaming: Bool
        public var terminalPunctuation: Bool

        public init(
            dates: Bool = true,
            times: Bool = true,
            dottedAcronyms: Bool = true,
            addressAbbreviations: Bool = true,
            currency: Bool = true,
            numbers: Bool = true,
            yearStyle: Bool = true,
            romanNumerals: Bool = true,
            titlesAndSuffixes: Bool = true,
            footnotes: Bool = true,
            urls: Bool = true,
            capsTaming: Bool = true,
            terminalPunctuation: Bool = true
        ) {
            self.dates = dates
            self.times = times
            self.dottedAcronyms = dottedAcronyms
            self.addressAbbreviations = addressAbbreviations
            self.currency = currency
            self.numbers = numbers
            self.yearStyle = yearStyle
            self.romanNumerals = romanNumerals
            self.titlesAndSuffixes = titlesAndSuffixes
            self.footnotes = footnotes
            self.urls = urls
            self.capsTaming = capsTaming
            self.terminalPunctuation = terminalPunctuation
        }

        public static let `default` = Options()
    }

    /// Normalize a sentence's spoken text. Order mirrors abogen's
    /// `normalize_for_pipeline`: structured forms (dates/times/acronyms) before
    /// number spelling, then titles, then the terminal-punctuation guarantee, then
    /// caps taming, with a final whitespace tidy.
    public static func normalize(_ text: String, options: Options = .default) -> String {
        guard !text.isEmpty else { return text }
        var out = text

        if options.urls { out = normalizeURLs(out) }
        if options.footnotes { out = stripFootnotes(out) }
        if options.dates { out = normalizeDates(out) }
        if options.times { out = normalizeTimes(out) }
        if options.dottedAcronyms { out = normalizeDottedAcronyms(out) }
        if options.addressAbbreviations { out = normalizeAddressAbbreviations(out) }
        if options.currency { out = normalizeCurrency(out) }
        if options.numbers { out = normalizeNumbers(out, yearStyle: options.yearStyle) }
        if options.romanNumerals { out = normalizeRomanNumerals(out) }
        if options.titlesAndSuffixes { out = expandTitlesAndSuffixes(out) }
        if options.capsTaming { out = tameAllCaps(out) }
        if options.terminalPunctuation { out = ensureTerminalPunctuation(out) }

        out = collapseWhitespace(out)
        return out
    }

    /// Collapse runs of intra-line spaces/tabs introduced by replacements (never
    /// touches newlines, which carry block structure). A replacement that drops a
    /// token can otherwise leave a double space the synthesizer reads as a pause.
    static func collapseWhitespace(_ text: String) -> String {
        guard text.contains("  ") || text.contains("\t") else { return text }
        return text
            .components(separatedBy: "\n")
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: true)
                    .map { $0.replacingOccurrences(of: "\t", with: "") }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}
