import Foundation
import KBMarkdown
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Owns the platform text view behind `MarkdownEditor` and keeps its styling current.
///
/// The rules that keep typing, undo, selection and input methods intact:
/// - Styling changes ATTRIBUTES only, straight on the text storage, so it never moves the
///   selection and never lands on the undo stack.
/// - Styling is recomputed from a debounced parse that runs off the main actor, and is
///   dropped when the text changed while it ran.
/// - Nothing restyles or replaces the text while the input method has marked text (a
///   Japanese composition in progress): the pass waits for the composition to end.
/// - The text view's string is the only truth; the binding just mirrors it.
@MainActor
final class MarkdownEditorController: NSObject {
    let textView: PlatformTextView
    var highlighter: MarkdownSourceHighlighter
    var style: MarkdownEditorStyle {
        didSet {
            guard style != oldValue else { return }
            applyBaseTypingAttributes()
            restyleNow()
        }
    }
    var debounce: Duration
    /// Called with the full text after every edit the user makes.
    var onTextChange: ((String) -> Void)?

    private var restyleTask: Task<Void, Never>?
    /// Bumped on every edit, so a pass computed for older text is never applied.
    private var generation = 0
    /// How many styling passes have reached the text storage, for tests.
    private(set) var appliedPasses = 0

    init(
        text: String = "",
        highlighter: MarkdownSourceHighlighter = MarkdownSourceHighlighter(),
        style: MarkdownEditorStyle = MarkdownEditorStyle(),
        debounce: Duration = .milliseconds(150)
    ) {
        self.highlighter = highlighter
        self.style = style
        self.debounce = debounce
        textView = Self.makeTextView()
        super.init()
        textView.delegate = self
        applyBaseTypingAttributes()
        replaceText(text)
        restyleNow()
    }

    // MARK: Text

    /// The source, exactly as the text view holds it.
    var text: String {
        #if canImport(UIKit)
        textView.text ?? ""
        #else
        textView.string
        #endif
    }

    /// Whether an input method is composing (marked text is showing).
    var hasMarkedText: Bool {
        #if canImport(UIKit)
        textView.markedTextRange != nil
        #else
        textView.hasMarkedText()
        #endif
    }

    /// Takes a text change from outside the editor (the binding). A no-op when it matches
    /// what the view holds, which is every time the change came from typing. Refused while
    /// marked text is active, so a composition is never cut short; returns whether the text
    /// now matches.
    @discardableResult
    func setText(_ newText: String) -> Bool {
        guard newText != text else { return true }
        guard !hasMarkedText else { return false }
        replaceText(newText)
        generation &+= 1
        restyleTask?.cancel()
        restyleNow()
        return true
    }

    private func replaceText(_ newText: String) {
        let selection = selectedRange
        #if canImport(UIKit)
        textView.text = newText
        #else
        textView.string = newText
        #endif
        let length = (newText as NSString).length
        let location = min(selection.location, length)
        selectedRange = NSRange(location: location, length: min(selection.length, length - location))
    }

    var selectedRange: NSRange {
        get { textView.selectedRange }
        set { textView.selectedRange = newValue }
    }

    // MARK: Styling

    /// Parses and styles now, on the calling (main) actor. Skipped while marked text is active.
    func restyleNow() {
        guard !hasMarkedText else { return }
        apply(highlighter.highlights(in: text))
    }

    /// Restyles after the debounce, off the main actor, unless the text changes first.
    func scheduleRestyle() {
        generation &+= 1
        let expected = generation
        let source = text
        let highlighter = highlighter
        let debounce = debounce
        restyleTask?.cancel()
        restyleTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let highlights = await Task.detached(priority: .userInitiated) {
                highlighter.highlights(in: source)
            }.value
            guard let self, !Task.isCancelled, self.generation == expected else { return }
            if self.hasMarkedText {
                // Still composing: try again once the composition has had time to end.
                self.scheduleRestyle()
                return
            }
            self.apply(highlights)
        }
    }

    /// Waits for the pending debounced pass, for tests.
    func waitForPendingRestyle() async {
        await restyleTask?.value
    }

    private func apply(_ highlights: [MarkdownHighlight]) {
        guard let storage = textStorage else { return }
        style.apply(highlights, to: storage)
        appliedPasses += 1
    }

    var textStorage: NSTextStorage? {
        #if canImport(UIKit)
        textView.textStorage
        #else
        textView.textStorage
        #endif
    }

    private func applyBaseTypingAttributes() {
        let base = style.baseAttributes()
        #if canImport(UIKit)
        textView.font = base[.font] as? UIFont
        textView.typingAttributes = base
        #else
        textView.font = base[.font] as? NSFont
        textView.typingAttributes = base
        #endif
    }

    /// The user edited the text: mirror it out and schedule a restyle.
    fileprivate func userDidEdit() {
        onTextChange?(text)
        scheduleRestyle()
    }

    // MARK: Text view

    private static func makeTextView() -> PlatformTextView {
        #if canImport(UIKit)
        // TextKit 2, explicitly.
        let view = UITextView(usingTextLayoutManager: true)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return view
        #else
        // TextKit 2, explicitly. Plain text: pasting rich text pastes its characters only.
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.usesFindBar = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 8, height: 12)
        return view
        #endif
    }
}

#if canImport(UIKit)
extension MarkdownEditorController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        userDidEdit()
    }
}
#else
extension MarkdownEditorController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        userDidEdit()
    }
}
#endif
