/// One accent phrase: the run of words a single pitch pattern is drawn over.
///
/// Pitch accent is a property of the accent PHRASE, not the word, so words must be grouped
/// before the notation can be drawn. NJD reports the grouping per word through
/// `JapaneseReader.Word.phraseChain`: a word that `attachesToPrevious` continues the current
/// phrase, and any other state opens a new one.
///
/// The accent of a phrase is the accent of its head (first) word. Rather than re-resolving a
/// nucleus and mora count onto the phrase, this exposes the head word and forwards its accent,
/// so the single source of truth stays the word the frontend analyzed. A caller that wants the
/// moras splits `head.surface`'s reading with `MoraSplitter`.
///
/// Non-empty by construction: `group(_:)` never emits an empty phrase, so `head` is always
/// defined.
public struct AccentPhrase: Equatable, Sendable {
    /// The words this phrase groups, in reading order. Always at least one.
    public let words: [JapaneseReader.Word]

    /// The head (first) word, whose accent the whole phrase carries.
    public var head: JapaneseReader.Word { words[0] }

    /// The phrase's pitch accent: the head word's nucleus and mora count.
    public var accent: JapaneseReader.PitchAccent { head.accent }

    /// Internal so the non-empty invariant holds: phrases only come from `group(_:)`.
    init(words: [JapaneseReader.Word]) {
        self.words = words
    }

    /// Group a word sequence into accent phrases by walking each word's `phraseChain`.
    ///
    /// The first word always opens a phrase. A word whose chain `attachesToPreviousWord` is
    /// true extends the current phrase; any other state (`beginsPhrase`, `startsNewPhrase`)
    /// opens a new one. A leading attaching word still opens a phrase rather than being
    /// dropped. An empty input yields an empty array.
    public static func group(_ words: [JapaneseReader.Word]) -> [AccentPhrase] {
        var phrases: [AccentPhrase] = []
        var current: [JapaneseReader.Word] = []
        for word in words {
            if word.phraseChain.attachesToPreviousWord, !current.isEmpty {
                current.append(word)
            } else {
                if !current.isEmpty { phrases.append(AccentPhrase(words: current)) }
                current = [word]
            }
        }
        if !current.isEmpty { phrases.append(AccentPhrase(words: current)) }
        return phrases
    }
}
