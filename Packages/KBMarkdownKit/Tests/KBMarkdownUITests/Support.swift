import KBMarkdown
import Testing

/// The source text `range` covers.
func slice(_ source: String, _ range: MarkdownSourceRange) -> String {
    guard let bounds = range.range(in: source) else { return "<out of range \(range)>" }
    return String(source[bounds])
}

/// A `[A1]`-style citation recognizer whose value is the label inside the brackets.
func citationRecognizer() throws -> MarkdownTokenRecognizer {
    try MarkdownTokenRecognizer(kind: "citation", pattern: #"\[([A-Z][0-9]+)\]"#) { $0.captures[1] }
}

/// The fastest of `runs` timings of `work`, so a busy machine measures the work, not the load.
@MainActor
func fastest(of runs: Int, _ work: () -> Void) -> Duration {
    let clock = ContinuousClock()
    return (0..<runs).map { _ in clock.measure(work) }.min() ?? .zero
}
