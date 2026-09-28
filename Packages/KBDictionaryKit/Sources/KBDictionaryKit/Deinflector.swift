import Foundation

/// Rule-based Japanese deinflection: maps an inflected verb/adjective surface to
/// candidate dictionary (base) forms, so JMdict lookup resolves 読んだ→読む,
/// 食べました→食べる, 高かった→高い, etc.
///
/// No morphological analyzer is required: candidates are **over-generated** and then
/// validated by whether they actually hit the dictionary (a wrong guess simply doesn't
/// match), so ambiguous endings (った → う/つ/る) are safe to enumerate. This is the
/// approach reader dictionaries (Yomichan, 10ten) use. It's single-step — it covers the
/// common inflections, not every nested form (ていた, させられる, …). A morphological
/// base form from OpenJTalk would be higher quality; this is the dependency-free path.
public enum Deinflector {
    /// 連用形 (い-row) → dictionary う-row ending, for ます / polite stems.
    private static let politeRows: [(Character, Character)] =
        [("い", "う"), ("き", "く"), ("ぎ", "ぐ"), ("し", "す"),
         ("ち", "つ"), ("に", "ぬ"), ("び", "ぶ"), ("み", "む"), ("り", "る")]
    /// 未然形 (あ-row) → dictionary う-row ending, for negative ない stems.
    private static let negativeRows: [(Character, Character)] =
        [("わ", "う"), ("か", "く"), ("が", "ぐ"), ("さ", "す"),
         ("た", "つ"), ("な", "ぬ"), ("ば", "ぶ"), ("ま", "む"), ("ら", "る")]

    /// Candidate base forms for a surface, most-specific (longest matched suffix) first.
    /// Excludes the surface itself — callers look that up directly before deinflecting.
    public static func candidates(for surface: String) -> [String] {
        var scored: [(form: String, weight: Int)] = []
        // `>=` (not `>`) so whole-word irregulars (行った → 行く, した → する) match with an
        // empty stem; the dictionary still validates each candidate.
        for (suffix, bases) in rules where surface.count >= suffix.count && surface.hasSuffix(suffix) {
            let stem = String(surface.dropLast(suffix.count))
            for base in bases {
                let form = stem + base
                if form != surface { scored.append((form, suffix.count)) }
            }
        }
        // Longer matched suffix = more specific = tried first; dedup, keep first.
        var seen = Set<String>()
        return scored.sorted { $0.weight > $1.weight }.compactMap { seen.insert($0.form).inserted ? $0.form : nil }
    }

    /// (suffix, [replacement endings]) rules. Over-generation is intentional.
    private static let rules: [(String, [String])] = {
        var rules: [(String, [String])] = []

        // i-adjectives → dictionary 〜い.
        rules += [("くなかった", ["い"]), ("かった", ["い"]), ("くない", ["い"]),
                  ("くて", ["い"]), ("ければ", ["い"]), ("く", ["い"])]

        // Polite ます / ました / ません (row-based, unambiguous per stem) + ichidan.
        for (renyo, dict) in politeRows {
            rules += [(String(renyo) + "ます", [String(dict)]),
                      (String(renyo) + "ました", [String(dict)]),
                      (String(renyo) + "ません", [String(dict)])]
        }
        rules += [("ます", ["る"]), ("ました", ["る"]), ("ません", ["る"])]

        // Negative ない / なかった (row-based) + ichidan.
        for (mizen, dict) in negativeRows {
            rules += [(String(mizen) + "ない", [String(dict)]),
                      (String(mizen) + "なかった", [String(dict)])]
        }
        rules += [("ない", ["る"]), ("なかった", ["る"])]

        // する compounds (勉強した→勉強 / 勉強する): drop the suffix to the noun, or → する;
        // also include the godan -す reading (話した→話す, 話して→話す).
        rules += [("しました", ["する", "す", ""]), ("します", ["する", "す", ""]),
                  ("しない", ["する", "す", ""]), ("して", ["する", "す", ""]),
                  ("した", ["する", "す", ""])]

        // Plain past / te-form. Ambiguous endings list every row; the dictionary filters.
        rules += [("んだ", ["む", "ぶ", "ぬ"]), ("いた", ["く"]), ("いだ", ["ぐ"]),
                  ("った", ["う", "つ", "る"]), ("た", ["る"]),
                  ("んで", ["む", "ぶ", "ぬ"]), ("いて", ["く"]), ("いで", ["ぐ"]),
                  ("って", ["う", "つ", "る"]), ("て", ["る"]), ("で", ["る"])]

        // 行く is the well-known irregular (行った, not 行いた) that regular rules mis-resolve.
        rules += [("行った", ["行く"]), ("行って", ["行く"]),
                  ("いった", ["いく"]), ("いって", ["いく"])]

        return rules
    }()
}
