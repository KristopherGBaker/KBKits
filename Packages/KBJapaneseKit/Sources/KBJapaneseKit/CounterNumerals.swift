import Foundation

/// Digits before a counter, rewritten as kanji numerals for ANALYSIS only.
///
/// Open JTalk reads a counter correctly after a kanji numeral and not after a digit. Measured
/// on the same sentences, changing nothing but the numeral's script:
///
///     入社５年の27歳    年[とし]  歳[とし]        入社五年の二十七歳   年[ねん]  歳[さい]
///     ２人 / １人       人[ひと]                 二人 / 一人          二人[ふたり] 一人[ひとり]
///     １日目            日[ひ]                   一日目               日[にち]
///
/// The counter kanji is analysed as a standalone noun and takes its kun reading, so 5年 reads
/// "toshi" and 27歳 reads "toshi" as well. A reader hit both on the first page of a modern novel.
///
/// A rule that simply forced the counter reading would not be enough: most of the graded
/// occurrences need a WHOLE-WORD reading that no per-kanji rule produces - ２人 is ふたり, not
/// に+にん, and 月１日 is ついたち. So the numeral is rewritten and the sentence re-analysed, which
/// uses Open JTalk's own counter knowledge instead of a table of our own.
///
/// The rewrite is display-only and never reaches the document, TTS or persistence: it happens
/// inside one analysis call and the words come back tiling the ORIGINAL text.
public enum CounterNumerals {

    /// A digit run rewritten in place: where it was, and where its kanji numeral now is.
    public struct Replacement: Equatable, Sendable {
        public let original: Range<Int>
        public let normalized: Range<Int>

        public init(original: Range<Int>, normalized: Range<Int>) {
            self.original = original
            self.normalized = normalized
        }
    }

    /// The counters this fires on. Deliberately a closed list rather than "any kanji": the
    /// rewrite changes what the analyser sees, so it must only fire where a digit really is a
    /// quantity. `目` is absent on purpose - it never follows a digit directly, it follows a
    /// counter (3年目), and the counter is what triggers the rewrite.
    static let counters: Set<Character> = [
        "人", "年", "月", "日", "時", "分", "秒", "歳", "才", "回", "度", "番", "階",
        "本", "個", "枚", "台", "軒", "冊", "匹", "頭", "羽", "名", "円", "週", "巻"
    ]

    /// Half-width and full-width digits, mapped to their value.
    private static func digit(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value - 0x30)          // 0-9
        case 0xFF10...0xFF19: return Int(scalar.value - 0xFF10)    // ０-９
        default: return nil
        }
    }

    /// 1...9999 as a Japanese kanji numeral: 27 -> 二十七, 100 -> 百, 2024 -> 二千二十四.
    ///
    /// Bounded at four digits on purpose. Beyond that a digit run is usually not a quantity at
    /// all (a phone number, a product code, a page range), and leaving it alone is a no-op
    /// rather than a guess. Zero and leading zeros are excluded for the same reason: 05分 is a
    /// clock face, not the number five.
    static func kanjiNumeral(_ value: Int) -> String? {
        guard (1...9999).contains(value) else { return nil }
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        var out = ""
        for (unit, place) in [("千", 1000), ("百", 100), ("十", 10)] {
            let count = (value / place) % 10
            if count == 0 { continue }
            // 十 not 一十, 百 not 一百: the leading 一 is written only above the thousands.
            out += (count == 1 ? "" : digits[count]) + unit
        }
        let ones = value % 10
        if ones != 0 { out += digits[ones] }
        return out
    }

    /// `text` with every qualifying digit run rewritten, or nil when there is nothing to do -
    /// so the overwhelmingly common case costs one scan and allocates nothing.
    public static func normalize(_ text: String) -> (text: String, replacements: [Replacement])? {
        let characters = Array(text)
        var out: [Character] = []
        var replacements: [Replacement] = []
        var index = 0
        out.reserveCapacity(characters.count)
        while index < characters.count {
            guard digit(characters[index]) != nil else {
                out.append(characters[index]); index += 1; continue
            }
            var end = index
            var value = 0
            while end < characters.count, let next = digit(characters[end]) {
                value = value * 10 + next
                end += 1
            }
            let followedByCounter = end < characters.count && counters.contains(characters[end])
            let noLeadingZero = digit(characters[index]) != 0
            if followedByCounter, noLeadingZero, end - index <= 4,
               let kanji = kanjiNumeral(value) {
                replacements.append(Replacement(original: index..<end,
                                                normalized: out.count..<(out.count + kanji.count)))
                out += Array(kanji)
            } else {
                out += characters[index..<end]
            }
            index = end
        }
        guard !replacements.isEmpty else { return nil }
        return (String(out), replacements)
    }

    /// One projected word: the surface as it appears in the ORIGINAL text, the reading the
    /// analysis produced for it, and which analysed words it came from.
    public struct Projected: Equatable, Sendable {
        public let surface: String
        public let reading: String
        public let sources: Range<Int>
    }

    /// Map words analysed over the normalized text back onto the original.
    ///
    /// The analysis surfaces TILE the text, which is what makes this exact rather than a search:
    /// walking them gives each word its span in the normalized string, and a span that does not
    /// touch a rewrite maps back by subtracting the accumulated length delta.
    ///
    /// A word that OVERLAPS a rewrite is merged with its neighbours until the group covers whole
    /// rewrites on both edges - 二十七 may be analysed as 二十 + 七, and neither half has an
    /// original to map to, but together they are exactly "27". Merging concatenates the readings,
    /// which is the reading of the group by construction.
    public static func project(
        _ words: [(surface: String, reading: String)],
        replacements: [Replacement],
        original: String
    ) -> [Projected] {
        let originalCharacters = Array(original)
        var spans: [Range<Int>] = []
        var cursor = 0
        for word in words {
            spans.append(cursor..<(cursor + word.surface.count))
            cursor += word.surface.count
        }

        var out: [Projected] = []
        var index = 0
        while index < words.count {
            var group = index..<(index + 1)
            var span = spans[index]
            // Grow while either edge cuts a rewrite in half.
            while let cut = replacements.first(where: { splits($0.normalized, span) }) {
                if cut.normalized.lowerBound < span.lowerBound, group.lowerBound > 0 {
                    group = (group.lowerBound - 1)..<group.upperBound
                } else if cut.normalized.upperBound > span.upperBound, group.upperBound < words.count {
                    group = group.lowerBound..<(group.upperBound + 1)
                } else {
                    break
                }
                span = spans[group.lowerBound].lowerBound..<spans[group.upperBound - 1].upperBound
            }
            let originalSpan = originalRange(of: span, replacements: replacements,
                                             originalCount: originalCharacters.count)
            let surface = String(originalCharacters[originalSpan])
            let reading = words[group].map(\.reading).joined()
            // A group that CAME FROM A REWRITE and has no kanji left in it is bare digits, and
            // "27" annotated にじゅうなな is noise no author writes; the counter beside it keeps
            // its reading, which is the whole point. The test only applies to rewritten groups:
            // blanking every kana word would strip の and break the tiling contract that says a
            // word's reading is its own kana.
            let rewritten = replacements.contains { overlaps($0.normalized, span) }
            let hasKanji = surface.contains { $0.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            } }
            out.append(Projected(surface: surface,
                                 reading: (rewritten && !hasKanji) ? "" : reading,
                                 sources: group))
            index = group.upperBound
        }
        return out
    }

    private static func overlaps(_ rewrite: Range<Int>, _ span: Range<Int>) -> Bool {
        rewrite.lowerBound < span.upperBound && span.lowerBound < rewrite.upperBound
    }

    /// True when `span` covers part of `rewrite` but not all of it.
    private static func splits(_ rewrite: Range<Int>, _ span: Range<Int>) -> Bool {
        guard overlaps(rewrite, span) else { return false }
        return rewrite.lowerBound < span.lowerBound || rewrite.upperBound > span.upperBound
    }

    /// A normalized span mapped back to original character indices.
    private static func originalRange(
        of span: Range<Int>, replacements: [Replacement], originalCount: Int
    ) -> Range<Int> {
        func map(_ position: Int, end: Bool) -> Int {
            var result = position
            for replacement in replacements {
                let normalizedLength = replacement.normalized.count
                let originalLength = replacement.original.count
                if replacement.normalized.upperBound <= position
                    || (end && replacement.normalized.upperBound == position) {
                    result += originalLength - normalizedLength
                } else if replacement.normalized.lowerBound < position {
                    // Inside a rewrite: only reachable for a group edge, which `project` has
                    // already grown past, so clamp to the rewrite's own boundary.
                    result = replacement.original.lowerBound
                        + (end ? originalLength : 0)
                        + (position - replacement.normalized.lowerBound - normalizedLength)
                    return min(max(result, 0), originalCount)
                }
            }
            return min(max(result, 0), originalCount)
        }
        let lower = map(span.lowerBound, end: false)
        let upper = map(span.upperBound, end: true)
        return lower..<max(lower, upper)
    }
}
