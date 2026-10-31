import KBMarkdown
import SwiftUI

/// Renders a `MarkdownDocument`: blocks stacked lazily, headings on the style's type scale,
/// paragraphs as `Text` with links and tokens, quotes with a rule, nested lists with markers
/// and read-only task boxes, tables in a `Grid`, and code in a monospaced panel that scrolls
/// sideways. Text is selectable.
///
/// The view does not scroll; put it in a `ScrollView`, where its `LazyVStack` builds only the
/// blocks on screen.
public struct MarkdownView: View {
    private let document: MarkdownDocument
    private let context: RenderContext
    private let onTokenTap: ((MarkdownToken) -> Void)?
    private let onLinkTap: ((URL) -> Void)?

    /// A view of `document`.
    ///
    /// - Parameters:
    ///   - style: Fonts, spacing and colours.
    ///   - codeBlock: Replaces a fenced block with the caller's view: given the fence's
    ///     language (nil for none) and the code, return a view, or nil for the default panel.
    ///     This is how a `mermaid` fence becomes a diagram.
    ///   - tokenPresentation: How a token shows; nil (the default) puts its value in a capsule.
    ///   - onTokenTap: Called when a token is tapped. Tokens are not tappable without it.
    ///   - onLinkTap: Called when a link is tapped; nil opens it with the system.
    public init(
        _ document: MarkdownDocument,
        style: MarkdownStyle = MarkdownStyle(),
        codeBlock: @escaping (_ language: String?, _ code: String) -> AnyView? = { _, _ in nil },
        tokenPresentation: @escaping (MarkdownToken) -> MarkdownTokenPresentation? = { _ in nil },
        onTokenTap: ((MarkdownToken) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.document = document
        self.context = RenderContext(
            style: style, codeBlock: codeBlock, tokenPresentation: tokenPresentation,
            tokensTappable: onTokenTap != nil)
        self.onTokenTap = onTokenTap
        self.onLinkTap = onLinkTap
    }

    /// A view of the document `source` holds, parsed with `parser`.
    public init(
        source: String,
        parser: MarkdownParser = MarkdownParser(),
        style: MarkdownStyle = MarkdownStyle(),
        codeBlock: @escaping (_ language: String?, _ code: String) -> AnyView? = { _, _ in nil },
        tokenPresentation: @escaping (MarkdownToken) -> MarkdownTokenPresentation? = { _ in nil },
        onTokenTap: ((MarkdownToken) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.init(
            parser.parse(source), style: style, codeBlock: codeBlock, tokenPresentation: tokenPresentation,
            onTokenTap: onTokenTap, onLinkTap: onLinkTap)
    }

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: context.style.blockSpacing) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, context: context, listDepth: 0)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction(handler: open))
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        if let token = TokenLink.token(from: url) {
            onTokenTap?(token)
            return .handled
        }
        guard let onLinkTap else { return .systemAction }
        onLinkTap(url)
        return .handled
    }
}

// MARK: - Blocks

private struct BlockView: View {
    let block: MarkdownBlock
    let context: RenderContext
    let listDepth: Int

    var body: some View {
        switch block {
        case let .heading(level, content, _):
            InlineTextView(content: content, context: context)
                .font(context.style.headingFont(level: level))
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.headingLevel(level))
        case let .paragraph(content, _):
            InlineTextView(content: content, context: context)
                .font(context.style.bodyFont)
        case let .blockQuote(blocks, _):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(context.style.quoteRuleColor)
                    .frame(width: 3)
                BlockStack(blocks: blocks, context: context, listDepth: listDepth)
                    .foregroundStyle(.secondary)
            }
        case let .list(list, _):
            ListView(list: list, context: context, depth: listDepth)
        case let .table(table, _):
            TableView(table: table, context: context)
        case let .code(code, _):
            if let custom = context.codeBlock(code.language, code.code) {
                custom
            } else {
                CodePanel(code: code, style: context.style)
            }
        case .thematicBreak:
            Divider()
        case let .html(html, _):
            Text(verbatim: html)
                .font(context.style.codeFont)
                .foregroundStyle(.secondary)
        }
    }

    private static func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

/// Blocks inside a quote or list item.
private struct BlockStack: View {
    let blocks: [MarkdownBlock]
    let context: RenderContext
    let listDepth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: context.style.blockSpacing / 2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, context: context, listDepth: listDepth)
            }
        }
    }
}

/// A run of inlines as one `Text`, drawn with token capsules when it has any.
private struct InlineTextView: View {
    let content: [MarkdownInline]
    let context: RenderContext

    var body: some View {
        let built = InlineTextBuilder(context: context).text(content)
        if built.hasCapsules {
            built.text.textRenderer(TokenCapsuleRenderer())
        } else {
            built.text
        }
    }
}

private struct ListView: View {
    let list: MarkdownList
    let context: RenderContext
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: context.style.listItemSpacing) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, at: index)
                        .frame(minWidth: context.style.listMarkerWidth, alignment: .trailing)
                    BlockStack(blocks: item.blocks, context: context, listDepth: depth + 1)
                }
            }
        }
        .font(context.style.bodyFont)
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, at index: Int) -> some View {
        switch (item.task, list.kind) {
        case (.checked?, _):
            Image(systemName: "checkmark.square.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("Completed", bundle: .module))
        case (.unchecked?, _):
            Image(systemName: "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Not completed", bundle: .module))
        case let (nil, .ordered(start)):
            Text(verbatim: "\(start + index).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case (nil, .unordered):
            Text(verbatim: ["•", "◦", "▪"][depth % 3])
                .foregroundStyle(.secondary)
        }
    }
}

private struct TableView: View {
    let table: MarkdownTable
    let context: RenderContext

    var body: some View {
        HorizontalOverflow {
            grid
        }
    }

    private var grid: some View {
        let columns = table.columnCount
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(table.header, column)
                            .bold()
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(row, column)
                        }
                    }
                }
            }
            .font(context.style.bodyFont)
            .padding(.vertical, 4)
    }

    private func cell(_ row: MarkdownTableRow, _ column: Int) -> some View {
        InlineTextView(content: column < row.cells.count ? row.cells[column].content : [], context: context)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch column < table.alignments.count ? table.alignments[column] : nil {
        case .center?: .center
        case .trailing?: .trailing
        case .leading?, nil: .leading
        }
    }
}

private struct CodePanel: View {
    let code: MarkdownCodeBlock
    let style: MarkdownStyle

    var body: some View {
        HorizontalOverflow {
            Text(verbatim: code.code)
                .font(style.codeFont)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Content at its ideal width: as is when it fits, in a sideways `ScrollView` when it does
/// not. Long code lines and wide tables scroll rather than wrap; short ones carry no scroll
/// view at all (which `ImageRenderer` cannot draw into).
private struct HorizontalOverflow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content()
                .fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                content()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}
