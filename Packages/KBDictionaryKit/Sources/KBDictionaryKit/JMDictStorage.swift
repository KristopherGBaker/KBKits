import Foundation

/// Where JMdict data physically comes from. `JMDictStore` is the policy above it
/// (deinflection, base-then-surface fallback, parsing furigana segmentation strings);
/// this is the raw retrieval underneath, and the only part that knows about a database.
///
/// It exists because GRDB cannot cross-compile to Android at all: the NDK ships no SQLite
/// headers and no linkable library, and the on-device `libsqlite.so` has been off limits to
/// apps since API 24. Everything above this protocol is pure Swift and portable, so the
/// seam is what lets the rest of the package move without committing to any particular
/// Android backend. Whatever that turns out to be (SQLite over JNI, a bundled flat index, a
/// service) implements these five members and nothing else changes.
///
/// The methods return empty rather than throwing: a dictionary miss and an unavailable
/// dictionary are the same thing to a reader, which shows "no entry" either way.
public protocol JMDictStorage: Sendable {
    /// Whether a dictionary opened successfully. False means every lookup returns nothing.
    var isReady: Bool { get }

    /// Entries whose kanji headword or kana reading matches `form` exactly, capped at `limit`.
    func entries(matchingForm form: String, limit: Int) -> [JMDictEntry]

    /// The English source word glossing a katakana loanword, or nil when the form is not a
    /// glossable English loanword or the dictionary predates the gloss column.
    func englishGloss(forKatakana form: String) -> String?

    /// Every kana form of every entry listing `form` as a headword or variant.
    func kanaReadings(forForm form: String) -> [String]

    /// Every kana form of every entry whose KANJI headword or variant BEGINS WITH `prefix`,
    /// capped at `limit`.
    ///
    /// The prefix, not the exact form, is the point. It answers "can the ordinary dictionary
    /// account for this reading of this surface?" across every inflected and compounded form
    /// the surface heads - 覗 reads のぞ because JMdict knows 覗く(のぞく), 撫 reads な because
    /// it knows 撫でる - which an exact-form lookup cannot see and a closed list of okurigana
    /// endings only approximates (it misses 撫でる). Callers test whether any returned reading
    /// starts with theirs.
    ///
    /// `limit` bounds the cost of a short, common prefix. Note which way truncation errs: a
    /// truncated answer can only FAIL to corroborate, and failing to corroborate is the branch
    /// that ACTS, so the limit belongs above the real fan-out rather than at a tidy round
    /// number. The worst single kanji in the shipping JMdict is 大, at 1,890 distinct readings.
    func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String]

    /// The raw JmdictFurigana segmentation string for the exact (form, reading) pair, or nil
    /// when the pair is unknown. Parsing it into spans is policy and lives above this seam,
    /// so a backend only has to store and return the string it was given.
    func furiganaSegmentation(form: String, reading: String) -> String?
}

/// The storage used when there is no dictionary to read: nothing is ready and every lookup
/// is empty. This is the honest representation of the case `JMDictStore` already handled
/// internally with a nil database handle, and it is what a platform with no backend yet gets.
public struct EmptyJMDictStorage: JMDictStorage {
    public init() {}

    public var isReady: Bool { false }
    public func entries(matchingForm form: String, limit: Int) -> [JMDictEntry] { [] }
    public func englishGloss(forKatakana form: String) -> String? { nil }
    public func kanaReadings(forForm form: String) -> [String] { [] }
    public func kanaReadings(forKanjiFormsStartingWith prefix: String, limit: Int) -> [String] { [] }
    public func furiganaSegmentation(form: String, reading: String) -> String? { nil }
}
