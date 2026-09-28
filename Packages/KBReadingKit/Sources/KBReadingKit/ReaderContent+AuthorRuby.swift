import KBCore

/// Propagating the author's own ruby across the document that carries it.
///
/// Kept out of `ReaderContent.swift` for the file-length limit, and public for the same reason
/// `applyingCorrections` is: three platforms render through two different choke points
/// (`ReaderContent.build` on Apple, the Android bridge's own `renderWords` over
/// `KaraokeWord.tokenize`), and there must be exactly ONE implementation of the run match, the
/// two gates and the placement, or Android quietly keeps the contradicting page.
extension ReaderContent {

    /// Rewrite each run of words whose surface the author rubied ONCE in this document, and
    /// whose reading we produced is one the ordinary dictionary cannot account for.
    ///
    /// BOTH gates are load-bearing and neither is sufficient. The single-reading gate alone
    /// leaves 30,220 corpus positions dominated by ordinary polysemous words (私 わたし against
    /// the author's わたくし); the corroboration gate alone would fire on any word we happen to
    /// read unusually. Together they select 3,354 positions that are names, places and rare
    /// compounds - the class where the author is the only authority there is.
    ///
    /// `corroborated(surface, ours)` asks the dictionary whether any form beginning with
    /// `surface` has a reading beginning with `ours` (`JMDictStore.corroborates`). TRUE means
    /// leave it alone: 覗 reads のぞ because JMdict knows 覗く, and that is a defensible reading
    /// however the author rubied it elsewhere. FALSE means the tokenizer assembled a reading out
    /// of individual kanji that no entry supports - つかさなみ for 司波 - which is the signature
    /// this fires on.
    ///
    /// A run of SEVERAL words collapses into one, exactly as a spanning compound join or a
    /// multi-word correction does: 沙名子 split by the tokenizer into 沙名|子 has one reading
    /// that belongs to the whole run and no per-token split, and the merged word keeps the run's
    /// full offset span so highlighting, find and scroll anchors still resolve.
    ///
    /// The analysis reading survives as a CANDIDATE on the new provenance, so a reader who
    /// thinks the author's ruby was context-specific can still change it back.
    public static func applyingAuthorRuby(
        _ index: AuthorRubyIndex,
        corroborated: (String, String) -> Bool,
        to words: [KaraokeWord]
    ) -> [KaraokeWord] {
        guard !index.isEmpty, !words.isEmpty else { return words }
        var result: [KaraokeWord] = []
        var index0 = words.startIndex
        while index0 < words.endIndex {
            guard let end = matchEnd(from: index0, in: words, index: index, corroborated: corroborated)
            else {
                result.append(words[index0])
                index0 += 1
                continue
            }
            let run = Array(words[index0..<end.upper])
            result.append(propagated(run, reading: end.reading, ours: end.ours))
            index0 = end.upper
        }
        return result
    }

    /// A run both gates cleared: where it ends, the author's reading to write, and the reading
    /// it replaces (kept so it can be offered back as an alternative).
    private struct Match {
        /// Index PAST the last word of the run.
        let upper: Int
        /// The run's concatenated surface, which is what the index is keyed on.
        let surface: String
        /// The author's reading, once one is settled; the surface's own accumulation until then.
        var reading: String = ""
        /// What the run renders today.
        let ours: String
    }

    /// The LONGEST run starting at `start` that passes both gates. Longest first, so 沙名子 wins
    /// over a 沙名 the author also happened to ruby - and a longer surface the author DID ruby
    /// consumes the decision even when a gate declines it, rather than letting a shorter run
    /// inside it fire. That mirrors the compound join, which stops at the longest known form.
    private static func matchEnd(
        from start: Int,
        in words: [KaraokeWord],
        index: AuthorRubyIndex,
        corroborated: (String, String) -> Bool
    ) -> Match? {
        let maximum = min(index.longestSurface, words.endIndex - start)
        guard maximum >= 1 else { return nil }
        var surface = ""
        var ours = ""
        var candidates: [Match] = []
        for offset in 0..<maximum {
            let word = words[start + offset]
            // Gapless: a run the tokenizer did not lay end to end is not a surface the author
            // could have rubied, and joining across a gap would write ruby over the gap's text.
            guard offset == 0 || word.utf16Lower == words[start + offset - 1].utf16Upper
            else { break }
            surface += word.text
            ours += KaraokeWord.renderedReading(segments: word.ruby, surface: word.text)
            candidates.append(Match(upper: start + offset + 1, surface: surface, ours: ours))
        }
        for candidate in candidates.reversed() {
            guard let authorReading = index.reading(for: candidate.surface) else { continue }
            // THE THIRD GATE, and it is not optional: the run must be a WHOLE adjacent kanji
            // stretch, never a proper part of one.
            //
            // An author who rubies 歩《あ》 (from 歩く) has told us what 歩 reads ALONE. Writing
            // that onto the 歩 inside 一歩 renders いっあ, because the correct いっぽ is a sandhi
            // form the isolated reading cannot carry. Measured over the 30-book corpus, this one
            // omission cost 102 new gold-free join defects - 一遍 いっへん for いっぺん, 内緒話
            // ないしょはな for ないしょばなし, 背表紙 せひょうし for せびょうし, 六分 ろっぶ for
            // ろっぷん - every one of them a rendaku or gemination the in-context analysis had
            // already got right.
            //
            // Phonology cannot be the gate here. `Sandhi` deliberately excludes rendaku, for
            // measured reasons of its own, so it would catch いっぽ and miss ばなし. Context can:
            // in every one of those defects the propagated token had a kanji neighbour, and in
            // every case the fix is meant for (沙名子, 茂作, 華山) it does not. So the run must be
            // maximal - the same notion of a run the compound join already scans.
            guard isWholeKanjiRun(start: start, upper: candidate.upper, in: words) else { return nil }
            // We already agree with the author here - which includes every occurrence the author
            // rubied, since the author's own ruby is what we rendered there.
            guard KaraokeWord.normalizeKana(candidate.ours) != authorReading else { return nil }
            guard !corroborated(candidate.surface, candidate.ours) else { return nil }
            // A TYPOGRAPHIC difference is not a different reading. Modern publishers set ruby in
            // full-size kana - 服部 as はつとり, 大給 as おぎゆう, 魔法力 as まほうりよく - and
            // taking that over our own はっとり would put the publisher's typesetting convention
            // on the page in place of the correct spelling. 346 corpus positions, every one of
            // them a reading we already had right. So when the two agree under the small-kana
            // fold, propagate only if the AUTHOR's spelling is the more precise one.
            guard smallKanaFolded(candidate.ours) != smallKanaFolded(authorReading)
                    || smallKana(in: authorReading) > smallKana(in: candidate.ours)
            else { return nil }
            return Match(upper: candidate.upper, surface: candidate.surface,
                         reading: authorReading, ours: candidate.ours)
        }
        return nil
    }

    /// Small kana folded to their full-size forms and the long mark dropped, so two spellings of
    /// ONE reading compare equal. Deliberately local rather than reused from `normalizeKana`,
    /// which folds script (katakana to hiragana) and must not fold size: a small-kana error is a
    /// real reading error everywhere else in this package.
    private static func smallKanaFolded(_ reading: String) -> String {
        String(reading.compactMap { character -> Character? in
            if character == "ー" { return nil }
            return Self.smallToLarge[character] ?? character
        })
    }

    private static func smallKana(in reading: String) -> Int {
        reading.count { Self.smallToLarge[$0] != nil }
    }

    private static let smallToLarge: [Character: Character] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お",
        "っ": "つ", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ", "ゎ": "わ",
        "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ",
        "ッ": "ツ", "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ"
    ]

    /// Whether `[start, upper)` is a WHOLE adjacent all-kanji stretch rather than part of one:
    /// no gapless all-kanji word immediately before it, and none immediately after.
    ///
    /// A run with a kana neighbour (沙名子 followed by は) is whole. A run with a kanji neighbour
    /// (the 歩 in 一歩) is not, and its reading belongs to the compound rather than to the token.
    private static func isWholeKanjiRun(start: Int, upper: Int, in words: [KaraokeWord]) -> Bool {
        func abuts(_ index: Int, _ neighbour: Int) -> Bool {
            guard words.indices.contains(neighbour) else { return false }
            let (left, right) = index < neighbour ? (words[index], words[neighbour])
                                                  : (words[neighbour], words[index])
            return left.utf16Upper == right.utf16Lower
                && FuriganaAnnotator.isKanjiOnly(words[neighbour].text)
        }
        return !abuts(start, start - 1) && !abuts(upper - 1, upper)
    }

    /// One word carrying the author's reading, placed by the SAME okurigana annotator the tier
    /// and the correction path use, with our own reading kept as the alternative.
    private static func propagated(
        _ run: [KaraokeWord],
        reading: String,
        ours: String
    ) -> KaraokeWord {
        let first = run[0]
        let surface = run.map(\.text).joined()
        let baseForm = run.flatMap(\.ruby).compactMap(\.baseForm).first
        let provenance = ReadingProvenance(candidates: [reading, KaraokeWord.normalizeKana(ours)],
                                           chosen: reading, source: .authorRuby)
        var placed = FuriganaAnnotator.segments(token: surface, reading: reading)
        if placed.isEmpty { placed = [RubySegment(text: surface, reading: reading)] }
        let stamped = placed.map { segment in
            RubySegment(text: segment.text, reading: segment.reading, baseForm: baseForm,
                        pitch: nil,
                        // Only a reading-bearing run can host provenance; a plain okurigana run
                        // carries none, matching the tier's own placement.
                        provenance: segment.reading == nil ? nil : provenance)
        }
        return KaraokeWord(id: first.id, text: surface, segmentIndex: first.segmentIndex,
                           utf16Lower: first.utf16Lower, utf16Upper: run[run.count - 1].utf16Upper,
                           traits: first.traits, ruby: stamped, gloss: first.gloss,
                           tightLeading: first.tightLeading, url: first.url)
    }
}
