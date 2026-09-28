import Foundation

/// Custom pronunciation overrides as **spoken-text substitutions**: "when you'd
/// speak TERM, say REPLACEMENT instead." The long-tail escape hatch for words the
/// rules-based normalizer mispronounces — user-managed in Settings, applied to the
/// spoken side before synthesis (never to the display text). Because the swap can
/// change word count, it flows through `PlaybackController.spokenTextTransform`, so
/// `SpokenTextAlignment` remaps the karaoke timeline back onto the display words.
///
/// Pure and dependency-free (Foundation `Regex` only) so it stays `swift test`-able.
/// Language-aware: English matches on whole words (`\b`, case-insensitive by
/// default); Japanese has no word boundaries, so it matches exact substrings.
public enum SpokenTextSubstitution {

    /// One override rule. `language` scopes the rule to a reading language (a kanji
    /// reading override only makes sense in Japanese); `caseSensitive` defaults off
    /// for English so "Pocket"/"pocket" both match.
    public struct Rule: Sendable, Equatable {
        public let term: String
        public let replacement: String
        public let language: SubstitutionLanguage
        public let caseSensitive: Bool

        public init(
            term: String,
            replacement: String,
            language: SubstitutionLanguage,
            caseSensitive: Bool = false
        ) {
            self.term = term
            self.replacement = replacement
            self.language = language
            self.caseSensitive = caseSensitive
        }
    }

    /// The languages an override can target. Mirrors the speech languages without
    /// pulling the feature-layer `SpeechLanguage` into dependency-free KBCore.
    public enum SubstitutionLanguage: String, Sendable, CaseIterable {
        case english
        case japanese
    }

    /// Apply every rule scoped to `language` to `text`, longest-term-first so a
    /// longer term wins over a shorter one it contains (e.g. "Pocket Reader" before
    /// "Pocket"). Rules whose term is empty are skipped. Returns `text` unchanged
    /// when no rule applies (the empty-list common case is a no-op).
    public static func apply(
        _ text: String,
        rules: [Rule],
        language: SubstitutionLanguage
    ) -> String {
        let scoped = rules
            .filter { $0.language == language && !$0.term.isEmpty }
            // Longest term first: prevents a short term from consuming a character of
            // a longer term before the longer one gets to match.
            .sorted { $0.term.count > $1.term.count }
        guard !scoped.isEmpty else { return text }

        var out = text
        for rule in scoped {
            out = apply(rule, to: out, language: language)
        }
        return out
    }

    private static func apply(
        _ rule: Rule, to text: String, language: SubstitutionLanguage
    ) -> String {
        switch language {
        case .english:
            return applyWholeWord(rule, to: text)
        case .japanese:
            // No word boundaries in Japanese — exact substring swap. Japanese terms
            // are inherently case-irrelevant, so caseSensitive is ignored here.
            return text.replacingOccurrences(of: rule.term, with: rule.replacement)
        }
    }

    /// Whole-word replacement around an escaped term (`\bTERM\b`), case-insensitive
    /// unless the rule opts in. Falls back to a literal substring swap if the term
    /// has no word characters to anchor a boundary on (e.g. "&" → "and").
    private static func applyWholeWord(_ rule: Rule, to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: rule.term)
        // `\b` only fires next to a word character; a symbol-only term can't anchor
        // one, so swap it literally instead of silently doing nothing.
        let canAnchor = rule.term.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard canAnchor else {
            return text.replacingOccurrences(of: rule.term, with: rule.replacement)
        }
        let pattern = "\\b\(escaped)\\b"
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Escape `$` in the replacement so a literal "$3" in a reading isn't read as
        // a capture-group reference.
        let template = NSRegularExpression.escapedTemplate(for: rule.replacement)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template)
    }
}
