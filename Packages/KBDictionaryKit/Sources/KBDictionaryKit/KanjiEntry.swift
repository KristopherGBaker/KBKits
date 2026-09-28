import Foundation

/// One character, as a learner studies it.
///
/// This is a different unit from a `JMDictEntry`, which is a WORD. Meeting 学校 is an
/// opportunity to learn 学 and 校 as characters, and the two have different failure modes:
/// a word card is forgotten as a whole, a character is confused with a lookalike or read
/// with the wrong on/kun. That is why the readings are split rather than flattened into
/// one list - the split is the thing being learned.
public struct KanjiEntry: Sendable, Hashable, Codable {
    /// The character itself.
    public let character: String
    /// On'yomi (the Sino-Japanese readings), in KANJIDIC's katakana convention.
    public let onReadings: [String]
    /// Kun'yomi (the native readings), in KANJIDIC's convention where a dot separates the
    /// part the character covers from its okurigana (`まな.ぶ`) and a hyphen marks a prefix
    /// or suffix position (`-ふる.す`). Kept verbatim: the dot is information a learner
    /// wants, and stripping it would make 学 read まなぶ as if the ぶ were in the character.
    public let kunReadings: [String]
    /// English meanings, most common first.
    public let meanings: [String]
    /// Stroke count, when KANJIDIC records one.
    public let strokeCount: Int?
    /// The Japanese school grade the character is taught in (1-6 for kyōiku kanji, 8 for
    /// the rest of the jōyō set, 9/10 for name-use characters), when recorded.
    public let grade: Int?
    /// Frequency rank across a corpus of newspaper text, 1 being most frequent. Nil for a
    /// character outside the top 2,500.
    public let frequency: Int?

    public init(
        character: String,
        onReadings: [String] = [],
        kunReadings: [String] = [],
        meanings: [String] = [],
        strokeCount: Int? = nil,
        grade: Int? = nil,
        frequency: Int? = nil
    ) {
        self.character = character
        self.onReadings = onReadings
        self.kunReadings = kunReadings
        self.meanings = meanings
        self.strokeCount = strokeCount
        self.grade = grade
        self.frequency = frequency
    }

    /// The meanings as one line, for a card front or a list row.
    public var glossLine: String { meanings.joined(separator: ", ") }
}

/// Where `KanjiStore` reads from. The seam exists for the same reason `JMDictStorage`
/// does: SQLite is not available on every platform this package builds for, and a store
/// that cannot open a database must degrade to empty rather than fail to compile.
public protocol KanjiStorage: Sendable {
    func entry(for character: String) -> KanjiEntry?
    /// Whether a database was actually opened. False means every lookup will be empty.
    var isReady: Bool { get }
}

/// The no-database storage: every lookup misses. Used where SQLite is unavailable.
public struct EmptyKanjiStorage: KanjiStorage {
    public init() {}
    public func entry(for character: String) -> KanjiEntry? { nil }
    public var isReady: Bool { false }
}
