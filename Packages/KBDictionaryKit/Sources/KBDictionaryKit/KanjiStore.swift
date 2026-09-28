public import Foundation
public import KBCore

/// Read-only per-character lookup, over the KANJIDIC SQLite built by
/// `Tools/build-kanjidic.swift` (issue 033).
///
/// **It ships bundled, unlike JMdict.** The full word dictionary is ~66 MB and has to be
/// built into Application Support; the kanji a reader actually meets are 3,100 characters
/// and 332 KB, so they travel with the package. That difference is what makes kanji cards
/// work on a fresh clone and on a device with no `make dict` run, instead of being another
/// feature that silently does nothing until someone remembers a build step.
public final class KanjiStore: Sendable {
    private let storage: any KanjiStorage

    /// The general initializer: any storage, including a fake in tests.
    public init(storage: any KanjiStorage) {
        self.storage = storage
    }

    #if canImport(GRDB)
    /// Opens the bundled KANJIDIC. `databaseURL` overrides it, which is how a test points
    /// at a fixture and how an app could ship a fuller build of its own.
    ///
    /// An override that opens but does not carry the `kanji` table falls back to the bundled
    /// database rather than being served: it used to report `isReady` and then answer nil for
    /// every character, which is how a caller ends up offering kanji cards that are all blank.
    public convenience init(databaseURL: URL? = nil) {
        if let databaseURL {
            let storage = SQLiteKanjiStorage(url: databaseURL)
            if storage.isReady {
                self.init(storage: storage)
                return
            }
        }
        self.init(storage: SQLiteKanjiStorage(url: Self.bundledURL))
    }
    #else
    /// No SQLite backend on this platform, so every lookup is empty. The initializer still
    /// takes a URL so callers need no conditional compilation.
    public convenience init(databaseURL: URL? = nil) {
        self.init(storage: EmptyKanjiStorage())
    }
    #endif

    /// Whether a database was opened. False means the caller should not offer kanji cards
    /// at all, rather than offering them and producing blanks.
    public var isReady: Bool { storage.isReady }

    /// The entry for a single character, or nil when the character is not in the shipped
    /// set (a rare variant, a name-only character) or is not a kanji at all.
    public func entry(for character: Character) -> KanjiEntry? {
        storage.entry(for: String(character))
    }

    /// The entries for every kanji in `word`, in the order they appear, skipping kana,
    /// punctuation and characters with no entry.
    ///
    /// Duplicates are collapsed: 人人 is one character to learn, not two, and offering the
    /// same card twice in one lookup would be a bug the reader has to notice and undo.
    public func entries(in word: String) -> [KanjiEntry] {
        var seen = Set<Character>()
        var results: [KanjiEntry] = []
        for character in word where Self.isKanji(character) {
            guard seen.insert(character).inserted else { continue }
            if let entry = entry(for: character) { results.append(entry) }
        }
        return results
    }

    /// Whether a character is a CJK ideograph, i.e. worth asking the dictionary about.
    ///
    /// Deliberately a scalar-range test rather than `isIdeographic`: the iteration mark 々
    /// and the kanji-repeat variants are ideographic by Unicode's reckoning but are not
    /// characters with readings, and asking about them only produces misses.
    static func isKanji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,    // CJK Unified Ideographs
             0x3400...0x4DBF,    // Extension A
             0xF900...0xFAFF:    // Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    /// The KANJIDIC bundled with this package.
    ///
    /// `Bundle.module` is the Apple path only: its generated accessor traps rather than
    /// returning nil when there is no resource bundle, and an Android APK has none, so
    /// reaching it there aborts the process instead of falling through to "no data". See
    /// `PackageResourceLocator`, and `JMDictStore.bundledSeedURL`, which has the same shape
    /// for the same reason, including the TARGET-keyed off-Apple lookup that survives this
    /// target being copied into a package with another name.
    static var bundledURL: URL? {
        #if canImport(Darwin)
        return Bundle.module.url(forResource: "kanjidic", withExtension: "sqlite")
        #else
        return PackageResourceLocator.url(targetName: "KBDictionaryKit",
                                          resource: "kanjidic", extension: "sqlite")
        #endif
    }
}
