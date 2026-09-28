public import KBCore
import Foundation

/// One rendered word in the reading surface. Carries its UTF-16 span within its
/// segment so the active word can be matched from `HighlightState` offsets.
public struct KaraokeWord: Identifiable, Sendable, Hashable {
    public let id: String         // stable: "<segmentIndex>.<wordIndex>"
    public let text: String
    public let segmentIndex: Int
    public let utf16Lower: Int
    public let utf16Upper: Int
    public let traits: TextTraits  // bold/italic retained from formatted sources
    /// Furigana segments (kana over kanji runs). Empty when the word has no kanji
    /// to annotate; populated only for CJK tokens. Rendered only when furigana is on.
    public let ruby: [RubySegment]
    /// The English source word for a katakana loanword (e.g. "communication" over
    /// コミュニケーション), rendered as ruby when the katakana-gloss toggle is on. nil for
    /// everything else (kanji words, native katakana, wasei/non-English loans).
    public let gloss: String?
    /// True when this word abuts the previous one with no source whitespace (the
    /// right side of an em/en-dash split). The reader suppresses the inter-word gap
    /// before it so `word—word` renders as authored yet highlights as two words.
    public let tightLeading: Bool
    /// The destination of the markdown `.link` run covering this word (M4a `StyleRun.url`),
    /// or nil for a non-link word. A single tap on a link word opens this URL; TTS still
    /// reads the visible text, not the URL.
    public let url: String?

    public init(
        id: String,
        text: String,
        segmentIndex: Int,
        utf16Lower: Int,
        utf16Upper: Int,
        traits: TextTraits = [],
        ruby: [RubySegment] = [],
        gloss: String? = nil,
        tightLeading: Bool = false,
        url: String? = nil
    ) {
        self.id = id
        self.text = text
        self.segmentIndex = segmentIndex
        self.utf16Lower = utf16Lower
        self.utf16Upper = utf16Upper
        self.traits = traits
        self.ruby = ruby
        self.gloss = gloss
        self.tightLeading = tightLeading
        self.url = url
    }

    /// Split a segment's text into words via the shared `WordTokenizer` (so the
    /// boundaries match the timing deriver and pacer exactly), baking in each
    /// word's `TextTraits` from `styleRuns` and — for kanji-bearing CJK tokens —
    /// its furigana ruby. (`KaraokeTextView` lays CJK paragraphs out with zero word
    /// spacing so the words abut naturally.)
    ///
    /// `reading`, when supplied, returns a token's hiragana reading for furigana
    /// (OpenJTalk when its dictionary is present); otherwise the tokenizer's own
    /// Latin transcription is used.
    ///
    /// `gloss`, when supplied, returns the English source word for a katakana loanword
    /// (JMdict-backed) — used for the katakana→English gloss ruby. Only consulted for
    /// pure-katakana tokens, so non-loanword tokens cost no lookup.
    ///
    /// `sourceRuby`, when supplied, is the segment's author-supplied furigana (Aozora `《》`,
    /// segment-local UTF-16 offsets). It takes PRECEDENCE over `reading` per covered span;
    /// `reading` is the fallback for kanji no source ruby covers (see `rubySegments`).
    /// Defaults empty so existing no-source callers compile and behave unchanged.
    ///
    /// `payload`, when supplied, is the dictionary reading tier (see `ReadingPayload`):
    /// it supersedes `reading` for kanji-bearing tokens (final reading + optional
    /// dictionary placement spans) and powers the guarded okurigana token join. It sits
    /// BELOW source ruby and defaults nil so every existing caller behaves unchanged.
    /// A copy whose ruby carries `pattern`, distributed across the segments that have a
    /// reading. Pitch is drawn over the kana lane, so only a segment WITH a reading can host
    /// it; plain runs (okurigana, punctuation) are left alone.
    ///
    /// The pattern is per mora of the word's whole reading, so it is split across the word's
    /// reading-bearing segments in order, each taking as many moras as its own reading has.
    /// If the arithmetic does not line up, the word is returned unchanged rather than
    /// annotated with a misaligned mark: a mark over the wrong mora is worse than none.
    func withPitch(_ pattern: [MoraPitch]) -> KaraokeWord {
        var remaining = pattern[...]
        var updated: [RubySegment] = []
        updated.reserveCapacity(ruby.count)
        for segment in ruby {
            guard let reading = segment.reading, !reading.isEmpty else {
                updated.append(segment)
                continue
            }
            // Align by consuming pattern entries until their moras spell this reading. The
            // entries already carry their mora text, so no re-splitting is needed here, which
            // also keeps this package free of the Japanese pipeline.
            var count = 0
            var spelled = ""
            while count < remaining.count, spelled.count < reading.count {
                spelled += remaining[remaining.startIndex + count].mora
                count += 1
            }
            guard count > 0, spelled == reading else { return self }
            updated.append(segment.withPitch(Array(remaining.prefix(count))))
            remaining = remaining.dropFirst(count)
        }
        guard remaining.isEmpty else { return self }
        return KaraokeWord(id: id, text: text, segmentIndex: segmentIndex,
                           utf16Lower: utf16Lower, utf16Upper: utf16Upper, traits: traits,
                           ruby: updated, gloss: gloss, tightLeading: tightLeading, url: url)
    }

    /// A copy of this word whose ruby renders the reader's `chosenReading` over the kanji
    /// run(s) of `text`, okurigana-correct, with the word's provenance preserved.
    ///
    /// The chosen reading is placed by the SAME okurigana annotator the tier uses
    /// (`FuriganaAnnotator.segments`), so a surface with a plain-kana tail keeps that tail as
    /// its own plain run: 広く with ひろく becomes `[("広","ひろ"), ("く", nil)]` and
    /// reconstructs to ひろく — the reading sits over 広 only, never over the whole surface.
    ///
    /// Provenance survives: the candidate list the popover offered is carried onto the new
    /// reading-bearing run, so correcting a word once does NOT remove the reader's ability to
    /// correct it again. `baseForm` (the lemma) is likewise re-stamped across the runs.
    ///
    /// A surface the annotator cannot split (no kanji to annotate) falls back to one run
    /// bearing the whole chosen reading rather than dropping it — a correction always names a
    /// kanji-bearing word, so this is a safety floor, not the intended path.
    func applyingCorrectedReading(_ chosenReading: String) -> KaraokeWord {
        // Carry forward the provenance/lemma the tokenizer settled onto this word: a correction
        // changes the reading, not the fact that the word still has alternatives to offer.
        let provenance = ruby.compactMap(\.provenance).first
        let baseForm = ruby.compactMap(\.baseForm).first
        var placed = FuriganaAnnotator.segments(token: text, reading: chosenReading)
        if placed.isEmpty {
            placed = [RubySegment(text: text, reading: chosenReading)]
        }
        let stamped = placed.map { segment in
            RubySegment(text: segment.text, reading: segment.reading, baseForm: baseForm,
                        pitch: nil,
                        // Only a reading-bearing run can host provenance; a plain okurigana run
                        // (reading == nil) carries none, matching the tier's own placement.
                        provenance: segment.reading == nil ? nil : provenance)
        }
        return KaraokeWord(id: id, text: text, segmentIndex: segmentIndex,
                           utf16Lower: utf16Lower, utf16Upper: utf16Upper, traits: traits,
                           ruby: stamped, gloss: gloss, tightLeading: tightLeading, url: url)
    }

    public static func tokenize(
        _ text: String,
        segmentIndex: Int,
        styleRuns: [StyleRun] = [],
        reading: ((String) -> String?)? = nil,
        gloss: ((String) -> String?)? = nil,
        baseForm: ((String) -> String?)? = nil,
        sourceRuby: [RubyRun] = [],
        payload: ((String) -> ReadingPayload?)? = nil,
        annotations: (([String]) -> [TokenAnnotation?])? = nil,
        annotatedPayload: ((String, TokenAnnotation) -> ReadingPayload?)? = nil,
        compoundReadings: ((String) -> [ReadingPayload])? = nil,
        segmenter: any CJKWordSegmenter = WordTokenizer.platformCJKSegmenter
    ) -> [KaraokeWord] {
        // Two merges before anything is resolved, for two different disagreements about where a
        // word ends: the author's ruby spans (`mergingAcrossRuby`) and the sentence analysis
        // (`regroupedForAnnotation`, which fixes ２|人 rendering ひと instead of ふたり).
        let regrouped = regroupedForAnnotation(
            mergingAcrossRuby(
                WordTokenizer.tokenize(text, transcription: true, segmenter: segmenter),
                sourceRuby: sourceRuby),
            annotations: annotations)
        let tokens = regrouped.tokens
        // ONE in-context pass per sentence: the aligner annotates the display tokens
        // it can place, and those take reading, base form and the tier's input from
        // the SENTENCE — never from re-analyzing their surface alone, whose
        // re-tokenization can differ (静か alone becomes 静+か, doubling the か).
        // Tokens the aligner could not place keep the per-surface fallback path.
        let aligned = regrouped.annotations
        let tokenAnnotations: [TokenAnnotation?] =
            (aligned?.count == tokens.count ? aligned : nil)
                ?? Array(repeating: nil, count: tokens.count)
        // Ruby overrides for kanji tokens whose okurigana was split off by the tokenizer
        // (一+つ) — dictionary-confirmed merges only; token objects/offsets stay unmerged.
        // Annotated tokens skip the join probes: their ruby is already in-context, and
        // a probe would re-analyze a merged surface in isolation.
        let okurigana = joinedRubyOverrides(tokens: tokens, payload: payload,
                                            baseForm: baseForm, sourceRuby: sourceRuby,
                                            annotations: tokenAnnotations)
        // Pass 1: each token's ruby with the compound join ABSENT — byte-for-byte today's
        // result. Only the individual tokens the tokenizer produced are resolved here; no
        // merged surface is ever analyzed.
        let providers = TokenRubyProviders(reading: reading, baseForm: baseForm,
                                           payload: payload, annotatedPayload: annotatedPayload)
        let baseRuby = tokens.indices.map { index in
            resolveTokenRuby(token: tokens[index], okuriganaOverride: okurigana[index],
                             annotation: tokenAnnotations[index], sourceRuby: sourceRuby,
                             providers: providers)
        }
        // Pass 2: the dictionary-decided compound join for runs the tokenizer split apart
        // (運転手 → 運転|手), keyed by the reading ACTUALLY rendered in pass 1 — the same value
        // Tools/FuriganaQA measures — so heteronym protection and the join judge what the
        // reader sees, not an annotation reading the tier may have discarded. A nil closure
        // skips pass 2 entirely (identical behavior and cost to before the join existed).
        let compound = compoundOverrides(tokens: tokens, baseRuby: baseRuby,
                                         sourceRuby: sourceRuby, compoundReadings: compoundReadings)
        // A run whose reading has no per-character split becomes ONE word carrying ONE ruby
        // (二日[ふつか]). It cannot be an override: overrides are per token, and a segment must
        // tile its own token's surface, so 二日 over the tokens 二|日 is not expressible. The
        // merged word keeps the run's full offset span, so highlighting, find and scroll
        // anchors still resolve; the karaoke unit becomes the compound, which is what it is.
        let spanningStart = Dictionary(uniqueKeysWithValues:
            compound.spanning.map { ($0.range.lowerBound, $0) })
        var words: [KaraokeWord] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            if let run = spanningStart[index], run.range.upperBound <= tokens.endIndex {
                let covered = tokens[run.range]
                let lower = covered.first!.offsets.lower
                let upper = covered.last!.offsets.upper
                words.append(KaraokeWord(
                    id: "\(segmentIndex).\(index)",
                    text: covered.map(\.text).joined(),
                    segmentIndex: segmentIndex,
                    utf16Lower: lower,
                    utf16Upper: upper,
                    traits: StyleRun.traits(in: styleRuns, lower: lower, upper: upper),
                    ruby: [run.segment],
                    gloss: glossFor(surface: covered.map(\.text).joined(), gloss: gloss),
                    tightLeading: covered.first!.tightLeading,
                    url: StyleRun.url(in: styleRuns, lower: lower, upper: upper)))
                index = run.range.upperBound
                continue
            }
            let token = tokens[index]
            words.append(KaraokeWord(
                id: "\(segmentIndex).\(index)",
                text: token.text,
                segmentIndex: segmentIndex,
                utf16Lower: token.offsets.lower,
                utf16Upper: token.offsets.upper,
                traits: StyleRun.traits(in: styleRuns,
                                        lower: token.offsets.lower, upper: token.offsets.upper),
                ruby: compound.overrides[index] ?? baseRuby[index],
                gloss: glossFor(surface: token.text, gloss: gloss),
                tightLeading: token.tightLeading,
                url: StyleRun.url(in: styleRuns, lower: token.offsets.lower, upper: token.offsets.upper))
            )
            index += 1
        }
        return words
    }

    /// The English gloss for a pure-katakana token, or nil. Skips the lookup for any
    /// token that isn't katakana (kanji/hiragana/Latin), so only loanword candidates
    /// hit the dictionary.
    private static func glossFor(surface: String, gloss: ((String) -> String?)?) -> String? {
        guard let gloss, FuriganaAnnotator.isKatakanaWord(surface) else { return nil }
        return gloss(surface)
    }

    /// True if the text contains Japanese/Chinese characters (script without word
    /// spaces). Thin alias over `WordTokenizer` for the reader's CJK layout checks.
    public static func containsCJK(_ text: String) -> Bool { WordTokenizer.containsCJK(text) }

    /// The id of the word containing a highlight offset within `segmentIndex`.
    public static func activeID(
        in words: [KaraokeWord],
        segmentIndex: Int,
        offsets: WordOffsets
    ) -> String? {
        words.first {
            $0.segmentIndex == segmentIndex &&
            $0.utf16Lower <= offsets.lower && offsets.lower < $0.utf16Upper
        }?.id
    }

    /// Ids of every word that overlaps a highlight span within `segmentIndex`. A
    /// single-word span yields one id (the cursor); a multi-word pacer chunk yields
    /// the whole group, so the reader can highlight all of them.
    public static func activeIDs(
        in words: [KaraokeWord],
        segmentIndex: Int,
        offsets: WordOffsets
    ) -> Set<String> {
        var ids = Set<String>()
        for word in words where word.segmentIndex == segmentIndex
            && word.utf16Lower < offsets.upper && offsets.lower < word.utf16Upper {
            ids.insert(word.id)
        }
        return ids
    }
}
