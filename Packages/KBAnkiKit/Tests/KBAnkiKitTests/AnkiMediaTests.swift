import Foundation
import Testing
import ZIPFoundation
@testable import KBAnkiKit

/// Reading a package's media. The manifest arrives in two shapes and a body may or
/// may not be zstd-compressed, so the tests hold both manifest shapes and both body
/// forms. The binary-manifest fixture is a hand-computed byte literal built to the
/// published protobuf wire format, NOT to whatever the parser happens to accept, so a
/// shared wrong assumption cannot pass by construction.
@Suite("Reading package media")
struct AnkiMediaTests {
    // MARK: Fixtures

    private func makePackage(_ entries: [String: Data]) throws -> URL {
        try AnkiTestPackage.make(entries)
    }

    private func zstdCompress(_ data: Data) -> Data {
        AnkiTestPackage.zstdCompress(data)
    }

    // MARK: Legacy JSON manifest

    @Test("A legacy JSON media manifest lists every referenced name")
    func legacyJSONManifestParsed() throws {
        let url = try makePackage([
            "media": Data(#"{"0":"sensei.mp3","1":"cat.jpg"}"#.utf8),
            "0": Data("audio".utf8),
            "1": Data("image".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        #expect(media.names.contains("sensei.mp3"))
        #expect(media.names.contains("cat.jpg"))
    }

    // MARK: Binary protobuf-wire manifest

    @Test("A current binary media manifest parses against the published wire format")
    func binaryManifestParsed() throws {
        // A fixed protobuf-wire MediaEntries message, hand-computed byte by byte to the
        // PUBLISHED format (repeated MediaEntry entries = 1; each entry is
        // { string name = 1; uint32 size = 2; bytes sha1 = 3; }). No encoder, no
        // helper, no closure builds this: every byte is justified in its comment so the
        // fixture and the parser cannot agree on a shared wrong assumption.
        //
        // Tag byte = (field_number << 3) | wire_type. Wire type 0 is a varint, 2 is
        // length-delimited (a length varint followed by that many bytes).
        let manifest: [UInt8] = [
            // ---- Entry 0 -------------------------------------------------------------
            0x0A,                                     // outer field 1 (entries), wire 2 (length-delimited)
            0x25,                                     // length 37: this MediaEntry sub-message is 37 bytes
              0x0A,                                   //   field 1 (name), wire 2
              0x0A,                                   //   length 10
              0x73, 0x65, 0x6E, 0x73, 0x65,           //   "sense"
              0x69, 0x2E, 0x6D, 0x70, 0x33,           //   "i.mp3"  -> "sensei.mp3"
              0x10,                                   //   field 2 (size), wire 0 (varint)
              0xB9, 0x60,                             //   varint 12345 (0x39 | 0x80, then 0x60): 96*128 + 57
              0x1A,                                   //   field 3 (sha1), wire 2
              0x14,                                   //   length 20 (a SHA-1 is 20 bytes)
              0xA0, 0xA1, 0xA2, 0xA3, 0xA4,           //   sha1 bytes 0..4  (fixed, non-default)
              0xA5, 0xA6, 0xA7, 0xA8, 0xA9,           //   sha1 bytes 5..9
              0xAA, 0xAB, 0xAC, 0xAD, 0xAE,           //   sha1 bytes 10..14
              0xAF, 0xB0, 0xB1, 0xB2, 0xB3,           //   sha1 bytes 15..19
            // ---- Unknown field between the two entries --------------------------------
            0x2A,                                     // outer field 5 (unknown), wire 2 (length-delimited)
            0x03,                                     // length 3
            0xDE, 0xAD, 0xBE,                         // opaque bytes the parser must SKIP, not misread
            // ---- Entry 1 -------------------------------------------------------------
            0x0A,                                     // outer field 1 (entries), wire 2
            0x22,                                     // length 34: this MediaEntry sub-message is 34 bytes
              0x0A,                                   //   field 1 (name), wire 2
              0x07,                                   //   length 7
              0x63, 0x61, 0x74, 0x2E,                 //   "cat."
              0x6A, 0x70, 0x67,                       //   "jpg"   -> "cat.jpg"
              0x10,                                   //   field 2 (size), wire 0 (varint)
              0xAC, 0x02,                             //   varint 300 (0x2C | 0x80, then 0x02): 2*128 + 44
              0x1A,                                   //   field 3 (sha1), wire 2
              0x14,                                   //   length 20
              0xC0, 0xC1, 0xC2, 0xC3, 0xC4,           //   sha1 bytes 0..4  (fixed, non-default, differs from entry 0)
              0xC5, 0xC6, 0xC7, 0xC8, 0xC9,           //   sha1 bytes 5..9
              0xCA, 0xCB, 0xCC, 0xCD, 0xCE,           //   sha1 bytes 10..14
              0xCF, 0xD0, 0xD1, 0xD2, 0xD3            //   sha1 bytes 15..19
        ]

        let entries = try AnkiMediaManifest.parse(Data(manifest))
        // The unknown field must be skipped, leaving exactly two entries.
        #expect(entries.count == 2)

        // Entry 0, field by field.
        #expect(entries[0].index == 0)
        #expect(entries[0].name == "sensei.mp3")
        #expect(entries[0].size == 12345)
        #expect(entries[0].sha1 == [
            0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9,
            0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3
        ])

        // Entry 1, field by field. That it decodes correctly proves the unknown field
        // between the two entries was skipped without corrupting the one that follows.
        #expect(entries[1].index == 1)
        #expect(entries[1].name == "cat.jpg")
        #expect(entries[1].size == 300)
        #expect(entries[1].sha1 == [
            0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
            0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3
        ])

        // The manifest's list index 1 maps to numbered ZIP entry "1".
        let catBytes = Data("meow-bytes".utf8)
        let url = try makePackage([
            "media": Data(manifest),
            "0": Data("voice-bytes".utf8),
            "1": catBytes
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        #expect(try media.data(named: "cat.jpg") == catBytes)
    }

    // MARK: zstd by content

    @Test("A media body is decompressed by its content, not by the manifest shape")
    func mediaBytesDecompressedByContentNotManifestShape() throws {
        // (a) LEGACY manifest, a zstd-compressed body: the returned bytes are decompressed.
        let original = Data("先生 the original uncompressed audio bytes".utf8)
        let legacyURL = try makePackage([
            "media": Data(#"{"0":"voice.mp3"}"#.utf8),
            "0": zstdCompress(original)
        ])
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let legacyMedia = try AnkiPackageReader().readMedia(contentsOf: legacyURL)
        #expect(try legacyMedia.data(named: "voice.mp3") == original)

        // (b) BINARY manifest, a plain body: the returned bytes are unchanged. A minimal
        // MediaEntries message with one entry named "plain.bin" at index 0.
        let binaryManifest: [UInt8] = [
            0x0A,                                   // outer field 1 (entries), wire 2
            0x0B,                                   // length 11: the MediaEntry sub-message
              0x0A,                                 //   field 1 (name), wire 2
              0x09,                                 //   length 9
              0x70, 0x6C, 0x61, 0x69, 0x6E,         //   "plain"
              0x2E, 0x62, 0x69, 0x6E                //   ".bin"  -> "plain.bin"
        ]
        let plain = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let binaryURL = try makePackage([
            "media": Data(binaryManifest),
            "0": plain
        ])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let binaryMedia = try AnkiPackageReader().readMedia(contentsOf: binaryURL)
        #expect(try binaryMedia.data(named: "plain.bin") == plain)
    }

    // MARK: Fetch by name

    @Test("One media file is fetched by its referenced name, and a miss returns nil")
    func fetchesOneMediaFileByName() throws {
        let sensei = Data("sensei-audio".utf8)
        let cat = Data("cat-image".utf8)
        let url = try makePackage([
            "media": Data(#"{"0":"sensei.mp3","1":"cat.jpg"}"#.utf8),
            "0": sensei,
            "1": cat
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        #expect(try media.data(named: "sensei.mp3") == sensei)
        #expect(try media.data(named: "sensei.mp3") != cat)
        #expect(try media.data(named: "missing.mp3") == nil)
    }

    // MARK: Laziness

    @Test("readMedia does not extract bodies, so a corrupt sibling never spoils a good one")
    func readMediaLazyDoesNotTouchOtherEntries() throws {
        // Two manifest-referenced numbered entries: entry "0" (good) and entry "1" whose
        // ZIP LOCAL FILE HEADER is DELIBERATELY corrupted after the archive is written,
        // by clobbering its `PK\x03\x04` (50 4B 03 04) signature. The central directory
        // still records the entry, so opening the archive and reading the manifest both
        // succeed and both names are listed, but the entry's body can no longer be
        // located: seeking to its local header finds an unparseable signature.
        //
        // Two facts about this ZIPFoundation fork shape the fixture, both verified in its
        // source. First, a flipped CRC byte would NOT throw: the fork does not reject a
        // CRC mismatch on a stored entry, so extraction would succeed (this is why the
        // earlier attempts failed). Second, the archive iterator reads each entry's local
        // header and STOPS at the first it cannot parse, so the corrupt entry is written
        // LAST; iterating to the manifest and the good entry never trips over it. Nothing
        // here is test-shaped: `data(named:)` already surfaces an unreadable numbered
        // entry as `AnkiError.unreadableArchive` in production.
        let valid = Data("valid-good-bytes".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build with the corrupt entry LAST and close the archive before reading it back.
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let ordered: [(String, Data)] = [
                ("media", Data(#"{"0":"good.mp3","1":"bad.mp3"}"#.utf8)),
                ("0", valid),
                ("1", Data("this body is made unreachable".utf8))
            ]
            for (name, bytes) in ordered {
                try archive.addEntry(
                    with: name, type: .file, uncompressedSize: Int64(bytes.count),
                    provider: { position, size in bytes.subdata(in: Int(position)..<Int(position) + size) })
            }
        }

        // Clobber entry "1"'s local file header signature, found by its stored file name
        // so no other header (nor the central directory record, 50 4B 01 02) is touched.
        // A local file header lays out the 2-byte file-name length 26 bytes in and the
        // file name itself 30 bytes in, with no extra field ahead of it here.
        var raw = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4B, 0x03, 0x04])
        var headerStart: Int?
        var cursor = raw.startIndex
        while let match = raw.range(of: signature, in: cursor..<raw.endIndex) {
            let start = match.lowerBound
            let nameStart = start + 30
            guard start + 28 <= raw.endIndex, nameStart <= raw.endIndex else { break }
            let nameLength = Int(raw[start + 26]) | (Int(raw[start + 27]) << 8)
            guard nameStart + nameLength <= raw.endIndex else { break }
            if raw[nameStart..<nameStart + nameLength] == Data("1".utf8) {
                headerStart = start
                break
            }
            cursor = match.upperBound
        }
        let start = try #require(headerStart, "entry 1 local file header not found")
        for offset in 0..<4 { raw[start + offset] = 0x00 }
        try raw.write(to: url)

        // readMedia reads only the manifest, so it succeeds and lists both names.
        let media = try AnkiPackageReader().readMedia(contentsOf: url)
        #expect(media.names.contains("good.mp3"))
        #expect(media.names.contains("bad.mp3"))

        // The good entry extracts to its exact bytes without touching the corrupt one.
        #expect(try media.data(named: "good.mp3") == valid)

        // Only asking for the corrupt entry throws, and it is the archive/read case.
        do {
            _ = try media.data(named: "bad.mp3")
            Issue.record("expected reading the corrupt entry to throw")
        } catch {
            // Typed throws makes `error` an AnkiError here; pin it to the read failure.
            guard case .unreadableArchive = error else {
                Issue.record("expected .unreadableArchive, got \(error)")
                return
            }
        }
    }

    // MARK: Export stays medialess (out of scope guard)

    @Test("Export writes an empty media manifest and no media bodies")
    func exportWritesEmptyMediaManifestNoBodies() throws {
        let draft = AnkiDeckDraft(
            deckName: "Example::Media",
            noteType: AnkiNoteTypeDraft(
                name: "Basic", fieldNames: ["Front", "Back"],
                templates: [AnkiCardTemplate(name: "Card 1", question: "{{Front}}", answer: "{{Back}}")]),
            notes: [AnkiNoteDraft(fields: ["先生", "teacher"])])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        try AnkiPackageWriter().write(draft, to: url, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive["media"])
        var manifest = Data()
        _ = try archive.extract(entry) { manifest.append($0) }
        // Exactly the empty JSON object, and no numbered body entries alongside it.
        #expect(manifest == Data("{}".utf8))
        let names = archive.map(\.path)
        #expect(!names.contains { Int($0) != nil })
        #expect(Set(names) == ["collection.anki2", "media"])
    }
}
