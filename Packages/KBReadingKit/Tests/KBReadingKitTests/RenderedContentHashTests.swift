import KBCore
import KBReadingKit
import Testing

/// The reader's change detection has to be able to tell these apart, and could not.
///
/// Reported symptom: scrolling "not even that far" left the page completely blank except for
/// images, and it never recovered. Cause: the reader paints a WINDOWED build first (fast open on a
/// long book) and swaps the full build in behind it, but the view-level signature hashed only the
/// title, theme, block COUNT and block IDS. `ReaderContent.build` always emits every paragraph and
/// only varies whether it carries words, so the two builds hashed IDENTICALLY, the swap was judged
/// a no-op, and the host kept the windowed content forever. Images survived because they carry no
/// words.
///
/// These pin the two collisions that mattered, so the detector cannot regress to counting ids.
@Suite
struct RenderedContentHashTests {

    private func word(_ text: String, id: String, reading: String?) -> KaraokeWord {
        KaraokeWord(id: id, text: text, segmentIndex: 0, utf16Lower: 0, utf16Upper: text.utf16.count,
                    ruby: [RubySegment(text: text, reading: reading)])
    }

    private func digest(_ blocks: [KaraokeBlock]) -> Int {
        var hasher = Hasher()
        for block in blocks { block.hashRenderedContent(into: &hasher) }
        return hasher.finalize()
    }

    /// A windowed build and a full build differ ONLY in whether paragraphs carry words.
    @Test
    func windowedAndFullBuildsHashDifferently() {
        let windowed: [KaraokeBlock] = [
            .paragraph(KaraokeParagraph(id: 0, words: [word("十分", id: "0.0", reading: "じゅうぶん")])),
            .paragraph(KaraokeParagraph(id: 1, words: []))          // outside the window
        ]
        let full: [KaraokeBlock] = [
            .paragraph(KaraokeParagraph(id: 0, words: [word("十分", id: "0.0", reading: "じゅうぶん")])),
            .paragraph(KaraokeParagraph(id: 1, words: [word("本", id: "1.0", reading: "ほん")]))
        ]
        #expect(windowed.count == full.count, "same block count - that was the collision")
        #expect(windowed.map(\.id) == full.map(\.id), "same block ids - that was the collision")
        #expect(digest(windowed) != digest(full),
                """
                a wordless paragraph hashes the same as a populated one, so the reader keeps \
                the windowed build and stays blank past the window
                """)
    }

    /// A corrected reading changes a word's ruby and NOTHING else - same ids, same counts.
    @Test
    func aCorrectedReadingHashesDifferently() {
        let before: [KaraokeBlock] = [
            .paragraph(KaraokeParagraph(id: 0, words: [word("十分", id: "0.0", reading: "じゅうぶん")]))
        ]
        let after: [KaraokeBlock] = [
            .paragraph(KaraokeParagraph(id: 0, words: [word("十分", id: "0.0", reading: "じゅっぷん")]))
        ]
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before[0].wordCount == after[0].wordCount, "same word count - the harder collision")
        #expect(digest(before) != digest(after),
                """
                a chosen reading changes only the ruby, so a count-based signature misses it \
                and the correction never reaches the screen
                """)
    }

    /// Unchanged content must hash the SAME, or the reader rebuilds on every update and the fix
    /// costs more than the bug.
    @Test
    func identicalContentHashesIdentically() {
        let blocks: [KaraokeBlock] = [
            .paragraph(KaraokeParagraph(id: 0, words: [word("本", id: "0.0", reading: "ほん")]))
        ]
        #expect(digest(blocks) == digest(blocks))
    }
}
