import Testing

@testable import KBKanaKit

@Suite("The romaji table")
struct RomajiTableTests {
    @Test("no spelling is a prefix of another")
    func noKeyIsAPrefixOfAnother() {
        // The invariant the longest-match lookup rests on. If `n` and `na` were both
        // spellings, typing `n` would commit to ん before the `a` arrived and `na` could
        // never be reached. It is why ん is spelled `nn` and not `n`.
        let keys = RomajiTable.entries.keys.sorted()
        for (earlier, later) in zip(keys, keys.dropFirst()) {
            #expect(later.hasPrefix(earlier) == false, "\"\(earlier)\" is a prefix of \"\(later)\"")
        }
    }

    @Test("the declared longest key really is the longest")
    func longestKeyIsAccurate() {
        // The lookback in both converters is bounded by this. Understate it and the four
        // letter spellings stop matching, silently.
        #expect(RomajiTable.entries.keys.map(\.count).max() == RomajiTable.longestKey)
    }

    @Test("every spelling produces kana and nothing else")
    func everyValueIsKana() {
        for (key, value) in RomajiTable.entries {
            #expect(KanaConverter.isKana(value), "\"\(key)\" produces \"\(value)\"")
        }
    }

    @Test("every spelling is lowercase, since lookup lowercases its input")
    func everyKeyIsLowercase() {
        for key in RomajiTable.entries.keys {
            #expect(key == key.lowercased(), "\"\(key)\"")
        }
    }

    @Test("the table is the size it was when it was transcribed, plus the entries added since")
    func tableSize() {
        // A transcription of 290 entries from another language deserves a count. Losing one
        // to a stray comma would show up as a single spelling nobody could type. The count is
        // 291 rather than 290 because `xtsu` was added: it was absent from the transcription
        // yet `ltsu`, its l-prefix twin, was present, so `xtsu` produced `xつ` instead of っ.
        #expect(RomajiTable.entries.count == 291)
    }

    @Test("the l-prefix and x-prefix small-kana families stay in step")
    func smallKanaPrefixesAgree() {
        // The owner's decision: an `l` prefix maps to the small kana, matching the `x` prefix
        // and every major IME. Pinning both families in one place so they cannot drift apart
        // again: `la` was `ら` while `xa` was `ぁ`, and `xtsu` was missing while `ltsu` gave っ.
        #expect(RomajiTable.entries["la"] == "ぁ")
        #expect(RomajiTable.entries["xa"] == "ぁ")
        #expect(RomajiTable.entries["ltsu"] == "っ")
        #expect(RomajiTable.entries["xtsu"] == "っ")
        // The two prefixes agree entry for entry where both spellings exist.
        #expect(RomajiTable.entries["la"] == RomajiTable.entries["xa"])
        #expect(RomajiTable.entries["ltsu"] == RomajiTable.entries["xtsu"])
    }
}
