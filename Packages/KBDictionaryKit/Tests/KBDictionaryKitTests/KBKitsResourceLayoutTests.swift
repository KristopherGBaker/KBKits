import Foundation
import Testing
@testable import KBDictionaryKit

/// Written for KBKits, not copied: it pins the thing the move itself could break.
///
/// SwiftPM names a resource bundle `<Package>_<Target>`, so this target's databases live in
/// `KBDictionaryKit_KBDictionaryKit` inside the package it came from and in
/// `KBKits_KBDictionaryKit` here. Nothing in the compiler notices a stale name: a lookup that
/// spells the old package out returns nil, `JMDictStore` silently falls through to no seed at
/// all, `KanjiStore` answers nothing for every character, and the only symptom is a reader
/// tapping a word and getting an empty card. So both databases are resolved through the
/// accessors production uses, opened, and checked to be sitting in the bundle this package
/// produces.
@Suite("Both bundled databases resolve from inside the KBKits package")
struct KBKitsResourceLayoutTests {

    /// SwiftPM's bundle name for this target under this package.
    private static let bundleName = "KBKits_KBDictionaryKit"

    /// The package-keyed name the private layout produced, and that must NOT be what answers
    /// here.
    private static let sourcePackageBundleName = "KBDictionaryKit_KBDictionaryKit"

    /// The `<Package>_<Target>` directory enclosing `resource`, found by walking up rather
    /// than by assuming a depth: a macOS bundle nests its payload under `Contents/Resources`,
    /// an iOS one puts it at the top, and off Apple it is a plain `.resources` directory.
    private func enclosingResourceBundle(of resource: URL) -> URL? {
        var directory = resource.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if ["bundle", "resources"].contains(directory.pathExtension) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("the JMdict seed is found in the KBKits resource bundle")
    func seedResolvesInsideKBKits() throws {
        let url = try #require(JMDictStore.bundledSeedURL,
                               "the bundled JMdict seed did not resolve from KBKits")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "jmdict-seed.sqlite")
        let bundle = try #require(enclosingResourceBundle(of: url),
                                  "the seed did not resolve inside a SwiftPM resource bundle")
        #expect(bundle.deletingPathExtension().lastPathComponent == Self.bundleName)
    }

    @Test("the KANJIDIC database is found in the same KBKits resource bundle")
    func kanjidicResolvesInsideKBKits() throws {
        let url = try #require(KanjiStore.bundledURL,
                               "the bundled KANJIDIC did not resolve from KBKits")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "kanjidic.sqlite")
        let bundle = try #require(enclosingResourceBundle(of: url),
                                  "the KANJIDIC did not resolve inside a SwiftPM resource bundle")
        #expect(bundle.deletingPathExtension().lastPathComponent == Self.bundleName)
    }

    /// One target copies both resources, so they must land in ONE bundle. Two directories here
    /// would mean the build resolved them from different places and one of them is not the copy
    /// this package ships.
    @Test("both databases come from a single bundle")
    func bothResolveFromTheSameBundle() throws {
        let seedURL = try #require(JMDictStore.bundledSeedURL)
        let kanjiURL = try #require(KanjiStore.bundledURL)
        let seedBundle = try #require(enclosingResourceBundle(of: seedURL))
        let kanjiBundle = try #require(enclosingResourceBundle(of: kanjiURL))
        #expect(seedBundle.standardizedFileURL == kanjiBundle.standardizedFileURL)
    }

    /// The negative half, and the reason the accessors are keyed to the target: the bundle the
    /// private package produced does not exist beside this one. Were either accessor still
    /// asking for that name, it would be asking for a directory that is not there.
    @Test("no bundle named after the source package is present")
    func theSourcePackageBundleIsAbsent() throws {
        let seedURL = try #require(JMDictStore.bundledSeedURL)
        let bundle = try #require(enclosingResourceBundle(of: seedURL))
        let root = bundle.deletingLastPathComponent()
        for suffix in ["bundle", "resources"] {
            let stale = root.appendingPathComponent("\(Self.sourcePackageBundleName).\(suffix)")
            #expect(!FileManager.default.fileExists(atPath: stale.path),
                    "a bundle named for the source package is present at \(stale.path)")
        }
    }

    /// Resolution alone is not enough: a resource that is present but was not copied whole
    /// still answers nothing. These open both databases through the real stores.
    @Test("both databases open through their stores",
          .enabled(if: DictionaryTestSupport.seedIsAvailable,
                   "needs a SQLite-backed storage to open anything"))
    func bothDatabasesOpen() throws {
        let seed = try #require(JMDictStore.bundledSeedURL)
        let kanji = try #require(KanjiStore.bundledURL)
        let dictionary = JMDictStore(databaseURL: seed)
        let kanjiStore = KanjiStore(databaseURL: kanji)
        #expect(dictionary.isReady)
        #expect(kanjiStore.isReady)
        // Ready is only "it opened". Ask each one a question it can only answer from the
        // bundled rows.
        #expect(!dictionary.lookup(form: "日本語").isEmpty)
        #expect(kanjiStore.entry(for: "学") != nil)
    }
}
