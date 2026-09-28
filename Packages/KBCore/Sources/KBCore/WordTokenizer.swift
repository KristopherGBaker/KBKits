import Foundation

/// Splits a segment's text into rendered-word boundaries (UTF-16 spans) — the
/// single source of truth shared by the reader's `KaraokeWord` layout, the
/// `ProportionalDeriver`'s fallback timing, and the silent reading pacer. One
/// tokenizer means an estimated timeline's words (and the pacer's highlight)
/// line up *exactly* with the words drawn on screen.
///
/// Space-delimited scripts split on whitespace runs, here, in portable Swift.
/// Japanese/Chinese have no inter-word spaces, so a whitespace split would make a
/// whole sentence one giant "word" (no wrapping, whole-line highlight); those go
/// through a `CJKWordSegmenter`, which is a seam because Apple's implementation
/// (`CFStringTokenizer`) has no equivalent off Apple platforms. Either way the
/// spans tile the string with no holes.
public enum WordTokenizer {

    /// One tokenized word: its UTF-16 span within the source text, the surface
    /// string, and — for CJK tokens, when requested — the tokenizer's Latin
    /// transcription (the romaji the furigana layer turns into a kana reading).
    public struct Token: Sendable, Hashable {
        public let offsets: WordOffsets
        public let text: String
        public let latinTranscription: String?
        /// True when no whitespace separated this token from the previous one — it
        /// was split off mid-run (the right side of an em/en dash). The reader lays
        /// such a token tight against its predecessor (no inter-word gap) so
        /// `word—word` renders exactly as authored while its halves highlight
        /// as two separate words.
        public let tightLeading: Bool

        public init(
            offsets: WordOffsets,
            text: String,
            latinTranscription: String? = nil,
            tightLeading: Bool = false
        ) {
            self.offsets = offsets
            self.text = text
            self.latinTranscription = latinTranscription
            self.tightLeading = tightLeading
        }
    }

    /// The segmenter used for CJK text when a caller does not name one. On Apple
    /// platforms this is `CoreFoundationCJKSegmenter`, the reference behavior; elsewhere
    /// it is the `ScalarCJKSegmenter` placeholder, which tiles the string but segments by
    /// character rather than by word. See `CJKWordSegmenter`.
    public static var platformCJKSegmenter: any CJKWordSegmenter {
        #if canImport(Darwin)
        CoreFoundationCJKSegmenter()
        #else
        ScalarCJKSegmenter()
        #endif
    }

    /// Tokenize `text` into word spans. `transcription` adds each CJK token's Latin
    /// transcription (one extra tokenizer query per token) — the reader needs it for
    /// furigana; the timing deriver and pacer do not.
    ///
    /// `segmenter` exists so a host on a platform without `CFStringTokenizer` can supply
    /// a real word segmenter; the default is right on Apple platforms and callers there
    /// have no reason to pass one.
    public static func tokenize(
        _ text: String,
        transcription: Bool = false,
        segmenter: any CJKWordSegmenter = WordTokenizer.platformCJKSegmenter
    ) -> [Token] {
        containsCJK(text)
            ? segmenter.segment(text, transcription: transcription)
            : tokenizeWhitespace(text)
    }

    /// True if the text contains Japanese/Chinese characters (kana or CJK
    /// ideographs / CJK punctuation), i.e. a script written without word spaces.
    public static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    // MARK: - Whitespace split

    private static func tokenizeWhitespace(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var startOffset = 0
        var buffer = ""
        var startTight = false      // does the current token abut the previous (no space between)?
        var sawWhitespace = true    // whitespace seen since the last token began? (string start counts)

        func flush() {
            guard !buffer.isEmpty else { return }
            tokens.append(Token(offsets: WordOffsets(lower: startOffset, upper: offset),
                                text: buffer, tightLeading: startTight))
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
                sawWhitespace = true
            } else {
                if buffer.isEmpty {
                    startOffset = offset
                    startTight = !sawWhitespace   // tight when the previous token ended with no space (a dash split)
                    sawWhitespace = false
                }
                buffer.unicodeScalars.append(scalar)
                // An em/en dash ends its word in place; the next run starts a new
                // token that abuts this one (tightLeading), so the pair renders
                // gap-free but highlights as two words. The dash stays on the left.
                if isSplittingDash(scalar) {
                    offset += width
                    flush()
                    continue
                }
            }
            offset += width
        }
        flush()
        return tokens
    }

    /// En dash (U+2013), em dash (U+2014), and horizontal bar (U+2015): sentence
    /// punctuation joining two *separate* words. Split on these even without spaces.
    /// A hyphen (U+002D / U+2010) is a compound-word joiner and is deliberately NOT
    /// split — the compound stays one highlighted word (cf. `SpokenTextTransform`).
    private static func isSplittingDash(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2013, 0x2014, 0x2015: return true
        default: return false
        }
    }

    // MARK: - Character class

    /// Internal rather than private: `ScalarCJKSegmenter` classifies by the same rule,
    /// so the two cannot drift.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF65...0xFF9F,   // Halfwidth katakana
             0x20000...0x2FFFF: // CJK Unified Ideographs Extensions B–F
            return true
        default:
            return false
        }
    }
}
