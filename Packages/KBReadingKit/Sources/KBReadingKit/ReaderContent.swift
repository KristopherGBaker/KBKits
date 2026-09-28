public import KBCore

/// Presentation model for the reader: the document's paragraphs pre-tokenized
/// into `KaraokeWord`s (built once per document), plus a per-segment word index
/// for fast active-word lookup from `HighlightState`.
public struct ReaderContent: Sendable {
    public let title: String
    public let paragraphs: [ReaderParagraph]
    /// The reading content as karaoke presentation blocks (paragraphs interleaved
    /// with retained images), materialized once at build. The reader body
    /// re-evaluates on every highlight tick; mapping `paragraphs` to `.karaoke`
    /// there would reallocate the whole array several times a second (and break
    /// identity short-circuiting downstream). Build it here instead.
    public let karaokeBlocks: [KaraokeBlock]
    let wordsBySegment: [Int: [KaraokeWord]]

    /// `reading` (optional) supplies a token's hiragana reading for furigana —
    /// an OpenJTalk-backed lookup when its dictionary is present, else nil so the
    /// tokenizer falls back to `CFStringTokenizer`. Memoized per surface here so a
    /// repeated word costs one lookup per document build.
    /// `readingPayload` (optional) is the JMdict furigana tier: the FINAL display
    /// reading (validate/repair applied) plus optional dictionary placement spans per
    /// kanji token — see `ReadingPayload`. nil (every non-Japanese / no-dictionary
    /// build) keeps furigana byte-identical to the pre-tier path.
    /// Attach pitch to a segment's words, after tokenization rather than during it.
    ///
    /// Pitch cannot be a per-word closure like `reading` or `baseForm`, because accent belongs
    /// to the accent PHRASE: 端 and 橋 both read はし and diverge only once a particle joins
    /// them, giving low-HIGH-HIGH against low-HIGH-low. A provider asked about one surface at a
    /// time cannot see the particle and would collapse that distinction.
    ///
    /// So the provider is handed the segment's word surfaces IN ORDER and returns one pattern
    /// per word, letting it group phrases across the words it was given. Running after
    /// tokenization also guarantees the patterns align to the same word split the reader
    /// renders, rather than to a second, possibly different, tokenization.
    ///
    /// A `nil` provider, a count mismatch, or a `nil` entry all leave a word's ruby untouched,
    /// so a partial or absent answer degrades to today's rendering instead of misaligning it.
    static func applyingPitch(
        _ pitch: (@Sendable ([String]) -> [[MoraPitch]?])?,
        to words: [KaraokeWord]
    ) -> [KaraokeWord] {
        guard let pitch, !words.isEmpty else { return words }
        let patterns = pitch(words.map(\.text))
        guard patterns.count == words.count else { return words }
        return zip(words, patterns).map { word, pattern in
            guard let pattern, !pattern.isEmpty else { return word }
            return word.withPitch(pattern)
        }
    }

    /// Apply a segment's reader-chosen readings to its already-tokenized words.
    ///
    /// Per occurrence and surface-guarded: a word takes a correction only when BOTH its
    /// `(utf16Lower, utf16Upper)` span equals the correction's offsets AND its `text` still
    /// equals the correction's recorded `surface`. Keying on the span (not the surface) is
    /// what makes this per-occurrence — 十分 corrected in one span of a sentence does not
    /// touch a second 十分 at a different span. The surface check is the last defence: a
    /// correction recorded against 十分 must never be written onto a 五分 that now sits at
    /// those offsets, so on a mismatch the word is left exactly as tokenized.
    ///
    /// An empty correction list returns `words` unchanged (the no-choice common case), so a
    /// word with no matching correction is byte-identical to the no-corrections build.
    /// PUBLIC because two platforms need it and there must be only ONE implementation of these
    /// semantics. The Apple apps reach it through `build`; the Android bridge renders through its
    /// own `renderWords` choke point over `KaraokeWord.tokenize` and cannot call `build` yet, so
    /// without this it would have to reimplement the span match, the surface guard and the
    /// okurigana placement - three chances to diverge on the exact behaviours this unit's
    /// mutations exist to protect.
    /// A correction may also span SEVERAL words. The compound join renders 日本人 as the two
    /// tokens 日本|人 sharing one reading, so a reader correcting it records a choice over the
    /// whole run - and a word-by-word match would find no word at 0..3 and silently do nothing,
    /// or, worse, match the head alone and render にほんじん followed by a bare じん. Such a run
    /// COLLAPSES into one word carrying one ruby, exactly as the join's own spanning case does
    /// (二日/ふつか): a reading that belongs to the compound has no per-token split, and the
    /// merged word keeps the run's full offset span, so highlighting, find and scroll anchors
    /// still resolve. The karaoke unit becomes the compound, which is what it is.
    public static func applyingCorrections(
        _ corrections: [RubyCorrection],
        to words: [KaraokeWord]
    ) -> [KaraokeWord] {
        guard !corrections.isEmpty else { return words }
        var result: [KaraokeWord] = []
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            guard let correction = corrections.first(where: { $0.utf16Lower == word.utf16Lower }),
                  let end = runEnd(correction, in: words, from: index)
            else {
                result.append(word)
                index += 1
                continue
            }
            let run = Array(words[index..<end])
            result.append(merged(run, correction: correction))
            index = end
        }
        return result
    }

    /// The index PAST the last word of the run `correction` covers, or nil when the words at
    /// `start` do not tile the correction's span exactly with the recorded surface.
    ///
    /// Both halves of the old guard survive: the span must match exactly (per-occurrence: 十分
    /// corrected in one span does not touch a second 十分 elsewhere) and the concatenated text
    /// must still equal the recorded surface, so a correction written against 十分 is never
    /// applied to a 五分 that now sits at those offsets.
    private static func runEnd(
        _ correction: RubyCorrection,
        in words: [KaraokeWord],
        from start: Int
    ) -> Int? {
        var surface = ""
        var index = start
        while index < words.endIndex, words[index].utf16Upper <= correction.utf16Upper {
            // Gapless: each word must begin where the last ended, or the span is not tiled and
            // the correction names something the tokenizer did not produce.
            guard words[index].utf16Lower == (index == start ? correction.utf16Lower
                                                             : words[index - 1].utf16Upper)
            else { return nil }
            surface += words[index].text
            index += 1
            if words[index - 1].utf16Upper == correction.utf16Upper {
                return surface == correction.surface ? index : nil
            }
        }
        return nil
    }

    /// One word carrying the corrected reading, from a run of one or more.
    ///
    /// A run of ONE returns exactly what the previous word-by-word implementation returned, so
    /// the single-token case - every correction made before compounds were correctable - is
    /// unchanged. A longer run collapses, taking its identity, traits and link from its first
    /// word and its span from the run, and carrying the provenance and lemma the join stamped so
    /// a corrected word can still be corrected again.
    private static func merged(
        _ run: [KaraokeWord],
        correction: RubyCorrection
    ) -> KaraokeWord {
        guard let first = run.first else { return run[0] }
        if run.count == 1 { return first.applyingCorrectedReading(correction.reading) }
        let joined = KaraokeWord(
            id: first.id,
            text: run.map(\.text).joined(),
            segmentIndex: first.segmentIndex,
            utf16Lower: correction.utf16Lower,
            utf16Upper: correction.utf16Upper,
            traits: first.traits,
            ruby: run.flatMap(\.ruby),
            gloss: first.gloss,
            tightLeading: first.tightLeading,
            url: first.url)
        return joined.applyingCorrectedReading(correction.reading)
    }

    /// Build the reader's presentation model.
    ///
    /// `window` (optional) restricts the expensive per-word work to a range of segment
    /// indices. The paragraph structure, `segmentRange`s and `karaokeBlocks` are ALWAYS
    /// the full document, so scroll anchors, the TOC and find targets resolve everywhere;
    /// only segments outside the window skip tokenization and carry an empty word list.
    /// That lets a caller paint the resume window immediately on a long book and swap in
    /// the complete build behind it. `nil` (the default) tokenizes everything, which is
    /// exactly the pre-window behavior.
    ///
    /// A segment with no words is already a normal state here (code blocks and tables are
    /// never tokenized), so every lookup below degrades the same way for an unbuilt
    /// segment: no active word id resolves, and `paragraphID(containing:)` still answers.
    public static func build(
        from document: Document,
        window: Range<Int>? = nil,
        reading: (@Sendable (String) -> String?)? = nil,
        gloss: (@Sendable (String) -> String?)? = nil,
        baseForm: (@Sendable (String) -> String?)? = nil,
        readingPayload: (@Sendable (String) -> ReadingPayload?)? = nil,
        pitch: (@Sendable ([String]) -> [[MoraPitch]?])? = nil,
        annotations: (@Sendable ([String]) -> [TokenAnnotation?])? = nil,
        annotatedPayload: (@Sendable (String, TokenAnnotation) -> ReadingPayload?)? = nil,
        /// JMdict's readings for a joined all-kanji run, so a compound the tokenizer split
        /// (博物館 as 博物 + 館) is read as the word rather than per fragment. Nil keeps the
        /// build identical to the pre-join path. Threaded through here because the reader
        /// reaches `tokenize` ONLY via this builder: without it the join would be reachable
        /// from a test and from the QA harness but never from the app.
        compoundReadings: (@Sendable (String) -> [ReadingPayload])? = nil,
        /// Reader-chosen readings, keyed by segment (sentence) index — the DISPLAY mirror of
        /// the spoken side's `spokenTextTransform`. After a segment is tokenized, a word whose
        /// `(utf16Lower, utf16Upper)` matches a correction AND whose `text` still equals the
        /// correction's recorded `surface` renders the chosen reading over its kanji, per
        /// occurrence. Empty (the default) leaves every word byte-identical to the pre-choice
        /// build. Threaded through here for the same reason `compoundReadings` is: the reader
        /// reaches `tokenize` ONLY via this builder.
        corrections: [Int: [RubyCorrection]] = [:],
        /// Whether the ordinary dictionary can account for a reading of a surface - any entry
        /// whose kanji form begins with the surface having a reading that begins with ours
        /// (`JMDictStore.corroborates`). Supplying it TURNS ON author-ruby propagation: a
        /// surface the author of this document rubied exactly once, that we read in a way no
        /// dictionary form supports, takes the author's reading at every later occurrence.
        ///
        /// Nil (the default) leaves every word byte-identical to the pre-propagation build,
        /// which is what a non-Japanese document and a build with no dictionary both get.
        /// Threaded through here for the same reason `compoundReadings` is: the Apple reader
        /// reaches `tokenize` ONLY via this builder, so a fix that is not passed here is a fix
        /// the app never renders.
        readingCorroborated: (@Sendable (String, String) -> Bool)? = nil,
        /// The author-ruby index to propagate, when the caller already has one. Nil (the
        /// default, and what every app caller passes) derives it from `document` itself, which
        /// is the only correct source for a real book.
        ///
        /// It exists for `Tools/FuriganaQA`, whose build-path divergence check drives `build`
        /// with a ONE-LINE document and compares it against a `tokenize` pass over a whole
        /// book. Without the override that check would report a divergence on every propagated
        /// token - an artifact of the harness's document, not a defect in this wiring - and a
        /// gate that cries wolf gets switched off.
        authorRuby: AuthorRubyIndex? = nil,
        /// The word segmenter, threaded through to `KaraokeWord.tokenize`.
        ///
        /// Defaulted to the platform one, so Apple rendering is byte-identical and no existing
        /// caller changes. It exists because the default is WRONG off Apple platforms:
        /// `WordTokenizer.platformCJKSegmenter` is `ScalarCJKSegmenter` there, which segments by
        /// CHARACTER. Before this parameter, a non-Apple host rendering through `build` silently
        /// lost word segmentation - the compound join cannot fire on per-character tokens, so
        /// 運転手 reads うんてんて - while every gate stayed green, because `CFStringTokenizer`
        /// makes the Apple side immune to the defect. The Android bridge supplies an
        /// OpenJTalk-backed segmenter.
        segmenter: any CJKWordSegmenter = WordTokenizer.platformCJKSegmenter
    ) -> ReaderContent {
        let memoizedReading = Self.memoize(reading)
        let memoizedGloss = Self.memoize(gloss)
        let memoizedBaseForm = Self.memoize(baseForm)
        let memoizedPayload = Self.memoize(readingPayload)
        // The author's own ruby, gathered across the WHOLE document before any segment is
        // tokenized. That is the structural point of building it here: `tokenize` sees one
        // segment at a time and can never learn what the author said four lines earlier, and
        // a first appearance rubied in chapter one has to reach chapter nine.
        //
        // Derived from the document each build and never cached, so it cannot leak into
        // another book - the property `RubyCorrection` needs a text hash to get.
        let authorRuby = authorRuby
            ?? (readingCorroborated == nil ? AuthorRubyIndex.empty
                                           : AuthorRubyIndex(document: document))
        var wordsBySegment: [Int: [KaraokeWord]] = [:]
        // The verbatim code of each `.codeBlock` segment, keyed by segment index — surfaced
        // as a `KaraokeBlock.codeBlock` (never tokenized) when weaving the karaoke blocks.
        var codeBySegment: [Int: String] = [:]
        // The rendered aligned-text of each `.table` segment, keyed by segment index —
        // surfaced as a `KaraokeBlock.table` (never tokenized), parallel to code blocks.
        var tableBySegment: [Int: String] = [:]
        for segment in document.segments {
            // A code block is verbatim and announce-only: keep its display text intact and do
            // NOT tokenize it into words (no per-word karaoke for code), so its word list stays
            // empty and no active word id ever resolves within it.
            if case .codeBlock = segment.blockStyle {
                codeBySegment[segment.sentenceIndex] = segment.displayText
                wordsBySegment[segment.sentenceIndex] = []
                continue
            }
            // A table is verbatim + announce-only too: keep its rendered display text intact and
            // do NOT tokenize it into words (no per-word karaoke for a table).
            if case .table = segment.blockStyle {
                tableBySegment[segment.sentenceIndex] = segment.displayText
                wordsBySegment[segment.sentenceIndex] = []
                continue
            }
            // Outside the caller's window: keep the segment (its paragraph, range and block
            // placement are unchanged) but skip tokenization, the reading/pitch providers and
            // every other per-word cost. This is the whole point of a windowed build.
            if let window, !window.contains(segment.sentenceIndex) {
                wordsBySegment[segment.sentenceIndex] = []
                continue
            }
            // Render the display text with its retained styling; offsets still align
            // with the highlight while displayText == text (the spoken side).
            let words =
                KaraokeWord.tokenize(segment.displayText, segmentIndex: segment.sentenceIndex,
                                     styleRuns: segment.styleRuns,
                                     reading: memoizedReading, gloss: memoizedGloss,
                                     baseForm: memoizedBaseForm,
                                     sourceRuby: segment.rubyRuns,
                                     payload: memoizedPayload,
                                     annotations: annotations,
                                     annotatedPayload: annotatedPayload,
                                     compoundReadings: compoundReadings,
                                     segmenter: segmenter)
            // The author's ruby first, then the READER's choices on top of it: a reader who
            // disagreed with a propagated reading and corrected it must not have the author's
            // ruby written back over their choice on the next build.
            let propagated = readingCorroborated.map {
                Self.applyingAuthorRuby(authorRuby, corroborated: $0, to: words)
            } ?? words
            // Apply the reader's chosen readings for THIS sentence before pitch, so a corrected
            // word carries the chosen reading on the same per-segment path the app renders.
            let corrected = Self.applyingCorrections(corrections[segment.sentenceIndex] ?? [],
                                                     to: propagated)
            wordsBySegment[segment.sentenceIndex] = Self.applyingPitch(pitch, to: corrected)
        }

        var paragraphs: [ReaderParagraph] = []
        // Every chapter's paragraphs, in order — not just the first chapter, or a
        // multi-chapter book renders only chapter 1 (and TOC jumps have no target).
        let modelParagraphs = document.chapters.flatMap(\.paragraphs)
        if modelParagraphs.isEmpty {
            // Fallback: one paragraph per segment.
            for segment in document.segments {
                paragraphs.append(ReaderParagraph(
                    id: segment.sentenceIndex,
                    segmentRange: segment.sentenceIndex ..< (segment.sentenceIndex + 1),
                    words: wordsBySegment[segment.sentenceIndex] ?? [],
                    blockStyle: segment.blockStyle
                ))
            }
        } else {
            for paragraph in modelParagraphs {
                let words = paragraph.segmentRange.flatMap { wordsBySegment[$0] ?? [] }
                // A paragraph is uniformly one block role — take its first segment's.
                let blockStyle = document.segment(at: paragraph.segmentRange.lowerBound)?.blockStyle ?? .body
                paragraphs.append(ReaderParagraph(
                    id: paragraph.segmentRange.lowerBound,
                    segmentRange: paragraph.segmentRange,
                    words: words,
                    blockStyle: blockStyle
                ))
            }
        }

        return ReaderContent(title: document.title, paragraphs: paragraphs,
                             karaokeBlocks: Self.karaokeBlocks(paragraphs: paragraphs,
                                                               images: document.images,
                                                               codeBySegment: codeBySegment,
                                                               tableBySegment: tableBySegment),
                             wordsBySegment: wordsBySegment)
    }

    /// Wrap a per-surface lookup with a cache so a repeated word (reading, gloss, or
    /// tier payload) costs one provider call per document build. Single-threaded
    /// within `build`.
    private static func memoize<Value>(
        _ provider: (@Sendable (String) -> Value?)?
    ) -> ((String) -> Value?)? {
        guard let provider else { return nil }
        var cache: [String: Value?] = [:]
        return { surface in
            if let hit = cache[surface] { return hit }
            let value = provider(surface)
            cache[surface] = value
            return value
        }
    }

    /// Weave retained images into the paragraph stream at their anchors. Each image
    /// renders *before* the paragraph whose first segment matches its anchor (and any
    /// trailing images go after the last paragraph), preserving source order.
    private static func karaokeBlocks(
        paragraphs: [ReaderParagraph],
        images: [DocumentImage],
        codeBySegment: [Int: String],
        tableBySegment: [Int: String]
    ) -> [KaraokeBlock] {
        // A `.codeBlock`/`.table`-role paragraph surfaces as a verbatim un-tokenized block; every
        // other role keeps its tokenized karaoke paragraph. All keep the paragraph's stable id
        // (its first segment index) as the scroll anchor, so navigation still resolves.
        func block(for paragraph: ReaderParagraph) -> KaraokeBlock {
            if case .codeBlock = paragraph.blockStyle {
                return .codeBlock(KaraokeCodeBlock(id: paragraph.id,
                                                   code: codeBySegment[paragraph.id] ?? ""))
            }
            if case .table = paragraph.blockStyle {
                return .table(KaraokeTable(id: paragraph.id,
                                           text: tableBySegment[paragraph.id] ?? ""))
            }
            return .paragraph(paragraph.karaoke)
        }
        guard !images.isEmpty else { return paragraphs.map(block) }
        let sorted = images.sorted {
            ($0.anchorSegmentIndex, $0.order) < ($1.anchorSegmentIndex, $1.order)
        }
        var blocks: [KaraokeBlock] = []
        var cursor = 0
        func drainImages(upTo segmentIndex: Int) {
            while cursor < sorted.count, sorted[cursor].anchorSegmentIndex <= segmentIndex {
                let image = sorted[cursor]
                blocks.append(.image(KaraokeImage(id: image.id, data: image.data, altText: image.altText,
                                                  aspectRatio: image.aspectRatio)))
                cursor += 1
            }
        }
        for paragraph in paragraphs {
            drainImages(upTo: paragraph.segmentRange.lowerBound)
            blocks.append(block(for: paragraph))
        }
        while cursor < sorted.count {
            let image = sorted[cursor]
            blocks.append(.image(KaraokeImage(id: image.id, data: image.data, altText: image.altText,
                                              aspectRatio: image.aspectRatio)))
            cursor += 1
        }
        return blocks
    }

    /// The words of ONE segment, as the reader renders them.
    ///
    /// `paragraphs` is public but a paragraph can span several segments, so a caller holding only
    /// that cannot slice one sentence out of it. The focus surfaces need exactly one sentence,
    /// and re-tokenizing it themselves is what made them render no furigana at all: they called
    /// `KaraokeWord.tokenize` with no reading, no tier, no join and no propagation, so a sentence
    /// that reads 沙名子[さなこ] in the reader came out bare beside it.
    ///
    /// Empty for a segment outside a windowed build, for a code block or table (never tokenized),
    /// and for an index the document does not have - all of which are already normal states here.
    public func words(inSegment segmentIndex: Int) -> [KaraokeWord] {
        wordsBySegment[segmentIndex] ?? []
    }

    /// The scroll anchor (paragraph id) for the paragraph containing a segment.
    public func paragraphID(containing segmentIndex: Int) -> Int? {
        paragraphs.first { $0.segmentRange.contains(segmentIndex) }?.id
    }

    /// The active word id within `segmentIndex` for the given highlight offsets
    /// (the chunk anchor / cursor — used for follow-scrolling).
    public func activeWordID(segmentIndex: Int, offsets: WordOffsets) -> String? {
        KaraokeWord.activeID(in: wordsBySegment[segmentIndex] ?? [],
                             segmentIndex: segmentIndex, offsets: offsets)
    }

    /// Every active word id for the given highlight span — one for a word cursor,
    /// several for a pacer word-group.
    public func activeWordIDs(segmentIndex: Int, offsets: WordOffsets) -> Set<String> {
        KaraokeWord.activeIDs(in: wordsBySegment[segmentIndex] ?? [],
                              segmentIndex: segmentIndex, offsets: offsets)
    }

    /// The active word id for a `HighlightState` (the chunk anchor / cursor, used
    /// for follow-scrolling), or nil when nothing is highlighted. Unwraps the
    /// segment + word offsets both reader UIs previously destructured by hand.
    @MainActor
    public func activeWordID(for highlight: HighlightState) -> String? {
        guard let segmentIndex = highlight.currentSegmentID?.sentenceIndex,
              let offsets = highlight.currentWordOffsets
        else { return nil }
        return activeWordID(segmentIndex: segmentIndex, offsets: offsets)
    }

    /// Every active word id for a `HighlightState` — one for a word cursor, several
    /// for a pacer word-group; empty when nothing is highlighted.
    @MainActor
    public func activeWordIDs(for highlight: HighlightState) -> Set<String> {
        guard let segmentIndex = highlight.currentSegmentID?.sentenceIndex,
              let offsets = highlight.currentWordOffsets
        else { return [] }
        return activeWordIDs(segmentIndex: segmentIndex, offsets: offsets)
    }
}

public struct ReaderParagraph: Identifiable, Sendable {
    public let id: Int // first segment index (also the scroll anchor)
    let segmentRange: Range<Int>
    public let words: [KaraokeWord]
    let blockStyle: BlockStyle

    /// Presentation paragraph for the karaoke view.
    public var karaoke: KaraokeParagraph {
        KaraokeParagraph(id: id, words: words, blockStyle: blockStyle)
    }
}
