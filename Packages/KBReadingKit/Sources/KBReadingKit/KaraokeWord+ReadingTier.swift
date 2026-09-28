import KBCore
import Foundation

/// The dictionary reading tier's consumption side: converting `ReadingPayload`
/// placement spans into ruby segments, and the guarded okurigana token join for
/// splits like 一+つ / 俄+か (`CFStringTokenizer` separates the okurigana, so the
/// kanji token alone validates to the wrong reading — いち, not ひと).
extension KaraokeWord {

    /// Ruby overrides (by token index) from dictionary-confirmed okurigana joins.
    ///
    /// For each kanji-bearing token followed by contiguous kana-only token(s)
    /// (lookahead ≤ 2), the MERGED surface is offered to the tier `payload` closure.
    /// The join applies ONLY when the merged surface resolves WITH placement spans
    /// (dictionary-confirmed pair) whose kana all sits over the kanji token — then the
    /// kanji token's ruby comes from those spans (一→ひと) and the kana tokens stay
    /// bare, exactly as they render today. Token objects, offsets, and highlight
    /// boundaries are never merged: only ruby content changes. Any group touched by
    /// source ruby is skipped — author ruby stays above this tier.
    static func joinedRubyOverrides(
        tokens: [WordTokenizer.Token],
        payload: ((String) -> ReadingPayload?)?,
        baseForm: ((String) -> String?)?,
        sourceRuby: [RubyRun],
        annotations: [TokenAnnotation?] = []
    ) -> [Int: [RubySegment]] {
        guard let payload else { return [:] }
        var overrides: [Int: [RubySegment]] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard FuriganaAnnotator.containsKanji(token.text),
                  !overlapsSourceRuby(token, sourceRuby),
                  // An in-context-annotated token needs no join: its ruby already
                  // comes from the sentence, and a probe here would re-analyze the
                  // merged surface in isolation.
                  !(annotations.indices.contains(index) && annotations[index] != nil)
            else { index += 1; continue }
            let followers = kanaFollowers(of: index, in: tokens, sourceRuby: sourceRuby)
            var consumed = 0
            // Longest merge first (俄+か+に before 俄+か), first confirmed one wins.
            for count in stride(from: followers.count, through: 1, by: -1) where consumed == 0 {
                let merged = token.text + followers.prefix(count).map(\.text).joined()
                guard let resolved = payload(merged), let spans = resolved.spans,
                      let head = headSegments(merged: merged, spans: spans,
                                              headLength: token.text.count) else { continue }
                let lemma = baseForm?(merged) ?? merged
                overrides[index] = head.map { $0.withBaseForm(lemma) }
                consumed = count
            }
            index += consumed + 1
        }
        return overrides
    }

    /// Up to two contiguous kana-only follower tokens (no gap, no source ruby) — the
    /// okurigana candidates the tokenizer split off the kanji token at `index`.
    private static func kanaFollowers(
        of index: Int,
        in tokens: [WordTokenizer.Token],
        sourceRuby: [RubyRun]
    ) -> [WordTokenizer.Token] {
        var followers: [WordTokenizer.Token] = []
        var upper = tokens[index].offsets.upper
        for next in tokens.dropFirst(index + 1).prefix(2) {
            guard next.offsets.lower == upper,
                  FuriganaAnnotator.isKanaOnly(next.text),
                  !overlapsSourceRuby(next, sourceRuby) else { break }
            followers.append(next)
            upper = next.offsets.upper
        }
        return followers
    }

    private static func overlapsSourceRuby(_ token: WordTokenizer.Token, _ sourceRuby: [RubyRun]) -> Bool {
        sourceRuby.contains { $0.lower < token.offsets.upper && token.offsets.lower < $0.upper }
    }

    /// The kanji token's ruby segments from a merged surface's placement spans, or nil
    /// when the join must be rejected: spans that don't tile the merged surface, a span
    /// straddling the token boundary, kana placed over the okurigana tokens (the merge
    /// isn't a plain okurigana split), or no kana over the kanji token at all.
    private static func headSegments(merged: String, spans: [ReadingSpan], headLength: Int) -> [RubySegment]? {
        guard spansTile(spans, count: merged.count) else { return nil }
        var head: [ReadingSpan] = []
        for span in spans {
            if span.range.upperBound <= headLength {
                head.append(span)
            } else if span.range.lowerBound < headLength || span.kana != nil {
                // Straddles the boundary, or reads kana over the bare okurigana tokens.
                return nil
            }
        }
        guard head.contains(where: { $0.kana != nil }),
              let segments = segments(surface: String(Array(merged)[0..<headLength]), spans: head)
        else { return nil }
        return segments
    }

    /// Convert dictionary placement spans into ruby segments over `surface`, merging
    /// adjacent bare (nil-kana) spans into one plain run. Returns nil unless the spans
    /// exactly tile the surface — the caller then falls back to the annotator alignment,
    /// so the tiling invariant can never break.
    static func segments(surface: String, spans: [ReadingSpan]) -> [RubySegment]? {
        let chars = Array(surface)
        guard spansTile(spans, count: chars.count) else { return nil }
        var segments: [RubySegment] = []
        for span in spans {
            let text = String(chars[span.range])
            if span.kana == nil, let last = segments.last, last.reading == nil {
                segments[segments.count - 1] = RubySegment(text: last.text + text)
            } else {
                segments.append(RubySegment(text: text, reading: span.kana))
            }
        }
        return segments
    }

    /// Whether spans exactly tile `0..<count` in order (no gaps, overlaps, or overrun).
    private static func spansTile(_ spans: [ReadingSpan], count: Int) -> Bool {
        var cursor = 0
        for span in spans {
            guard span.range.lowerBound == cursor else { return false }
            cursor = span.range.upperBound
        }
        return cursor == count && count > 0
    }
}

extension FuriganaAnnotator {
    /// A token made entirely of kana (hiragana/katakana, incl. ー) — an okurigana
    /// candidate for the reading-tier token join.
    static func isKanaOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isKanaScalar)
    }

    /// A token made entirely of kanji (URO + Extension A + 々) — a compound-join
    /// candidate. Matches the join instrument's `isAllKanji` gate exactly.
    static func isKanjiOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy(isJoinKanjiScalar)
    }

    /// A token that may OPEN a compound run while carrying its own okurigana: a kanji FIRST,
    /// at least one kana LETTER, and nothing but kanji and kana letters throughout (生き, 読み,
    /// 打ち合わ).
    ///
    /// Deliberately narrower than "contains kanji". A leading kana would make the joined
    /// surface start mid-word, and anything that is neither kanji nor kana is never part of a
    /// form JMdict lists, so admitting it would only cost lookups.
    ///
    /// It is also narrower than `isKanaScalar`, which answers "is this scalar in a kana block"
    /// and therefore says yes to ・ (U+30FB KATAKANA MIDDLE DOT) and ゠ (U+30A0 KATAKANA-HIRAGANA
    /// DOUBLE HYPHEN). Those are PUNCTUATION that happens to live in the katakana block, and a
    /// cross-model review found the hole by joining 生・|方 - a run over a token that is not a
    /// word. The stricter test is local to this predicate on purpose: `isKanaScalar` also gates
    /// the okurigana-follower join and the absorption probe, whose measured behaviour must not
    /// move for a fix to THIS rule.
    static func isKanjiWithOkurigana(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, isJoinKanjiScalar(first),
              text.unicodeScalars.contains(where: isKanaLetterScalar)
        else { return false }
        return text.unicodeScalars.allSatisfy { isJoinKanjiScalar($0) || isKanaLetterScalar($0) }
    }

    /// A kana LETTER, as opposed to a scalar that merely sits in a kana block.
    ///
    /// IN: ー (U+30FC prolonged sound mark) and the COMBINING voiced marks U+3099/U+309A, which
    /// spell part of a word - a decomposed が is か + U+3099, and excluding it would reject a
    /// perfectly ordinary token depending only on how the text was normalised.
    ///
    /// OUT: ・ (U+30FB) and ゠ (U+30A0), which are separators, and the SPACING sound marks ゛
    /// (U+309B) and ゜ (U+309C), which stand alone rather than attaching to a kana and so are
    /// punctuation for this purpose. The first pair came from a cross-model review that joined
    /// 生・|方; the second pair from the same review's residual note, and is the same class.
    private static func isKanaLetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30FB, 0x30A0, 0x309B, 0x309C: false
        default: isKanaScalar(scalar)
        }
    }

    private static func isJoinKanjiScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || scalar.value == 0x3005
    }
}

/// The dictionary-decided compound join. The display tokenizer (and OpenJTalk) split a
/// kanji compound JMdict holds as one entry (運転手 -> 運転|手) and each half is read
/// alone, so the ruby across the run spells a nonword (うんてんて). This join asks the
/// dictionary what readings the JOINED form has and, when the reading we already render
/// is not among them, replaces it: unambiguously where the dictionary settles it, and
/// otherwise by the nearest-reading heuristic in `nearest`, which is a considered guess
/// and says so.
///
/// It is decided by the dictionary, never by re-analysing the merged surface (that is the
/// 静か → しずかか defect), so unlike `joinedRubyOverrides` it is SAFE to run on the
/// in-context-annotated tokens the pipeline actually ships.
extension KaraokeWord {

    /// The injected JMdict seam for the compound join: a joined form's kana readings, and
    /// the JmdictFurigana placement-spans row for one (form, reading) pair. Bundled so the
    /// decision never re-analyses a merged surface — it only reads the dictionary.
    struct CompoundJoinLookup {
        let readings: (String) -> [String]
        let spans: (String, String) -> [ReadingSpan]?
    }

    /// Ruby overrides (by token index) from dictionary-confirmed compound joins.
    ///
    /// For each maximal run of adjacent, gapless, all-kanji, author-ruby-free display
    /// tokens, sub-runs of length >= 2 are scanned LONGEST FIRST and NON-OVERLAPPING
    /// (歴史博物館 before 博物館, and 博物館 even when it sits inside a longer ineligible
    /// stretch). `readings(form)` gives the joined form's kana readings; `spans(form,
    /// reading)` gives the JmdictFurigana placement row for a pair. `renderedReadings` is the
    /// reading each token ACTUALLY renders (aligned to `tokens`); the run is left alone unless
    /// that concatenated rendering is absent from `readings(joined)` AND a replacement is
    /// settled - by the dictionary where it can be, otherwise by the nearest-reading
    /// heuristic, which declines ties.
    static func compoundJoinOverrides(
        tokens: [WordTokenizer.Token],
        renderedReadings: [String],
        sourceRuby: [RubyRun],
        readings: @escaping (String) -> [String],
        spans: @escaping (String, String) -> [ReadingSpan]?
    ) -> JoinResult {
        let lookup = CompoundJoinLookup(readings: readings, spans: spans)
        var result = JoinResult()
        var index = 0
        while index < tokens.count {
            guard joinEligible(tokens[index], sourceRuby: sourceRuby)
                    || joinHeadEligible(tokens[index], sourceRuby: sourceRuby)
            else { index += 1; continue }
            var end = index + 1
            while end < tokens.count,
                  joinEligible(tokens[end], sourceRuby: sourceRuby),
                  tokens[end].offsets.lower == tokens[end - 1].offsets.upper {
                end += 1
            }
            scanRun(tokens: tokens, renderedReadings: renderedReadings,
                    range: index..<end, lookup: lookup, into: &result)
            index = end
        }
        return result
    }

    /// Longest-first, non-overlapping sub-run scan over `range` — the exact grouping
    /// `Tools/FuriganaQA.joinRuns` measures, so a run this replaces is a run the gate sees.
    private static func scanRun(
        tokens: [WordTokenizer.Token],
        renderedReadings: [String],
        range: Range<Int>,
        lookup: CompoundJoinLookup,
        into result: inout JoinResult
    ) {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            var matched = false
            var length = range.upperBound - cursor
            while length >= 2 {
                let runTokens = Array(tokens[cursor..<(cursor + length)])
                let runRendered = Array(renderedReadings[cursor..<(cursor + length)])
                // A run OPENED by an okurigana-bearing token is held to a stricter standard: it
                // is replaced only when the settled reading has a placement row that distributes
                // per token, and never when that reading absorbs okurigana the text spells on.
                let okuriganaHead = FuriganaAnnotator.isKanjiWithOkurigana(runTokens[0].text)
                switch decideRun(runTokens, renderedReadings: runRendered, lookup: lookup,
                                 requirePlacement: okuriganaHead) {
                case .unknown:
                    length -= 1
                case .leave:
                    // A KNOWN joined form is consumed even when left alone, and shorter
                    // sub-runs inside it are NOT tried — deliberately matching
                    // FuriganaQA.joinRuns, which stops at the first (longest) form the
                    // dictionary knows and moves its cursor past it. Instrument parity means
                    // the fix never silently disagrees with a run the gate cannot see.
                    cursor += length; matched = true
                case .replace(let perToken):
                    for (offset, segments) in perToken.enumerated() {
                        result.overrides[cursor + offset] = segments
                    }
                    cursor += length; matched = true
                case .spanning(let segment):
                    result.spanning.append(
                        SpanningRun(range: cursor..<(cursor + length), segment: segment))
                    cursor += length; matched = true
                }
                if matched { break }
            }
            if !matched { cursor += 1 }
        }
    }

    /// A run's tokens rendered as ONE word carrying ONE ruby, plus the range it replaces.
    struct SpanningRun: Hashable {
        let range: Range<Int>
        let segment: RubySegment
    }

    /// Per-token replacements, plus runs that must collapse into a single word because their
    /// reading cannot be split per character.
    struct JoinResult {
        var overrides: [Int: [RubySegment]] = [:]
        var spanning: [SpanningRun] = []
    }

    private enum RunDecision {
        case unknown                     // joined form not in the dictionary: dig shorter
        case leave                       // known form, but nothing to (or safe to) replace
        case replace([[RubySegment]])    // per-token ruby segments for the whole run
        /// One indivisible reading over the whole run (二日/ふつか). The reading belongs to the
        /// compound as a unit and has no per-character split, so the only truthful rendering
        /// is a single ruby spanning every token of the run.
        case spanning(RubySegment)
    }

    private static func decideRun(
        _ runTokens: [WordTokenizer.Token],
        renderedReadings: [String],
        lookup: CompoundJoinLookup,
        requirePlacement: Bool = false
    ) -> RunDecision {
        let joined = runTokens.map(\.text).joined()
        let candidates = lookup.readings(joined)
        guard !candidates.isEmpty else { return .unknown }
        // `ours` is what the run ACTUALLY renders (already katakana-folded per token), not an
        // annotation reading the tier may have discarded downstream. Heteronym protection is
        // then fed the truth: a rendering already among JMdict's readings is left alone.
        let ours = normalizeKana(renderedReadings.joined())
        // `.unknown` rather than `.leave` under `requirePlacement`: `.leave` CONSUMES the run and
        // stops the scan digging into it, and an okurigana-head run that decides nothing must
        // leave the all-kanji sub-runs inside it scanned exactly as they are today.
        if candidates.contains(where: { normalizeKana($0) == ours }) {
            return requirePlacement ? .unknown : .leave
        }
        guard let replacement = chooseReplacement(joined, candidates, lookup.spans, ours: ours)
        else { return requirePlacement ? .unknown : .leave }
        if requirePlacement,
           absorbsOkurigana(joined, reading: replacement.reading, lookup: lookup) {
            return .unknown
        }
        // Replace ONLY when the settled reading's spans distribute per kanji across the display
        // tokens. When there is no spans row, or the row is one indivisible span (二日/ふつか,
        // jukujikun) that straddles the 二|日 token boundary, `distribute` returns nil and the
        // run is LEFT ALONE. Putting an indivisible reading on whichever token comes first is a
        // GUESS about placement — the guess rule 4 already refuses — and for an all-kanji run it
        // renders `reading + bare kanji`, which can never equal a kana reading: measured over a
        // 20-book corpus that fallback fired 316 times across 84 forms and was correct ZERO
        // times, while turning 二[に]日[ひ] into 二[ふつか]日. So decline it.
        // The candidate list is stamped onto the segments here, where it still exists. It used
        // to be discarded, which left a heuristic pick looking exactly as settled on screen as
        // a dictionary one and would have made the reader-choice affordance a regression when
        // it arrived (docs/furigana/backlog-reading-choice.md).
        let provenance = ReadingProvenance(candidates: candidates, chosen: replacement.reading,
                                           source: replacement.source)
        if let spanRow = replacement.spans,
           let perToken = distribute(runTokens, spans: spanRow, lemma: joined,
                                     provenance: provenance) {
            return .replace(perToken)
        }
        // An okurigana head means part of the surface already reads as itself, so a single ruby
        // spanning the run would put kana over kana (生き方 → 生き方[いきかた]). Without a row
        // that distributes there is no truthful placement, so decline and let the shorter
        // all-kanji sub-runs be scanned as they are today.
        if requirePlacement { return .unknown }
        // The reading is settled but will not tile per character: either JmdictFurigana has no
        // row, or the row is ONE indivisible span (二日/ふつか, jukujikun) straddling the token
        // boundary. Declining left the nonword the tokenizer produced on the page (二[に]日[ひ]),
        // which is never right. Putting the whole reading on the FIRST token was tried and was
        // correct zero times in 316, because it renders 二[ふつか]日 with a bare kanji inside the
        // word's own furigana. Spanning the run with one ruby is the reading the dictionary
        // actually gives, at the granularity it gives it.
        return .spanning(RubySegment(text: joined, reading: replacement.reading,
                                     baseForm: joined, provenance: provenance))
    }

    /// The replacement (reading, optional spans) for a joined form whose rendered reading is
    /// wrong, or nil when nothing settles it. Three arms, in decreasing confidence: exactly
    /// one kana reading (spans used when the pair has a row); several readings with EXACTLY
    /// ONE carrying a placement-spans row; and failing both, the nearest candidate to what
    /// the page already renders (see `nearest`, which states its tradeoff). Ties decline.
    private static func chooseReplacement(
        _ joined: String,
        _ candidates: [String],
        _ spans: (String, String) -> [ReadingSpan]?,
        ours: String
    ) -> Replacement? {
        if candidates.count == 1 {
            let reading = candidates[0]
            let row = spans(joined, reading)
            return Replacement(reading: reading, spans: (row?.isEmpty == false) ? row : nil,
                               source: .dictionary)
        }
        let withSpans = candidates.compactMap { reading -> (String, [ReadingSpan])? in
            guard let row = spans(joined, reading), !row.isEmpty else { return nil }
            return (reading, row)
        }
        if withSpans.count == 1 {
            return Replacement(reading: withSpans[0].0, spans: withSpans[0].1,
                               source: .dictionary)
        }
        // Scored over ALL candidates, not just the span-backed ones. Scoring only `withSpans`
        // would silently drop the nearest candidate when it happens to lack a placement row
        // and render a FARTHER reading instead, which asserts a reading the evidence points
        // away from. Picking the nearest and then failing to place it is the honest outcome:
        // the caller declines the run, exactly as it does for every other unplaceable reading.
        guard let pick = nearest(candidates, ours: ours) ?? commonest(candidates, ours: ours)
        else { return nil }
        let row = spans(joined, pick)
        return Replacement(reading: pick, spans: (row?.isEmpty == false) ? row : nil,
                           source: .heuristic)
    }

    /// What settled a joined form's reading: the reading, its placement row when the pair has
    /// one, and WHICH arm decided. Named rather than a tuple because the third member is the
    /// one a reader-facing affordance keys off, and an unlabelled `.2` hides that.
    private struct Replacement {
        let reading: String
        let spans: [ReadingSpan]?
        let source: ReadingProvenance.Source
    }

    /// The candidate agreeing with the MOST of what the page already renders, when exactly one
    /// candidate is nearest. Used only after the unambiguous arms above decline.
    ///
    /// Why a prefix and not a guess: the per-token analysis is usually right about most of a
    /// run and wrong about one part, so the candidate sharing the longest leading kana run is
    /// the one the analysis was reaching for. 日本人 is the clean case - we render にっぽん +
    /// ひと, JMdict lists にほんじん and にっぽんじん, and only the second agrees with the
    /// prefix already correct.
    ///
    /// THE TRADEOFF, deliberately taken and not an oversight. This is a heuristic and it will
    /// sometimes pick a contextually wrong reading: 十分 becomes じゅうぶん (sufficient) where
    /// a passage may mean じゅっぷん (ten minutes), and 四月 becomes よつき (four months) where
    /// しがつ (April) is far commoner. The argument for it is that the alternative is NOT "no
    /// reading" - it is a WRONG one, because the run already renders something. Today 十分
    /// renders じゅうふん, which is not a reading of the word in any context. Replacing a
    /// nonword with a real reading that may be contextually wrong is a smaller error, and it
    /// is graded against the author's own ruby rather than taste.
    ///
    /// The real answer to this class is asking the reader, which is why the candidate list is
    /// worth keeping when that affordance is built. See docs/furigana/backlog-reading-choice.md.
    private static func nearest(_ candidates: [String], ours: String) -> String? {
        guard !candidates.isEmpty, !ours.isEmpty else { return nil }
        let scored = candidates.map { (sharedPrefix(normalizeKana($0), ours), $0) }
        guard let best = scored.map(\.0).max() else { return nil }
        let winners = scored.filter { $0.0 == best }
        // A tie is not settled by this rule any more than by the arms above: leave it. This
        // also covers "nothing shares a prefix at all": `nearest` is only reached with two or
        // more candidates, so a best score of zero means EVERY candidate scored zero, which is
        // a tie and declines right here. An explicit `best > 0` guard was written first and
        // removed once mutation testing showed that deleting it changed no outcome. It was
        // unreachable, and a guard no test can reach is worse than the invariant written down.
        guard winners.count == 1 else { return nil }
        return winners[0].1
    }

    /// The dictionary's FIRST reading, but only when what the page renders shares nothing with
    /// any candidate - which means it is not a reading the word has in any context, but a kun
    /// concatenation the tokenizer assembled (安心 rendered やすこころ, 艶書 つやしょ).
    ///
    /// The line is deliberate. Where the rendering partly agrees with a candidate there is real
    /// ambiguity and `nearest` either settles it or declines; guessing there would overwrite a
    /// genuine heteronym (一日 is いちにち or ついたち depending on the sentence) and is the
    /// reader's call, not ours. Where it agrees with NOTHING there is no ambiguity to respect,
    /// only a nonword, and JMdict lists its readings commonest-first.
    ///
    /// Measured over 18 books: 73 author-ruby positions recovered against 35 changed, and ZERO
    /// forms went from right to wrong. Reported as `.heuristic`, so it invites correction.
    private static func commonest(_ candidates: [String], ours: String) -> String? {
        guard !ours.isEmpty, candidates.count > 1,
              candidates.allSatisfy({ sharedPrefix(normalizeKana($0), ours) == 0 })
        else { return nil }
        return candidates.first
    }

    /// Length of the longest common leading run of two kana strings, in Characters so a
    /// combining or surrogate pair cannot split a grapheme mid-way.
    private static func sharedPrefix(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0.0 == $0.1 }.count
    }

    /// Distribute the joined form's placement spans across the run's tokens, per kanji
    /// (博物館 → 博[はく]物[ぶつ]館[かん]). Nil when a span straddles a token boundary or
    /// the spans do not tile the joined surface — the caller then LEAVES the run alone
    /// rather than guess a placement.
    private static func distribute(
        _ runTokens: [WordTokenizer.Token],
        spans: [ReadingSpan],
        lemma: String,
        provenance: ReadingProvenance
    ) -> [[RubySegment]]? {
        let perToken = runTokens.map { Array($0.text) }
        let total = perToken.reduce(0) { $0 + $1.count }
        guard spansTileRange(spans, count: total) else { return nil }
        var result: [[RubySegment]] = []
        var start = 0
        for chars in perToken {
            let stop = start + chars.count
            var local: [ReadingSpan] = []
            for span in spans {
                if span.range.lowerBound >= start, span.range.upperBound <= stop {
                    local.append(ReadingSpan(range: (span.range.lowerBound - start)..<(span.range.upperBound - start),
                                             kana: span.kana))
                } else if span.range.lowerBound < stop, span.range.upperBound > start {
                    return nil   // a span straddles the token boundary
                }
            }
            guard let segments = segments(surface: String(chars), spans: local) else { return nil }
            result.append(segments.map {
                // Only a reading-bearing run hosts provenance; a plain okurigana run carries
                // none, matching `KaraokeWord.applyingCorrectedReading`'s placement. Before the
                // okurigana head this was near-theoretical (a JMdict row over an all-kanji form
                // rarely has a bare span); with 生[い]き it is the normal shape.
                RubySegment(text: $0.text, reading: $0.reading, baseForm: lemma,
                            pitch: $0.pitch, provenance: $0.reading == nil ? nil : provenance)
            })
            start = stop
        }
        return result
    }

    private static func joinEligible(_ token: WordTokenizer.Token, sourceRuby: [RubyRun]) -> Bool {
        FuriganaAnnotator.isKanjiOnly(token.text) && !overlapsSourceRuby(token, sourceRuby)
    }

    /// Whether a token may OPEN a run while carrying its own okurigana. Only the HEAD of a run
    /// may: every later token stays kanji-only, so the class widens by one token at one end.
    private static func joinHeadEligible(_ token: WordTokenizer.Token, sourceRuby: [RubyRun]) -> Bool {
        FuriganaAnnotator.isKanjiWithOkurigana(token.text) && !overlapsSourceRuby(token, sourceRuby)
    }

    /// Whether the joined surface is an okurigana-LESS variant spelling whose canonical form
    /// carries the okurigana: 受け取 for 受け取り, 取り扱 for 取り扱い, 打ち壊 for 打ち壊し,
    /// 積み重 for 積み重ね. The reading such a form carries ABSORBS okurigana that the running
    /// text usually still spells in the next token, so placing it renders the okurigana twice
    /// (受け|取|らし|て becomes うけとりらして, where うけとらして is the word).
    ///
    /// The dictionary decides it without looking at the text at all: append the LAST kana of the
    /// reading about to be placed and ask whether THAT longer surface is a form JMdict lists
    /// with the SAME reading. 受け取 + り is 受け取り/うけとり, so decline. 生き方 + た and
    /// 笑い顔 + お are not forms, so those runs are untouched.
    ///
    /// This deliberately also declines the rarer places where the bare spelling is the whole
    /// word (Soseki writes 取り扱をかえた). Rendering a real word's reading twice is the worse
    /// error, and the brief puts truncated token boundaries out of scope rather than papering
    /// over them.
    private static func absorbsOkurigana(
        _ joined: String,
        reading: String,
        lookup: CompoundJoinLookup
    ) -> Bool {
        guard let tail = reading.last, FuriganaAnnotator.isKanaOnly(String(tail)) else { return false }
        return lookup.readings(joined + String(tail))
            .contains { normalizeKana($0) == normalizeKana(reading) }
    }

    /// Katakana folded to hiragana, so a katakana JMdict reading never false-mismatches a
    /// hiragana rendering (and vice versa) in the ours-vs-listed comparison.
    static func normalizeKana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value)
                ? (Unicode.Scalar(scalar.value - 0x60) ?? scalar) : scalar
        }))
    }

    /// Whether spans exactly tile `0..<count` in order — the compound-join copy of the
    /// okurigana path's private tiling check.
    private static func spansTileRange(_ spans: [ReadingSpan], count: Int) -> Bool {
        var cursor = 0
        for span in spans {
            guard span.range.lowerBound == cursor else { return false }
            cursor = span.range.upperBound
        }
        return cursor == count && count > 0
    }
}
