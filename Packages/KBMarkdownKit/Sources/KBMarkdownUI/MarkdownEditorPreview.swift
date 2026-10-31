import KBMarkdown
import SwiftUI

/// The source editor, the rendered preview, or both side by side, over one string.
///
/// The string stays the only truth: the preview is re-parsed from it, debounced and off the
/// main actor, so typing never waits on rendering. Pair it with `MarkdownEditorModePicker`
/// (or any control bound to the same mode) for a preview toggle.
public struct MarkdownEditorPreview: View {
    /// What the helper shows.
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case edit
        case preview
        case split
    }

    @Binding private var text: String
    @Binding private var mode: Mode
    private let parser: MarkdownParser
    private let editorStyle: MarkdownEditorStyle
    private let style: MarkdownStyle
    private let codeBlock: (_ language: String?, _ code: String) -> AnyView?
    private let tokenPresentation: (MarkdownToken) -> MarkdownTokenPresentation?
    private let onTokenTap: ((MarkdownToken) -> Void)?
    private let debounce: Duration
    @State private var document: MarkdownDocument?

    /// The helper over `text`, showing `mode`. `parser`'s recognizers drive both halves; the
    /// rest configure the editor and the preview as `MarkdownEditor` and `MarkdownView` do.
    public init(
        text: Binding<String>,
        mode: Binding<Mode>,
        parser: MarkdownParser = MarkdownParser(),
        editorStyle: MarkdownEditorStyle = MarkdownEditorStyle(),
        style: MarkdownStyle = MarkdownStyle(),
        codeBlock: @escaping (_ language: String?, _ code: String) -> AnyView? = { _, _ in nil },
        tokenPresentation: @escaping (MarkdownToken) -> MarkdownTokenPresentation? = { _ in nil },
        onTokenTap: ((MarkdownToken) -> Void)? = nil,
        debounce: Duration = .milliseconds(150)
    ) {
        _text = text
        _mode = mode
        self.parser = parser
        self.editorStyle = editorStyle
        self.style = style
        self.codeBlock = codeBlock
        self.tokenPresentation = tokenPresentation
        self.onTokenTap = onTokenTap
        self.debounce = debounce
    }

    public var body: some View {
        switch mode {
        case .edit:
            editor
        case .preview:
            preview
        case .split:
            HStack(spacing: 0) {
                editor
                Divider()
                preview
            }
        }
    }

    private var editor: some View {
        MarkdownEditor(text: $text, parser: parser, style: editorStyle, debounce: debounce)
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(
                document ?? parser.parse(text), style: style, codeBlock: codeBlock,
                tokenPresentation: tokenPresentation, onTokenTap: onTokenTap)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: text) {
            // The first render parses inline; later edits re-parse after the debounce.
            guard document != nil else {
                document = parser.parse(text)
                return
            }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let parser = parser
            let source = text
            let parsed = await Task.detached(priority: .userInitiated) { parser.parse(source) }.value
            guard !Task.isCancelled else { return }
            document = parsed
        }
    }
}

/// A segmented control choosing what `MarkdownEditorPreview` shows.
public struct MarkdownEditorModePicker: View {
    @Binding private var mode: MarkdownEditorPreview.Mode

    /// A picker bound to `mode`.
    public init(mode: Binding<MarkdownEditorPreview.Mode>) {
        _mode = mode
    }

    public var body: some View {
        Picker(selection: $mode) {
            Text("Edit", bundle: .module).tag(MarkdownEditorPreview.Mode.edit)
            Text("Preview", bundle: .module).tag(MarkdownEditorPreview.Mode.preview)
            Text("Split", bundle: .module).tag(MarkdownEditorPreview.Mode.split)
        } label: {
            Text("Editor mode", bundle: .module)
        }
        .pickerStyle(.segmented)
    }
}
