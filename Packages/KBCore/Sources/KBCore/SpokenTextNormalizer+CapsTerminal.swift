import Foundation

/// ALL-CAPS taming and the terminal-punctuation guarantee. Caps taming sentence-
/// cases shouted runs while preserving genuine acronyms; the terminal pass appends
/// a period to an unpunctuated sentence so Kokoro applies end-of-utterance prosody
/// (it synthesizes one sentence at a time). Ported from abogen.
extension SpokenTextNormalizer {

    private static let acronymAllowlist: Set<String> = [
        "AI", "API", "CPU", "DIY", "GPU", "HTML", "HTTP", "HTTPS", "ID", "JSON",
        "MP3", "MP4", "NASA", "OCR", "PDF", "SQL", "TV", "TTS", "UK", "UN", "UFO",
        "OK", "URL", "USA", "US", "VR", "CEO", "FBI", "CIA", "DNA", "GPS", "USB",
        "PIN", "ATM", "FAQ", "ASAP", "RSVP", "IQ", "PR", "HR", "IT"]

    private static let romanLetters = Set("IVXLCDM")

    /// Sentence-case a run of 2+ all-caps words ("THIS IS A TEST" → "This is a
    /// test"), but keep any token that is a known acronym or a short Roman numeral.
    static func tameAllCaps(_ text: String) -> String {
        // Match runs of caps words separated by spaces (length-aware: a lone short
        // cap token like "OK" inside lowercase prose is left alone).
        let pattern = #"\b[A-Z][A-Z0-9'’-]*(?:\s+[A-Z][A-Z0-9'’-]*){1,}\b"#
        return replaceMatches(in: text, pattern: pattern) { groups in
            let segment = groups[0]
            guard shouldTame(segment) else { return nil }
            return sentenceCase(segment)
        }
    }

    private static func shouldTame(_ segment: String) -> Bool {
        let letters = segment.filter { $0.isLetter }
        guard letters.count > 1, !letters.contains(where: { $0.isLowercase }) else { return false }
        return true
    }

    private static func sentenceCase(_ segment: String) -> String {
        let words = segment.split(separator: " ", omittingEmptySubsequences: false)
        var firstWordSeen = false
        let mapped = words.map { word -> String in
            let str = String(word)
            if preserveCaps(str) {
                firstWordSeen = true
                return str
            }
            let lowered = str.lowercased()
            if !firstWordSeen {
                firstWordSeen = true
                return capitalizeFirstLetter(lowered)
            }
            return lowered
        }
        return mapped.joined(separator: " ")
    }

    private static func preserveCaps(_ word: String) -> Bool {
        let letters = String(word.filter { $0.isLetter })
        guard !letters.isEmpty else { return false }
        var base = letters
        if word.uppercased().hasSuffix("'S"), letters.count > 1 {
            base = String(letters.dropLast())
        }
        if acronymAllowlist.contains(base.uppercased()) { return true }
        if base.count <= 7, base.uppercased().allSatisfy({ romanLetters.contains($0) }) { return true }
        return false
    }

    private static func capitalizeFirstLetter(_ word: String) -> String {
        guard let idx = word.firstIndex(where: { $0.isLetter }) else { return word }
        return String(word[..<idx]) + word[idx].uppercased() + word[word.index(after: idx)...]
    }

    // MARK: Terminal punctuation

    private static let terminalPunctuation: Set<Character> = [".", "?", "!", "…", ";", ":"]
    private static let closingPunctuation = Set("\"'”’)]}»›")

    /// Append a period to a sentence that ends without terminal punctuation,
    /// respecting trailing closing quotes/brackets and ellipses. Operates per line
    /// so block structure (newlines) is preserved.
    static func ensureTerminalPunctuation(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map(amendLine).joined(separator: "\n")
    }

    private static func amendLine(_ line: String) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        let stripped = String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        let trailingWS = String(line.dropFirst(stripped.count))

        // Peel trailing closing punctuation.
        var closers = ""
        var body = stripped
        while let last = body.last, closingPunctuation.contains(last) {
            closers = String(last) + closers
            body.removeLast()
        }
        guard let last = body.last else { return line }
        if body.hasSuffix("...") || body.hasSuffix("…") { return line }
        if terminalPunctuation.contains(last) { return line }
        return body + "." + closers + trailingWS
    }
}
