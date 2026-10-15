import Foundation
import Testing
@testable import KBAnkiKit

/// Fields as real decks write them, not as a tidy fixture would.
@Suite("Taking an Anki field apart")
struct AnkiFieldTextTests {
    @Test("Markup around a word yields the bare word")
    func markupIsRemoved() {
        // A lemma of "<div>先生</div>" matches no dictionary entry AND poisons the
        // dedup key, so duplicate detection quietly stops working too.
        #expect(AnkiFieldText.cleaned("<div>先生</div>").text == "先生")
        #expect(AnkiFieldText.cleaned("<b>先生</b>").text == "先生")
    }

    @Test("A sound marker becomes a filename, not text in the meaning")
    func soundMarkersAreExtracted() {
        let cleaned = AnkiFieldText.cleaned("teacher [sound:sensei.mp3]")
        #expect(cleaned.audioFileNames == ["sensei.mp3"])
        #expect(cleaned.text == "teacher")
    }

    @Test("An image tag becomes a filename before the tag strip could eat it")
    func imagesAreExtracted() {
        // src is an attribute: a general tag strip would discard the filename with it.
        let cleaned = AnkiFieldText.cleaned("<img src=\"classroom.jpg\"> a classroom")
        #expect(cleaned.imageFileNames == ["classroom.jpg"])
        #expect(cleaned.text == "a classroom")
    }

    @Test("Block tags become a line break rather than joining two sentences")
    func blockTagsBreakLines() {
        // Joining here would produce "firstsecond", a word no dictionary holds.
        let cleaned = AnkiFieldText.cleaned("<div>first</div><div>second</div>")
        #expect(cleaned.text.contains("\n"))
        #expect(!cleaned.text.contains("firstsecond"))
    }

    @Test("Entities decode after tags are gone, so an escaped tag survives as text")
    func entitiesDecodeAfterStripping() {
        // Decoding first would turn &lt;b&gt; into a real tag that the strip then eats.
        #expect(AnkiFieldText.cleaned("A &amp; B").text == "A & B")
        #expect(AnkiFieldText.cleaned("&lt;b&gt;").text == "<b>")
    }

    @Test("Everything at once, in the order a real field needs")
    func fullPipeline() {
        let raw = "<div>teacher &amp; master [sound:sensei.mp3]</div><img src=\"c.jpg\">"
        let cleaned = AnkiFieldText.cleaned(raw)
        #expect(cleaned.text == "teacher & master")
        #expect(cleaned.audioFileNames == ["sensei.mp3"])
        #expect(cleaned.imageFileNames == ["c.jpg"])
    }

    // MARK: Furigana

    @Test("Inline furigana splits into a word and its reading")
    func furiganaSplits() {
        let split = AnkiFieldText.splittingFurigana("先生[せんせい]")
        #expect(split.base == "先生")
        #expect(split.reading == "せんせい")
    }

    @Test("A space marks where a group's word begins")
    func furiganaRespectsGroupBoundaries() {
        // Without the boundary rule the second reading would swallow everything
        // before it, and the base would lose を.
        let split = AnkiFieldText.splittingFurigana("日本語[にほんご]を 勉強[べんきょう]します")
        #expect(split.base == "日本語を勉強します")
        #expect(split.reading == "にほんごをべんきょうします")
    }

    @Test("A field with no brackets is returned untouched and claims no reading")
    func plainFieldIsUnchanged() {
        let split = AnkiFieldText.splittingFurigana("先生")
        #expect(split.base == "先生")
        #expect(split.reading == nil)
    }

    @Test("An unclosed bracket imports as itself rather than losing the word")
    func malformedGroupIsTolerated() {
        // Merely odd input should not cost the learner the card.
        let split = AnkiFieldText.splittingFurigana("先生[せんせい")
        #expect(split.base.contains("先生"))
        #expect(split.reading == nil)
    }
}
