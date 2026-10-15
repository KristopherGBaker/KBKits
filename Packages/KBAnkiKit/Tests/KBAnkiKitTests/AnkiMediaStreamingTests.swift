import Foundation
import Testing
@testable import KBAnkiKit

/// Fetching more than one media body.
///
/// Split from ``AnkiMediaTests`` because it tests a different property: not what a
/// manifest means, but what a caller copying a whole deck is guaranteed. One body is
/// live at a time, the caller's throw stops the stream, and a name the manifest never
/// listed is a failure rather than a card left pointing at nothing.
@Suite("Streaming package media")
struct AnkiMediaStreamingTests {
    private func makePackage(_ entries: [String: Data]) throws -> URL {
        try AnkiTestPackage.make(entries)
    }

    private func zstdCompress(_ data: Data) -> Data {
        AnkiTestPackage.zstdCompress(data)
    }

    @Test("Streaming yields the asked-for bodies in order, one at a time")
    func streamsBodiesInOrder() throws {
        let bodies = ["a.mp3": Data("aaa".utf8), "b.mp3": Data("bb".utf8), "c.jpg": Data("cccc".utf8)]
        let url = try makePackage([
            "media": Data(#"{"0":"a.mp3","1":"b.mp3","2":"c.jpg"}"#.utf8),
            "0": bodies["a.mp3"]!,
            "1": bodies["b.mp3"]!,
            "2": bodies["c.jpg"]!
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        var order = [String]()
        var received = [String: Data]()
        try media.forEachBody(named: ["c.jpg", "a.mp3"]) { name, body in
            order.append(name)
            received[name] = body
        }
        // The caller's order, not the manifest's, and nothing it did not ask for.
        #expect(order == ["c.jpg", "a.mp3"])
        #expect(received["c.jpg"] == bodies["c.jpg"])
        #expect(received["a.mp3"] == bodies["a.mp3"])
        #expect(received["b.mp3"] == nil)
    }

    @Test("A body the caller throws on stops the stream where it stood")
    func streamStopsOnCallerThrow() throws {
        struct Stop: Error {}
        let url = try makePackage([
            "media": Data(#"{"0":"a.mp3","1":"b.mp3"}"#.utf8),
            "0": Data("aaa".utf8),
            "1": Data("bb".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        var seen = 0
        // A caller whose disk write fails mid-import must not have the rest fetched
        // behind it; that is what makes rolling back to a staging directory bounded.
        #expect(throws: Stop.self) {
            try media.forEachBody(named: ["a.mp3", "b.mp3"]) { _, _ in
                seen += 1
                throw Stop()
            }
        }
        #expect(seen == 1)
    }

    @Test("A referenced name the manifest never listed is a failure, not a skip")
    func streamThrowsOnUnmanifestedName() throws {
        let url = try makePackage([
            "media": Data(#"{"0":"a.mp3"}"#.utf8),
            "0": Data("aaa".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        var seen = [String]()
        // `data(named:)` answers nil here, which is right for a lookup and wrong for a
        // copy: a silent skip leaves a card pointing at audio that never arrived.
        #expect(try media.data(named: "ghost.mp3") == nil)
        #expect(throws: AnkiError.self) {
            try media.forEachBody(named: ["a.mp3", "ghost.mp3"]) { name, _ in seen.append(name) }
        }
        #expect(seen == ["a.mp3"])
    }

    @Test("Byte count is the decompressed size, not what the manifest recorded")
    func byteCountUsesActualBodies() throws {
        // A zstd-compressed body: what lands on disk is the 600 decompressed bytes, not
        // the smaller frame the archive stores. A figure taken from the archive's own
        // size field would understate what the caller is agreeing to write.
        let plain = Data(repeating: 0x41, count: 600)
        let url = try makePackage([
            "media": Data(#"{"0":"big.mp3","1":"small.mp3"}"#.utf8),
            "0": zstdCompress(plain),
            "1": Data("xy".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        #expect(try media.byteCount(of: ["big.mp3", "small.mp3"]) == 602)
        // Only what was asked for; an unreferenced file in the package is not counted.
        #expect(try media.byteCount(of: ["small.mp3"]) == 2)
        #expect(try media.byteCount(of: []) == 0)
    }

    @Test("A manifest entry whose numbered body is not in the package fails")
    func streamThrowsWhenNumberedEntryIsMissing() throws {
        // The manifest promises two files; the package only holds entry "0". This is the
        // second way a reference can dangle, and it is not the same bug as a name the
        // manifest never listed: here the manifest is right and the archive is short.
        let url = try makePackage([
            "media": Data(#"{"0":"a.mp3","1":"b.mp3"}"#.utf8),
            "0": Data("aaa".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        // The name IS in the manifest, so the lookup resolves and only the fetch fails.
        #expect(media.names.contains("b.mp3"))
        var seen = [String]()
        #expect(throws: AnkiError.self) {
            try media.forEachBody(named: ["a.mp3", "b.mp3"]) { name, _ in seen.append(name) }
        }
        // It got the good one first, then stopped. A caller staging files has written one.
        #expect(seen == ["a.mp3"])
        // Sizing a deck hits the same wall rather than quietly undercounting it, which
        // would show a person a total smaller than what an import then refuses to deliver.
        #expect(throws: AnkiError.self) { _ = try media.byteCount(of: media.names) }
    }
}
