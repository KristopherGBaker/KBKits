public import Foundation
import ZIPFoundation

/// A package's media, read on demand.
///
/// An `.apkg` stores media as numbered zip entries ("0", "1", ...) plus a `media`
/// manifest mapping each number to the name a note refers to. This holds the manifest
/// and a handle back to the package, NOT any media body: ``data(named:)`` pulls one
/// entry's bytes when asked, so listing a deck's media never extracts it.
public struct AnkiMedia: Sendable {
    /// Every referenced media name, in manifest order.
    public let names: [String]

    /// Name to the numbered zip entry that holds it.
    private let indexByName: [String: Int]
    /// The package the entries live in. Reopened per fetch rather than kept open, so
    /// an `AnkiMedia` stays a plain value.
    private let packageURL: URL

    init(packageURL: URL, entries: [AnkiMediaEntry]) {
        self.packageURL = packageURL
        self.names = entries.map(\.name)
        self.indexByName = Dictionary(entries.map { ($0.name, $0.index) }) { first, _ in first }
    }

    /// The bytes of the media file `name` refers to, or nil when the manifest lists no
    /// such name.
    ///
    /// The one numbered entry is extracted here, not at ``AnkiPackageReader/readMedia(contentsOf:)``
    /// time, so a corrupt or missing sibling entry never spoils a good one. A body that
    /// begins with the zstd magic (`28 B5 2F FD`) is decompressed; anything else is
    /// returned as stored. That is decided by the BYTES, not by which manifest shape
    /// the package used, because current Anki compresses some media bodies whichever
    /// manifest it wrote.
    public func data(named name: String) throws(AnkiError) -> Data? {
        guard let index = indexByName[name] else { return nil }
        return try Self.body(at: index, name: name, in: try Self.open(packageURL))
    }

    /// Visit the bodies of `names` one at a time, sharing a single opened package.
    ///
    /// Use this for anything that touches more than one file. ``data(named:)`` opens the
    /// package per call, and ZIPFoundation resolves an entry by scanning its central
    /// directory, so a loop over a real deck's media is quadratic: sizing Kaishi 1.5k's
    /// 4354 files that way costs 46 seconds, of which 45 is lookup and none is the audio.
    /// Indexing the directory once first brings the same work to 0.14 seconds.
    ///
    /// One body is live at a time. `handle` receives it and it is released before the
    /// next is fetched, so 110 MB of audio never has to be resident at once.
    ///
    /// A name absent from the manifest throws rather than being skipped: a caller
    /// copying a deck's media would otherwise report success over a card whose audio
    /// silently never arrived.
    public func forEachBody(
        named names: [String],
        _ handle: (String, Data) throws -> Void
    ) throws {
        guard !names.isEmpty else { return }
        let archive = try Self.open(packageURL)
        var entries = [String: Entry]()
        for entry in archive { entries[entry.path] = entry }

        for name in names {
            guard let index = indexByName[name] else {
                throw AnkiError.unreadableArchive("no media named \(name) in this package")
            }
            guard let entry = entries[String(index)] else {
                throw AnkiError.unreadableArchive("media entry \(index) (\(name)) is missing from the package")
            }
            try handle(name, try Self.body(of: entry, name: name, index: index, in: archive))
        }
    }

    /// The total size of `names` as they will land on disk, decompressed.
    ///
    /// Derived from the actual bodies, never from the manifest's recorded sizes: those
    /// are whatever wrote the package claimed, and a package that understates them would
    /// have a caller consent to a download far larger than the figure it was shown.
    public func byteCount(of names: [String]) throws -> Int {
        var total = 0
        try forEachBody(named: names) { _, body in total += body.count }
        return total
    }

    private static func open(_ url: URL) throws(AnkiError) -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }
    }

    private static func body(at index: Int, name: String, in archive: Archive) throws(AnkiError) -> Data {
        guard let entry = archive[String(index)] else {
            throw AnkiError.unreadableArchive("media entry \(index) (\(name)) is missing from the package")
        }
        return try body(of: entry, name: name, index: index, in: archive)
    }

    private static func body(
        of entry: Entry, name: String, index: Int, in archive: Archive
    ) throws(AnkiError) -> Data {
        var raw = Data()
        do {
            _ = try archive.extract(entry) { raw.append($0) }
        } catch {
            throw AnkiError.unreadableArchive(error.localizedDescription)
        }
        if raw.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            return try ZstdDecompressor.decompress(raw)
        }
        return raw
    }
}

/// One parsed manifest entry: the name a note refers to, its numbered zip position,
/// and the size and SHA-1 the binary manifest records (both absent, and left at their
/// defaults, in the legacy JSON manifest).
struct AnkiMediaEntry: Sendable, Equatable {
    let index: Int
    let name: String
    let size: UInt32
    let sha1: [UInt8]
}

/// Parses the `media` manifest in either shape Anki has shipped.
///
/// The legacy manifest is a JSON object mapping a string index to a name
/// (`{"0":"sensei.mp3"}`). The current one is a protobuf-wire message: a repeated
/// `MediaEntry { string name = 1; uint32 size = 2; bytes sha1 = 3; }` under field 1,
/// where list order is the numbered zip index. This reads the wire form by hand,
/// skipping unknown fields, rather than pulling in a protobuf runtime.
enum AnkiMediaManifest {
    static func parse(_ rawData: Data) throws(AnkiError) -> [AnkiMediaEntry] {
        // The manifest ITSELF is compressed in a current package, not just the media
        // bodies it names. Dispatching on the first byte without this reads a zstd
        // frame as protobuf and yields nonsense for every real deck; a hand-built
        // fixture never shows it, because nobody writes a fixture pre-compressed.
        let data = rawData.starts(with: [0x28, 0xB5, 0x2F, 0xFD])
            ? try ZstdDecompressor.decompress(rawData)
            : rawData
        guard let first = data.first(where: { !Self.isJSONWhitespace($0) }) else {
            // An empty manifest carries no media. Anki writes `{}` for a medialess deck.
            return []
        }
        if first == UInt8(ascii: "{") {
            return try parseJSON(data)
        }
        return try parseBinary(data)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: Legacy JSON

    private static func parseJSON(_ data: Data) throws(AnkiError) -> [AnkiMediaEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else {
            throw AnkiError.unreadableArchive("the media manifest is not a readable JSON object")
        }
        return object.compactMap { key, value in
            guard let index = Int(key), let name = value as? String else { return nil }
            return AnkiMediaEntry(index: index, name: name, size: 0, sha1: [])
        }
        .sorted { $0.index < $1.index }
    }

    // MARK: Binary protobuf wire

    private static func parseBinary(_ data: Data) throws(AnkiError) -> [AnkiMediaEntry] {
        var reader = WireReader(bytes: Array(data))
        var entries: [AnkiMediaEntry] = []
        while !reader.isAtEnd {
            let tag = try reader.readTag()
            // Field 1, length-delimited, is one MediaEntry. Its position in the stream
            // is its numbered zip index. Anything else (an unknown field between two
            // entries, a future addition) is skipped by wire type without disturbing
            // the entry that follows.
            if tag.field == 1, tag.wire == .lengthDelimited {
                let body = try reader.readLengthDelimited()
                entries.append(try parseEntry(body, index: entries.count))
            } else {
                try reader.skip(tag.wire)
            }
        }
        return entries
    }

    private static func parseEntry(_ bytes: [UInt8], index: Int) throws(AnkiError) -> AnkiMediaEntry {
        var reader = WireReader(bytes: bytes)
        var name = ""
        var size: UInt32 = 0
        var sha1: [UInt8] = []
        while !reader.isAtEnd {
            let tag = try reader.readTag()
            switch (tag.field, tag.wire) {
            case (1, .lengthDelimited):
                let raw = try reader.readLengthDelimited()
                // A media name that is not valid UTF-8 is a corrupt manifest, not a
                // name to guess at: refuse it rather than substitute replacement bytes.
                guard let decoded = String(bytes: raw, encoding: .utf8) else {
                    throw AnkiError.unreadableArchive("a media manifest name is not valid UTF-8")
                }
                name = decoded
            case (2, .varint):
                size = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (3, .lengthDelimited):
                sha1 = try reader.readLengthDelimited()
            default:
                try reader.skip(tag.wire)
            }
        }
        return AnkiMediaEntry(index: index, name: name, size: size, sha1: sha1)
    }
}

/// The sliver of protobuf wire decoding this manifest needs: varints, length-delimited
/// fields, and skipping the wire types a field it does not recognise can carry. Hand
/// written on purpose so nothing here depends on a protobuf runtime.
private struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    /// The four wire types this format uses, plus the ones a skip has to step over.
    enum WireType: Equatable {
        case varint
        case fixed64
        case lengthDelimited
        case fixed32
        case unsupported(Int)

        init(_ raw: Int) {
            switch raw {
            case 0: self = .varint
            case 1: self = .fixed64
            case 2: self = .lengthDelimited
            case 5: self = .fixed32
            default: self = .unsupported(raw)
            }
        }
    }

    mutating func readVarint() throws(AnkiError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else {
                throw AnkiError.unreadableArchive("the media manifest ended inside a varint")
            }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else {
                throw AnkiError.unreadableArchive("a media manifest varint is too long")
            }
        }
        return result
    }

    mutating func readTag() throws(AnkiError) -> (field: Int, wire: WireType) {
        let raw = try readVarint()
        return (Int(raw >> 3), WireType(Int(raw & 0x07)))
    }

    mutating func readLengthDelimited() throws(AnkiError) -> [UInt8] {
        let length = Int(try readVarint())
        guard length >= 0, offset + length <= bytes.count else {
            throw AnkiError.unreadableArchive("a media manifest length field runs past the end")
        }
        let slice = Array(bytes[offset..<offset + length])
        offset += length
        return slice
    }

    mutating func skip(_ wire: WireType) throws(AnkiError) {
        switch wire {
        case .varint:
            _ = try readVarint()
        case .lengthDelimited:
            _ = try readLengthDelimited()
        case .fixed64:
            try advance(by: 8)
        case .fixed32:
            try advance(by: 4)
        case .unsupported(let raw):
            throw AnkiError.unreadableArchive("unsupported media manifest wire type \(raw)")
        }
    }

    private mutating func advance(by count: Int) throws(AnkiError) {
        guard offset + count <= bytes.count else {
            throw AnkiError.unreadableArchive("a media manifest fixed field runs past the end")
        }
        offset += count
    }
}
