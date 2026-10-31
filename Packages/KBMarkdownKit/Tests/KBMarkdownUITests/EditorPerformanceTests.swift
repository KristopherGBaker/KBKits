import Foundation
import KBMarkdown
import SwiftUI
import Testing
@testable import KBMarkdownUI

@MainActor
@Suite("Editor performance")
struct EditorPerformanceTests {
    /// The documented debug bound (README) for a whole editor pass over 2,000 lines: parse,
    /// highlights, and every attribute written to the text storage.
    static let bound = Duration.milliseconds(150)

    @Test("a full styling pass over 2,000 lines stays under 150 ms in debug")
    func fullPass() throws {
        let line = "Text with **strong**, `code`, [link](https://e.x) and [A1]; 日本語 _em_."
        let blocks = [
            "## Heading", "", line, line, "", "- item", "  - nested [B2]", "", "```swift", "let x = 1", "```", ""
        ]
        let source = (0..<2_000).map { blocks[$0 % blocks.count] }.joined(separator: "\n")
        let highlighter = MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()]))
        let style = MarkdownEditorStyle()
        let storage = NSTextStorage(string: source)
        let elapsed = fastest(of: 3) {
            style.apply(highlighter.highlights(in: source), to: storage)
        }
        #expect(storage.string == source)
        #expect(elapsed < Self.bound, "took \(elapsed)")
    }
}
