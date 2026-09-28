import KBCore
import Foundation

extension KaraokeWord {

    /// Merge display tokens that the sentence analysis treats as ONE word.
    ///
    /// The display tokenizer splits by script, the analyser splits by morphology, and they
    /// disagree wherever a word mixes scripts: `２人` tokenizes as `２ | 人` and analyses as one
    /// word reading ふたり. `FuriganaAlignment` annotates only a token that begins at an analysis
    /// word start AND ends at one, so BOTH halves come back nil, both fall back to isolated
    /// per-surface analysis, and 人 renders ひと - "hito" over a word that says "futari".
    ///
    /// The regrouping needs no new seam. A run of unannotated tokens is offered to the SAME
    /// `annotations` closure as one merged surface; if the analysis places it, the merge is real
    /// and the tokens become one display word carrying the word's reading, the way 二日[ふつか]
    /// already works. If it does not, nothing changes.
    ///
    /// Bounded deliberately. Only runs the aligner rejected are probed, only when the aligner
    /// placed something (ALL-nil means its tiling guard failed and the whole sentence is
    /// unaligned - merging there would fuse the sentence into one word), and only up to
    /// `maxRun` tokens, so a pathological line cannot collapse. Each probe is checked against
    /// the analysis, so a merge the analysis will not place is a no-op rather than a guess.
    ///
    /// RETURNS THE ANNOTATIONS TOO, so the caller does not ask again. Each call is an Open JTalk
    /// frontend pass over the sentence; a first draft left `tokenize` to re-align afterwards and
    /// doubled that cost on every sentence in the book. A sentence with nothing to merge - almost
    /// all of them - still costs exactly one pass.
    static func regroupedForAnnotation(
        _ tokens: [WordTokenizer.Token],
        annotations: (([String]) -> [TokenAnnotation?])?,
        maxRun: Int = 4
    ) -> (tokens: [WordTokenizer.Token], annotations: [TokenAnnotation?]?) {
        guard let annotations else { return (tokens, nil) }
        // The alignment pass happens either way and its result is always returned: an early
        // exit that skipped it would silently strip the in-context readings from every
        // single-token sentence, which is the opposite of this file's purpose.
        let surfaces = tokens.map(\.text)
        let aligned = annotations(surfaces)
        // THE LENGTH IS THE WHOLE TEST, and two earlier versions of this guard added a second
        // one that was wrong.
        //
        // An aligner that could not tile the sentence at all returns an EMPTY array (Open JTalk
        // answers 二十七日 for 27日, so the analysis describes different text and any merge would
        // be a guess). A sentence it tiled but placed nothing in returns the right length, all
        // nil - 四月 split 四|月 against the single analysis word 四月 - and that is precisely
        // what this function exists to repair.
        //
        // Asking additionally that some token be placed cost both cases. Requiring a NON-EMPTY
        // reading skipped 「二月、三月、四月。」, where the only placed tokens are 、 and 。,
        // which align with empty readings: 四月 rendered よつき, while the same list followed by
        // ordinary words read しがつ. Requiring merely a non-nil token still skipped a bare 四月,
        // where nothing is placed at all.
        guard tokens.count > 1, aligned.count == tokens.count else {
            return (tokens, aligned)
        }

        // Candidate runs: maximal stretches the aligner could not place, capped in length.
        var runs: [Range<Int>] = []
        var index = 0
        while index < tokens.count {
            guard aligned[index] == nil else { index += 1; continue }
            var end = index
            while end < tokens.count, aligned[end] == nil, end - index < maxRun { end += 1 }
            if end - index >= 2 {
                runs.append(index..<end)
            }
            index = end
        }
        guard !runs.isEmpty else { return (tokens, aligned) }

        // Ask ONCE, with every candidate run merged, and keep only the merges the analysis
        // actually placed. Probing runs one at a time would cost a frontend pass each.
        //
        // `probeRanges` records which ORIGINAL tokens each probe entry stands for, so the result
        // is rebuilt by walking the probe - not by re-deriving positions from the run list,
        // which is where the first version put an annotation on the wrong token.
        var probeSurfaces: [String] = []
        var probeRanges: [Range<Int>] = []
        var cursor = 0
        for run in runs {
            while cursor < run.lowerBound {
                probeSurfaces.append(surfaces[cursor]); probeRanges.append(cursor..<(cursor + 1))
                cursor += 1
            }
            probeSurfaces.append(surfaces[run].joined()); probeRanges.append(run)
            cursor = run.upperBound
        }
        while cursor < surfaces.count {
            probeSurfaces.append(surfaces[cursor]); probeRanges.append(cursor..<(cursor + 1))
            cursor += 1
        }
        let probed = annotations(probeSurfaces)
        guard probed.count == probeSurfaces.count else { return (tokens, aligned) }

        var out: [WordTokenizer.Token] = []
        var outAnnotations: [TokenAnnotation?] = []
        for (position, range) in probeRanges.enumerated() {
            if range.count == 1 {
                out.append(tokens[range.lowerBound])
                outAnnotations.append(aligned[range.lowerBound])
            } else if probed[position]?.reading.isEmpty == false {
                out.append(merge(tokens[range]))
                outAnnotations.append(probed[position])
            } else {
                // The analysis did not place the merged surface either: leave the run exactly
                // as it was, so a failed probe is a no-op rather than a regrouping.
                out += tokens[range]
                outAnnotations += aligned[range]
            }
        }
        return (out, outAnnotations)
    }

    /// Several adjacent tokens as one. The transcription is dropped: it describes a single
    /// token's romaji and cannot be concatenated meaningfully.
    private static func merge(_ run: ArraySlice<WordTokenizer.Token>) -> WordTokenizer.Token {
        WordTokenizer.Token(
            offsets: WordOffsets(lower: run.first!.offsets.lower, upper: run.last!.offsets.upper),
            text: run.map(\.text).joined(),
            latinTranscription: nil,
            tightLeading: run.first!.tightLeading)
    }
}
