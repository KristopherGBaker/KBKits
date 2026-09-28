import Foundation

/// Shared regex plumbing for the normalizer passes. Uses `NSRegularExpression`
/// (stable capture-group indexing + a clean "replace each match via a closure"
/// loop) rather than Swift `Regex`, whose builder ergonomics fight closure-based
/// substitution. Caches compiled patterns since each pass runs per sentence.
extension SpokenTextNormalizer {

    private static let regexCache = RegexCache()

    final class RegexCache: @unchecked Sendable {
        private var store: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
            let key = "\(options.rawValue)|\(pattern)"
            lock.lock(); defer { lock.unlock() }
            if let cached = store[key] { return cached }
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            store[key] = compiled
            return compiled
        }
    }

    /// Replace every match of `pattern`. `transform` receives the captured groups
    /// (index 0 = whole match) and returns the replacement, or nil to leave the
    /// match untouched. Matches are rewritten right-to-left so earlier ranges stay
    /// valid.
    static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        _ transform: ([String]) -> String?
    ) -> String {
        replaceMatches(in: text, pattern: pattern, options: options, withContext: false) { groups, _, _ in
            transform(groups)
        }
    }

    /// Context-aware variant: `transform` also receives the whole-match range and
    /// the full string, for passes (the year heuristic) that look around a match.
    static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        withContext: Bool,
        _ transform: ([String], Range<String.Index>, String) -> String?
    ) -> String {
        guard let regex = regexCache.regex(pattern, options: options) else { return text }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let nsRange = match.range(at: index)
                if nsRange.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(nsText.substring(with: nsRange))
                }
            }
            guard let replacement = transform(groups, matchRange, text) else { continue }
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }

    /// A `±radius`-character window of `text` around `range`, used by the year
    /// heuristic to scan for nearby "address"/era markers.
    static func contextWindow(_ text: String, around range: Range<String.Index>, radius: Int) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
            ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
            ?? text.endIndex
        return String(text[lower..<upper])
    }
}
