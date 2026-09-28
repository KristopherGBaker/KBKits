import Testing
import KBCore

private typealias Segmenter = MixedScriptSegmenter

/// The concatenation of every run's text must reproduce the source exactly (no
/// characters dropped or duplicated) — the contract callers rely on to map per-run
/// audio + timing back onto the full segment.
private func expectLossless(_ text: String) {
    #expect(Segmenter.runs(in: text).map(\.text).joined() == text)
}

@Test func segmenterReturnsNothingForEmptyString() {
    #expect(Segmenter.runs(in: "").isEmpty)
    #expect(!Segmenter.isMixed(""))
}

@Test func segmenterKeepsPureJapaneseAsOneRun() {
    let runs = Segmenter.runs(in: "東京に行きます。")
    #expect(runs.count == 1)
    #expect(runs.first?.script == .japanese)
    #expect(!Segmenter.isMixed("東京に行きます。"))
}

@Test func segmenterKeepsPureEnglishAsOneRun() {
    let runs = Segmenter.runs(in: "Hello there, world.")
    #expect(runs.count == 1)
    #expect(runs.first?.script == .english)
    #expect(!Segmenter.isMixed("Hello there, world."))
}

@Test func segmenterSplitsEnglishWordEmbeddedInJapanese() {
    let text = "これはAppleです。"
    #expect(Segmenter.isMixed(text))
    let runs = Segmenter.runs(in: text)
    #expect(runs.map(\.script) == [.japanese, .english, .japanese])
    #expect(runs.map(\.text) == ["これは", "Apple", "です。"])
    expectLossless(text)
    // Offsets land on the right UTF-16 boundaries for stitching back.
    #expect(runs[1].utf16Start == ("これは" as String).utf16.count)
}

@Test func segmenterKeepsShortAllCapsAcronymOnJapaneseSide() {
    // "API" among Japanese stays Japanese so OpenJTalk spells it エーピーアイ.
    let text = "APIを使う"
    let runs = Segmenter.runs(in: text)
    #expect(runs.count == 1)
    #expect(runs.first?.script == .japanese)
    #expect(!Segmenter.isMixed(text))
}

@Test func segmenterTreatsLongOrLowercaseLatinAsEnglish() {
    // Lowercase / mixed-case or long tokens are words, not initialisms.
    #expect(Segmenter.runs(in: "Swift").first?.script == .english)
    #expect(Segmenter.runs(in: "iPhone").first?.script == .english)
    // 5+ uppercase letters exceed the acronym length → treated as a word.
    #expect(Segmenter.runs(in: "HELLO").first?.script == .english)
}

@Test func segmenterRoutesAcronymAmongEnglishToEnglish() {
    // Surrounded by English words, an initialism reads on the English path.
    let text = "use the API now"
    let runs = Segmenter.runs(in: text)
    #expect(runs.count == 1)
    #expect(runs.first?.script == .english)
}

@Test func segmenterAttachesNeutralAndDigitsToNeighbours() {
    let text = "バージョン2.0 はApple製"
    expectLossless(text)
    let runs = Segmenter.runs(in: text)
    // The version number + space ride with the preceding Japanese; "Apple" splits
    // out; the trailing 製 returns to Japanese.
    #expect(runs.map(\.script) == [.japanese, .english, .japanese])
    #expect(runs.map(\.text) == ["バージョン2.0 は", "Apple", "製"])
}

@Test func segmenterHandlesMultipleEnglishRuns() {
    let text = "私はSwiftとKotlinが好き。"
    expectLossless(text)
    let runs = Segmenter.runs(in: text)
    #expect(runs.map(\.script) == [.japanese, .english, .japanese, .english, .japanese])
    #expect(runs.map(\.text) == ["私は", "Swift", "と", "Kotlin", "が好き。"])
}

@Test func segmenterTreatsPunctuationOnlyStringAsJapanese() {
    // No definite script anywhere → defaults to the (Japanese) base voice.
    let runs = Segmenter.runs(in: "！？…")
    #expect(runs.count == 1)
    #expect(runs.first?.script == .japanese)
}

@Test func segmenterAttachesLeadingNeutralToFollowingRun() {
    let text = "  Hello"
    let runs = Segmenter.runs(in: text)
    #expect(runs.count == 1)
    #expect(runs.first?.script == .english)
    #expect(runs.first?.text == "  Hello")
}
