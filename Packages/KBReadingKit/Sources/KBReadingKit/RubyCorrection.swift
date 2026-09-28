public import KBCore

/// A reader's chosen reading for ONE occurrence of a word, carried into the display
/// build so the RUBY on the page changes too, matching what synthesis already speaks.
///
/// The spoken side already solved per-occurrence choice by handing the transform the
/// sentence index (`PlaybackController.spokenTextTransform`). Display ruby is built once
/// by `ReaderContent.build`, whose words are keyed by both halves of the identity a
/// choice needs: `KaraokeWord.tokenize` produces tokens carrying `utf16Lower`/`utf16Upper`
/// within their segment. So a correction is `sentenceIndex → [RubyCorrection]` (see the
/// `corrections` parameter on `ReaderContent.build`), and each correction names the exact
/// UTF-16 span it applies to, so 十分 renders じゅっぷん where the reader chose it and
/// じゅうぶん in another sentence of the same book (`docs/furigana/backlog-reading-choice.md`).
///
/// Dependency-free by design: it sits beside `SpokenTextSubstitution.Rule` in the
/// SwiftUI-free reading target, so the app converts its `PronunciationOverride` (or its
/// `ReadingCorrection`) to this exactly as it converts to `SpokenTextSubstitution.Rule`.
/// The reading package cannot depend on the app; this value type is the seam. It reaches
/// macOS, iOS AND Android, because `ReaderContent.build` is the one choke point all three
/// tokenize through.
public struct RubyCorrection: Sendable, Equatable {
    /// The lower UTF-16 offset of the corrected word WITHIN its segment (matches
    /// `KaraokeWord.utf16Lower`).
    public let utf16Lower: Int
    /// The upper UTF-16 offset of the corrected word within its segment (matches
    /// `KaraokeWord.utf16Upper`).
    public let utf16Upper: Int
    /// The surface recorded when the reader made the choice. The surface guard: a
    /// correction whose recorded surface no longer equals the token at those offsets is
    /// SKIPPED, because writing a reader's chosen reading onto a DIFFERENT word is worse
    /// than losing the correction. This is the last defence when a text hash has not
    /// caught a change.
    public let surface: String
    /// The kana reading the reader chose, placed over the kanji run(s) of `surface`.
    public let reading: String

    public init(utf16Lower: Int, utf16Upper: Int, surface: String, reading: String) {
        self.utf16Lower = utf16Lower
        self.utf16Upper = utf16Upper
        self.surface = surface
        self.reading = reading
    }
}
