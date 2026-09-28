// These build their own SQLite fixtures with GRDB, so unlike the seed-backed suites
// they cannot merely skip where GRDB is absent: they would not compile. The suites
// that assert against dictionary DATA use `.enabled(if:)` instead and stay visible.
#if canImport(GRDB)
import Foundation
import GRDB
import Testing
@testable import KBDictionaryKit

/// A FULL dictionary must ship a populated `furigana` table (P3 contract assertion 10).
/// The package bundles only the seed, so this checks whatever full build the machine has:
/// set `KB_FULL_JMDICT` to a jmdict.sqlite path (`make dict` prints one) to run it.
/// Unset — CI, a fresh clone — it skips.
@Suite(.enabled(if: DictionaryTestSupport.seedIsAvailable))
struct BundledFuriganaTests {
    @Test func fullDictionaryHasFuriganaRows() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_FULL_JMDICT"],
              FileManager.default.fileExists(atPath: path) else {
            // No full dictionary on this machine — the seed has its own fixtures.
            return
        }
        let url = URL(fileURLWithPath: path)
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM furigana") ?? 0
        }
        #expect(count >= 200_000, "a full jmdict.sqlite must carry the furigana table")
        // And the store actually serves spans from it (這入る is a P1 fixture pair).
        let store = JMDictStore(databaseURL: url)
        #expect(!store.furiganaSegments(form: "這入る", reading: "はいる").isEmpty)
    }

    @Test func fullDictionaryHasPartsOfSpeech() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_FULL_JMDICT"],
              FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)

        // JMdict writes parts of speech as DTD entity references (`<pos>&adj-i;</pos>`),
        // which `XMLParser` does not deliver as character data. Every sense in a full build
        // therefore came out with an empty `pos`, and the lookup panel showed a blank label
        // beside every one. Nothing caught it: the table was populated, the glosses were
        // right, and the only symptom was a field that was always empty.
        let store = JMDictStore(databaseURL: url)
        let verb = try #require(store.lookup(base: "食べる", surface: "食べる").first)
        #expect(verb.senses.first?.pos.contains("v1") == true)
        let adjective = try #require(store.lookup(base: "綺麗", surface: "綺麗").first)
        #expect(adjective.senses.first?.pos.contains("adj-na") == true)
        let noun = try #require(store.lookup(base: "猫", surface: "猫").first)
        #expect(noun.senses.first?.pos.contains("n") == true)

        // The five XML built-ins must survive the entity flattening as real references,
        // or a gloss like "S&M" arrives mangled.
        // Full-width ＳＭ is how JMdict keys this one; its gloss carries a literal "S&M".
        let ampersand = store.lookup(base: "ＳＭ", surface: "ＳＭ")
            .flatMap { $0.senses }.flatMap { $0.glosses }
        #expect(ampersand.contains { $0.contains("&") })
    }

    @Test func seedFallbackIsDistinguishableFromAFullDictionary() throws {
        // The seed holds a few dozen entries. `isReady` is true for it, so a caller that
        // reads `isReady` as "lookup works" offers the affordance and then reports every
        // miss as a word with no entry, when the truth is a dictionary that was never
        // installed. That is exactly how this presented on 2026-08-21: a working-looking
        // menu item and "no dictionary entry" for every word.
        let absent = URL(fileURLWithPath: "/nonexistent/jmdict.sqlite")
        let seeded = JMDictStore(databaseURL: absent)
        #expect(seeded.isReady)
        #expect(seeded.isUsingBundledSeed)

        guard let path = ProcessInfo.processInfo.environment["KB_FULL_JMDICT"],
              FileManager.default.fileExists(atPath: path) else { return }
        let full = JMDictStore(databaseURL: URL(fileURLWithPath: path))
        #expect(full.isReady)
        #expect(!full.isUsingBundledSeed)
    }
}
#endif
