import Testing
@testable import KBJapaneseKit

// TEST: the wiring `JapaneseFurigana.providers` assembles. The interesting case is the
// one that runs on every machine without the ~23 MB Open JTalk dictionary installed:
// no reader must mean "fall back", never a crash or a half-wired set of closures.

@Suite("Japanese furigana wiring")
struct JapaneseFuriganaTests {
    @Test("no reader → no reading/baseForm/payload")
    func withoutADictionaryEverythingReaderBackedIsNil() throws {
        // Drive the degraded wiring through the seam directly by handing `providers` an
        // explicit `nil` reader. This asserts the no-reader path WITHOUT reading any
        // process-global dictionary state, so a sibling suite that configures a
        // dictionary cannot race this expectation.
        let providers = JapaneseFurigana.providers(dictionary: nil, reader: nil)
        #expect(providers.reading == nil)
        #expect(providers.baseForm == nil)
        // No reader means no tier either: the tier repairs an OpenJTalk reading, and
        // there isn't one to repair.
        #expect(providers.payload == nil)
        // The gloss is dictionary-backed, not reader-backed, so a nil dictionary is
        // what turns it off here.
        #expect(providers.gloss == nil)
    }
}
