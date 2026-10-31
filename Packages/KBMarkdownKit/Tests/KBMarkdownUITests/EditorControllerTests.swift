#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import KBMarkdown
import Testing
@testable import KBMarkdownUI

/// The editor's text view on macOS, driven the way AppKit drives it: typing through
/// `insertText`, composition through `setMarkedText`. No window unless a test needs undo.
@MainActor
@Suite("Editor controller (macOS)")
struct EditorControllerTests {
    private func controller(_ text: String) throws -> MarkdownEditorController {
        MarkdownEditorController(
            text: text,
            highlighter: MarkdownSourceHighlighter(parser: MarkdownParser(recognizers: [try citationRecognizer()])),
            style: EditorStylingTests.style,
            debounce: .milliseconds(5))
    }

    private func isBold(_ controller: MarkdownEditorController, at index: Int) -> Bool {
        (controller.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.isBold == true
    }

    @Test("the text view is TextKit 2, plain text, with undo and no smart substitutions")
    func textKit2() throws {
        let editor = try controller("# Hi")
        #expect(editor.textView.textLayoutManager != nil)
        #expect(!editor.textView.isRichText)
        #expect(editor.textView.allowsUndo)
        #expect(!editor.textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.textView.isAutomaticDashSubstitutionEnabled)
        #expect(editor.text == "# Hi")
        #expect(editor.appliedPasses == 1)
    }

    @Test("typing reports the exact text and restyles after the debounce, keeping the selection")
    func typingRestyles() async throws {
        let editor = try controller("plain ")
        var reported: [String] = []
        editor.onTextChange = { reported.append($0) }
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        editor.textView.insertText("**bold**", replacementRange: editor.textView.selectedRange())
        #expect(reported == ["plain **bold**"])
        #expect(!isBold(editor, at: 9), "styling waits for the debounce")
        await editor.waitForPendingRestyle()
        #expect(isBold(editor, at: 9))
        #expect(editor.text == "plain **bold**")
        #expect(editor.textView.selectedRange() == NSRange(location: 14, length: 0))
    }

    @Test("an edit during a pending pass supersedes it")
    func staleRestyleDropped() async throws {
        let editor = try controller("")
        editor.textView.insertText("**a**", replacementRange: NSRange(location: 0, length: 0))
        let passes = editor.appliedPasses
        editor.textView.insertText(" b", replacementRange: NSRange(location: 5, length: 0))
        await editor.waitForPendingRestyle()
        #expect(editor.appliedPasses == passes + 1)
        #expect(isBold(editor, at: 2))
    }

    @Test("marked text (an IME composition) is never restyled or replaced until committed")
    func markedTextIsSafe() async throws {
        let editor = try controller("# 見出し\n\n")
        let end = (editor.text as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.textView.setMarkedText(
            "にほん", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText)
        let passes = editor.appliedPasses

        editor.restyleNow()
        editor.scheduleRestyle()
        await editor.waitForPendingRestyle()
        #expect(editor.appliedPasses == passes, "no pass while composing")
        #expect(editor.setText("replaced") == false, "an outside change cannot cut a composition short")
        #expect(editor.text == "# 見出し\n\nにほん")

        editor.textView.insertText("日本", replacementRange: editor.textView.markedRange())
        #expect(!editor.hasMarkedText)
        #expect(editor.text == "# 見出し\n\n日本")
        await editor.waitForPendingRestyle()
        #expect(editor.appliedPasses > passes)
        #expect(editor.setText("replaced"))
        #expect(editor.text == "replaced")
    }

    @Test("an outside change equal to the text is a no-op; a different one replaces and restyles")
    func outsideChanges() throws {
        let editor = try controller("a")
        let passes = editor.appliedPasses
        #expect(editor.setText("a"))
        #expect(editor.appliedPasses == passes)
        #expect(editor.setText("**b**"))
        #expect(editor.text == "**b**")
        #expect(editor.appliedPasses == passes + 1)
        #expect(isBold(editor, at: 2))
    }

    @Test("undo still restores the exact text after styling passes")
    func undoSurvivesStyling() async throws {
        let editor = try controller("start")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor.textView
        let undo = try #require(editor.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.insertText(" **more**", replacementRange: NSRange(location: 5, length: 0))
        undo.endUndoGrouping()
        await editor.waitForPendingRestyle()
        #expect(isBold(editor, at: 8))
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.text == "start")
        window.contentView = nil
    }
}
#endif
