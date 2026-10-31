import KBMarkdown
import Testing

/// A document of `lines` lines mixing every construct the parser and highlighter handle.
func largeDocument(lines: Int) -> String {
    let section = [
        "## Section heading with *emphasis*",
        "",
        "A paragraph with **strong**, _em_, `code`, a [link](https://example.com/page) and [A1] [B2].",
        "It continues on a second line with ~~strike~~ and 日本語のテキスト [C3].",
        "",
        "> A quote with *style*",
        "> and a second line [D4]",
        "",
        "- item one",
        "  - nested item",
        "    - deeper [E5]",
        "- [x] task item",
        "",
        "| Col | Value |",
        "|:----|------:|",
        "| *a* | `1` |",
        "",
        "```swift",
        "let value = 42 // [F6] not a token",
        "```",
        ""
    ]
    var out: [String] = []
    out.reserveCapacity(lines)
    while out.count < lines { out.append(section[out.count % section.count]) }
    return out.joined(separator: "\n")
}

/// The fastest of `runs` timings of `work`, so a busy machine measures the work, not the load.
func fastest(of runs: Int, _ work: () -> Void) -> Duration {
    let clock = ContinuousClock()
    return (0..<runs).map { _ in clock.measure(work) }.min() ?? .zero
}

@Suite("Performance")
struct PerformanceTests {
    /// The documented debug bound (README): parse plus highlights of 2,000 lines.
    static let bound = Duration.milliseconds(150)

    @Test("parsing and highlighting 2,000 lines stays under 150 ms in debug")
    func parseAndHighlight() throws {
        let source = largeDocument(lines: 2_000)
        #expect(source.split(separator: "\n", omittingEmptySubsequences: false).count == 2_000)
        let highlighter = MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()]))
        var count = 0
        let elapsed = fastest(of: 3) { count = highlighter.highlights(in: source).count }
        #expect(count > 2_000)
        #expect(elapsed < Self.bound, "took \(elapsed)")
    }
}
