import KBMarkdown
import SwiftUI

/// A plain-text Markdown source editor that styles the source as it is typed: headings,
/// emphasis and strong (markers dimmed), inline and fenced code in monospace, links, list and
/// quote markers, and the parser's registered tokens.
///
/// A `UITextView` on iOS and an `NSTextView` on macOS, both TextKit 2. The bound string is
/// the only truth and round-trips exactly: styling never changes a character. See
/// `MarkdownEditorController` for the rules that keep typing, undo and input methods intact.
public struct MarkdownEditor: View {
    @Binding private var text: String
    private let highlighter: MarkdownSourceHighlighter
    private let style: MarkdownEditorStyle
    private let debounce: Duration

    /// An editor over `text`. `parser` supplies the token recognizers to highlight; styling
    /// follows `debounce` after the last keystroke. A changed parser takes effect from the
    /// next keystroke; a changed style restyles at once.
    public init(
        text: Binding<String>,
        parser: MarkdownParser = MarkdownParser(),
        style: MarkdownEditorStyle = MarkdownEditorStyle(),
        debounce: Duration = .milliseconds(150)
    ) {
        _text = text
        self.highlighter = MarkdownSourceHighlighter(parser: parser)
        self.style = style
        self.debounce = debounce
    }

    public var body: some View {
        EditorRepresentable(text: $text, highlighter: highlighter, style: style, debounce: debounce)
    }
}

#if canImport(UIKit)
private struct EditorRepresentable: UIViewRepresentable {
    @Binding var text: String
    let highlighter: MarkdownSourceHighlighter
    let style: MarkdownEditorStyle
    let debounce: Duration

    func makeCoordinator() -> MarkdownEditorController {
        MarkdownEditorController(text: text, highlighter: highlighter, style: style, debounce: debounce)
    }

    func makeUIView(context: Context) -> UITextView {
        context.coordinator.textView
    }

    func updateUIView(_ view: UITextView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ controller: MarkdownEditorController) {
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        controller.highlighter = highlighter
        controller.debounce = debounce
        controller.style = style
        controller.setText(text)
    }
}
#elseif canImport(AppKit)
private struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let highlighter: MarkdownSourceHighlighter
    let style: MarkdownEditorStyle
    let debounce: Duration

    func makeCoordinator() -> MarkdownEditorController {
        MarkdownEditorController(text: text, highlighter: highlighter, style: style, debounce: debounce)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = context.coordinator.textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ controller: MarkdownEditorController) {
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        controller.highlighter = highlighter
        controller.debounce = debounce
        controller.style = style
        controller.setText(text)
    }
}
#endif
