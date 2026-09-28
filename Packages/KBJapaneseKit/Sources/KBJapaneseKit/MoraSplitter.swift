/// Split a kana reading into moras, the unit standard Japanese pitch notation draws over.
///
/// A mora is not a character. The rules that matter for notation:
///
/// - A small kana (ゃゅょぁぃぅぇぉ and their katakana equivalents) following another kana
///   forms ONE mora with it: きゃ, しゅ, ちょ, ファ, ティ are each a single mora.
/// - The long-vowel mark ー is its own mora, so コーヒー is ko-o-hi-i, four moras.
/// - The sokuon っ/ッ is its own mora, so きって is ki-t-te, three moras.
/// - The moraic nasal ん/ン is its own mora, so にほん is ni-ho-n, three moras.
///
/// The splitter is pure string logic: it needs no dictionary and never throws. Non-kana
/// characters pass through one per mora, and a small kana with no preceding kana (leading,
/// or after a non-kana) stands alone rather than merging into nothing.
///
/// Lossless by construction: joining the returned elements reproduces the input exactly.
public enum MoraSplitter {
    /// The moras of `reading`, in order, each a substring of the input. Concatenating the
    /// result reproduces `reading`; an empty string yields an empty array.
    public static func moras(in reading: String) -> [String] {
        var moras: [String] = []
        for character in reading {
            if isSmallKana(character),
               let previous = moras.last,
               let lastCharacter = previous.last,
               canTakeSmallKana(lastCharacter) {
                // A small kana fuses with the preceding kana into one mora.
                moras[moras.count - 1] = previous + String(character)
            } else {
                moras.append(String(character))
            }
        }
        return moras
    }

    /// The small kana that fuse with a preceding kana: the small y-glides and small vowels,
    /// hiragana and katakana. Deliberately does NOT include ー, っ/ッ, or ん/ン, each of which
    /// is its own mora.
    private static let smallKana: Set<Character> = [
        "ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ",
        "ャ", "ュ", "ョ", "ァ", "ィ", "ゥ", "ェ", "ォ"
    ]

    private static func isSmallKana(_ character: Character) -> Bool {
        smallKana.contains(character)
    }

    /// The three kana that are a whole mora by themselves and therefore cannot take a small
    /// kana after them: the long-vowel mark, the sokuon and the moraic nasal. A small kana
    /// attaches to a consonant-plus-vowel kana (き + ゃ), and there is no consonant for it to
    /// palatalise in ー, っ or ん, so ーゃ is two moras rather than one.
    private static let standaloneMoras: Set<Character> = ["ー", "っ", "ッ", "ん", "ン"]

    /// Whether `character` can carry a following small kana. The rule has three parts and each
    /// exclusion has the same justification: a small kana palatalises a consonant, so the host
    /// must HAVE a consonant to palatalise.
    ///
    /// 1. It must be a kana LETTER, so punctuation and marks inside the kana blocks are out.
    /// 2. It must not be ー, っ or ん, each of which is already a whole mora with no consonant.
    /// 3. It must not itself be a small kana, which is the palatalising element rather than a
    ///    host.
    ///
    /// The letter ranges are deliberately narrower than the Hiragana and Katakana Unicode
    /// blocks, because those blocks also contain punctuation and marks that are not kana at
    /// all. U+30FB KATAKANA MIDDLE DOT, U+30A0 KATAKANA DOUBLE HYPHEN, the iteration marks
    /// and the standalone voiced marks all sit inside the blocks, and a block-range test
    /// wrongly lets them absorb a small kana. Only 0x3041-0x3096 and 0x30A1-0x30FA are
    /// letters.
    private static func canTakeSmallKana(_ character: Character) -> Bool {
        // A small kana is the palatalising element itself, so it has no consonant of its own
        // to palatalise and cannot host another: ぁぃ is two moras.
        guard !isSmallKana(character) else { return false }
        guard !standaloneMoras.contains(character) else { return false }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return false }
        return (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value)
    }
}
