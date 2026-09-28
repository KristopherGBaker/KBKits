import Testing
import KBCore

/// The tiling contract every `CJKWordSegmenter` owes `WordTokenizer`: spans cover the
/// whole string, in order, with no gap and no overlap. A hole here silently drops
/// characters from the rendered line, which is why it is asserted structurally rather
/// than by comparing against one expected split.
private func expectTiles(_ tokens: [WordTokenizer.Token], over text: String) {
    #expect(tokens.first?.offsets.lower == 0)
    #expect(tokens.last?.offsets.upper == text.utf16.count)
    for (previous, next) in zip(tokens, tokens.dropFirst()) {
        #expect(previous.offsets.upper == next.offsets.lower)
    }
    // Reassembling the spans must reproduce the input exactly.
    let utf16 = Array(text.utf16)
    let rebuilt = tokens.map { token in
        String(decoding: utf16[token.offsets.lower..<token.offsets.upper], as: UTF16.self)
    }.joined()
    #expect(rebuilt == text)
}

@Test func scalarSegmenterTilesJapaneseText() {
    // ScalarCJKSegmenter is the off-Apple placeholder, so it never runs by default here.
    // Passing it explicitly is the point of the seam being a parameter: the fallback is
    // testable on the platform where it is NOT the default.
    let text = "東京に行く。"
    expectTiles(ScalarCJKSegmenter().segment(text, transcription: false), over: text)
}

@Test func scalarSegmenterTilesMixedScriptText() {
    let text = "東京 to Osaka で行く。"
    expectTiles(ScalarCJKSegmenter().segment(text, transcription: false), over: text)
}

@Test func scalarSegmenterSplitsCJKPerScalarAndKeepsLatinRunsWhole() {
    let tokens = ScalarCJKSegmenter().segment("東京 to", transcription: false)
    #expect(tokens.map(\.text) == ["東", "京", " ", "to"])
}

@Test func scalarSegmenterOffersNoTranscription() {
    // It has no transliterator, and the contract says report that rather than guess.
    let tokens = ScalarCJKSegmenter().segment("東京", transcription: true)
    #expect(tokens.allSatisfy { $0.latinTranscription == nil })
}

@Test func tokenizeHonorsAnInjectedSegmenter() {
    let text = "東京に行く。"
    let injected = WordTokenizer.tokenize(text, segmenter: ScalarCJKSegmenter())
    #expect(injected.map(\.text) == ["東", "京", "に", "行", "く", "。"])
    expectTiles(injected, over: text)
}

@Test func nonCJKTextNeverReachesTheSegmenter() {
    // The whitespace path is portable and must not be routed through the seam, so an
    // injected segmenter that would fail the assertion is simply never called.
    let tokens = WordTokenizer.tokenize("The quick brown.", segmenter: ScalarCJKSegmenter())
    #expect(tokens.map(\.text) == ["The", "quick", "brown."])
}

#if canImport(Darwin)
@Test func platformSegmenterTilesAndIsTheCoreFoundationOne() {
    let text = "東京に行く。"
    #expect(WordTokenizer.platformCJKSegmenter is CoreFoundationCJKSegmenter)
    expectTiles(WordTokenizer.platformCJKSegmenter.segment(text, transcription: false), over: text)
}

@Test func coreFoundationSegmenterProducesLatinTranscriptionWhenAsked() {
    let tokens = CoreFoundationCJKSegmenter().segment("東京", transcription: true)
    #expect(tokens.contains { $0.latinTranscription?.isEmpty == false })
}
#endif
