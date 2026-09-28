import Foundation

/// Word-boundary segmentation for scripts written without inter-word spaces.
///
/// This is a seam because it is the one piece of `WordTokenizer` that cannot be written
/// in portable Swift: Apple's answer is `CFStringTokenizer`, which has no equivalent on
/// Linux or Android. It is also the one piece whose OUTPUT is load-bearing rather than
/// incidental, because word spans drive the reader's layout, the proportional timing
/// deriver, and the silent reading pacer alike. A host that swaps this out is changing
/// where highlights land, not just how text is split.
///
/// Implementors must return spans that TILE the input: every UTF-16 offset belongs to
/// exactly one token, with no gaps and no overlap. `WordTokenizer` relies on it, and a
/// hole silently drops characters from the rendered line.
public protocol CJKWordSegmenter: Sendable {
    /// Segment `text` into word spans. `transcription` requests each token's Latin
    /// transcription (the romaji the furigana layer turns into a kana reading); an
    /// implementation with no transliterator returns `nil` for it rather than guessing.
    func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token]
}

#if canImport(Darwin)

/// The Apple segmenter, and the behavior every other implementation is compared against.
/// Uses `CFStringTokenizer` at word-boundary granularity with a Japanese locale, filling
/// any gap between tokens (a space, say) so the spans tile the string.
public struct CoreFoundationCJKSegmenter: CJKWordSegmenter {
    public init() {}

    public func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token] {
        let cf = text as CFString
        let fullRange = CFRangeMake(0, CFStringGetLength(cf))
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier("ja_JP" as CFString))
        guard let tokenizer = CFStringTokenizerCreate(
            nil, cf, fullRange, kCFStringTokenizerUnitWordBoundary, locale) else { return [] }

        var tokens: [WordTokenizer.Token] = []
        var cursor = 0

        func emit(lower: Int, upper: Int, latin: String? = nil) {
            guard upper > lower,
                  let sub = CFStringCreateWithSubstring(nil, cf, CFRangeMake(lower, upper - lower)) as String?,
                  !sub.isEmpty else { return }
            tokens.append(WordTokenizer.Token(offsets: WordOffsets(lower: lower, upper: upper),
                                              text: sub, latinTranscription: latin))
        }

        var status = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while status != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let lower = range.location
            let upper = range.location + range.length
            if lower > cursor { emit(lower: cursor, upper: lower) }   // gap (e.g. a space)
            let latin = transcription
                ? CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                : nil
            emit(lower: lower, upper: upper, latin: latin)
            cursor = upper
            status = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        if cursor < fullRange.length { emit(lower: cursor, upper: fullRange.length) }
        return tokens
    }
}

#endif

/// The portable segmenter: every CJK scalar becomes its own token, and runs of non-CJK
/// text between them are split on whitespace.
///
/// This is a PLACEHOLDER, not a port. It tiles the string, so nothing downstream breaks
/// and no character is dropped, but it segments by character rather than by word: a
/// two-character compound highlights as two units instead of one, and it never produces a
/// Latin transcription, so furigana falls back to whatever the caller does when
/// `latinTranscription` is `nil`. It exists so `KBCore` compiles and behaves sanely off
/// Apple platforms while a real implementation (ICU `BreakIterator` plus `Transliterator`,
/// reached over JNI on Android) is written and compared against
/// `CoreFoundationCJKSegmenter` on the same corpus.
public struct ScalarCJKSegmenter: CJKWordSegmenter {
    public init() {}

    public func segment(_ text: String, transcription: Bool) -> [WordTokenizer.Token] {
        var tokens: [WordTokenizer.Token] = []
        var offset = 0
        var runStart = 0
        var run = ""

        func flushRun() {
            guard !run.isEmpty else { return }
            tokens.append(WordTokenizer.Token(offsets: WordOffsets(lower: runStart, upper: offset),
                                              text: run))
            run = ""
        }

        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if WordTokenizer.isCJK(scalar) {
                flushRun()
                tokens.append(WordTokenizer.Token(
                    offsets: WordOffsets(lower: offset, upper: offset + width),
                    text: String(scalar)))
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushRun()
                // Whitespace is a token of its own here so the spans still tile the
                // string; the Apple path achieves the same thing by gap filling.
                tokens.append(WordTokenizer.Token(
                    offsets: WordOffsets(lower: offset, upper: offset + width),
                    text: String(scalar)))
            } else {
                if run.isEmpty { runStart = offset }
                run.unicodeScalars.append(scalar)
            }
            offset += width
        }
        flushRun()
        return tokens
    }
}
