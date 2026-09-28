import Testing
import KBCore

@Test func wordTokenizerSplitsAsciiOnWhitespaceWithUTF16Offsets() {
    let tokens = WordTokenizer.tokenize("The quick brown.")
    #expect(tokens.map(\.text) == ["The", "quick", "brown."])
    #expect(tokens[0].offsets.lower == 0 && tokens[0].offsets.upper == 3)
    #expect(tokens[1].offsets.lower == 4 && tokens[1].offsets.upper == 9)
    #expect(tokens[2].offsets.lower == 10 && tokens[2].offsets.upper == 16)
    // No CJK → no Latin transcription, regardless of the flag.
    #expect(tokens.allSatisfy { $0.latinTranscription == nil })
}

@Test func wordTokenizerSplitsJapaneseIntoTilingSpans() {
    let text = "東京に行く。"
    #expect(WordTokenizer.containsCJK(text))
    let tokens = WordTokenizer.tokenize(text)
    #expect(tokens.count > 1)                                // not one giant "word"
    #expect(tokens.first?.offsets.lower == 0)
    #expect(tokens.last?.offsets.upper == text.utf16.count)
    // Spans are contiguous (each token starts where the previous ended), so they
    // tile the whole string with no gaps...
    for (prev, next) in zip(tokens, tokens.dropFirst()) {
        #expect(prev.offsets.upper == next.offsets.lower)
    }
    // ...and reassembling the surfaces reproduces the source exactly.
    #expect(tokens.map(\.text).joined() == text)
}

@Test(.enabled(if: hasReferenceCJKSegmenter))
func wordTokenizerAddsLatinTranscriptionOnlyWhenRequested() {
    let text = "東京"
    #expect(WordTokenizer.tokenize(text, transcription: false).allSatisfy { $0.latinTranscription == nil })
    // With transcription on, the kanji token carries a (romaji) reading.
    let withRomaji = WordTokenizer.tokenize(text, transcription: true)
    #expect(withRomaji.contains { $0.latinTranscription?.isEmpty == false })
}

@Test func wordTokenizerEmptyOrBlankTextYieldsNoTokens() {
    #expect(WordTokenizer.tokenize("").isEmpty)
    #expect(WordTokenizer.tokenize("   \n ").isEmpty)
}

@Test func wordTokenizerSplitsEmDashIntoTwoTightWords() {
    // No surrounding spaces → one token today; should split into two words, the
    // dash kept on the left, the right side flagged tight (renders gap-free).
    let tokens = WordTokenizer.tokenize("yes—no")
    #expect(tokens.map(\.text) == ["yes—", "no"])
    #expect(tokens[0].offsets.lower == 0 && tokens[0].offsets.upper == 4)  // "yes—" incl. dash
    #expect(tokens[1].offsets.lower == 4 && tokens[1].offsets.upper == 6)  // "no"
    #expect(tokens[0].tightLeading == false)
    #expect(tokens[1].tightLeading == true)
    // No characters lost, no space added: the surfaces reassemble to the source.
    #expect(tokens.map(\.text).joined() == "yes—no")
}

@Test func wordTokenizerSplitsEnDashRangeIntoTwoTightWords() {
    let tokens = WordTokenizer.tokenize("1965–1972")
    #expect(tokens.map(\.text) == ["1965–", "1972"])
    #expect(tokens[1].tightLeading == true)
    #expect(tokens.map(\.text).joined() == "1965–1972")
}

@Test func wordTokenizerKeepsHyphenatedCompoundAsOneWord() {
    // Hyphens join a compound — deliberately NOT split (cf. SpokenTextTransform).
    let tokens = WordTokenizer.tokenize("well-known")
    #expect(tokens.map(\.text) == ["well-known"])
    #expect(tokens[0].tightLeading == false)
}

@Test func wordTokenizerSpacedDashStaysOwnNormallySpacedToken() {
    // A spaced dash is already its own whitespace-delimited token — unchanged, and
    // not tight (the spaces stay), so its layout is exactly as before.
    let tokens = WordTokenizer.tokenize("a — b")
    #expect(tokens.map(\.text) == ["a", "—", "b"])
    #expect(tokens.allSatisfy { !$0.tightLeading })
}
