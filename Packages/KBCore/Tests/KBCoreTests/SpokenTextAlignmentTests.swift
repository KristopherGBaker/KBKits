import Testing
@testable import KBCore

/// The karaoke-alignment safety net: an expanding spoken transform must not
/// desync the highlight. These verify that an expanded display token collapses to
/// a single highlighted unit and that the rest of the sentence stays aligned.
@Suite("SpokenTextAlignment")
struct SpokenTextAlignmentTests {

    private func provenance() -> TimingProvenance {
        TimingProvenance(providerID: .kokoro, providerVersion: "test",
                         strategy: .durationPredictor, textHash: "x")
    }

    private func timeline(_ words: [WordToken]) -> HighlightTimeline {
        HighlightTimeline(segmentID: SegmentID(documentID: DocumentID("doc"), sentenceIndex: 0),
                          audioDuration: 1.0, words: words,
                          confidence: .aligned, provenance: provenance())
    }

    @Test func unchangedTextMapsOneToOne() {
        let spans = SpokenTextAlignment.align(display: "hello world", spoken: "hello world")
        #expect(spans.count == 2)
        #expect(spans[0].display == spans[0].spoken)
        #expect(spans[1].display == spans[1].spoken)
    }

    @Test func expandedTokenClaimsItsExpansion() {
        // "In 1995 we" → "In nineteen ninety-five we": the year word expands.
        let display = "In 1995 we"
        let spoken = "In nineteen ninety-five we"
        let spans = SpokenTextAlignment.align(display: display, spoken: spoken)
        #expect(spans.count == 3)
        // "In" and "we" stay aligned; "1995" maps to the whole spoken expansion.
        let yearSpan = spans[1]
        let displayYear = display.range(fromUTF16: yearSpan.display)
        #expect(displayYear.map { String(display[$0]) } == "1995")
        let spokenExpansion = spoken.range(fromUTF16: yearSpan.spoken)
        #expect(spokenExpansion.map { String(spoken[$0]) } == "nineteen ninety-five")
    }

    @Test func remapCollapsesExpandedTokensToOneUnit() {
        let display = "In 1995 we"
        let spoken = "In nineteen ninety-five we"
        // Spoken timeline: In | nineteen | ninety-five | we (4 tokens).
        let spokenWords = WordTokenizer.tokenize(spoken)
        let tokens = spokenWords.enumerated().map { index, word in
            WordToken(offsets: word.offsets, start: Double(index) * 0.25, duration: 0.25)
        }
        let remapped = SpokenTextAlignment.remap(
            timeline: timeline(tokens), display: display, spoken: spoken)
        // 4 spoken tokens collapse to 3 display tokens (year = 1 unit).
        #expect(remapped.words.count == 3)
        // The year unit spans both spoken tokens' time (0.25 → 0.75).
        let yearToken = remapped.words[1]
        let displayYear = display.range(fromUTF16: yearToken.offsets)
        #expect(displayYear.map { String(display[$0]) } == "1995")
        #expect(yearToken.start == 0.25)
        #expect(abs(yearToken.duration - 0.5) < 1e-9)
        // The trailing "we" remains aligned to the right display word.
        let weToken = remapped.words[2]
        #expect(display.range(fromUTF16: weToken.offsets).map { String(display[$0]) } == "we")
    }

    @Test func hyphenSplitMapsBothSpokenWordsToOneDisplayWord() {
        // The length-preserving hyphen transform: "staff-level" → "staff level".
        let display = "the staff-level role"
        let spoken = "the staff level role"
        let remapped = SpokenTextAlignment.remap(
            timeline: timeline([
                WordToken(offsets: WordOffsets(lower: 0, upper: 3), start: 0, duration: 0.25),
                WordToken(offsets: WordOffsets(lower: 4, upper: 9), start: 0.25, duration: 0.25),
                WordToken(offsets: WordOffsets(lower: 10, upper: 15), start: 0.5, duration: 0.25),
                WordToken(offsets: WordOffsets(lower: 16, upper: 20), start: 0.75, duration: 0.25)
            ]), display: display, spoken: spoken)
        // "staff" + "level" collapse onto the single display word "staff-level".
        #expect(remapped.words.count == 3)
        let compound = remapped.words[1]
        #expect(display.range(fromUTF16: compound.offsets).map { String(display[$0]) } == "staff-level")
    }

    /// M5 announce+skip: a code segment's spoken text is the short marker while its display is
    /// the verbatim multi-line code — a large length/word-count mismatch. `remap` must NOT trap
    /// (no precondition/range crash); the exact remapped shape is not pinned.
    @Test func remapIsCrashSafeForCodeBlockAnnounceVsMultilineCode() {
        let spoken = "Code block."
        let display = "func main() {\n    print(\"hi\")\n\n    exit(0)\n}"
        let spokenWords = WordTokenizer.tokenize(spoken)
        let tokens = spokenWords.enumerated().map { index, word in
            WordToken(offsets: word.offsets, start: Double(index) * 0.25, duration: 0.25)
        }
        let remapped = SpokenTextAlignment.remap(
            timeline: timeline(tokens), display: display, spoken: spoken)
        // Returned without trapping; it collapses to at most the spoken token count.
        #expect(remapped.words.count <= tokens.count)
    }

    // MARK: - Phase 3: kana-ruby spoken text remaps onto the kanji display

    /// Tile `spoken` with the SAME tokenizer `remap` uses, remap the timeline onto
    /// `display`, then report the DISPLAY span the karaoke cursor lands on for a given
    /// spoken UTF-16 offset — by finding the remapped token active at that offset's
    /// original tiling time. Faithful to the real playback path (spoken-tiled timeline
    /// → `remap`), so these prove ruby'd words highlight their base with no extra code.
    private func resolvedDisplaySpan(
        display: String, spoken: String, spokenOffset: Int
    ) -> WordOffsets? {
        let spokenTokens = WordTokenizer.tokenize(spoken)
        guard let sourceIndex = spokenTokens.firstIndex(where: {
            $0.offsets.lower <= spokenOffset && spokenOffset < $0.offsets.upper
        }) else { return nil }
        let tokens = spokenTokens.enumerated().map { index, word in
            WordToken(offsets: word.offsets, start: Double(index), duration: 1)
        }
        let remapped = SpokenTextAlignment.remap(
            timeline: timeline(tokens), display: display, spoken: spoken)
        // `remap` folds consecutive tokens sharing a display span, keeping the earliest
        // start; the fold covering our token's time starts at/before it.
        let time = Double(sourceIndex)
        return remapped.words.last { $0.start <= time + 1e-9 }?.offsets
    }

    @Test(.enabled(if: hasReferenceCJKSegmenter))
    func rubyWholeWordMapsSpokenReadingOntoDisplayBase() {
        // 本気《マジ》だ: display 本気だ, spoken マジだ. The マジ reading shares no chars with
        // 本気 (a changed gap), so it maps onto 本気's display span [0,2); だ stays [2,3).
        let display = "本気だ", spoken = "マジだ"
        #expect(resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: 0)
            == WordOffsets(lower: 0, upper: 2))
        #expect(resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: 1)
            == WordOffsets(lower: 0, upper: 2))
        #expect(resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: 2)
            == WordOffsets(lower: 2, upper: 3))
    }

    @Test func rubyReadingNeverResolvesPastItsBase() {
        // 私《わたくし》は: display 私は, spoken わたくしは. The わたくし reading maps to 私 [0,1);
        // no reading offset resolves at/beyond は ([1,2)).
        let display = "私は", spoken = "わたくしは"
        for offset in 0..<4 {   // わ た く し
            let span = resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: offset)
            #expect(span == WordOffsets(lower: 0, upper: 1))
            #expect((span?.lower ?? 0) < 1)
        }
        #expect(resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: 4)
            == WordOffsets(lower: 1, upper: 2))
    }

    @Test(.enabled(if: hasReferenceCJKSegmenter))
    func wholeSentenceRubyMapsEveryTokenToTheBaseSpan() {
        // 本気《マジ》 with no okurigana: display 本気, spoken マジ. Every spoken token maps to [0,2).
        let display = "本気", spoken = "マジ"
        for offset in 0..<2 {
            #expect(resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: offset)
                == WordOffsets(lower: 0, upper: 2))
        }
    }

    @Test func rubyDivergenceDoesNotShiftTheIdenticalSurroundings() {
        // 彼は本気で走った vs 彼はマジで走った: only 本気→マジ diverges. Assert at the offset level
        // (no assumption on tokenizer word boundaries): the character-identical prefix 彼は and
        // suffix で走った keep their identity mapping; マジ resolves within 本気's display span.
        let display = "彼は本気で走った", spoken = "彼はマジで走った"
        // Prefix 彼は (offsets 0,1) is identical in both strings → maps to itself.
        let prefix = resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: 0)
        #expect(prefix?.lower == 0)
        // マジ (spoken offsets 2,3) resolves inside 本気's display span [2,4).
        for offset in 2..<4 {
            let span = resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: offset)
            #expect((span?.lower ?? -1) >= 2 && (span?.upper ?? .max) <= 4)
        }
        // Suffix で走った is character-identical AND same length (マジ and 本気 are both 2 UTF-16
        // units), so every trailing spoken offset maps to a display span CONTAINING the same offset
        // (identity) — the divergence did not shift the trailing mappings by even one unit.
        for offset in 4..<8 {
            let span = resolvedDisplaySpan(display: display, spoken: spoken, spokenOffset: offset)
            #expect(span.map { $0.lower <= offset && offset < $0.upper } == true)
        }
    }

    @Test func noopWhenSpokenEqualsDisplay() {
        let display = "plain sentence here"
        let words = WordTokenizer.tokenize(display).enumerated().map { index, word in
            WordToken(offsets: word.offsets, start: Double(index) * 0.3, duration: 0.3)
        }
        let original = timeline(words)
        let remapped = SpokenTextAlignment.remap(
            timeline: original, display: display, spoken: display)
        #expect(remapped.words == original.words)
    }
}
