import Foundation
import Testing
import ZIPFoundation
import libzstd
@testable import KBAnkiKit

/// Current Anki compresses the collection with zstd, so this is the format most
/// downloaded decks actually arrive in. Fixtures are compressed here rather than
/// checked in, so the test exercises the real codec and stays regenerable.
@Suite("Reading a zstd-compressed collection")
struct ZstdCollectionTests {
    private func compress(_ data: Data) throws -> Data {
        let bound = ZSTD_compressBound(data.count)
        var output = Data(count: bound)
        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                ZSTD_compress(destination.baseAddress, bound, source.baseAddress, data.count, 3)
            }
        }
        #expect(ZSTD_isError(written) == 0)
        return output.prefix(written)
    }

    /// A minimal schema 18 collection: enough tables for the reader to find a note.
    private func makeCollection() throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki21")
        let database = try SQLiteDatabase(path: path.path, access: .createOrOpen)
        try database.execute("CREATE TABLE notetypes (id integer primary key, name text not null)")
        try database.execute(
            "CREATE TABLE fields (ntid integer not null, ord integer not null, name text not null)")
        try database.execute("""
            CREATE TABLE notes (
                id integer primary key, guid text not null, mid integer not null,
                tags text not null, flds text not null
            )
            """)
        try database.execute("INSERT INTO notetypes VALUES (7, 'Kaishi')")
        try database.execute(
            "INSERT INTO fields VALUES (7, 0, 'Word'), (7, 1, 'Reading'), (7, 2, 'Meaning')")
        try database.execute("""
            INSERT INTO notes VALUES
                (1, 'g1', 7, ' core ', '先生\(AnkiFields.separator)せんせい\(AnkiFields.separator)teacher')
            """)
        return try Data(contentsOf: path)
    }

    private func makePackage(_ entries: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(data.count),
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    @Test("A zstd collection reads like any other")
    func zstdCollectionIsRead() throws {
        let url = try makePackage([
            "collection.anki21b": try compress(try makeCollection()),
            "media": Data("{}".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let collection = try AnkiPackageReader().read(contentsOf: url)
        let noteType = try #require(collection.noteTypes.first)
        let note = try #require(collection.notes.first)
        #expect(note.value(of: "Word", in: noteType) == "先生")
        #expect(note.value(of: "Meaning", in: noteType) == "teacher")
        #expect(note.tags == ["core"])
    }

    @Test("A package holding both the compressed and legacy collection prefers the compressed one")
    func compressedCollectionWins() throws {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).anki2")
        let legacy = try SQLiteDatabase(path: legacyPath.path, access: .createOrOpen)
        try legacy.execute("CREATE TABLE col (models text not null, decks text not null)")
        try legacy.execute("INSERT INTO col VALUES ('{}', '{}')")
        try legacy.execute("""
            CREATE TABLE notes (
                id integer primary key, guid text not null, mid integer not null,
                tags text not null, flds text not null
            )
            """)
        try legacy.execute("INSERT INTO notes VALUES (1, 'g0', 7, '', 'from the legacy copy')")

        let url = try makePackage([
            "collection.anki2": try Data(contentsOf: legacyPath),
            "collection.anki21b": try compress(try makeCollection()),
            "media": Data("{}".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        // Anki writes both for cross-version compatibility; the newest is complete.
        #expect(try AnkiPackageReader().read(contentsOf: url).notes.first?.fields.first == "先生")
    }

    @Test("A corrupt compressed collection fails as an unreadable archive, not silently")
    func corruptZstdIsReported() throws {
        let url = try makePackage([
            "collection.anki21b": Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02, 0x03]),
            "media": Data("{}".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: AnkiError.self) { try AnkiPackageReader().read(contentsOf: url) }
    }

    @Test("A frame cut short is reported, not returned as a partial body")
    func truncatedFrameIsReported() throws {
        let body = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let whole = try compress(body)
        // Half a frame: the decoder consumes every byte it is given and still expects
        // more. Returning what decoded so far would hand back a truncated SQLite file,
        // which fails much later as "no such table" rather than as a cut-short deck.
        let half = whole.prefix(whole.count / 2)
        #expect(throws: AnkiError.unreadableArchive("zstd: the compressed collection is truncated")) {
            _ = try ZstdDecompressor.decompress(Data(half))
        }
    }

    @Test("A whole frame is not mistaken for a truncated one")
    func completeFrameIsAccepted() throws {
        // Guards the fix from over-correcting: the completion check must pass for every
        // intact frame, including one small enough to decode in a single chunk.
        let small = Data("先生".utf8)
        #expect(try ZstdDecompressor.decompress(try compress(small)) == small)
    }

    @Test("Round-tripping a large body through the decompressor preserves every byte")
    func largePayloadSurvives() throws {
        // Streaming decompression grows its own output; a body larger than one output
        // chunk is what proves the loop appends rather than overwrites.
        let body = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        let restored = try ZstdDecompressor.decompress(try compress(body))
        #expect(restored == body)
    }
}
