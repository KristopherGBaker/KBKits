import Foundation
import Testing
@testable import KBAnkiKit

/// Read a real, downloaded deck rather than a fixture this package built itself.
///
/// Every other test here proves self-consistency: our writer against our reader, our
/// hand-rolled bytes against our parser. That cannot catch a shared wrong assumption
/// about what Anki actually ships, and it has not: reading Kaishi 1.5k immediately
/// showed the media manifest arrives zstd-compressed, which no fixture had.
///
/// Skipped when the deck is absent, so a checkout without it stays green.
/// File-level so the suite trait can read it: a trait naming a static on the type it
/// annotates is a circular macro reference.
private let realDeckPath = "\(NSHomeDirectory())/Downloads/Kaishi.1.5k.apkg"
private let realDeckExists = FileManager.default.fileExists(atPath: realDeckPath)

@Suite("A real downloaded deck", .enabled(if: realDeckExists))
struct RealDeckTests {
    private var url: URL { URL(fileURLWithPath: realDeckPath) }

    @Test("Its notes, decks and fields read back")
    func realDeckReads() throws {
        let collection = try AnkiPackageReader().read(contentsOf: url)
        // The legacy collection.anki2 in this package is the upgrade stub Anki writes
        // for old clients and holds ONE note. Preferring it would import a single
        // placeholder and call the import a success.
        #expect(collection.notes.count > 1000)
        let noteType = try #require(collection.noteTypes.first)
        #expect(!noteType.fieldNames.isEmpty)

        let note = try #require(collection.notes.first)
        #expect(note.fields.count <= noteType.fieldNames.count)
        #expect(!note.guid.isEmpty)
        // Every note belongs somewhere, which is what a deck picker needs.
        #expect(!note.deckIDs.isEmpty)
    }

    @Test("Its media manifest parses and a named file comes back")
    func realDeckMediaReads() throws {
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        // The manifest is a zstd frame in this package, so a parser that dispatches on
        // the first byte without decompressing reads it as protobuf and finds nothing.
        #expect(media.names.count > 100)

        let name = try #require(media.names.first)
        let bytes = try #require(try media.data(named: name))
        #expect(!bytes.isEmpty)
        // Indexed on open, decompressed on demand: a hundred megabytes of audio must
        // never have to be resident to read one file.
        #expect(bytes.count < 10_000_000)
    }

    @Test("Field names look like the ones auto-matching expects")
    func realDeckFieldNames() throws {
        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteType = try #require(collection.noteTypes.first)
        let lowered = noteType.fieldNames.map { $0.lowercased() }
        // Not asserting an exact list: a deck may rename its fields between releases.
        // What must hold is that SOMETHING carries the word and something the meaning,
        // or auto-matching has nothing to match on.
        #expect(lowered.contains { $0.contains("word") || $0.contains("expression") })
        #expect(lowered.contains { $0.contains("meaning") || $0.contains("definition") })
    }

    @Test("Its media filenames are what a confinement rule has to survive")
    func realDeckMediaFileNames() throws {
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        let names = Set(media.names)
        #expect(names.count > 4000)

        // The one that matters. A media store confining writes to its deck directory
        // has to reject traversal, and the obvious rule is `name.contains("..")`. This
        // deck ships "undou_squat_personal_trainer_woman..webp": a doubled dot inside a
        // single component, entirely harmless, which that rule would refuse. Reject `.`
        // and `..` as whole PATH COMPONENTS instead, which no real name here is.
        #expect(names.contains { $0.contains("..") })
        let traversing = names.filter { name in
            name.components(separatedBy: "/").contains { $0 == "." || $0 == ".." }
        }
        #expect(traversing.isEmpty)
        // Nor does any real name carry a separator or start at the root.
        #expect(!names.contains { $0.contains("/") || $0.contains("\\") })

        // Japanese names, with full-width pitch marks, arrive already precomposed.
        // A store that normalized on write but not on lookup would still match here,
        // so this pins the assumption rather than proving the store correct.
        #expect(names.contains { !$0.allSatisfy(\.isASCII) })
        #expect(names.allSatisfy { $0 == $0.precomposedStringWithCanonicalMapping })
        // Well inside every filesystem's per-component limit.
        #expect(names.allSatisfy { $0.utf8.count <= 255 })
    }

    @Test("Every file its notes reference is in the manifest")
    func realDeckMediaIsComplete() throws {
        let reader = AnkiPackageReader()
        let collection = try reader.read(contentsOf: url)
        let media = try reader.readMedia(contentsOf: url)

        var referenced = Set<String>()
        for note in collection.notes {
            for field in note.fields {
                let cleaned = AnkiFieldText.cleaned(field)
                referenced.formUnion(cleaned.audioFileNames)
                referenced.formUnion(cleaned.imageFileNames)
            }
        }
        // This deck references all 4354 of its files and no others, so field-text
        // extraction and the manifest agree exactly. A regression in either one, an
        // unhandled [sound:] spelling or a manifest entry read past, shows up as drift
        // in both directions rather than as a plausible smaller number.
        #expect(referenced == Set(media.names))
    }

    @Test("Sizing all its media is affordable enough to do before consent")
    func realDeckSizingIsFast() throws {
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        let started = ContinuousClock.now
        let total = try media.byteCount(of: media.names)
        let elapsed = ContinuousClock.now - started

        #expect(total > 100_000_000)
        // The number that motivated `forEachBody`. Fetching these one at a time through
        // `data(named:)` takes 46 seconds, because ZIPFoundation resolves each entry by
        // scanning the whole central directory: 4354 lookups over 4354 entries, before a
        // single byte of audio is decompressed. Indexing once costs 0.14 seconds. The
        // bound is loose enough not to flake on a busy machine and still two orders of
        // magnitude under the behaviour it exists to prevent.
        #expect(elapsed < .seconds(5))
    }

    @Test("Streaming its media keeps one body in hand at a time")
    func realDeckStreamsOneBody() throws {
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        let names = Array(media.names.prefix(200))

        var seen = [String]()
        var largest = 0
        try media.forEachBody(named: names) { name, body in
            seen.append(name)
            largest = max(largest, body.count)
            // Nothing accumulates the body itself. A caller that did would hold all
            // 110 MB, which is the whole reason this API exists rather than a map.
        }
        #expect(seen == names)
        #expect(largest > 0)
    }

    @Test("A name it never heard of is a failure, not a silent skip")
    func realDeckUnknownNameThrows() throws {
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        let real = try #require(media.names.first)
        #expect(throws: AnkiError.self) {
            try media.forEachBody(named: [real, "not-in-this-deck.mp3"]) { _, _ in }
        }
    }
}
