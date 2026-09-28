import Foundation

/// The two regular ways a Japanese word's reading changes because of a NEIGHBOUR rather
/// than because of the word itself.
///
/// Both are position-locked, which is what makes them safe to recognize:
///
/// - **head** — handakuon: the FIRST mora takes a handakuten because a sokuon or a moraic
///   nasal precedes it inside the compound. 分 ふん → ぷん in 三十分 and 何分,
///   本 ほん → ぽん in 三本, 匹 ひき → ぴき in 一匹.
/// - **tail** — gemination (促音便): the LAST mora becomes っ because something follows.
///   八 はち → はっ in 八分, 六 ろく → ろっ, 十 じゅう → じゅっ, 脱 だつ → だっ in 脱兎.
///
/// Neither variant is ever a JMdict headword reading — a dictionary lists citation forms —
/// so a validator that only compares against listed readings sees every one of them as
/// "impossible" and repairs a CORRECT in-context reading into the citation form. That is
/// how 五時三十八分 came to render as ごじさんじゅうはちぶ: OpenJTalk produced 八[はっ]
/// 分[ぷん] and both were overridden, to はち and ふん, because JMdict lists 八 as はち and
/// 分 as ふん/ぶ/ぶん.
///
/// Deliberately NOT modelled: 連声 (観音 かんのん), vowel fusion, and irregular
/// counter forms (十 → じっ) — each changes more than one character, so recognizing them
/// needs real rules rather than a substitution, and a miss here only costs a repair.
public enum Sandhi {
    /// は行 → ぱ行, the only head alternation this type accepts.
    ///
    /// RENDAKU (連濁: か→が, さ→ざ, た→だ, は→ば) is deliberately NOT here, and the reason is
    /// measured rather than assumed. Accepting it cost 32 author-graded positions across the
    /// 18-book corpus and gained none: 脛が五六カ所 kept ずね where the author wrote すね,
    /// 鑿と槌 kept づち for つち, 極りが悪く kept ぎま for きま. Every one of those tokens is
    /// word-INITIAL - after a particle, a comma, or an inflected verb - where rendaku cannot
    /// apply at all, and OpenJTalk voiced it anyway.
    ///
    /// The asymmetry that makes handakuon safe and rendaku not: a rendaku reading is an
    /// ordinary word-initial reading (ずね is what 脛 sounds like in 向こう脛 AND what a wrong
    /// analysis of a bare 脛 produces), so telling the two apart needs the word boundary, which
    /// this seam is not given. A ぱ行 initial is conditioned by the sokuon or moraic nasal in
    /// front of it and essentially never begins a native word standing alone - there is no
    /// second reading of ぷん to confuse it with.
    private static let handakuon: [Character: Character] = [
        "は": "ぱ", "ひ": "ぴ", "ふ": "ぷ", "へ": "ぺ", "ほ": "ぽ"
    ]

    /// The kana a final mora may contract from when gemination applies.
    private static let geminable: Set<Character> = ["ち", "つ", "き", "く", "う"]

    /// True when `variant` is `listed` with a head voicing and/or a tail gemination applied,
    /// and nothing else. Both strings must already be hiragana.
    public static func isVariant(_ variant: String, of listed: String) -> Bool {
        guard variant != listed else { return false }
        var undone = Array(variant)
        let base = Array(listed)
        guard undone.count == base.count, !base.isEmpty else { return false }

        // A whole reading contracted to っ (血 ち → っ) is not a word: gemination only ever
        // shortens the last mora of a reading that has something in front of it.
        let tail = base.count >= 2 && undone[undone.count - 1] == "っ" && geminable.contains(base[base.count - 1])
        if tail { undone[undone.count - 1] = base[base.count - 1] }

        let head = undone[0] != base[0] && handakuon[base[0]] == undone[0]
        if head { undone[0] = base[0] }

        guard tail || head else { return false }
        return undone == base
    }

    /// The listed reading a variant came from, or nil when it came from none of them.
    public static func source(of variant: String, among listed: [String]) -> String? {
        listed.first { isVariant(variant, of: $0) }
    }

    /// The listed reading's placement row, re-pointed at the variant.
    ///
    /// Safe for exactly the reason the alternations are recognizable: each touches ONE
    /// character, at the very start or the very end of the reading, so it lands inside the
    /// first or the last span and no boundary moves. 落書き keeps 書[が]き rather than
    /// collapsing to one ruby over the whole token - which matters beyond looks, because the
    /// compound join is gated on placement rows and a span-less token cannot join.
    ///
    /// A row whose relevant end is an OKURIGANA span (`kana == nil`, the surface character
    /// reading as itself) carries no kana to change there, and one whose kana does not start
    /// or end where the listed reading does is not a row for this reading. Both return nil
    /// rather than a guessed placement.
    public static func transfer(
        _ spans: [FuriganaSpan],
        from listed: String,
        to variant: String
    ) -> [FuriganaSpan]? {
        guard isVariant(variant, of: listed), !spans.isEmpty else { return nil }
        let base = Array(listed), changed = Array(variant)
        var out = spans

        if changed[0] != base[0] {
            guard let kana = out[0].kana, kana.first == base[0] else { return nil }
            out[0] = FuriganaSpan(range: out[0].range, kana: String(changed[0]) + kana.dropFirst())
        }
        if changed[changed.count - 1] != base[base.count - 1] {
            let index = out.count - 1
            guard let kana = out[index].kana, kana.last == base[base.count - 1] else { return nil }
            out[index] = FuriganaSpan(range: out[index].range,
                                      kana: kana.dropLast() + String(changed[changed.count - 1]))
        }
        return out
    }
}
